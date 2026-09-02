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
        _ offset: TimeInterval, down: Double = 1_000_000, up: Double = 500_000
    ) -> SystemSample {
        var sample = Make.system(timestamp: anchor.addingTimeInterval(offset), pressurePercent: 5)
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
        // Rolled bucket 60 MB, plus 2 s of raw remainder at 1 MB/s. The last
        // raw row's dt falls back to +1 s, so 2.999... s in total.
        XCTAssertEqual(totals.downloaded, 60_000_000 + 3_000_000, accuracy: 1_000_001)
        XCTAssertEqual(totals.uploaded, 30_000_000 + 1_500_000, accuracy: 1_000_001)
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
        let now = anchor.addingTimeInterval(120)
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

        // Other metrics survive the clear untouched.
        let points = try store.systemHistory(.oneDay, now: now)
        XCTAssertEqual(points.first?.networkInBytesPerSec ?? -1, 1_000_000, accuracy: 0.001)
    }
}
