import XCTest

@testable import MacPerfMonitorCore

final class MenuTrendHistoryTests: XCTestCase {
    /// A multiple of 30 seconds, so it starts a bucket at every range width and
    /// the expected groupings below are exact.
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_010)

    private func history(
        seconds: ClosedRange<Int>, step: Int = 1, value: (Int) -> Double?
    ) -> MenuTrendHistory {
        var history = MenuTrendHistory()
        for second in stride(from: seconds.lowerBound, through: seconds.upperBound, by: step) {
            history.append(at: origin.addingTimeInterval(TimeInterval(second))) { metric in
                metric == .cpuLoad ? value(second) : nil
            }
        }
        return history
    }

    func testEveryRangeFitsThePanelWithoutPlottingEverySample() {
        XCTAssertNil(MenuChartRange.oneMinute.bucketSeconds)
        for range in MenuChartRange.allCases {
            guard let width = range.bucketSeconds else { continue }
            let slots = range.seconds / width
            XCTAssertGreaterThanOrEqual(slots, 60, "\(range)")
            XCTAssertLessThanOrEqual(slots, 120, "\(range)")
            XCTAssertEqual(
                width.truncatingRemainder(dividingBy: MenuTrendHistory.baseBucket), 0, "\(range)")
        }
    }

    func testBucketsKeepTheTrueMeanAndTheRealExtremes() throws {
        // One spike in an otherwise flat ten seconds.
        let history = history(seconds: 0...9) { $0 == 7 ? 100 : 10 }
        let series = history.series(.cpuLoad, range: .fifteenMinutes)

        XCTAssertEqual(series.capacity, 90)
        XCTAssertEqual(series.values.count, 1)
        XCTAssertEqual(series.values[0], (9 * 10 + 100) / 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(series.minima)[0], 10)
        XCTAssertEqual(try XCTUnwrap(series.maxima)[0], 100)
        XCTAssertEqual(series.top, 100)
        XCTAssertEqual(series.dates, [origin])
    }

    func testWiderRangesMergeTheFiveSecondBuckets() {
        let history = history(seconds: 0...59) { Double($0) }

        let five = history.series(.cpuLoad, range: .fiveMinutes)
        XCTAssertEqual(five.values.count, 12)
        XCTAssertEqual(five.values.first, 2)
        XCTAssertEqual(five.dates[1], origin.addingTimeInterval(5))

        let hour = history.series(.cpuLoad, range: .oneHour)
        XCTAssertEqual(hour.capacity, 120)
        XCTAssertEqual(hour.values, [14.5, 44.5])
        XCTAssertEqual(hour.minima, [0, 30])
        XCTAssertEqual(hour.maxima, [29, 59])
    }

    func testMissingReadingsLeaveAGapRatherThanAZero() throws {
        // The metric is only measured in the first and last five seconds.
        let history = history(seconds: 0...14) { $0 < 5 || $0 >= 10 ? 50 : nil }
        let series = history.series(.cpuLoad, range: .fiveMinutes)
        XCTAssertEqual(series.values.count, 3)
        XCTAssertEqual(series.values[0], 50)
        XCTAssertTrue(series.values[1].isNaN)
        XCTAssertTrue(try XCTUnwrap(series.maxima)[1].isNaN)
        XCTAssertEqual(series.values[2], 50)
        XCTAssertEqual(series.dates[1], origin.addingTimeInterval(5))
        XCTAssertEqual(series.top, 50)
        XCTAssertTrue(history.series(.gpuUtilization, range: .fiveMinutes).values.isEmpty)
    }

    func testTimeTheAppWasNotRunningStaysAGap() {
        // A recorded stretch, forty minutes with nothing, then live samples.
        var history = history(seconds: 600...899) { _ in 80 }
        history.prepend(self.history(seconds: 0...299) { _ in 20 })
        let hour = history.series(.cpuLoad, range: .oneHour)

        XCTAssertEqual(hour.values.count, 30)
        XCTAssertEqual(hour.dates.first, origin)
        XCTAssertEqual(hour.values.prefix(10), Array(repeating: 20, count: 10)[...])
        XCTAssertTrue(hour.values[10..<20].allSatisfy(\.isNaN))
        XCTAssertEqual(hour.values.suffix(10), Array(repeating: 80, count: 10)[...])
    }

    func testPrependKeepsTheLiveReadingsOfASharedBucket() {
        // Seconds 0 to 9 recorded, but the live ring began at second 7: the
        // bucket from 5 to 9 is in both, and the live half of it wins.
        var history = history(seconds: 7...9) { _ in 90 }
        history.prepend(self.history(seconds: 0...9) { _ in 10 })
        let series = history.series(.cpuLoad, range: .fiveMinutes)
        XCTAssertEqual(series.values, [10, 90])
    }

    func testPrependIntoAnEmptyHistoryTakesItWhole() {
        var history = MenuTrendHistory()
        history.prepend(self.history(seconds: 0...9) { _ in 10 })
        XCTAssertEqual(history.series(.cpuLoad, range: .fiveMinutes).values, [10, 10])
    }

    func testOnlyTheLastHourIsKept() {
        let history = history(seconds: 0...7200, step: 5) { Double($0) }
        let hour = history.series(.cpuLoad, range: .oneHour)
        XCTAssertEqual(hour.values.count, 120)
        XCTAssertEqual(hour.dates.last, origin.addingTimeInterval(7200))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(hour.minima?.first), 3600)

        let five = history.series(.cpuLoad, range: .fiveMinutes)
        XCTAssertEqual(five.values.count, 60)
        XCTAssertEqual(five.dates.first, origin.addingTimeInterval(7200 - 295))
    }

    func testALateSampleIsIgnored() {
        var history = history(seconds: 10...10) { _ in 1 }
        history.append(at: origin) { _ in 99 }
        XCTAssertEqual(history.series(.cpuLoad, range: .fiveMinutes).values, [1])
    }

    func testRawSeriesKeepsTheLastMinuteInLiveSlots() {
        let dates = (0..<200).map { origin.addingTimeInterval(Double($0) * 0.5) }
        let values = (0..<200).map(Double.init)
        let series = MenuTrendSeries.raw(
            dates: dates, values: values, range: .oneMinute, interval: 0.5)

        XCTAssertEqual(series.capacity, 120)
        XCTAssertEqual(series.values.count, 120)
        XCTAssertEqual(series.values.last, 199)
        XCTAssertEqual(series.dates.first, dates[80])
        XCTAssertNil(series.minima)
        XCTAssertNil(series.maxima)
    }

    func testRawSeriesNeverOverflowsItsSlotsAfterACadenceChange() {
        // Four samples a second, then the cadence drops to one: the minute
        // still holds more samples than its new 60 slots, and the newest win.
        let dates = (0..<240).map { origin.addingTimeInterval(Double($0) * 0.25) }
        let series = MenuTrendSeries.raw(
            dates: dates, values: dates.map { _ in 1 }, range: .oneMinute, interval: 1)
        XCTAssertEqual(series.capacity, 60)
        XCTAssertEqual(series.values.count, 60)
        XCTAssertEqual(series.dates.last, dates.last)
    }

    func testRawSeriesOfNothingIsEmpty() {
        let series = MenuTrendSeries.raw(dates: [], values: [], range: .oneMinute, interval: 1)
        XCTAssertTrue(series.values.isEmpty)
        XCTAssertNil(series.top)
    }
}
