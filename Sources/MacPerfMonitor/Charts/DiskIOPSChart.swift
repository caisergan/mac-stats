import MacPerfMonitorCore
import SwiftUI

struct DiskIOPSChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false
    /// Hovering the plot pins a marker and reads out both directions at that
    /// sample.
    var scrubbable = false

    @State private var scrubPoint: TrendScrubPoint?

    private var accessibilitySummary: String {
        guard let latest = points.last else { return t("No data yet.") }
        let peak =
            points.map {
                max($0.diskReadOperationsPerSec, $0.diskWriteOperationsPerSec)
            }.max() ?? 0
        return t(
            "Currently %1$@ read and %2$@ write operations per second. Peak %3$@ over the shown window.",
            String(Int(latest.diskReadOperationsPerSec)),
            String(Int(latest.diskWriteOperationsPerSec)), String(Int(peak)))
    }

    var body: some View {
        let readPoints = points.map {
            TrendPoint(date: $0.date, value: $0.diskReadOperationsPerSec)
        }
        let writePoints = points.map {
            TrendPoint(date: $0.date, value: $0.diskWriteOperationsPerSec)
        }
        ZStack(alignment: .topLeading) {
            TrendChart(
                series: [
                    TrendSeries(points: readPoints, color: DiskStyle.read, filled: true),
                    TrendSeries(
                        points: writePoints, color: DiskStyle.write, filled: false,
                        lineWidth: 1.8),
                ],
                xDomain: xDomain,
                yFormat: { "\(Int(max($0, 0)))" },
                showsTimeAxis: showsTimeAxis,
                scrubbable: scrubbable,
                scrubReporting: { scrubPoint = $0 },
                scrubReadout: false
            )
            if scrubbable {
                TrendScrubReadout(
                    point: scrubPoint,
                    geometry: TrendChartGeometry(leftGutter: 38, showsTimeAxis: showsTimeAxis),
                    inset: 60
                ) { point in
                    ChartScrubCard(date: point.date) {
                        ChartScrubRow(
                            color: DiskStyle.read, name: t("Read"),
                            value: Self.operations(
                                TrendPoint.value(at: point.date, in: readPoints)))
                        ChartScrubRow(
                            color: DiskStyle.write, name: t("Write"),
                            value: Self.operations(
                                TrendPoint.value(at: point.date, in: writePoints)))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk operations per second trend")
        .accessibilityValue(accessibilitySummary)
    }

    private static func operations(_ value: Double?) -> String {
        t("%@/s", String(Int(max(value ?? 0, 0))))
    }
}
