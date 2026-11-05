import AppKit
import SwiftUI
import XCTest

@testable import MacPerfMonitor
@testable import MacPerfMonitorCore

@MainActor
final class MenuPanelTests: XCTestCase {
    func testFigureTextSeparatesTheNumberFromItsUnit() {
        XCTAssertEqual(MenuFigureText.split("15.4 GB").figure, "15.4")
        XCTAssertEqual(MenuFigureText.split("15.4 GB").unit, "GB")
        XCTAssertEqual(MenuFigureText.split("80%").figure, "80")
        XCTAssertEqual(MenuFigureText.split("80%").unit, "%")
        XCTAssertEqual(MenuFigureText.split("57\u{00B0}C").figure, "57")
        XCTAssertEqual(MenuFigureText.split("57\u{00B0}C").unit, "\u{00B0}C")
        XCTAssertEqual(MenuFigureText.split("15,4\u{00A0}Go").unit, "Go")
        XCTAssertEqual(MenuFigureText.split("--").figure, "--")
        XCTAssertEqual(MenuFigureText.split("--").unit, "")
    }

    func testCompactRateKeepsTheFigureAndTheUnitsFirstLetter() {
        XCTAssertEqual(MenuFigureText.compactRate("557 KB/s"), "557K")
        XCTAssertEqual(MenuFigureText.compactRate("48.7 MB/s"), "48.7M")
        XCTAssertEqual(MenuFigureText.compactRate("0 B/s"), "0B")
        // Not a rate: nothing to shorten.
        XCTAssertEqual(MenuFigureText.compactRate("17W"), "17W")
        XCTAssertEqual(MenuFigureText.compactRate("--"), "--")
    }

