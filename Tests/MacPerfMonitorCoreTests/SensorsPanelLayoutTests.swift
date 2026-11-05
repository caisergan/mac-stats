import XCTest

@testable import MacPerfMonitorCore

final class SensorsPanelLayoutTests: XCTestCase {
    /// The readings `macperfmonitor-cli sensors` printed on an M5 MacBook, which
    /// is what the panel's arrangement was designed against.
    private var m5Readings: [SensorReadingValue] {
        func reading(
            _ name: String, _ kind: SensorKind, _ domain: SensorDomain, _ value: Double,
            computed: Bool = false, core: Bool = false
        ) -> SensorReadingValue {
            // Only derived readings have a key that names them. An SMC reading's
            // key is its code, so nothing here may rely on it saying what it is.
            SensorReadingValue(
                key: computed ? name : "SMC \(name) \(kind.rawValue)", name: name, kind: kind,
                domain: domain, value: value, isComputed: computed, isCore: core)
        }
        let cpuCores = [
            ("CPU super core 1", 58.6), ("CPU super core 2", 57.6), ("CPU super core 4", 58.9),
            ("CPU super core 5", 57.2), ("CPU performance core 1", 57.6),
            ("CPU performance core 2", 56.7), ("CPU performance core 4", 57.8),
            ("CPU performance core 5", 56.5), ("CPU performance core 10", 55.0),
            ("CPU performance core 11", 55.1), ("CPU performance core 12", 55.0),
        ]
        return [reading("Fan #0", .fan, .sensor, 0)]
            + [
                reading("Airport", .temperature, .sensor, 42.5),
                reading("Battery 2", .temperature, .sensor, 33.0),
                reading("NAND", .temperature, .sensor, 38.9),
            ]
            + cpuCores.map { reading($0.0, .temperature, .cpu, $0.1, core: true) }
            + [
                reading("Average CPU", .temperature, .cpu, 56.9, computed: true),
                reading("Hottest CPU", .temperature, .cpu, 58.9, computed: true),
            ]
            + (1...8).map { reading("GPU \($0)", .temperature, .gpu, 54, core: true) }
            + [
                reading("Average GPU", .temperature, .gpu, 53.9, computed: true),
                reading("Hottest GPU", .temperature, .gpu, 54, computed: true),
                reading("DC In", .voltage, .sensor, 20.412),
                reading("12V rail", .voltage, .sensor, 12.516),
                reading("DC In", .current, .sensor, 0.6),
                reading("Battery", .power, .sensor, 1.21),
                reading("DC In", .power, .sensor, 12.17),
                reading("System Total", .power, .sensor, 16.04),
                reading("Average System Total", .power, .sensor, 16.04, computed: true),
                reading("GPU Power", .power, .gpu, 0.04, computed: true),
                reading("CPU Power", .power, .cpu, 0.39, computed: true),
                reading("ANE Power", .power, .system, 0, computed: true),
                reading("RAM Power", .power, .system, 0.13, computed: true),
                reading("Total System Consumption", .energy, .sensor, 0.01, computed: true),
            ]
    }

    func testEveryReadingLandsInExactlyOnePlace() {
        let readings = m5Readings
        let layout = SensorsPanelLayout(readings: readings)
        let placed =
            [layout.systemTotal, layout.cpuAverage, layout.gpuAverage].compactMap { $0 }
            + layout.hottest + layout.fans + layout.cpuCores + layout.gpuCores
            + layout.otherTemperatures + layout.supply + layout.components + layout.totals
        XCTAssertEqual(placed.count, readings.count)
        XCTAssertEqual(Set(placed.map(\.key)), Set(readings.map(\.key)))
    }

