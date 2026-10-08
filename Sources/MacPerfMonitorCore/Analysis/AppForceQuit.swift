import Foundation

/// The pure half of force quitting a whole app: which of its processes to
/// signal, in what order, and what happened to each. The app supplies the
/// liveness check and the signal, so this is unit-tested without killing
/// anything.
public enum AppForceQuit {
    /// What sending `SIGKILL` to one pid did.
    public enum SignalOutcome: Equatable, Sendable {
        case sent
        /// macOS refused: a system process, or another user's.
        case notPermitted
        /// The pid no longer exists.
        case gone
        case failed(Int32)
    }

    /// The members grouped by what the first pass did to them.
    public struct Tally: Sendable {
        public var signalled: [ProcessIdentity] = []
        public var notPermitted: [ProcessIdentity] = []
        /// Already exited, or the pid now belongs to a different process.
        public var gone: [ProcessIdentity] = []
        public var failed: [(identity: ProcessIdentity, errno: Int32)] = []

        public init() {}
    }

    /// The members to signal, parents before children. Killing the app's main
    /// process first stops it relaunching helpers as they die (Chrome restarts
    /// a killed GPU or renderer process). `launchd`, the kernel, and the
    /// caller itself are never included, and duplicates are dropped.
    public static func order(_ members: [ProcessSample], selfPID: Int32) -> [ProcessSample] {
        var seen: Set<ProcessIdentity> = []
        let targets = members.filter {
            $0.pid > 1 && $0.pid != selfPID && seen.insert($0.id).inserted
        }
        let byPID = Dictionary(
            targets.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var depthByPID: [Int32: Int] = [:]
        func depth(_ sample: ProcessSample, _ guardCount: Int = 0) -> Int {
            if let known = depthByPID[sample.pid] { return known }
            guard guardCount < targets.count, sample.ppid != sample.pid,
                let parent = byPID[sample.ppid]
            else { return 0 }
            let value = depth(parent, guardCount + 1) + 1
            depthByPID[sample.pid] = value
            return value
        }
        return targets.enumerated()
            .map { (offset: $0.offset, depth: depth($0.element), sample: $0.element) }
            .sorted { ($0.depth, $0.offset) < ($1.depth, $1.offset) }
            .map(\.sample)
    }

    /// One pass over `ordered`: skip anything no longer running (checked just
    /// before its signal, so a reused pid is never hit), signal the rest, and
    /// sort each member by what happened.
    public static func signalAll(
        _ ordered: [ProcessSample],
        isRunning: (ProcessIdentity) -> Bool,
        send: (Int32) -> SignalOutcome
    ) -> Tally {
        var tally = Tally()
        for member in ordered {
            guard isRunning(member.id) else {
                tally.gone.append(member.id)
                continue
            }
            switch send(member.pid) {
            case .sent: tally.signalled.append(member.id)
            case .notPermitted: tally.notPermitted.append(member.id)
            case .gone: tally.gone.append(member.id)
            case .failed(let code): tally.failed.append((member.id, code))
            }
        }
        return tally
    }
}
