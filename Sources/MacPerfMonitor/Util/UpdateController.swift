import AppKit
import Combine
import MacPerfMonitorCore
import Sparkle
import os

/// Owns the Sparkle updater for the directly-distributed (non-App-Store) build.
///
/// Update policy (PRD): check on every cold start, on wake from sleep, and — for
/// a long-running menubar app that may stay up for days — on a 24-hour schedule.
/// The schedule is declared in Info.plist (`SUEnableAutomaticChecks` +
/// `SUScheduledCheckInterval` = 86400); the cold-start and wake checks are driven
/// explicitly from `AppDelegate` via `checkInBackground()`.
///
/// `checkInBackground()` is silent unless an update is actually available, so
/// firing it on launch and on every wake never nags the user — it only surfaces
/// UI when there is something to install. The menu's "Check for Updates…" calls
/// `checkForUpdates()`, which always shows feedback (including "you're up to
/// date") because the user asked.
///
/// Everything here is main-thread bound: it is created by the app delegate on
/// the main thread (Sparkle's user driver presents AppKit UI), and every caller
/// — the delegate's launch/wake hooks and the SwiftUI menu — is already on main.
///
/// It is also Sparkle's `SPUUpdaterDelegate`, used for one thing: to stop the
/// privileged root helper just before an update installs. Sparkle only knows
/// about the app bundle, not our LaunchDaemon, so without this the old root
/// helper would keep running its old binary across the swap (mirrors the pkg
/// installer's preinstall).
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Whether a manual check can be started right now (false briefly while a
    /// check is already running). Bound by the "Check for Updates…" menu item so
    /// it disables itself rather than starting overlapping checks.
    @Published var canCheckForUpdates = false

    /// Invoked on the main thread immediately before an update installs, so the
    /// app can stop the privileged helper before the bundle is replaced. Wired up
    /// by the app delegate to `HelperManager.stopForUpdate()`.
    var onWillInstallUpdate: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    /// Unified-log channel for update diagnostics. Sparkle collapses every
    /// failure — appcast unreachable, TLS rejected, DNS blocked, HTML returned
    /// instead of XML — into one generic "An error occurred in retrieving update
    /// information. Please try again later." alert, with the real cause dropped.
    /// Logging the underlying NSError here is the only way a field report can
    /// tell us *why* a user's check failed. Pull it from an affected machine:
    ///   log show --last 30m --info --predicate \
    ///     'subsystem == "uk.co.bzwrd.macperfmonitor" && category == "update"'
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "uk.co.bzwrd.macperfmonitor",
        category: "update")

    /// `startingUpdater` is false only where no update check should run, such as
    /// a test rendering a surface that reads this object.
    init(startingUpdater: Bool = true) {
        super.init()
        // startingUpdater: true starts the updater immediately, which begins the
        // scheduled background checks declared in Info.plist. Self as updater
        // delegate so we get the pre-install hook; the standard user driver gives
        // the usual macOS update experience.
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: self, userDriverDelegate: nil)

        // Mirror Sparkle's own readiness into a published property so SwiftUI menu
        // items can enable/disable correctly (KVO-observable on the updater).
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// A user-initiated check: always shows UI, including an up-to-date result.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// A silent background check: surfaces UI only when an update is available.
    /// Used for the cold-start and wake-from-sleep checks so they never nag.
    func checkInBackground() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle is about to install an update and replace the app bundle. Stop the
    /// privileged helper first (Sparkle doesn't know about it) so the new binary
    /// replaces a stopped one and is demand-launched fresh.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        onWillInstallUpdate?()
    }

    // MARK: - SPUUpdaterDelegate: error surfacing

    /// Catch-all for any aborted update cycle — this is what fires when the
    /// appcast can't be retrieved or parsed (the "retrieving update information"
    /// alert). Logs the full NSError chain so the real cause is recoverable.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("Update aborted: \(Self.describe(error), privacy: .public)")
    }

    /// The enclosure (full archive or binary delta) failed to download — a
    /// distinct phase from appcast retrieval, captured for the same reason.
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        log.error(
            "Failed to download update \(item.displayVersionString, privacy: .public) (build \(item.versionString, privacy: .public)): \(Self.describe(error), privacy: .public)"
        )
    }

    /// End of every update cycle. A non-nil `error` is the same failure as
    /// `didAbortWithError`; nil means the check completed cleanly (offered an
    /// update or confirmed up to date). Logging both ends confirms from a
    /// tester's log that the check actually ran and how it resolved.
    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        if let error {
            log.error(
                "Update check (kind \(updateCheck.rawValue)) finished with error: \(Self.describe(error), privacy: .public)"
            )
        } else {
            log.info("Update check (kind \(updateCheck.rawValue)) finished OK")
        }
    }

    /// Flatten an NSError and its underlying-error chain into one log line:
    /// `[domain code] description` per level, plus the failing URL when present.
    /// This is what turns "please try again" into an actionable cause — e.g.
    /// NSURLErrorDomain -1200 (TLS/cert), -1003 (host not found / DNS),
    /// -1009 (offline), -1001 (timeout), or a parse error from a proxy/portal
    /// returning HTML in place of the appcast XML.
    private static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 5 {
            var line = "[\(e.domain) \(e.code)] \(e.localizedDescription)"
            if let url = e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                line += " url=\(url)"
            }
            parts.append(line)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ← ")
    }
}