    func testTrailRatesComeFromNeighbouringCounters() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [0.0, 2, 4, 4, 6].map { start.addingTimeInterval($0) }
        // 10 B/s, then a counter reset reads as zero, a repeated moment is
        // skipped, and the counter carries on.
        XCTAssertEqual(
            MenuTrail.rates(counters: [100, 120, 50, 50, 70], dates: dates), [10, 0, 10])
        XCTAssertEqual(MenuTrail.rates(counters: [1], dates: [start]), [])
        XCTAssertEqual(MenuTrail.rates(counters: [1, 2], dates: [start]), [])
    }

    func testGroupPartsSumEachDirectionSeparately() {
        let metric = MenuRankedMetric(
            parts: { [$0.diskReadBytesPerSec, $0.diskWriteBytesPerSec] }, colors: [.blue, .orange],
            format: { "\($0)" }, trail: { _ in [] })
        let group = AppProcessGroup(
            id: "app", name: "App", iconPath: nil,
            processes: [
                MenuPanelFixtures.process("a", pid: 1, diskRead: 10, diskWrite: 100),
                MenuPanelFixtures.process("b", pid: 2, diskRead: 5, diskWrite: .nan),
            ])
        XCTAssertEqual(metric.parts(of: group), [15, 100])
    }

    func testHeightClampKeepsAShortTabAndCapsATallOne() {
        _ = NSApplication.shared
        func height(content: CGFloat, maximum: CGFloat) -> CGFloat {
            let host = NSHostingView(
                rootView: MenuPanelHeightClamp(maximum: maximum) {
                    ScrollView(.vertical) {
                        Color.clear.frame(height: content)
                    }
                }
                .frame(width: 380))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        XCTAssertEqual(height(content: 300, maximum: 620), 300, accuracy: 1)
        XCTAssertEqual(height(content: 900, maximum: 620), 620, accuracy: 1)
    }

    /// Every tab fits the panel's width and the screen, in both appearances, and
    /// follows its content rather than taking a fixed height. Set
    /// `MACPERF_PANEL_ARTIFACTS` to a folder to write each one out as a PNG.
    func testEveryTabRendersAtThePanelsWidth() async throws {
        _ = NSApplication.shared
        let panels: [(String, CombinedMenuBarPanel)] = [
            ("memory", .metric(.ram)), ("cpu", .metric(.cpu)), ("gpu", .metric(.gpu)),
            ("energy", .metric(.energy)), ("temperature", .metric(.temperature)),
            ("network", .metric(.network)), ("disk", .metric(.disk)),
            ("sensors", .metric(.sensors)), ("alerts", .alerts),
        ]
        let suite = "MenuPanelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MenuPanelFixtures.seededModel()
        let clock = MenuClock(source: model.liveTick.eraseToAnyPublisher())
        let updates = UpdateController(startingUpdater: false)
        let configuration = CombinedMenuBarConfiguration(defaults: defaults)
        let components = AppComponentsManager(defaults: defaults)
        let notch = NotchDisplayController(defaults: defaults)
        let appState = AppState()
        var heights: [String: CGFloat] = [:]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (name, panel) in panels {
                let selection = CombinedMenuBarPanelSelection(panel: panel)
                let appeared = expectation(description: "\(name) appears")
                let host = NSHostingView(
                    rootView: CombinedMenuBarContentView(
                        selection: selection, selectionChanged: { _ in }, dismiss: {}
                    )
                    .background(appearance == .aqua ? Color(white: 0.96) : Color(white: 0.12))
                    .environmentObject(model)
                    .environmentObject(model.menuLists)
                    .environmentObject(appState)
                    .environmentObject(configuration)
                    .environmentObject(updates)
                    .environmentObject(clock)
                    .environmentObject(components)
                    .environmentObject(notch)
                    .onAppear { DispatchQueue.main.async { appeared.fulfill() } })
                let window = NSWindow(
                    contentRect: CGRect(x: 100, y: 40, width: MenuPanelStyle.width, height: 800),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                await fulfillment(of: [appeared], timeout: 5)
                if name == "sensors" {
                    // The first sweep reads the real SMC on its own queue. A
                    // machine with no sensors simply shows the placeholder.
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                XCTAssertEqual(size.width, MenuPanelStyle.width, accuracy: 1, name)
                XCTAssertLessThanOrEqual(size.height, 800, name)
                XCTAssertGreaterThan(size.height, 150, name)
                heights[name] = size.height
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try capture(window, host, name: "\(name)-\(appearance.rawValue)")
            }
        }
        print("menu panel heights:", heights.sorted { $0.key < $1.key })
    }

    private func capture(_ window: NSWindow, _ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MACPERF_PANEL_ARTIFACTS"]
        else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name + ".png")
        let screenshot = Process()
        screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenshot.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try screenshot.run()
        screenshot.waitUntilExit()
        if screenshot.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        }
    }
}

/// A plausible Mac for the panel tests: a few grouped apps with history behind
/// them, so every tab has something to show.
@MainActor
enum MenuPanelFixtures {
    static func process(
        _ name: String, pid: Int32, path: String? = nil, footprint: UInt64 = 0, cpu: Double = 0,
        gpu: Double? = nil, energy: Double = 0, network: Double = 0, diskRead: Double = 0,
        diskWrite: Double = 0, at timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        ppid: Int32 = 1
    ) -> ProcessSample {
        var sample = ProcessSample(
            timestamp: timestamp, pid: pid, ppid: ppid, name: name,
            physFootprint: footprint, residentSize: footprint, virtualSize: 0,
            lifetimeMaxFootprint: footprint, cpuPercent: cpu, cpuTimeUser: 0, cpuTimeSystem: 0,
            threadCount: 1, fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, networkBytesPerSec: network,
            isTranslated: false, architecture: .arm64,
            startTime: Date(timeIntervalSince1970: 1_699_000_000), uid: 501,
            dataSource: .directUserRead, footprintReadable: true)
        sample.executablePath = path
        sample.gpuPercent = gpu
        sample.energyImpact = energy
        sample.diskReadBytesPerSec = diskRead
        sample.diskWriteBytesPerSec = diskWrite
        return sample
    }

