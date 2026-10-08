import Foundation

/// The processes that belong to one app, with their combined footprint: every
/// Google Chrome Helper under Google Chrome, every shell under the terminal it
/// runs in. The "by app" view of the process list and the menu bar lists.
public struct AppProcessGroup: Sendable, Identifiable, Equatable {
    /// Stable for the app's lifetime: the `.app` bundle path for an app, or
    /// `pid:<n>` for a group headed by a process outside any app bundle.
    public var id: String
    /// The app's name ("Google Chrome"), or the head process's display name.
    public var name: String
    /// A path that resolves to the group's icon: the `.app` bundle, or the
    /// head process's executable.
    public var iconPath: String?
    /// Members in the order they were given (callers sort as they need).
    public var processes: [ProcessSample]

    public init(id: String, name: String, iconPath: String?, processes: [ProcessSample]) {
        self.id = id
        self.name = name
        self.iconPath = iconPath
        self.processes = processes
    }

    public var physFootprint: UInt64 { processes.reduce(0) { $0 &+ $1.physFootprint } }
    public var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
}

/// Assigns each process to the app it belongs to. Pure, so it is unit-tested
/// and shared by the process table and the menu bar.
///
/// A process belongs to, in order of preference:
/// 1. the outermost `.app` bundle its own executable lives in (helpers nested
///    inside `Google Chrome.app` belong to Google Chrome);
/// 2. the app of the process macOS holds responsible for it (Safari's WebKit
///    XPC services, a shell in Terminal);
/// 3. the app of its nearest ancestor by parent PID that has one;
/// 4. otherwise, the group of its responsible process, or a group of its own.
public enum AppGrouping {
    /// `launchd`. It is every daemon's parent, so the ancestor walk stops here.
    static let launchdPID: Int32 = 1

    /// The outermost `.app` bundle enclosing `path`, or nil outside any bundle.
    public static func appBundlePath(forExecutable path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The app name for a bundle path: its file name without `.app`.
    public static func appName(forBundlePath path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    /// Group `processes` by app. Groups come back in first-seen order; members
    /// keep their input order.
    public static func group(_ processes: [ProcessSample]) -> [AppProcessGroup] {
        let byPID = Dictionary(
            processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var appByPID: [Int32: String?] = [:]

        /// The `.app` a process belongs to by its own path or its ancestry
        /// (rules 1 to 3), memoized so each chain is walked once.
        func app(for pid: Int32, depth: Int = 0) -> String? {
            if let known = appByPID[pid] { return known }
            guard let sample = byPID[pid], depth < 64 else { return nil }
            appByPID[pid] = .some(nil)  // guards against cycles
            var result = appBundlePath(forExecutable: sample.executablePath)
            if result == nil, let r = sample.responsiblePID, r != pid {
                result = app(for: r, depth: depth + 1)
            }
            if result == nil, sample.ppid != pid, sample.ppid > launchdPID {
                result = app(for: sample.ppid, depth: depth + 1)
            }
            appByPID[pid] = .some(result)
            return result
        }

        var order: [String] = []
        var groups: [String: AppProcessGroup] = [:]
        for sample in processes {
            let id: String
            let name: String
            let iconPath: String?
            if let bundle = app(for: sample.pid) {
                id = bundle
                name = appName(forBundlePath: bundle)
                iconPath = bundle
            } else {
                // Rule 4: join the responsible process when it is visible, so a
                // daemon's helpers still collapse under it.
                let head =
                    sample.responsiblePID.flatMap { byPID[$0] }
                    .flatMap { app(for: $0.pid) == nil ? $0 : nil } ?? sample
                id = "pid:\(head.pid)"
                name = head.displayName
                iconPath = head.executablePath
            }
            if groups[id] == nil {
                order.append(id)
                groups[id] = AppProcessGroup(
                    id: id, name: name, iconPath: iconPath, processes: [])
            }
            groups[id]?.processes.append(sample)
        }
        return order.compactMap { groups[$0] }
    }
}
