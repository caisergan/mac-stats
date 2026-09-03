import XCTest

@testable import MacPerfMonitorCore

/// The parts of the sensors layer that do not need an SMC: platform
/// resolution, the catalogue's per-generation split, the formatting, and the
/// panel's ordering rule.
final class SensorsTests: XCTestCase {

    // MARK: - Platform

    func testPlatformResolvesFromTheBrandString() {
        XCTAssertEqual(SensorPlatform.resolve("Apple M1"), .m1)
        XCTAssertEqual(SensorPlatform.resolve("Apple M1 Pro"), .m1Pro)
        XCTAssertEqual(SensorPlatform.resolve("Apple M2 Max"), .m2Max)
        XCTAssertEqual(SensorPlatform.resolve("Apple M3 Ultra"), .m3Ultra)
        XCTAssertEqual(SensorPlatform.resolve("Apple M4"), .m4)
        XCTAssertEqual(SensorPlatform.resolve("Apple M5"), .m5)
        XCTAssertEqual(
            SensorPlatform.resolve("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"), .intel)
    }

    /// The families are matched newest first, so the "m1" inside a longer name
    /// can never claim an M5 machine.
    func testPlatformDoesNotMatchAnOlderFamilyInsideANewerName() {
        XCTAssertEqual(SensorPlatform.resolve("Apple M5 Pro (m1 compatible)"), .m5Pro)
    }

    func testPlatformIsNilForAnUnrecognisedChip() {
        XCTAssertNil(SensorPlatform.resolve("Some Future Silicon"))
        XCTAssertNil(SensorPlatform.resolve(nil))
    }

    // MARK: - Catalogue

    /// The same key means different silicon on different chips, which is the
    /// whole reason the catalogue is filtered before anything is named.
    func testTheSameKeyIsNamedPerGeneration() {
        func name(_ key: String, on platform: SensorPlatform) -> String? {
            SensorCatalog.entries(for: platform).first { $0.key == key }?.name
        }
        XCTAssertEqual(name("Tp01", on: .m2), "CPU performance core 1")
        XCTAssertEqual(name("Tp01", on: .m4), "CPU performance core 1")
        // The M5 table has no Tp01 at all: its low Tp keys are super cores.
        XCTAssertNil(name("Tp01", on: .m5))
        XCTAssertEqual(name("Tp00", on: .m5), "CPU super core 1")
    }

    /// Intel-era CPU and GPU keys are Intel only here, unlike in Stats: on
    /// Apple silicon `TG0H` is a live key holding a frozen value.
    func testIntelEraKeysAreNotOfferedOnAppleSilicon() {
        let apple = SensorCatalog.entries(for: .m5).map(\.key)
        for key in ["TG0H", "TG0D", "TG0P", "TC0D", "TC0P", "TN0D"] {
            XCTAssertFalse(apple.contains(key), "\(key) should be Intel only")
        }
        let intel = SensorCatalog.entries(for: .intel).map(\.key)
        XCTAssertTrue(intel.contains("TG0H"))
        XCTAssertTrue(intel.contains("TC0D"))
    }

    func testAnUnknownChipGetsTheWholeCatalogue() {
        XCTAssertEqual(SensorCatalog.entries(for: nil).count, SensorCatalog.all.count)
    }

    /// Only the per-core die sensors carry the average flag: folding a package
    /// or proximity sensor into the average would measure the same heat twice.
    func testOnlyPerCoreSensorsFeedTheAverages() {
        let averaged = SensorCatalog.entries(for: .m5).filter(\.average)
        XCTAssertFalse(averaged.isEmpty)
        for entry in averaged {
            XCTAssertEqual(entry.kind, .temperature)
            XCTAssertTrue(entry.domain == .cpu || entry.domain == .gpu)
        }
    }

    // MARK: - Formatting

    func testFormattedValueUsesThePrecisionOfItsKind() {
        func format(_ kind: SensorKind, _ value: Double) -> String {
            SensorReadingValue(
                key: "k", name: "n", kind: kind, domain: .sensor, value: value
            ).formattedValue
        }
        XCTAssertEqual(format(.temperature, 51.44), "51.4\u{00B0}C")
        XCTAssertEqual(format(.voltage, 20.4512), "20.451V")
        XCTAssertEqual(format(.current, 0.338), "0.34A")
        XCTAssertEqual(format(.power, 1.194), "1.19W")
        XCTAssertEqual(format(.energy, 0.071), "0.07Wh")
        XCTAssertEqual(format(.fan, 2500), "2500 RPM")
        // Past 100 the decimals stop earning their width.
        XCTAssertEqual(format(.power, 143.6), "143W")
    }

    func testMenuBarValueKeepsTheDegreeSignAndTightensTheDecimals() {
        func compact(_ kind: SensorKind, _ value: Double) -> String {
            SensorReadingValue(
                key: "k", name: "n", kind: kind, domain: .sensor, value: value
            ).menuBarValue
        }
        // The sign stays, the scale letter goes: "51\u{00B0}", not "51" or "51\u{00B0}C".
        XCTAssertEqual(compact(.temperature, 51.44), "51\u{00B0}")
        XCTAssertEqual(compact(.power, 1.94), "1.9W")
        XCTAssertEqual(compact(.power, 12.4), "12W")
        XCTAssertEqual(compact(.fan, 2500), "2500")
    }

    // MARK: - Fans

    func testFanPercentageIgnoresAPlaceholderRange() {
        XCTAssertEqual(SensorsReader.fanPercentage(value: 2500, maxSpeed: 6500), 38)
        // The SMC reports 1 for a fan whose range it does not know.
        XCTAssertEqual(SensorsReader.fanPercentage(value: 1, maxSpeed: 6500), 0)
        XCTAssertEqual(SensorsReader.fanPercentage(value: 2500, maxSpeed: 1), 0)
        XCTAssertEqual(SensorsReader.fanPercentage(value: 0, maxSpeed: 6500), 0)
    }

    // MARK: - Panel order

    /// Rows are grouped by domain in first-appearance order, keeping the
    /// reader's order inside each domain. That is what lands "Average CPU"
    /// under the cores it summarises instead of at the end of the section.
    func testPanelOrderGroupsByDomainInFirstAppearanceOrder() {
        func reading(_ key: String, _ domain: SensorDomain) -> SensorReadingValue {
            SensorReadingValue(
                key: key, name: key, kind: .temperature, domain: domain, value: 40)
        }
        let input = [
            reading("Airport", .system),
            reading("core 1", .cpu),
            reading("NAND", .system),
            reading("GPU 1", .gpu),
            reading("Average CPU", .cpu),
        ]
        XCTAssertEqual(
            SensorsPanelOrder.sorted(input).map(\.key),
            ["Airport", "NAND", "core 1", "Average CPU", "GPU 1"])
    }

    func testSectionOrderPutsFansFirstAndEnergyLast() {
        XCTAssertEqual(SensorKind.displayOrder.first, .fan)
        XCTAssertEqual(SensorKind.displayOrder.last, .energy)
        XCTAssertEqual(Set(SensorKind.displayOrder), Set(SensorKind.allCases))
    }
}
