import Foundation
import os.log

/// Per-connection network history from `/usr/bin/nettop`'s per-socket mode.
/// Where `NetworkProcessReader` aggregates per process (`-P`), this reader
/// parses the per-connection rows: one line per TCP socket carrying its
/// cumulative `bytes_in`/`bytes_out` and its remote endpoint, grouped under a
/// parent process line. That is the only unprivileged per-remote accounting
/// macOS exposes; a NetworkExtension system extension is deliberately out of
/// scope for this feature.
///
/// Runs `nettop -m tcp -x -J bytes_in,bytes_out -L 1` one-shot on its own
/// background queue at a slow fixed cadence (default 30 s: connection history
/// is a retrospective view, not a live meter), differences consecutive
/// cumulative snapshots per (pid, remote endpoint) into byte deltas, and hands
/// them to `onDeltas` on its own queue. A connection that closes between two
/// runs loses its final sub-cadence bytes; counters that reset (a flow
/// closing, a reused endpoint) clamp to zero like every other delta here.
///
/// UDP is intentionally not collected: an unconnected UDP socket has no remote
/// endpoint to attribute traffic to, so its bytes already appear in the
/// system-wide and per-app totals.
public final class ConnectionHistoryReader {
    /// One connection's transferred bytes over one reader cycle.
    public struct Delta: Sendable, Equatable {
        public var pid: Int32
        public var remoteIP: String
        public var remotePort: Int
        public var inBytes: UInt64
        public var outBytes: UInt64
        public var timestamp: Date

        public init(
            pid: Int32, remoteIP: String, remotePort: Int,
            inBytes: UInt64, outBytes: UInt64, timestamp: Date
        ) {
            self.pid = pid
            self.remoteIP = remoteIP
            self.remotePort = remotePort
            self.inBytes = inBytes
            self.outBytes = outBytes
            self.timestamp = timestamp
        }
    }

    /// A parsed snapshot row: which process, which remote endpoint, and the
    /// cumulative counters at that instant.
    struct Snapshot: Equatable {
        var pid: Int32
        var remoteIP: String
        var remotePort: Int
        var inBytes: UInt64
        var outBytes: UInt64
    }

    private static let log = Logger(
        subsystem: "uk.co.bzwrd.macperfmonitor", category: "nettop-conn")
    private static let toolPath = "/usr/bin/nettop"

    private let lock = NSLock()
    private var wantRunning = false
    private var prevSnapshots: [Snapshot] = []
    private let cadence: TimeInterval
    /// Called on the reader's background queue with the deltas of one cycle.
    /// Install before `start()`; never invoked concurrently.
    private let onDeltas: @Sendable ([Delta]) -> Void

    private let refreshQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.nettop-conn", qos: .utility)

    public init(
        cadence: TimeInterval = 30, onDeltas: @escaping @Sendable ([Delta]) -> Void
    ) {
        self.cadence = max(cadence, 5)
        self.onDeltas = onDeltas
    }

    /// Start the background collection loop. Idempotent.
    public func start() {
        lock.lock()
        let already = wantRunning
        wantRunning = true
        lock.unlock()
        guard !already else { return }
        refreshQueue.async { [weak self] in self?.refreshLoop() }
    }

    /// Stop the loop and drop the counter state, so re-enabling starts with a
    /// clean baseline instead of one giant delta across the off period.
    public func stop() {
        lock.lock()
        wantRunning = false
        prevSnapshots = []
        lock.unlock()
    }

    // MARK: - Background refresh

    private func refreshLoop() {
        while true {
            lock.lock()
            let want = wantRunning
            lock.unlock()
            guard want else { return }

            let at = Date()
            guard let output = Self.runOneShot() else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            let snapshots = Self.parse(output: output)
            let deltas = Self.diff(current: snapshots, previous: prevSnapshots, at: at)

            lock.lock()
            prevSnapshots = snapshots
            lock.unlock()

            if !deltas.isEmpty {
                onDeltas(deltas)
            }
            let elapsed = Date().timeIntervalSince(at)
            Thread.sleep(forTimeInterval: max(cadence - elapsed, cadence / 2))
        }
    }

    /// Difference the cumulative per-connection counters. Rows are summed per
    /// (pid, remote) key first, because parallel connections to the same
    /// remote endpoint are legal and must not steal each other's baseline.
    /// Keys that vanished are dropped (their sub-cycle tail is lost, the price
    /// of snapshot differencing); counter decreases clamp to zero.
    static func diff(
        current: [Snapshot], previous: [Snapshot], at: Date
    ) -> [Delta] {
        let previousTotals = totals(previous)
        func totals(_ rows: [Snapshot]) -> [String: (inBytes: UInt64, outBytes: UInt64)] {
            var result: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
            for row in rows {
                let existing = result[key(row)] ?? (0, 0)
                result[key(row)] = (
                    existing.inBytes + row.inBytes, existing.outBytes + row.outBytes
                )
            }
            return result
        }
        // One representative row per key for identity, and the summed counters.
        var representative: [String: Snapshot] = [:]
        var currentTotals: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
        for row in current {
            if representative[key(row)] == nil { representative[key(row)] = row }
            let existing = currentTotals[key(row)] ?? (0, 0)
            currentTotals[key(row)] = (
                existing.inBytes + row.inBytes, existing.outBytes + row.outBytes
            )
        }
        var deltas: [Delta] = []
        deltas.reserveCapacity(currentTotals.count)
        for (rowKey, current) in currentTotals {
            guard let row = representative[rowKey], let prev = previousTotals[rowKey] else {
                continue
            }
            let inDelta = CPUMath.delta(current.inBytes, prev.inBytes)
            let outDelta = CPUMath.delta(current.outBytes, prev.outBytes)
            guard inDelta > 0 || outDelta > 0 else { continue }
            deltas.append(
                Delta(
                    pid: row.pid, remoteIP: row.remoteIP,
                    remotePort: row.remotePort,
                    inBytes: inDelta, outBytes: outDelta, timestamp: at))
        }
        return deltas
    }

