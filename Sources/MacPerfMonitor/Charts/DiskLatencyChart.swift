import MacPerfMonitorCore
import SwiftUI

/// Average device service time per operation. The latency fields are optional
/// (nil marks an interval with no IO), so each series carries only the points
/// that have a value: `TrendChart`'s gap splitting then leaves quiet stretches
/// blank instead of bridging them or drawing a misleading 0 ms floor.
struct DiskLatencyChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false
    /// Hovering the plot pins a marker and reads out whichever directions had
    /// a measurable service time at that sample.
    var scrubbable = false

    @State private var scrubPoint: TrendScrubPoint?

    private var readPoints: [TrendPoint] {
        points.compactMap { point in
            point.diskReadLatencyMs.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var writePoints: [TrendPoint] {
        points.compactMap { point in
            point.diskWriteLatencyMs.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var accessibilitySummary: String {
        let reads = readPoints
        let writes = writePoints
        switch (reads.last, writes.last) {
        case (nil, nil):
            return t("No disk activity with measurable latency in the shown window.")
        case (let read?, nil):
            return t(
                "Latest read %@ milliseconds per operation.", String(format: "%.2f", read.value))
        case (nil, let write?):
            return t(
                "Latest write %@ milliseconds per operation.", String(format: "%.2f", write.value))
        case (let read?, let write?):
            return t(
                "Latest read %1$@ milliseconds per operation, write %2$@ milliseconds per operation.",
                String(format: "%.2f", read.value), String(format: "%.2f", write.value))
        }
    }

    var body: some View {
        let reads = readPoints
        let writes = writePoints
        ZStack(alignment: .topLeading) {
            TrendChart(
                series: [
                    TrendSeries(points: reads, color: DiskStyle.read, filled: false),
                    TrendSeries(
                        points: writes, color: DiskStyle.write, filled: false, lineWidth: 1.8),
                ],
                xDomain: xDomain,
                yFormat: { Self.milliseconds($0) },
                showsTimeAxis: showsTimeAxis,
                scrubbable: scrubbable,
                scrubReporting: { scrubPoint = $0 },
                scrubReadout: false
            )
            if scrubbable {
                TrendScrubReadout(
                    point: scrubPoint,
                    geometry: TrendChartGeometry(leftGutter: 38, showsTimeAxis: showsTimeAxis),
                    inset: 56
                ) { point in
                    ChartScrubCard(date: point.date) {
                        // A direction with no IO near the marker has no service
                        // time to give, so its row is left out rather than
                        // quoted from whenever it was last busy.
                        if let read = TrendPoint.value(
                            at: point.date, in: reads, within: tolerance)
                        {
                            ChartScrubRow(
                                color: DiskStyle.read, name: t("Read"),
                                value: Self.milliseconds(read))
                        }
                        if let write = TrendPoint.value(
                            at: point.date, in: writes, within: tolerance)
                        {
                            ChartScrubRow(
                                color: DiskStyle.write, name: t("Write"),
                                value: Self.milliseconds(write))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk service time trend")
        .accessibilityValue(accessibilitySummary)
    }

    /// How far from the marker a sample may sit and still be its reading. A
    /// twenty-fourth of the window is the same rule the live surfaces use to
    /// decide a line has gapped.
    private var tolerance: TimeInterval {
        guard let xDomain else { return .infinity }
        return max(xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 24, 30)
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.1f ms", locale: .current, max(value, 0))
    }
}
