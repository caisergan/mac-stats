import XCTest

@testable import MacPerfMonitorCore

/// GeoLocator against the real GeoLite2 database when the user has installed
/// it (the license forbids shipping one in the repo); otherwise skipped. The
/// no-database paths are always exercised.
final class GeoLocatorTests: XCTestCase {
    func testMissingDatabaseFailsToOpen() {
        XCTAssertNil(GeoLocator(url: URL(fileURLWithPath: "/nonexistent.mmdb")))
    }

    func testGarbageFileFailsToOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("geo-garbage-\(UUID().uuidString).mmdb")
        try Data(repeating: 0x51, count: 4_096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(GeoLocator(url: url))
    }

    func testPublicLookupAgainstInstalledDatabase() throws {
        let url = GeoLocator.defaultDatabaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("GeoLite2 database not installed")
        }
        let locator = try XCTUnwrap(GeoLocator(url: url))
        let info = try XCTUnwrap(locator.lookup("8.8.8.8"))
        XCTAssertEqual(info.countryCode, "US")
        // Private space has no geo entry.
        XCTAssertNil(locator.lookup("192.168.1.1"))
    }
}
