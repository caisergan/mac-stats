import AppKit
import MacPerfMonitorCore
import XCTest

@testable import MacPerfMonitor

@MainActor
final class CompactMenuBarTests: XCTestCase {
    func testCompactIsTheDefaultDesignAndNotAClassicShape() throws {
        let suite = "MacPerfMonitorTests.MenuBarDesign.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CombinedMenuBarConfiguration(defaults: defaults)

        XCTAssertEqual(configuration.design, .compact)
        for metric in MenuBarMetric.allCases {
            XCTAssertEqual(configuration.effectiveStyles[metric], .compact, "\(metric)")
            XCTAssertFalse(
                MenuBarWidgetStyle.supported(for: metric).contains(.compact), "\(metric)")
            XCTAssertNotEqual(MenuBarWidgetStyle.default(for: metric), .compact, "\(metric)")
        }
        // Compact cannot be stored as a Classic shape.
        configuration.setStyle(.compact, for: .cpu)
        XCTAssertEqual(configuration.style(for: .cpu), .mini)
    }

    func testClassicKeepsEveryEarlierChoiceAndCompactKeepsItsOwnColours() throws {
        let suite = "MacPerfMonitorTests.MenuBarDesign.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A setup saved before Compact existed.
        defaults.set(
            ["energy": "batteryDetails", "network": "speed", "cpu": "lineChart"],
            forKey: CombinedMenuBarConfiguration.stylesDefaultsKey)
        defaults.set(
            ["cpu": false, "ram": false], forKey: CombinedMenuBarConfiguration.colorDefaultsKey)

        let configuration = CombinedMenuBarConfiguration(defaults: defaults)
        // Compact draws everything one way and ignores the Classic colour-offs.
        XCTAssertEqual(configuration.effectiveStyles[.energy], .compact)
        XCTAssertTrue(configuration.isColored(.cpu))
        configuration.setColored(false, for: .gpu)

        configuration.design = .classic
        XCTAssertEqual(configuration.effectiveStyles[.energy], .batteryDetails)
        XCTAssertEqual(configuration.effectiveStyles[.cpu], .lineChart)
        XCTAssertNil(configuration.effectiveStyles[.ram])
        XCTAssertFalse(configuration.isColored(.cpu))
        XCTAssertFalse(configuration.isColored(.ram))
        // The colour switched off under Compact stays a Compact choice.
        XCTAssertTrue(configuration.isColored(.gpu))

        let reopened = CombinedMenuBarConfiguration(defaults: defaults)
        XCTAssertEqual(reopened.design, .classic)
        reopened.design = .compact
        XCTAssertFalse(reopened.isColored(.gpu))
        XCTAssertTrue(reopened.isColored(.cpu))
    }

    func testCompactBatteryFillFollowsTheCharge() {
        func fill(_ charge: Double, lowPower: Bool = false, colored: Bool = true) -> NSColor {
            StatsMenuBarWidgets.compactBatteryFill(
                charge: charge, isLowPowerMode: lowPower, isColored: colored, isDark: true)
        }
        XCTAssertEqual(fill(1.0), .systemGreen)
        XCTAssertEqual(fill(0.41), .systemGreen)
        XCTAssertEqual(fill(0.40), .systemYellow)
        XCTAssertEqual(fill(0.20), .systemYellow)
        XCTAssertEqual(fill(0.19), .systemRed)
        XCTAssertEqual(fill(0.80, lowPower: true), .systemMint)
        // With the colour switch off only the flat-battery warning survives.
        XCTAssertEqual(fill(0.80, colored: false), StatsMenuBarWidgets.textColor(true))
        XCTAssertEqual(fill(0.10, colored: false), .systemRed)
    }

    func testVerdictThresholds() {
        func cpu(_ fraction: Double, alarm: Bool = false) -> MenuBarVerdict {
            CombinedMenuBarReadout(
                metric: .cpu, value: "", isAlarm: alarm, fraction: fraction
            ).verdict
        }
        XCTAssertEqual(cpu(0.69), .calm)
        XCTAssertEqual(cpu(0.70), .elevated)
        XCTAssertEqual(cpu(0.90), .strained)
        XCTAssertEqual(cpu(0.10, alarm: true), .strained)

        // Memory follows pressure, not the share of RAM in use.
        var ram = CombinedMenuBarReadout(metric: .ram, value: "", isAlarm: false, fraction: 0.95)
        XCTAssertEqual(ram.verdict, .calm)
        ram.pressureLevel = .warning
        XCTAssertEqual(ram.verdict, .elevated)
        ram.pressureLevel = .critical
        XCTAssertEqual(ram.verdict, .strained)

        // A low battery only counts off the charger.
        var battery = CombinedMenuBarReadout(
            metric: .energy, value: "8%", isAlarm: false, batteryCharge: 0.08,
            isBatteryPresent: true, isOnAC: true)
        XCTAssertEqual(battery.verdict, .calm)
        battery.isOnAC = false
        XCTAssertEqual(battery.verdict, .strained)
        battery.batteryCharge = 0.18
        XCTAssertEqual(battery.verdict, .elevated)

        let network = CombinedMenuBarReadout(
            metric: .network, value: "900 MB/s", isAlarm: false, fraction: 1)
        XCTAssertEqual(network.verdict, .calm)
    }

