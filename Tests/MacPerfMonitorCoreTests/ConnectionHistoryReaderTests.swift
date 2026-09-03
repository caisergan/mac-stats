import XCTest

@testable import MacPerfMonitorCore

/// The per-connection nettop parser and the snapshot differencing, against the
/// exact row shapes `nettop -m tcp -x -J bytes_in,bytes_out -L 1` produces
/// (verified on the reference machine).
final class ConnectionHistoryReaderTests: XCTestCase {
    private let output = """
        time,           ,                                                                                        bytes_in,       bytes_out,
        02:47:56.444578,launchd.1,                                                                                          0,              0,
        02:47:56.440179,   tcp6 *.5900<->*.*,                                                                              ,               ,
        02:47:56.440212,   tcp4 *:5900<->*:*,                                                                              ,               ,
        02:47:56.444581,apsd.150,                                                                                       5495276,         711450,
        02:47:56.442200,   tcp4 192.168.1.219:49853<->17.57.146.57:5223,                                                   5495276,         711450,
        02:47:56.444583,kdc.161,                                                                                               0,              0,
        02:47:56.444584,rapportd.508,                                                                                      71114,          36489,
        """

    func testParseAttributesConnectionsToEnclosingProcess() {
        let snapshots = ConnectionHistoryReader.parse(output: output)
        XCTAssertEqual(snapshots.count, 1)
        let only = snapshots[0]
        XCTAssertEqual(only.pid, 150)
        XCTAssertEqual(only.remoteIP, "17.57.146.57")
        XCTAssertEqual(only.remotePort, 5223)
        XCTAssertEqual(only.inBytes, 5_495_276)
        XCTAssertEqual(only.outBytes, 711_450)
    }

    func testParseProcessRowsAndHeaderOnly() {
        XCTAssertNil(ConnectionHistoryReader.parseProcess(line: "time,  ,  bytes_in,  bytes_out,"))
        XCTAssertEqual(
            ConnectionHistoryReader.parseProcess(
                line: "02:47:56.444581,apsd.150,  5495276,  711450,"), 150)
        XCTAssertNil(
            ConnectionHistoryReader.parseProcess(
                line: "02:47:56.442200,   tcp4 1.2.3.4:5<->6.7.8.9:443,  1,  2,"))
    }

    func testDiffDifferencesCountersAndDropsVanishedKeys() {
        let at = Date()
        let previous: [ConnectionHistoryReader.Snapshot] = [
            .init(
                pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 1_000, outBytes: 500),
            .init(pid: 508, remoteIP: "10.0.0.9", remotePort: 7000, inBytes: 10, outBytes: 10),
        ]
        let current: [ConnectionHistoryReader.Snapshot] = [
            // Two parallel connections to the same endpoint: their counters sum.
            .init(
                pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 2_000, outBytes: 900),
            .init(
                pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 2_000, outBytes: 900),
        ]
        let deltas = ConnectionHistoryReader.diff(current: current, previous: previous, at: at)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].inBytes, 3_000)
        XCTAssertEqual(deltas[0].outBytes, 1_300)
        XCTAssertEqual(deltas[0].remotePort, 5223)
    }

    func testDiffCountsAFlowThatOpenedThisCycle() {
        // A TCP flow's counters start at zero when the socket opens, so a key
        // that is new relative to a non-empty baseline contributes its whole
        // current count. Skipping it lost the first sighting of every
        // connection, and lost short flows (most HTTPS requests) entirely.
        let at = Date()
        let previous: [ConnectionHistoryReader.Snapshot] = [
            .init(pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 1_000, outBytes: 0)
        ]
        let current: [ConnectionHistoryReader.Snapshot] = [
            .init(
                pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 1_000, outBytes: 0),
            .init(
                pid: 508, remoteIP: "93.184.216.34", remotePort: 443, inBytes: 8_000, outBytes: 900),
        ]
        let deltas = ConnectionHistoryReader.diff(current: current, previous: previous, at: at)
        XCTAssertEqual(deltas.count, 1, "the unchanged flow contributes nothing")
        XCTAssertEqual(deltas[0].remoteIP, "93.184.216.34")
        XCTAssertEqual(deltas[0].inBytes, 8_000)
        XCTAssertEqual(deltas[0].outBytes, 900)
    }

    func testDiffIgnoresFirstSightingAndCounterResets() {
        let at = Date()
        let current: [ConnectionHistoryReader.Snapshot] = [
            .init(pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 9_000, outBytes: 0)
        ]
        XCTAssertTrue(ConnectionHistoryReader.diff(current: current, previous: [], at: at).isEmpty)
        // Counter went backwards (flow churn): clamps to zero, no row.
        let previous: [ConnectionHistoryReader.Snapshot] = [
            .init(
                pid: 150, remoteIP: "17.57.146.57", remotePort: 5223, inBytes: 10_000, outBytes: 0)
        ]
        XCTAssertTrue(
            ConnectionHistoryReader.diff(current: current, previous: previous, at: at).isEmpty)
    }
}