    func testReadingsGoWhereTheyAnswerSomething() {
        let layout = SensorsPanelLayout(readings: m5Readings)
        XCTAssertEqual(layout.systemTotal?.name, "System Total")
        XCTAssertEqual(layout.hottest.map(\.name), ["Hottest CPU", "Hottest GPU"])
        XCTAssertEqual(layout.fans.map(\.name), ["Fan #0"])
        XCTAssertEqual(layout.cpuCores.count, 11)
        XCTAssertEqual(layout.gpuCores.count, 8)
        XCTAssertEqual(layout.cpuAverage?.value, 56.9)
        XCTAssertEqual(layout.gpuAverage?.value, 53.9)
        XCTAssertEqual(
            layout.totals.map(\.name), ["Average System Total", "Total System Consumption"])
    }

    func testOtherTemperaturesAndComponentsLeadWithTheHighest() {
        let layout = SensorsPanelLayout(readings: m5Readings)
        XCTAssertEqual(layout.otherTemperatures.map(\.name), ["Airport", "NAND", "Battery 2"])
        XCTAssertEqual(
            layout.components.map(\.name), ["CPU Power", "RAM Power", "GPU Power", "ANE Power"])
    }

    func testSupplyPutsWattsAheadOfTheRails() {
        let layout = SensorsPanelLayout(readings: m5Readings)
        XCTAssertEqual(
            layout.supply.map(\.name), ["DC In", "Battery", "DC In", "12V rail", "DC In"])
        XCTAssertEqual(layout.supply.prefix(2).map(\.kind), [.power, .power])
    }

    func testSupplyLabelsTellSharedNamesApart() {
        let layout = SensorsPanelLayout(readings: m5Readings)
        func label(_ name: String, _ kind: SensorKind, _ kindName: String) throws -> String {
            let reading = try XCTUnwrap(
                layout.supply.first { $0.name == name && $0.kind == kind })
            return layout.supplyLabel(reading, kindName: kindName)
        }
        XCTAssertEqual(try label("DC In", .power, "Power"), "DC In")
        XCTAssertEqual(try label("DC In", .voltage, "Voltage"), "DC In voltage")
        XCTAssertEqual(try label("DC In", .current, "Current"), "DC In current")
        XCTAssertEqual(try label("12V rail", .voltage, "Voltage"), "12V rail")
    }

    func testUnknownReadingsAreLeftOut() {
        let unknown = SensorReadingValue(
            key: "Tx0A", name: "Tx0A", kind: .temperature, domain: .unknown, value: 40)
        XCTAssertEqual(SensorsPanelLayout(readings: [unknown]).otherTemperatures, [])
    }

    func testAMacWithoutPerCoreSensorsStillListsItsTemperatures() {
        let layout = SensorsPanelLayout(
            readings: [
                SensorReadingValue(
                    key: "GPU diode", name: "GPU diode", kind: .temperature, domain: .gpu, value: 50
                )
            ])
        XCTAssertTrue(layout.gpuCores.isEmpty)
        XCTAssertEqual(layout.otherTemperatures.map(\.key), ["GPU diode"])
    }

    func testCoreLabelsNameTheClusterAndNumber() {
        XCTAssertEqual(SensorsPanelLayout.coreLabel("CPU super core 4"), "S4")
        XCTAssertEqual(SensorsPanelLayout.coreLabel("CPU performance core 10"), "P10")
        XCTAssertEqual(SensorsPanelLayout.coreLabel("CPU efficiency core 2"), "E2")
        XCTAssertEqual(SensorsPanelLayout.coreLabel("CPU core 3"), "3")
        XCTAssertEqual(SensorsPanelLayout.coreLabel("GPU 5"), "5")
        XCTAssertEqual(SensorsPanelLayout.coreLabel("Thermal"), "The")
    }

    func testComponentLabelDropsTheWordItsColumnStates() {
        XCTAssertEqual(SensorsPanelLayout.componentLabel("CPU Power"), "CPU")
        XCTAssertEqual(SensorsPanelLayout.componentLabel("Heatpipe"), "Heatpipe")
    }
}
