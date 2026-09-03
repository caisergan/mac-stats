import GRDB
import XCTest

@testable import MacPerfMonitorCore

/// The v16 network byte totals round-trip: rates integrate into per-bucket
/// transferred amounts on the system and process tiers, the totals query
/// stitches raw/minute/hour without double-counting a bucket, per-app usage
/// groups by executable across launches, and Clear zeroes only the network
/// sums.
final class NetworkHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    /// Aligned to the minute and the hour, so rollup bucketing is predictable.
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-nethistory-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func systemTick(
        _ offset: TimeInterval, down: Double = 1_000_000, up: Double = 500_000,
        from base: Date? = nil
    ) -> SystemSample {
        var sample = Make.system(
            timestamp: (base ?? anchor).addingTimeInterval(offset), pressurePercent: 5)
        sample.networkInBytesPerSec = down
        sample.networkOutBytesPerSec = up
        return sample
    }

    private func processTick(
        _ offset: TimeInterval, pid: Int32, down: Double
    ) -> ProcessSample {
        var process = Make.process(
            timestamp: anchor.addingTimeInterval(offset), pid: pid, name: "worker",
            footprint: 1 << 20)
        process.executablePath = "/usr/local/bin/worker"
        process.networkInBytesPerSec = down
        return process
    }

    func testSystemTotalsRoundTripThroughMinuteTier() throws {
        for offset in stride(from: 0.0, to: 60.0, by: 2.0) {
            try store.insert(systemSample: systemTick(offset))
        }
        let now = anchor.addingTimeInterval(120)  // minute m0 is complete
        try Retention.run(store.databasePool, now: now)

        // 30 samples x 2 s each at 1 MB/s down and 500 KB/s up, so the bucket
        // carries exactly 60 MB and 30 MB.
        let totals = try store.networkBytesTransferred(.oneDay, now: now)
        XCTAssertEqual(totals.downloaded, 60_000_000, accuracy: 1)
        XCTAssertEqual(totals.uploaded, 30_000_000, accuracy: 1)

        // "All" reaches the same figures while the hour tier is still empty:
        // the minute tier owns everything below its watermark.
        let all = try store.networkBytesTransferred(.all, now: now)
        XCTAssertEqual(all.downloaded, 60_000_000, accuracy: 1)
        XCTAssertEqual(all.uploaded, 30_000_000, accuracy: 1)
    }

    func testTotalsStitchTiersWithoutDoubleCounting() throws {
        for offset in stride(from: 0.0, to: 60.0, by: 2.0) {
            try store.insert(systemSample: systemTick(offset))
        }
        let minuteDone = anchor.addingTimeInterval(120)
        try Retention.run(store.databasePool, now: minuteDone)
        let hourDone = anchor.addingTimeInterval(7200)
        try Retention.run(store.databasePool, now: hourDone)

        // The hour tier now owns m0; the minute and raw tiers hold nothing
        // above its watermark, so the stitched total is the bucket once.
        let totals = try store.networkBytesTransferred(.all, now: hourDone)
        XCTAssertEqual(totals.downloaded, 60_000_000, accuracy: 1)
        XCTAssertEqual(totals.uploaded, 30_000_000, accuracy: 1)

        let series = try store.networkUsageSeries(.all, now: hourDone)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].downloaded, 60_000_000, accuracy: 1)
        XCTAssertEqual(series[0].uploaded, 30_000_000, accuracy: 1)
    }

    func testRawRemainderAfterMinuteWatermarkIsCounted() throws {
        for offset in stride(from: 0.0, to: 60.0, by: 2.0) {
            try store.insert(systemSample: systemTick(offset))
        }
        let minuteDone = anchor.addingTimeInterval(120)
        try Retention.run(store.databasePool, now: minuteDone)
        // Fresh traffic after the watermark lives only in the raw tier.
        try store.insert(systemSample: systemTick(120))
        try store.insert(systemSample: systemTick(122))

        let totals = try store.networkBytesTransferred(.oneDay, now: anchor.addingTimeInterval(124))
        // Rolled bucket 60 MB, plus the raw remainder: the row at +120 s spans
        // to the next row (+122), the trailing row spans to the query instant
        // (+124), so exactly 4 s at 1 MB/s.
        XCTAssertEqual(totals.downloaded, 60_000_000 + 4_000_000, accuracy: 1)
        XCTAssertEqual(totals.uploaded, 30_000_000 + 2_000_000, accuracy: 1)
    }

    func testPerAppUsageGroupsByExecutableAcrossLaunches() throws {
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(0),
                processes: [processTick(0, pid: 1000, down: 1000)],
                unreadableProcessCount: 0))
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(60),
                processes: [processTick(60, pid: 1001, down: 1000)],
                unreadableProcessCount: 0))
        // A process with no network usage must not appear in the table at all:
        // every process in the catalog would otherwise bury the real users.
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(60),
                processes: [processTick(60, pid: 1002, down: 0)],
                unreadableProcessCount: 0))

        let now = anchor.addingTimeInterval(120)  // minute m0 and m1 are complete
        try Retention.run(store.databasePool, now: now)
        let apps = try store.networkAppUsage(.oneDay, now: now)
        XCTAssertEqual(apps.count, 1, "two launches of one executable group into one row")
        XCTAssertEqual(apps[0].downloaded, 120_000, accuracy: 1)
        XCTAssertEqual(apps[0].uploaded, 0, accuracy: 1)
        XCTAssertEqual(apps[0].displayName, "worker")

        // The 24 h period charts 5-minute grid buckets, and both launches sit
        // inside the first one.
        let series = try store.networkAppUsageSeries(
            executablePath: "/usr/local/bin/worker", bundleID: nil, .oneDay, now: now)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].downloaded, 120_000, accuracy: 1)
    }

    func testRawTierHourQueriesReturnData() throws {
        // The Hour period reads the raw tier, whose trailing-dt query binds
        // two placeholders; the until/since order was once swapped, which
        // filtered out every row. Lock the exact spans: rows at +0 and +2 s,
        // query instant +4 s.
        try store.insert(systemSample: systemTick(0))
        try store.insert(systemSample: systemTick(2))
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(0),
                processes: [processTick(0, pid: 1000, down: 1000)],
                unreadableProcessCount: 0))
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(2),
                processes: [processTick(2, pid: 1000, down: 1000)],
                unreadableProcessCount: 0))
        let now = anchor.addingTimeInterval(4)

        let series = try store.networkUsageSeries(.lastHour, now: now)
        XCTAssertEqual(series.count, 1)
        // systemTick's default rate is 1 MB/s down, spanning 4 s in total.
        XCTAssertEqual(series[0].downloaded, 4_000_000, accuracy: 1)

        let apps = try store.networkAppUsage(.lastHour, now: now)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].downloaded, 4_000, accuracy: 1)

        let appSeries = try store.networkAppUsageSeries(
            executablePath: "/usr/local/bin/worker", bundleID: nil, .lastHour, now: now)
        XCTAssertEqual(appSeries.count, 1)
        XCTAssertEqual(appSeries[0].downloaded, 4_000, accuracy: 1)
    }

    func testDeadProcessUsageDoesNotGrowWithTime() throws {
        // A process that stopped transferring (its last raw row carries its
        // final rate) must not accrue phantom bytes as the query instant moves
        // on: the trailing row's dt stops at its minute bucket's end, exactly
        // like the minute rollup counts it. The original code extrapolated the
        // last rate to now and the per-app figure climbed ~rate x elapsed
        // forever.
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(0),
                processes: [processTick(0, pid: 1000, down: 1000)],
                unreadableProcessCount: 0))
        // The process vanishes: no further rows, whatever the query instant.
        let early = try store.networkAppUsage(.lastHour, now: anchor.addingTimeInterval(60))
        let later = try store.networkAppUsage(.lastHour, now: anchor.addingTimeInterval(600))
        XCTAssertEqual(early.count, 1)
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(early[0].downloaded, later[0].downloaded)
        // Bounded: one row at 1000 B/s, the anchor is minute-aligned, so the
        // row's bucket ends 60 s after it: 60,000 bytes, never more.
        XCTAssertEqual(later[0].downloaded, 60_000)
    }

    func testTotalsCountTheHourBucketTheWindowEdgeLandsIn() throws {
        // Data 30 days back, inside one hour bucket that straddles the window's
        // left edge: eleven samples BEFORE the edge (+600..+1200) and eleven
        // AFTER it (+2400..+3000), one per minute. The totals must count only
        // the after-edge traffic; a naive `bucket >= since` drops the whole
        // hour bucket the edge lands in (the original bug lost ~52 minutes).
        let base = anchor.addingTimeInterval(-30 * 86_400)  // hour-aligned
        for offset in stride(from: 600.0, through: 1200.0, by: 60.0) {
            try store.insert(systemSample: systemTick(offset, from: base))
        }
        for offset in stride(from: 2400.0, through: 3000.0, by: 60.0) {
            try store.insert(systemSample: systemTick(offset, from: base))
        }
        // Roll raw to minute and minute to hour without trimming the 30-day-old
        // tiers (the default retention would drop them in the same pass).
        try Retention.run(
            store.databasePool, now: base.addingTimeInterval(4200),
            policy: RetentionPolicy(
                rawWindow: 40 * 86_400, minuteWindow: 40 * 86_400,
                hourWindow: 90 * 86_400))

        // Window edge sits at +1800, mid-hour-bucket; the query runs "now" at
        // +30 days so the 30 d period starts exactly there.
        let totals = try store.networkBytesTransferred(
            .thirtyDays, now: anchor.addingTimeInterval(1800))
        // 11 minutes x 60 s x 1 MB/s, before-edge traffic excluded.
        XCTAssertEqual(totals.downloaded, 660_000_000)
        XCTAssertEqual(totals.uploaded, 330_000_000)
    }

    func testClearNetworkHistoryZeroesOnlyNetworkSums() throws {
        for offset in stride(from: 0.0, to: 60.0, by: 2.0) {
            try store.insert(systemSample: systemTick(offset))
        }
        let now = anchor.addingTimeInterval(120)
        try Retention.run(store.databasePool, now: now)
        try store.clearNetworkHistory()

        let totals = try store.networkBytesTransferred(.oneDay, now: now)
        XCTAssertEqual(totals.downloaded, UInt64(0))
        XCTAssertEqual(totals.uploaded, UInt64(0))

        let points = try store.systemHistory(.oneDay, now: now)
        XCTAssertEqual(points.first?.networkInBytesPerSec ?? -1, 1_000_000, accuracy: 0.001)
    }

    func testInterfaceUsageAccruesAndRollsUp() throws {
        try store.insert(systemSample: systemTick(0))
        // Two drains of observed bytes land in the same minute bucket.
        try store.recordInterfaceUsage(["en0": (300, 150)], at: anchor)
        try store.recordInterfaceUsage(["en0": (300, 150)], at: anchor.addingTimeInterval(30))

        let minuteTotals = try store.interfaceUsage(.lastHour, now: anchor.addingTimeInterval(60))
        XCTAssertEqual(minuteTotals.count, 1)
        XCTAssertEqual(minuteTotals[0].name, "en0")
        XCTAssertEqual(minuteTotals[0].downloaded, UInt64(600))
        XCTAssertEqual(minuteTotals[0].uploaded, UInt64(300))

        let hourDone = anchor.addingTimeInterval(7200)
        try Retention.run(store.databasePool, now: hourDone)
        let hourTotals = try store.interfaceUsage(.all, now: hourDone)
        XCTAssertEqual(hourTotals.count, 1)
        XCTAssertEqual(hourTotals[0].downloaded, UInt64(600))

        let series = try store.interfaceUsageSeries("en0", .all, now: hourDone)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].downloaded, 600, accuracy: 0.001)
    }

    func testConnectionDeltasRoundTripAndGroupByRemoteAndApp() throws {
        try store.insert(
            Sampler.Snapshot(
                system: systemTick(0),
                processes: [processTick(0, pid: 1000, down: 0)],
                unreadableProcessCount: 0))
        let first = anchor.addingTimeInterval(30)
        try store.recordConnectionDeltas([
            ConnectionHistoryReader.Delta(
                pid: 1000, remoteIP: "17.57.146.57", remotePort: 443,
                inBytes: 1_000, outBytes: 200, timestamp: first)
        ])
        // A second cycle later the same day adds up.
        try store.recordConnectionDeltas([
            ConnectionHistoryReader.Delta(
                pid: 1000, remoteIP: "17.57.146.57", remotePort: 443,
                inBytes: 500, outBytes: 100, timestamp: first.addingTimeInterval(30))
        ])
        // An unknown pid (process not in the catalog) is dropped, not crashed on.
        try store.recordConnectionDeltas([
            ConnectionHistoryReader.Delta(
                pid: 99_999, remoteIP: "1.2.3.4", remotePort: 80,
                inBytes: 1, outBytes: 1, timestamp: first)
        ])

        let rows = try store.connectionUsage(.all, now: anchor.addingTimeInterval(60))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].remoteIP, "17.57.146.57")
        XCTAssertEqual(rows[0].downloaded, 1_500)
        XCTAssertEqual(rows[0].uploaded, 300)
        XCTAssertEqual(rows[0].firstTransfer, first)
        XCTAssertEqual(rows[0].lastTransfer, first.addingTimeInterval(30))
    }
}
