import Foundation
import os.log

/// Per-process network throughput from `/usr/bin/nettop`. macOS exposes no public,
/// unprivileged per-process byte counters the way it does for CPU/memory/disk, so
/// nettop is the only practical route.
///
/// Runs the one-shot `nettop -P -x -J bytes_in,bytes_out -L 1` on its **own
/// background queue — never on the sampler's hot path**. `nettop` can take several
/// seconds to produce a sample on some machines (≈20 ms on others); running it
/// synchronously inside the per-process scan dragged the entire sampler (menu bar
/// included) down to nettop's speed. Instead a background loop runs it, differences
/// consecutive cumulative snapshots into per-PID byte rates over the *actual*
/// elapsed interval, and caches them. The sampler reads the cache non-blocking via
/// `latestRates()`, so a slow nettop only makes the per-app network figures
/// refresh less often — it no longer throttles sampling.
///
/// `start()` launches the loop; `stop()` halts it. A hard timeout guards against
/// a wedged nettop. Pacing (`paceSleep`) runs at two speeds depending on whether
/// anything is displaying per-app rates; see `setInteractive`.
/// `CPUMath.delta` clamps the occasional counter decrease (a flow closing, or a
/// counter reset) to zero.
public final class NetworkProcessReader {
    /// One process's cumulative byte counts (kernel counters, persistent).
    public struct Counters: Sendable, Equatable {
        public var inBytes: UInt64
        public var outBytes: UInt64
        public init(inBytes: UInt64 = 0, outBytes: UInt64 = 0) {
            self.inBytes = inBytes
            self.outBytes = outBytes
        }
    }

