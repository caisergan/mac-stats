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
/// a wedged nettop. Pacing (`paceSleep`) targets one nettop run every
/// `minRefreshInterval`: on machines where a run takes longer than the floor it
/// respawns back-to-back, so the per-app figures stay as fresh as the platform
/// allows. `CPUMath.delta` clamps the occasional counter decrease (a flow
/// closing, or a counter reset) to zero.
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
    /// Target cadence for one nettop run on a machine where a run is cheap: a
    /// run starts every `minRefreshInterval` seconds at most. Where a run costs
    /// more than that, `paceSleep` stretches the interval further, keyed to the
    /// measured run duration.
    static let minRefreshInterval: TimeInterval = 5

    /// How long to pause after a run that took `elapsed` seconds: enough that
    /// the full cycle is at least `minRefreshInterval`, and at least twice the
    /// run duration, so nettop occupies at most ~1/3 of wall time however slow
    /// it is.
    ///
    /// The adaptive term is not optional. A fixed floor alone degenerates on a
    /// slow machine: a run takes ~5 s idle and ~17 s under load on some Macs,
    /// so `floor - elapsed` is never taken and the loop respawns nettop
    /// back-to-back, hundreds of times an hour, exactly when the machine is
    /// already struggling (docs/fd-count-1620-diagnosis.md, TL;DR item 3).
    /// With `-s 1` bringing a run to ~5 s the two terms now sit close together
    /// anyway: a fast machine gets the full 5 s cadence the floor asks for, the
    /// measured ~5 s machine a 15 s cycle, and only a genuinely struggling one
    /// backs further off. The cost is staler per-app rates there;
    /// `refreshLoop` differences over actual elapsed time, so they stay
    /// correct at any cadence.
    static func paceSleep(afterRunTaking elapsed: TimeInterval) -> TimeInterval {
        max(minRefreshInterval - elapsed, 2 * elapsed)
    }

    private let lock = NSLock()
    private var wantRunning = false
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
        prevCounters.removeAll()
        prevAt = nil
        ratesCache.removeAll()
        lock.unlock()
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

    private func refreshLoop() {
        while true {
            lock.lock()
            let want = wantRunning
            lock.unlock()
            guard want else { return }

            let runAt = Date()
            guard let output = Self.runOneShot() else {
                // Transient failure / timeout — pause so a persistent failure can't
                // spin this queue.
                Thread.sleep(forTimeInterval: 2)
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

            // Adaptive pacing: a floor on fast machines, and on slow ones a pause
            // proportional to the run itself so nettop never respawns back-to-back.
            let elapsed = Date().timeIntervalSince(runAt)
            let pause = Self.paceSleep(afterRunTaking: elapsed)
            if pause > 0 {
                Thread.sleep(forTimeInterval: pause)
            }
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