    private static func processes(at date: Date, wobble: Double) -> [ProcessSample] {
        let search = "/Applications/Search.app/Contents/Frameworks/Search Helper.app/Helper"
        let mono = "/Applications/Monocode Native.app/Contents/MacOS/monocode"
        return [
            process(
                "Search Helper (Renderer)", pid: 101, path: search, footprint: 1_900_000_000,
                cpu: 18 + wobble, gpu: 7, energy: 21, network: 3_100, diskRead: 1_000,
                diskWrite: 32_000, at: date),
            process(
                "Search", pid: 100, path: "/Applications/Search.app/Contents/MacOS/Search",
                footprint: 1_700_000_000, cpu: 6, gpu: 2.3, energy: 6, network: 100,
                diskRead: 3_000, diskWrite: 280_000, at: date),
            process(
                "Monocode Native", pid: 200, path: mono, footprint: 4_200_000_000, cpu: 14,
                gpu: 1.9, energy: 14, network: 300, diskRead: 1_000, diskWrite: 7_000, at: date),
            process(
                "Monocode Helper", pid: 201, path: mono, footprint: 900_000_000, cpu: 6 + wobble,
                gpu: 0.2, energy: 10, network: 3_800, diskWrite: 2_000, at: date),
            process(
                "WindowServer", pid: 300, path: "/System/Library/WindowServer",
                footprint: 1_100_000_000,
                cpu: 9.6, gpu: 31, energy: 12, at: date),
            process(
                "Mac Performance Monitor", pid: 400,
                path: "/Applications/Mac Performance Monitor.app/Contents/MacOS/monitor",
                footprint: 312_000_000, cpu: 5.8, energy: 6, diskWrite: 64_000, at: date),
            process(
                "cloudd", pid: 500, path: "/usr/libexec/cloudd", footprint: 210_000_000, cpu: 5,
                energy: 3, network: 812, diskRead: 2_000, diskWrite: 128_000, at: date),
            process(
                "accountsd", pid: 600, path: "/usr/libexec/accountsd", footprint: 96_000_000,
                cpu: 1.2, energy: 1, network: 210, diskWrite: 1_000, at: date),
        ]
    }

    private static func cpu(at date: Date, usage: Double) -> CPUSample {
        let performance: [CoreUsage] = (0..<4).map { index in
            CoreUsage(
                index: index, kind: .performance, usage: usage * 0.7, user: usage * 0.5,
                system: usage * 0.2)
        }
        let efficiency: [CoreUsage] = (4..<10).map { index in
            CoreUsage(
                index: index, kind: .efficiency, usage: usage * 1.3, user: usage,
                system: usage * 0.3)
        }
        return CPUSample(
            timestamp: date, totalUsage: usage, userFraction: usage * 0.7,
            systemFraction: usage * 0.3, idleFraction: 1 - usage,
            cores: performance + efficiency, performanceUsage: usage * 0.7,
            efficiencyUsage: usage * 1.3, performanceCoreCount: 4, efficiencyCoreCount: 6,
            loadAverage1: 2, loadAverage5: 2, loadAverage15: 2)
    }