    private static func key(_ snapshot: Snapshot) -> String {
        "\(snapshot.pid)/\(snapshot.remoteIP):\(snapshot.remotePort)"
    }

    // MARK: - Subprocess

    /// One `nettop -m tcp -L 1` to a pipe with a hard timeout, mirroring
    /// `NetworkProcessReader.runOneShot`. The 90 s ceiling clears nettop's
    /// measured ~30 s worst-case run on slow machines (see there).
    private static func runOneShot(timeout: TimeInterval = 90) -> String? {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            log.error("nettop not found at \(toolPath, privacy: .public)")
            return nil
        }
        return autoreleasepool {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: toolPath)
            // -m tcp per-connection rows · -x raw bytes · -J only the byte
            // columns (which also drops the interface/state columns, keeping
            // every row to time,label,in,out) · -s 1 the sampling delay, which
            // cuts a one-shot run from nettop's ~30 s default to ~5 s · -L 1 one
            // sample then exit.
            task.arguments = ["-m", "tcp", "-x", "-J", "bytes_in,bytes_out", "-s", "1", "-L", "1"]
            let outPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = FileHandle.nullDevice
            task.standardInput = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                log.error("nettop launch failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            let handle = outPipe.fileHandleForReading
            let done = DispatchSemaphore(value: 0)
            let box = ConnDataBox()
            DispatchQueue.global(qos: .utility).async {
                box.data = handle.readDataToEndOfFile()
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                log.error("nettop timed out after \(timeout, privacy: .public)s; terminating")
                task.terminate()
            }
            task.waitUntilExit()
            return String(decoding: box.data, as: UTF8.self)
        }
    }

    // MARK: - Parsing

    /// Test hook: a full one-shot output block into snapshot rows.
    static func parse(output: String) -> [Snapshot] {
        var result: [Snapshot] = []
        var currentPID: Int32?
        output.enumerateLines { line, _ in
            if let snapshot = parseConnection(line: line) {
                result.append(
                    Snapshot(
                        pid: currentPID ?? snapshot.pid, remoteIP: snapshot.remoteIP,
                        remotePort: snapshot.remotePort, inBytes: snapshot.inBytes,
                        outBytes: snapshot.outBytes))
            } else if let pid = parseProcess(line: line) {
                currentPID = pid
            }
        }
        return result
    }

    /// Parse one connection row: `tcp4 laddr:lport<->raddr:rport` (or tcp6,
    /// whose port separator is a dot) followed by the two byte columns. Listen
    /// rows carry no counters and rows whose remote is unconnected (`*`) have
    /// nothing to attribute; both return nil.
    static func parseConnection(
        line: String
    ) -> (pid: Int32, remoteIP: String, remotePort: Int, inBytes: UInt64, outBytes: UInt64)? {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = cleaned.split(separator: ",", omittingEmptySubsequences: false).map(
            String.init
        ).map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = fields.last, last.isEmpty { fields.removeLast() }
        guard fields.count >= 4 else { return nil }
        let endpoint = fields[fields.count - 3]
        guard
            let inBytes = UInt64(fields[fields.count - 2]),
            let outBytes = UInt64(fields[fields.count - 1]),
            let arrow = endpoint.range(of: "<->")
        else { return nil }
        let remotePart = String(endpoint[arrow.upperBound...])
        let isV6 = endpoint.hasPrefix("tcp6")
        let separator: Character = isV6 ? "." : ":"
        guard let portIndex = remotePart.lastIndex(of: separator) else { return nil }
        let ip = String(remotePart[..<portIndex])
        guard let port = Int(remotePart[remotePart.index(after: portIndex)...]), ip != "*",
            ip != "::1", !ip.hasPrefix("127.")
        else { return nil }
        // pid is resolved by the caller from the enclosing process row; the
        // bare value here only satisfies the tuple shape.
        return (0, ip, port, inBytes, outBytes)
    }

    /// Parse one process row: `name.pid` in the second-to-value position,
    /// same convention as `NetworkProcessReader.parse(line:)`.
    static func parseProcess(line: String) -> Int32? {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = cleaned.split(separator: ",", omittingEmptySubsequences: false).map(
            String.init
        ).map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = fields.last, last.isEmpty { fields.removeLast() }
        guard fields.count >= 4 else { return nil }
        let label = fields[fields.count - 3]
        guard !label.contains("<->"), let dot = label.lastIndex(of: "."),
            let pid = Int32(label[label.index(after: dot)...])
        else { return nil }
        return pid
    }
}

/// Reference box shared with `NetworkProcessReader`'s subprocess plumbing.
private final class ConnDataBox: @unchecked Sendable { var data = Data() }
