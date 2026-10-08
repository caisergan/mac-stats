import AppKit
import Darwin
import MacPerfMonitorCore
import SwiftUI

/// An app the user asked to force quit, with its processes as they were
/// when they asked. The member list is topped up with any process that has
/// joined the app since (looked up by `groupID`) when the kill runs.
struct AppForceQuitTarget: Identifiable {
    let id = UUID()
    /// `AppProcessGroup.id`: the `.app` path, or `pid:<n>`.
    let groupID: String
    let name: String
    let members: [ProcessSample]

    init(group: AppProcessGroup) {
        groupID = group.id
        name = group.name
        members = group.processes
    }
}

extension ProcessRowIntent {
    /// Ask to force quit a whole app. From the menu bar the main window is
    /// surfaced first, since it hosts the confirmation. The target is set at
    /// once: the confirmation presents itself when the window's content is on
    /// screen, however long the window takes to open.
    static func requestAppKill(
        _ target: AppForceQuitTarget, appState: AppState, bringWindowForward: Bool
    ) {
        appState.pendingAppForceQuit = target
        guard bringWindowForward else { return }
        NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Hosts the force-quit-app confirmation on the main window, next to the
/// single-process one, and runs the kill.
///
/// The kill, in order:
/// 1. Re-read the app's members, adding any process that joined it since the
///    menu was built.
/// 2. Send `SIGKILL` to each, parents first so the app cannot relaunch the
///    helpers it is losing. Each pid is checked against its start time just
///    before its signal, so a pid macOS has handed to another process since
///    is never hit.
/// 3. Retry any refusal (a system or other-user process) through the root
///    helper when Full Coverage is on.
/// 4. Watch until every member has really exited (a zombie counts as
///    exited), signalling again any that linger, for up to `verifyTimeout`.
/// 5. Grey out the stopped rows, and explain whatever survived.
struct AppForceQuitConfirmation: ViewModifier {
    @Binding var target: AppForceQuitTarget?
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var helper: HelperManager
    @State private var failureMessage: String?
    /// Whether the confirmation is up. Separate from `target` so a request
    /// made before the window opened is presented once this view is on screen
    /// (the main window mounts its content only while visible).
    @State private var presented = false

    /// How long to wait for every member to exit before reporting survivors.
    static let verifyTimeout: TimeInterval = 3
    static let verifyInterval: TimeInterval = 0.2

    private var showingFailure: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title, isPresented: $presented, titleVisibility: .visible, presenting: target
            ) { target in
                Button("Force Quit", role: .destructive) { perform(target) }
                Button("Cancel", role: .cancel) { self.target = nil }
            } message: { _ in
                Text(
                    t(
                        "This sends SIGKILL (kill -9) to every process in the app. They stop "
                            + "at once without saving, so any unsaved work is lost."))
            }
            .alert("Couldn\u{2019}t force quit everything", isPresented: showingFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
            .onAppear(perform: presentIfPending)
            .onChange(of: target?.id) { _, _ in presentIfPending() }
            .onChange(of: presented) { _, shown in
                // Dismissed without a choice (Escape, or a click outside).
                if !shown { target = nil }
            }
    }

    /// Raise the confirmation for a pending target, one beat after this view
    /// is on screen so a window that is still ordering in has settled.
    private func presentIfPending() {
        guard target != nil, !presented else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if target != nil { presented = true }
        }
    }

    private var title: String {
        guard let target else { return "" }
        return target.members.count == 1
            ? t("Force quit %@?", target.name)
            : t(
                "Force quit %1$@ and its %2$@ processes?", target.name, String(target.members.count)
            )
    }