    func testOnlyTemperatureSensorsCarryAVerdict() {
        XCTAssertEqual(
            MenuBarSensorCell(kind: .temperature, text: "80°", templates: [], value: 79.6)
                .verdict, .elevated)
        XCTAssertEqual(
            MenuBarSensorCell(kind: .temperature, text: "95°", templates: [], value: 95)
                .verdict, .strained)
        XCTAssertEqual(
            MenuBarSensorCell(kind: .power, text: "99W", templates: [], value: 99).verdict,
            .calm)
    }

    func testDirectionArrowsTintOnlyOnceTheFigureIsNonZero() {
        let readout = CombinedMenuBarReadout(
            metric: .network, value: "1 KB/s", secondaryValue: "0 KB/s", isAlarm: false,
            primaryBytesPerSec: 1000, secondaryBytesPerSec: 999)
        XCTAssertTrue(readout.isDirectionActive(input: true))
        XCTAssertFalse(readout.isDirectionActive(input: false))
    }

    func testCompactCellHoldsItsWidthAsTheFigureMoves() {
        func width(_ value: String) -> CGFloat {
            var readout = CombinedMenuBarReadout(metric: .cpu, value: value, isAlarm: false)
            readout.valueTemplate = MenuBarMetric.cpu.menuBarValueTemplate
            return StatsMenuBarWidgets.cell(for: readout, style: .compact, isDark: true).width
        }
        XCTAssertEqual(width("5%"), width("26%"))
        XCTAssertEqual(width("26%"), width("100%"))
    }

    func testBatteryShowsItsTimeWhileChargingAndDischargingAndNothingWithoutOne() {
        func width(time: String?, charging: Bool) -> CGFloat {
            var readout = CombinedMenuBarReadout(
                metric: .energy, value: "80%", isAlarm: false, batteryCharge: 0.8,
                isBatteryCharging: charging, isBatteryPresent: true, isOnAC: charging,
                batteryTimeText: time)
            readout.valueTemplate = MenuBarMetric.energy.menuBarValueTemplate
            return StatsMenuBarWidgets.cell(for: readout, style: .compact, isDark: true).width
        }
        let withoutTime = width(time: nil, charging: true)
        XCTAssertGreaterThan(width(time: "0:52", charging: true), withoutTime)
        XCTAssertGreaterThan(width(time: "4:28", charging: false), withoutTime)
        // No "n/a" placeholder: a missing estimate takes no room at all.
        XCTAssertEqual(withoutTime, width(time: nil, charging: false))
    }

    func testTextSizePersistsAndFallsBackToTheMenuBarSize() throws {
        let suite = "MacPerfMonitorTests.CompactTextSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CombinedMenuBarConfiguration(defaults: defaults).textSize, 13)
        CombinedMenuBarConfiguration(defaults: defaults).textSize = 11
        XCTAssertEqual(CombinedMenuBarConfiguration(defaults: defaults).textSize, 11)
        // A stored size Settings no longer offers falls back to the default.
        defaults.set(40, forKey: CombinedMenuBarConfiguration.textSizeDefaultsKey)
        XCTAssertEqual(CombinedMenuBarConfiguration(defaults: defaults).textSize, 13)
    }

    func testTextSizeScalesEveryCompactShape() {
        func width(_ metric: MenuBarMetric, size: CGFloat) -> CGFloat {
            var readout = CombinedMenuBarReadout(
                metric: metric, value: "80%", secondaryValue: metric == .network ? "1 KB/s" : nil,
                isAlarm: false, batteryCharge: 0.8, isBatteryPresent: true,
                batteryTimeText: "0:52")
            readout.valueTemplate = metric.menuBarValueTemplate
            readout.sensorCells = [
                MenuBarSensorCell(kind: .power, text: "21W", templates: ["0.0W"], value: 21)
            ]
            readout.compactTextSize = size
            return StatsMenuBarWidgets.cell(for: readout, style: .compact, isDark: true).width
        }
        for metric: MenuBarMetric in [.cpu, .energy, .sensors, .network] {
            XCTAssertLessThan(width(metric, size: 10), width(metric, size: 13), "\(metric)")
            XCTAssertLessThan(width(metric, size: 13), width(metric, size: 15), "\(metric)")
        }
    }
}
