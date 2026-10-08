import Darwin
import XCTest

@testable import MacPerfMonitorCore

final class AppForceQuitTests: XCTestCase {
    private func sample(_ pid: Int32, ppid: Int32 = 1, start: TimeInterval = 0) -> ProcessSample {
        ProcessSample(
            timestamp: Date(), pid: pid, ppid: ppid, name: "p\(pid)", physFootprint: 0,
            residentSize: 0, virtualSize: 0, lifetimeMaxFootprint: 0, cpuPercent: 0,
            cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1, fdTotal: 0, fdVnode: 0,
            fdSocket: 0, fdPipe: 0, fdOther: 0, diskBytesRead: 0, diskBytesWritten: 0,
            isTranslated: false, architecture: .arm64,
            startTime: Date(timeIntervalSince1970: start), uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
    }

    func testParentsComeBeforeChildren() {
        // Helpers listed first (as a CPU-sorted list would have them), app last.
        let ordered = AppForceQuit.order(
            [sample(12, ppid: 11), sample(11, ppid: 10), sample(10), sample(13, ppid: 10)],
            selfPID: 999)
        XCTAssertEqual(ordered.map(\.pid), [10, 11, 13, 12])
    }

    func testNeverTargetsLaunchdKernelOrSelfAndDropsDuplicates() {
        let ordered = AppForceQuit.order(
            [sample(0), sample(1), sample(50), sample(60), sample(60)], selfPID: 50)
        XCTAssertEqual(ordered.map(\.pid), [60])
    }

    func testParentCycleStillOrdersEveryMember() {
        let ordered = AppForceQuit.order([sample(20, ppid: 21), sample(21, ppid: 20)], selfPID: 1)
        XCTAssertEqual(Set(ordered.map(\.pid)), [20, 21])
    }

    func testSignalAllSkipsExitedAndSortsOutcomes() {
        let members = [sample(30), sample(31), sample(32), sample(33)]
        var sent: [Int32] = []
        let tally = AppForceQuit.signalAll(
            members,
            isRunning: { $0.pid != 31 },  // 31 exited (or its pid was reused)
            send: { pid in
                sent.append(pid)
                switch pid {
                case 32: return .notPermitted
                case 33: return .failed(EINVAL)
                default: return .sent
                }
            })
        XCTAssertEqual(sent, [30, 32, 33], "an exited member must never be signalled")
        XCTAssertEqual(tally.signalled.map(\.pid), [30])
        XCTAssertEqual(tally.gone.map(\.pid), [31])
        XCTAssertEqual(tally.notPermitted.map(\.pid), [32])
        XCTAssertEqual(tally.failed.map(\.identity.pid), [33])
    }

    /// The whole pass against real processes: a shell and the two children it
    /// launched, listed children first, are all stopped.
    func testForceQuitsARealProcessTree() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        try shell.run()
        defer { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }
        let reader = ProcessReader()

        func liveSample(_ pid: Int32) -> ProcessSample? {
            guard let info = reader.taskAllInfo(pid) else { return nil }
            var s = sample(pid, ppid: info.ppid)
            s.startTime = info.startTime
            return s
        }
        // Wait for the shell to launch both children.
        var children: [ProcessSample] = []
        let deadline = Date().addingTimeInterval(3)
        while children.count < 2, Date() < deadline {
            children = reader.listPIDs().compactMap(liveSample)
                .filter { $0.ppid == shell.processIdentifier }
            usleep(20_000)
        }
        XCTAssertEqual(children.count, 2)
        let parent = try XCTUnwrap(liveSample(shell.processIdentifier))

        let ordered = AppForceQuit.order(children + [parent], selfPID: getpid())
        XCTAssertEqual(ordered.first?.pid, parent.pid, "the parent goes first")
        let tally = AppForceQuit.signalAll(
            ordered, isRunning: reader.isRunning,
            send: { kill($0, SIGKILL) == 0 ? .sent : .failed(errno) })
        XCTAssertEqual(tally.signalled.count, 3)

        let stopDeadline = Date().addingTimeInterval(3)
        while ordered.contains(where: { reader.isRunning($0.id) }), Date() < stopDeadline {
            usleep(20_000)
        }
        XCTAssertFalse(ordered.contains { reader.isRunning($0.id) })
    }

    func testIsRunningTracksARealProcessThroughItsKill() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        let reader = ProcessReader()
        let info = try XCTUnwrap(reader.taskAllInfo(pid))
        let identity = ProcessIdentity(pid: pid, startTime: info.startTime)

        XCTAssertTrue(reader.isRunning(identity))
        XCTAssertFalse(
            reader.isRunning(
                ProcessIdentity(pid: pid, startTime: info.startTime.addingTimeInterval(-60))),
            "the same pid with another start time is a different process")

        XCTAssertEqual(kill(pid, SIGKILL), 0)
        // Unreaped, the child is a zombie, which must already count as stopped.
        let deadline = Date().addingTimeInterval(2)
        while reader.isRunning(identity), Date() < deadline { usleep(10_000) }
        XCTAssertFalse(reader.isRunning(identity))
        child.waitUntilExit()
        XCTAssertFalse(reader.isRunning(identity))
    }
}