    private func perform(_ target: AppForceQuitTarget) {
        self.target = nil
        let fresh =
            AppGrouping.group(model.latest?.processes ?? [])
            .first { $0.id == target.groupID }?.processes ?? []
        let members = AppForceQuit.order(target.members + fresh, selfPID: getpid())
        guard !members.isEmpty else { return }
        let reader = ProcessReader()

        // Next runloop tick, so the confirmation has fully dismissed before a
        // failure alert may be presented (see `ForceQuitConfirmation`).
        DispatchQueue.main.async {
            let tally = AppForceQuit.signalAll(
                members, isRunning: reader.isRunning, send: Self.sendKill)
            self.escalate(tally.notPermitted, members: members, reader: reader) { refused in
                self.verify(
                    target: target, members: members, refused: refused,
                    failed: tally.failed.map(\.identity), reader: reader,
                    deadline: Date().addingTimeInterval(Self.verifyTimeout))
            }
        }
    }

    private static func sendKill(_ pid: Int32) -> AppForceQuit.SignalOutcome {
        switch ProcessActions.forceQuit(pid: pid) {
        case .success: return .sent
        case .alreadyGone: return .gone
        case .notPermitted: return .notPermitted
        case .failed(let code): return .failed(code)
        }
    }

    /// Retry each refused member through the root helper, one at a time,
    /// re-checking it is the same process just before. Hands back the members
    /// the helper could not stop either (all of them when it is off).
    private func escalate(
        _ refused: [ProcessIdentity], members: [ProcessSample], reader: ProcessReader,
        completion: @escaping ([ProcessIdentity]) -> Void
    ) {
        guard helper.canEscalate, !refused.isEmpty else {
            completion(refused)
            return
        }
        var remaining = refused[...]
        var stillRefused: [ProcessIdentity] = []
        func next() {
            guard let identity = remaining.popFirst() else {
                completion(stillRefused)
                return
            }
            guard reader.isRunning(identity) else { return next() }
            helper.forceQuit(pid: identity.pid) { outcome in
                if outcome == .notPermitted { stillRefused.append(identity) }
                next()
            }
        }
        next()
    }

    /// Poll until every member we could signal has exited, signalling again
    /// any still running, then record the result.
    private func verify(
        target: AppForceQuitTarget, members: [ProcessSample], refused: [ProcessIdentity],
        failed: [ProcessIdentity], reader: ProcessReader, deadline: Date
    ) {
        let unreachable = Set(refused + failed)
        let lingering = members.filter { !unreachable.contains($0.id) && reader.isRunning($0.id) }
        if !lingering.isEmpty, Date() < deadline {
            for member in lingering { _ = ProcessActions.forceQuit(pid: member.pid) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyInterval) {
                self.verify(
                    target: target, members: members, refused: refused, failed: failed,
                    reader: reader, deadline: deadline)
            }
            return
        }

        let stopped = members.filter { !reader.isRunning($0.id) }
        model.markTerminated(stopped)
        AppLog.ui.notice(
            "force-quit app \(target.name, privacy: .public): \(stopped.count, privacy: .public) of \(members.count, privacy: .public) stopped"
        )
        let survivors = members.count - stopped.count
        guard survivors > 0 else { return }
        let lead = t(
            "%1$@ of %2$@ processes in \u{201C}%3$@\u{201D} stopped.", String(stopped.count),
            String(members.count), target.name)
        let refusedAlive = refused.filter { reader.isRunning($0) }.count
        let reason: String
        if refusedAlive > 0, !helper.canEscalate {
            reason = t(
                "macOS would not let %1$@ stop %2$@ of them. They are likely system processes or "
                    + "owned by another user. Turn on Full Coverage in Settings to stop processes as root.",
                AppInfo.displayName, String(refusedAlive))
        } else {
            reason = t(
                "%@ did not exit. Some processes are protected by macOS, or are stuck waiting "
                    + "on the system and exit only when that finishes.", String(survivors))
        }
        failureMessage = lead + " " + reason
    }
}

extension View {
    /// Host the app's force-quit-app confirmation, driven by `target`.
    func appForceQuitConfirmation(target: Binding<AppForceQuitTarget?>) -> some View {
        modifier(AppForceQuitConfirmation(target: target))
    }
}
