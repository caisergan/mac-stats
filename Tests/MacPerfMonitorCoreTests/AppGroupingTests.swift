import XCTest

@testable import MacPerfMonitorCore

final class AppGroupingTests: XCTestCase {
    private func sample(
        _ pid: Int32, _ name: String, path: String?, ppid: Int32 = 1,
        responsible: Int32? = nil, footprint: UInt64 = 0, cpu: Double = 0
    ) -> ProcessSample {
        ProcessSample(
            timestamp: Date(), pid: pid, ppid: ppid, responsiblePID: responsible ?? pid,
            name: name, executablePath: path, physFootprint: footprint, residentSize: 0,
            virtualSize: 0, lifetimeMaxFootprint: 0, cpuPercent: cpu, cpuTimeUser: 0,
            cpuTimeSystem: 0, threadCount: 1, fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0,
            fdOther: 0, diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false,
            architecture: .arm64, startTime: Date(timeIntervalSince1970: 0), uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
    }

    private let chrome = "/Applications/Google Chrome.app"

    func testOutermostAppBundle() {
        XCTAssertEqual(
            AppGrouping.appBundlePath(
                forExecutable:
                    "\(chrome)/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
            ), chrome)
        XCTAssertNil(AppGrouping.appBundlePath(forExecutable: "/bin/zsh"))
        XCTAssertNil(AppGrouping.appBundlePath(forExecutable: nil))
        XCTAssertEqual(AppGrouping.appName(forBundlePath: chrome), "Google Chrome")
    }

    func testHelpersJoinTheirAppAndTotalsAdd() {
        let groups = AppGrouping.group([
            sample(
                10, "Google Chrome", path: "\(chrome)/Contents/MacOS/Google Chrome",
                footprint: 100, cpu: 1),
            sample(
                11, "Google Chrome Helper",
                path:
                    "\(chrome)/Contents/Frameworks/X.framework/Helpers/Helper.app/Contents/MacOS/Helper",
                ppid: 10, footprint: 50, cpu: 2.5),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, chrome)
        XCTAssertEqual(groups[0].name, "Google Chrome")
        XCTAssertEqual(groups[0].processes.map(\.pid), [10, 11])
        XCTAssertEqual(groups[0].physFootprint, 150)
        XCTAssertEqual(groups[0].cpuPercent, 3.5)
    }

    func testXPCServiceJoinsResponsibleApp() {
        let safari = "/Applications/Safari.app"
        let groups = AppGrouping.group([
            sample(20, "Safari", path: "\(safari)/Contents/MacOS/Safari"),
            sample(
                21, "com.apple.WebKit.WebContent",
                path:
                    "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                ppid: 1, responsible: 20),
        ])
        XCTAssertEqual(groups.map(\.id), [safari])
        XCTAssertEqual(groups[0].processes.count, 2)
    }

    func testShellJoinsTerminalThroughAncestors() {
        let terminal = "/System/Applications/Utilities/Terminal.app"
        let groups = AppGrouping.group([
            sample(30, "Terminal", path: "\(terminal)/Contents/MacOS/Terminal"),
            sample(31, "login", path: "/usr/bin/login", ppid: 30),
            sample(32, "zsh", path: "/bin/zsh", ppid: 31),
            sample(33, "node", path: "/opt/homebrew/bin/node", ppid: 32),
        ])
        XCTAssertEqual(groups.map(\.id), [terminal])
        XCTAssertEqual(groups[0].processes.map(\.pid), [30, 31, 32, 33])
    }

    func testDaemonsStayApartButCollectTheirResponsibleChildren() {
        let groups = AppGrouping.group([
            sample(40, "beam.smp", path: "/opt/homebrew/bin/beam.smp"),
            sample(41, "epmd", path: "/opt/homebrew/bin/epmd", ppid: 40, responsible: 40),
            sample(50, "mds", path: "/System/Library/Frameworks/mds"),
        ])
        XCTAssertEqual(groups.map(\.id), ["pid:40", "pid:50"])
        XCTAssertEqual(groups[0].name, "beam.smp")
        XCTAssertEqual(groups[0].processes.map(\.pid), [40, 41])
    }

    func testParentCycleDoesNotHang() {
        let groups = AppGrouping.group([
            sample(60, "a", path: "/usr/bin/a", ppid: 61),
            sample(61, "b", path: "/usr/bin/b", ppid: 60),
        ])
        XCTAssertEqual(groups.flatMap(\.processes).count, 2)
    }
}