    static func seededModel() -> SamplerModel {
        let model = SamplerModel(persistenceEnabled: false)
        let now = Date()
        let gigabyte: UInt64 = 1_073_741_824
        var gpu = GPUSample(
            utilization: 51, renderUtilization: 47, tilerUtilization: 23,
            inUseMemoryBytes: 2 * gigabyte, name: "Apple M5")
        gpu.coreCount = 10
        gpu.gpuPowerWatts = 3.12
        gpu.cpuPowerWatts = 2.84
        gpu.dieTemperatureC = 54
        gpu.fanRPM = 0
        gpu.aneTimeMillisecondsPerSecond = 182
        gpu.aneSampleIsPartial = false
        gpu.anePowerWatts = 0.42
        gpu.sampledAt = now
        let device = DiskDeviceSample(
            registryEntryID: 1, bsdName: "disk0", model: "APPLE SSD AP1024Z",
            protocolName: "Apple Fabric", sizeBytes: 994_660_000_000, isInternal: true,
            isRemovable: false, readBytesPerSec: 8_000, writeBytesPerSec: 557_000,
            readOperationsPerSec: 2, writeOperationsPerSec: 41,
            averageReadTimeMilliseconds: 0.21, averageWriteTimeMilliseconds: 0.38,
            readErrors: 0, writeErrors: 0, readRetries: 0, writeRetries: 0)
        for index in 0..<31 {
            let date = now.addingTimeInterval(Double(index - 30))
            var system = SystemSample(
                timestamp: date, totalRAM: 24 * gigabyte, free: 6 * gigabyte, active: 0,
                inactive: 0, wired: 2 * gigabyte + 400_000_000, speculative: 0,
                compressed: 4 * gigabyte, appMemory: 9 * gigabyte, cachedFiles: gigabyte,
                swapTotal: 0, swapUsed: 0, pressureLevel: .normal,
                pressurePercent: 23 + sin(Double(index) / 4) * 2, pageIns: 0, pageOuts: 0,
                compressions: 0, decompressions: 0)
            system.cpuDieC = 57 + sin(Double(index) / 5) * 3
            system.gpuDieC = 54
            system.ssdTemperatureC = 39
            system.fanRPM = 0
            system.networkInBytesPerSec = index % 7 < 2 ? 1_100_000 : 2_000
            system.networkOutBytesPerSec = index % 9 < 2 ? 340_000 : 8_000
            system.diskReadBytesPerSec = index % 9 < 2 ? 900_000 : 8_000
            system.diskWriteBytesPerSec = 557_000 + sin(Double(index)) * 200_000
            system.batteryCharge = 84 - Double(index) / 8
            system.aneTimeMillisecondsPerSecond = 182 + sin(Double(index) / 3) * 120
            system.aneSampleIsPartial = false
            system.anePowerWatts = 0.42 + sin(Double(index) / 3) * 0.2
            system.anePowerSampledAt = date
            system.anePowerSampleInterval = 1
            let disk = DiskSample(
                timestamp: date, readBytesPerSec: index % 9 == 0 ? 900_000 : 8_000,
                writeBytesPerSec: 557_000 + sin(Double(index)) * 200_000,
                readOperationsPerSec: 2, writeOperationsPerSec: 41, devices: [device])
            let network = NetworkSample(
                timestamp: date, inBytesPerSec: index % 7 == 0 ? 1_100_000 : 2_000,
                outBytesPerSec: 8_000, sessionInBytes: 1_420_000_000, sessionOutBytes: 214_000_000,
                primaryInterface: "en0", localIPv4: "192.168.1.24")
            let battery = BatterySample(
                timestamp: date, isPresent: true, chargePercent: 84 - Double(index) / 8,
                timeToEmptyMinutes: 300, powerWatts: 16)
            model.publishForBenchmark(
                .init(
                    system: system,
                    processes: processes(at: date, wobble: sin(Double(index) / 2) * 4),
                    unreadableProcessCount: 0,
                    cpu: cpu(at: date, usage: 0.15 + Double(index % 11) / 40)),
                gpu: gpu, network: network, disk: disk, battery: battery)
        }
        let live = processes(at: now, wobble: 0)
        func apps(_ value: (ProcessSample) -> Double) -> [AppProcessGroup] {
            AppGrouping.group(live)
                .map { group -> AppProcessGroup in
                    var group = group
                    group.processes.sort { value($0) > value($1) }
                    return group
                }
                .sorted {
                    $0.processes.reduce(0) { $0 + value($1) }
                        > $1.processes.reduce(0) { $0 + value($1) }
                }
        }
        let lists: [(MenuListKind, (ProcessSample) -> Double)] = [
            (.footprint, { Double($0.physFootprint) }), (.cpu, { $0.cpuPercent }),
            (.energy, { $0.energyImpact }), (.network, { $0.networkBytesPerSec }),
            (.disk, { $0.diskReadBytesPerSec + $0.diskWriteBytesPerSec }),
            (.gpu, { $0.gpuPercent ?? 0 }),
        ]
        for (kind, value) in lists {
            model.menuLists.update(kind, with: live.sorted { value($0) > value($1) })
            model.menuLists.updateApps(kind, with: apps(value))
        }
        return model
    }
}
