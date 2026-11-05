import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

/// The panel's Top network apps list: how often its data refreshes, and how the
/// rows hold together once that data changes every second.
@MainActor
final class NetworkAppListTests: XCTestCase {
    // MARK: - Reader pace

    func testOpenNetworkPanelRunsTheReaderLiveEvenWithTheWindowOpen() {
        XCTAssertEqual(
            SamplerModel.networkReaderPace(
                trackingEnabled: true, networkPanelOpen: true, processConsumers: 0),
            .live)
        XCTAssertEqual(
            SamplerModel.networkReaderPace(
                trackingEnabled: true, networkPanelOpen: true, processConsumers: 2),
            .live)
    }

    /// A main window can stay open all day, so it must not buy 1 Hz spawns.
    func testMainWindowAloneStaysOnTheDisplayPace() {
        XCTAssertEqual(
            SamplerModel.networkReaderPace(
                trackingEnabled: true, networkPanelOpen: false, processConsumers: 1),
            .display)
    }

    func testNobodyWatchingFallsBackToTheHistoryPace() {
        XCTAssertEqual(
            SamplerModel.networkReaderPace(
                trackingEnabled: true, networkPanelOpen: false, processConsumers: 0),
            .background)
        XCTAssertEqual(
            SamplerModel.networkReaderPace(
                trackingEnabled: false, networkPanelOpen: true, processConsumers: 1),
            .background)
    }

    // MARK: - Recent rate

    private func trail(_ rates: [(age: TimeInterval, rate: Double)]) -> [ProcessHistoryPoint] {
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        return rates.map {
            ProcessHistoryPoint(
                date: newest.addingTimeInterval(-$0.age), footprint: 0, cpuPercent: 0, fdTotal: 0,
                diskRead: 0, diskWritten: 0, networkBytesPerSec: $0.rate)
        }
    }

    /// One point a second, as while the panel is open: all five count, and the
    /// burst six seconds ago has aged out.
    func testRecentRateCoversFiveSecondsOfAOneHertzTrail() throws {
        let rate = try XCTUnwrap(
            SamplerModel.recentNetworkRate(
                in: trail([
                    (5, 9_000), (4, 500), (3, 500), (2, 0), (1, 0), (0, 0),
                ])))
        XCTAssertEqual(rate, 200, accuracy: 0.001)
    }

    /// The main window's slower scans leave fewer points in the same span.
    func testRecentRateCoversTheSameSpanAtASlowerCadence() throws {
        let rate = try XCTUnwrap(
            SamplerModel.recentNetworkRate(in: trail([(10, 9_000), (5, 9_000), (0, 40)])))
        XCTAssertEqual(rate, 40, accuracy: 0.001)
    }

    func testRecentRateOfAnEmptyTrailIsUnknown() {
        XCTAssertNil(SamplerModel.recentNetworkRate(in: []))
    }

    // MARK: - Ranking

    private func process(_ name: String, pid: Int32, rate: Double) -> ProcessSample {
        MenuPanelFixtures.process(name, pid: pid, network: rate)
    }

    private func recent(_ rates: [(ProcessSample, Double)]) -> [ProcessIdentity: Double] {
        Dictionary(uniqueKeysWithValues: rates.map { ($0.0.id, $0.1) })
    }

    /// A one-second burst from a quiet process does not take the top row, but
    /// every row still reads its current rate.
    func testRanksByTheAverageAndShowsTheCurrentRate() {
        let steady = process("steady", pid: 10, rate: 100)
        let burst = process("burst", pid: 20, rate: 900)
        let ranked = SamplerModel.rankedNetwork(
            [burst, steady], recentRates: recent([(steady, 500), (burst, 180)]), limit: 10)

        XCTAssertEqual(ranked.processes.map(\.name), ["steady", "burst"])
        XCTAssertEqual(ranked.processes.map(\.networkBytesPerSec), [100, 900])
        XCTAssertEqual(ranked.apps.map(\.name), ["steady", "burst"])
    }

    /// A second with no traffic must not flash the empty state over the list.
    func testASilentSecondKeepsTheList() {
        let app = process("app", pid: 10, rate: 0)
        let ranked = SamplerModel.rankedNetwork(
            [app], recentRates: recent([(app, 2_000)]), limit: 10)

        XCTAssertEqual(ranked.processes.map(\.name), ["app"])
        XCTAssertEqual(ranked.processes.first?.networkBytesPerSec, 0)
        XCTAssertEqual(ranked.apps.count, 1)
    }

    func testAWholeQuietWindowEmptiesBothLists() {
        let app = process("app", pid: 10, rate: 0)
        let ranked = SamplerModel.rankedNetwork(
            [app], recentRates: recent([(app, 0)]), limit: 10)

        XCTAssertTrue(ranked.processes.isEmpty)
        XCTAssertTrue(ranked.apps.isEmpty)
    }

    func testSilentRowsKeepAFixedOrder() {
        let active = process("active", pid: 50, rate: 10)
        let high = process("high", pid: 30, rate: 0)
        let low = process("low", pid: 20, rate: 0)
        let ranked = SamplerModel.rankedNetwork(
            [high, active, low], recentRates: recent([(active, 10), (high, 0), (low, 0)]),
            limit: 10)

        XCTAssertEqual(ranked.processes.map(\.name), ["active", "low", "high"])
    }

    func testRespectsTheLimit() {
        let processes = (1...5).map { process("p\($0)", pid: Int32($0), rate: Double($0)) }
        let ranked = SamplerModel.rankedNetwork(
            processes, recentRates: recent(processes.map { ($0, $0.networkBytesPerSec) }),
            limit: 2)

        XCTAssertEqual(ranked.processes.map(\.name), ["p5", "p4"])
        XCTAssertEqual(ranked.apps.count, 2)
    }
}