    private static let log = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "nettop")
    private static let toolPath = "/usr/bin/nettop"
    /// Cadence floor while something on screen is showing per-app rates.
    static let interactiveRefreshInterval: TimeInterval = 5
    /// Cadence floor when nothing is: the reader is then only feeding the
    /// per-app byte history, which is bucketed to the minute, so anything under
    /// half a bucket is resolution nobody can see.
    static let backgroundRefreshInterval: TimeInterval = 30

    /// How long to pause after a run that took `elapsed` seconds.
    ///
    /// Interactive: the floor's remainder and nothing more, so a machine where
    /// a run takes about as long as the floor (measured ~5 s here) keeps nettop
    /// running continuously and the figures land every five seconds. That is
    /// what a visible read-out is worth.
    ///
    /// Background: the larger floor, plus at least twice the run duration so
    /// nettop occupies at most ~1/3 of wall time however slow it gets. The
    /// adaptive term is not optional here. A fixed floor alone degenerates on a
    /// slow machine: a run takes ~5 s idle and ~17 s under load on some Macs,
    /// so `floor - elapsed` stops binding and the loop respawns nettop
    /// back-to-back, ~500-700 times an hour, exactly when the machine is
    /// already struggling (docs/fd-count-1620-diagnosis.md). That document
    /// measured the CPU per run at ~0.06 s and still called it out: the cost is
    /// process-spawn churn and a full system socket walk, not cycles.
    ///
    /// Either way `refreshLoop` differences over the actual elapsed interval,
    /// so the rates, and the byte totals integrated from them, stay exact at
    /// any cadence. Only the peak-rate columns lose within-bucket detail.
    static func paceSleep(
        afterRunTaking elapsed: TimeInterval, interactive: Bool
    ) -> TimeInterval {
        if interactive { return max(0, interactiveRefreshInterval - elapsed) }
        return max(backgroundRefreshInterval - elapsed, 2 * elapsed)
    }

    /// Signals the pause as well as guarding state, so promoting the reader to
    /// interactive cuts a background pause short instead of leaving a freshly
    /// opened panel waiting out the rest of it.
    private let lock = NSCondition()
    private var wantRunning = false
    private var interactive = false
    /// Set when a pause should end early (a mode promotion, or `stop()`).
    private var wakeEarly = false
    /// Previous cumulative counters and when they were sampled, to difference the
    /// next snapshot into rates.
    private var prevCounters: [Int32: Counters] = [:]
    private var prevAt: Date?
    /// Latest per-PID byte rates (bytes/sec), read non-blocking by the sampler.
    private var ratesCache: [Int32: Rates] = [:]

    /// Dedicated background queue so the nettop one-shot never runs on the sampler's
    /// hot path.
    private let refreshQueue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.nettop", qos: .utility)

    public init() {}

    /// Enable per-app sampling and start the background refresh loop. Idempotent.
    public func start() {
        lock.lock()
        let already = wantRunning
        wantRunning = true
        lock.unlock()
        guard !already else { return }
        refreshQueue.async { [weak self] in self?.refreshLoop() }
    }

    /// Disable per-app sampling and drop cached state. Idempotent; the loop exits at
    /// its next iteration.
    public func stop() {
        lock.lock()
        wantRunning = false
        wakeEarly = true
        prevCounters.removeAll()
        prevAt = nil
        ratesCache.removeAll()
        lock.broadcast()
        lock.unlock()
    }

    /// Tell the reader whether anything is displaying per-app rates right now
    /// (a per-app surface in the main window, or the network menu bar popover).
    /// Off, the loop drops to the background cadence, which is all the
    /// minute-bucketed history needs. Safe from any queue.
    ///
    /// Promoting to interactive wakes the loop out of a background pause, so
    /// opening a panel costs one nettop run rather than up to that pause plus
    /// one.
    public func setInteractive(_ interactive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard interactive != self.interactive else { return }
        self.interactive = interactive
        if interactive {
            wakeEarly = true
            lock.broadcast()
        }
    }

    /// Per-PID byte rates with the download/upload direction split the nettop
    /// counters already carry. The sampler feeds both the headline figure (the
    /// sum) and the split (the per-app byte history).
    public struct Rates: Sendable, Equatable {
        public var inBytesPerSec: Double
        public var outBytesPerSec: Double
        public var totalBytesPerSec: Double { inBytesPerSec + outBytesPerSec }

        public init(inBytesPerSec: Double, outBytesPerSec: Double) {
            self.inBytesPerSec = inBytesPerSec
            self.outBytesPerSec = outBytesPerSec
        }
    }

    /// The latest per-PID rates — read non-blocking on the sampler queue. Empty
    /// until the second nettop sample lands (a rate needs two).
    public func latestRates() -> [Int32: Rates] {
        lock.lock()
        defer { lock.unlock() }
        return ratesCache
    }

    // MARK: - Background refresh

    /// Wait out `duration`, returning early when `setInteractive(true)` or
    /// `stop()` asks for it. `NSCondition.wait(until:)` can also return
    /// spuriously, so the deadline is rechecked rather than trusted.
    private func pause(for duration: TimeInterval) {
        guard duration > 0 else { return }
        let deadline = Date().addingTimeInterval(duration)
        lock.lock()
        defer { lock.unlock() }
        while !wakeEarly, wantRunning, Date() < deadline {
            lock.wait(until: deadline)
        }
        wakeEarly = false
    }

    private func refreshLoop() {
        while true {
            lock.lock()
            let want = wantRunning
            lock.unlock()
            guard want else { return }

            let runAt = Date()
            guard let output = Self.runOneShot() else {
                // Transient failure / timeout: pause so a persistent failure
                // cannot spin this queue.
                pause(for: 2)
                continue
            }
            let counters = Self.parse(output: output)

            lock.lock()
            if let prevAt {
                let dt = runAt.timeIntervalSince(prevAt)
                if dt > 0 {
                    var rates: [Int32: Rates] = [:]
                    rates.reserveCapacity(counters.count)
                    for (pid, cur) in counters {
                        guard let prev = prevCounters[pid] else { continue }
                        let inDelta = CPUMath.delta(cur.inBytes, prev.inBytes)
                        let outDelta = CPUMath.delta(cur.outBytes, prev.outBytes)
                        // Keep a process that only uploaded (backup daemons) or
                        // only downloaded: a total-only gate would hide it.
                        guard inDelta > 0 || outDelta > 0 else { continue }
                        rates[pid] = Rates(
                            inBytesPerSec: Double(inDelta) / dt,
                            outBytesPerSec: Double(outDelta) / dt)
                    }
                    ratesCache = rates
                }
            }
            prevCounters = counters
            prevAt = runAt
            lock.unlock()

            // Two-speed pacing: the display cadence while someone is looking,
            // the history cadence otherwise.
            let elapsed = Date().timeIntervalSince(runAt)
            lock.lock()
            let pause = Self.paceSleep(afterRunTaking: elapsed, interactive: interactive)
            lock.unlock()
            self.pause(for: pause)
        }
    }

    // MARK: - Subprocess

    /// Run one `nettop -L 1` to a pipe and return its full output, or nil on
    /// failure / timeout. Logging mode (not the interactive curses UI). Reads on a
    /// background thread with a hard timeout so a wedged nettop can't stall the
    /// refresh loop. The timeout must clear nettop's worst REAL run, not just a
    /// wedged one: on some machines (measured, macOS 26) a single `-L 1` run
    /// takes a deterministic ~30 s of wall time, so anything near the old 15 s
    /// floor killed every cycle and the reader silently produced no rates.
    private static func runOneShot(timeout: TimeInterval = 90) -> String? {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            log.error("nettop not found at \(toolPath, privacy: .public)")
            return nil
        }
        return autoreleasepool {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: toolPath)
            // -P per process · -x raw bytes (no unit scaling) · -J only the byte
            // columns · -s 1 the sampling delay. The delay matters: without it
            // nettop waits its (measured ~30 s on this class of machine) default
            // interval before producing its first sample; -s 1 brings a one-shot
            // run down to ~5 s, which is what paces the refresh below. · -L 1 one
            // logging sample then exit.
            task.arguments = ["-P", "-x", "-J", "bytes_in,bytes_out", "-s", "1", "-L", "1"]
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
            // Read to EOF on a background thread so the read can be abandoned if
            // nettop wedges past the deadline.
            let handle = outPipe.fileHandleForReading
            let done = DispatchSemaphore(value: 0)
            let box = DataBox()
            DispatchQueue.global(qos: .utility).async {
                box.data = handle.readDataToEndOfFile()
                done.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                log.error("nettop timed out after \(timeout, privacy: .public)s; terminating")
                task.terminate()
                return nil
            }
            task.waitUntilExit()
            return String(decoding: box.data, as: UTF8.self)
        }
    }

    // MARK: - Parsing

    /// Test hook / shared parser: a full one-shot nettop output block into
    /// cumulative per-PID counters.
    static func parse(output: String) -> [Int32: Counters] {
        var result: [Int32: Counters] = [:]
        output.enumerateLines { line, _ in
            if let row = parse(line: line) { result[row.pid] = row.counters }
        }
        return result
    }

    /// Parse one nettop CSV row to (pid, cumulative counters), or nil for the
    /// header and malformed lines. Position-independent: the last two fields are
    /// bytes_in/bytes_out and the field before them is `name.pid`, so it copes with
    /// both the timestamped and plain formats and with process names that contain
    /// commas, dots, or spaces.
    static func parse(line: String) -> (pid: Int32, counters: Counters)? {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = cleaned.split(separator: ",", omittingEmptySubsequences: false).map(
            String.init)
        while let last = fields.last, last.isEmpty { fields.removeLast() }
        guard fields.count >= 3,
            let outBytes = UInt64(fields[fields.count - 1]),
            let inBytes = UInt64(fields[fields.count - 2])
        else { return nil }

        let label = fields[fields.count - 3]
        guard let dot = label.lastIndex(of: "."),
            let pid = Int32(label[label.index(after: dot)...])
        else { return nil }

        return (pid, Counters(inBytes: inBytes, outBytes: outBytes))
    }
}

/// Reference box so the background read thread can hand the captured data back to
/// the spawning thread across the timeout semaphore.
private final class DataBox: @unchecked Sendable { var data = Data() }
