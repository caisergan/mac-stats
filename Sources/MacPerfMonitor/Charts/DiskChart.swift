import MacPerfMonitorCore
import SwiftUI

struct DiskChart: View {
    let read: LiveColumn
    let write: LiveColumn
    var xDomain: ClosedRange<Date>? = nil
    var yDomain: ClosedRange<Double>? = nil
    var showsTimeAxis = false
    /// Hovering the plot pins a marker and reads out both directions at that
    /// sample.
    var scrubbable = false

    /// The scrubbed point reported by `TrendChart`, nil when the pointer
    /// leaves. Only its time is used: the read-out quotes both directions at
    /// that sample, which the chart's own single-value read-out cannot do.
    @State private var scrubPoint: TrendScrubPoint?

    init(
        points: [SystemHistoryPoint], xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false,
        scrubbable: Bool = false
    ) {
        self.init(
            read: LiveColumn(points) { $0.diskReadBytesPerSec },
            write: LiveColumn(points) { $0.diskWriteBytesPerSec },
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis,
            scrubbable: scrubbable)
    }

    /// The live Dashboard path: zero-copy columns of the window.
    init(
        window: SystemHistoryWindow, xDomain: ClosedRange<Date>? = nil,
        yDomain: ClosedRange<Double>? = nil, showsTimeAxis: Bool = false,
        scrubbable: Bool = false
    ) {
        self.init(
            read: LiveColumn(window, .diskReadBytesPerSec),
            write: LiveColumn(window, .diskWriteBytesPerSec),
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis,
            scrubbable: scrubbable)
    }

    private init(
        read: LiveColumn, write: LiveColumn, xDomain: ClosedRange<Date>?,
        yDomain: ClosedRange<Double>?, showsTimeAxis: Bool, scrubbable: Bool
    ) {
        self.read = read
        self.write = write
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.showsTimeAxis = showsTimeAxis
        self.scrubbable = scrubbable
    }

    private var accessibilitySummary: String {
        guard let latestRead = read.lastValue, let latestWrite = write.lastValue else {
            return t("No data yet.")
        }
        let peak = max(read.range?.max ?? 0, write.range?.max ?? 0)
        if peak < 1 { return t("No physical disk activity over the shown window.") }
        return t(
            "Currently %1$@ read, %2$@ write. Peak %3$@ over the shown window.",
            ByteFormat.rate(latestRead), ByteFormat.rate(latestWrite), ByteFormat.rate(peak))
    }

    var body: some View {
        let readPoints = LiveTrend.points(read, xDomain: xDomain)
        let writePoints = LiveTrend.points(write, xDomain: xDomain)
        ZStack(alignment: .topLeading) {
            TrendChart(
                series: [
                    TrendSeries(points: readPoints, color: DiskStyle.read, filled: true),
                    TrendSeries(
                        points: writePoints, color: DiskStyle.write, filled: false,
                        lineWidth: 1.8),
                ],
                xDomain: xDomain,
                yDomain: yDomain,
                yFormat: { ByteFormat.rate(max($0, 0)) },
                showsTimeAxis: showsTimeAxis,
                scrubbable: scrubbable,
                scrubReporting: { scrubPoint = $0 },
                scrubReadout: false,
                leftGutter: 56
            )
            if scrubbable {
                TrendScrubReadout(
                    point: scrubPoint,
                    geometry: TrendChartGeometry(leftGutter: 56, showsTimeAxis: showsTimeAxis),
                    inset: 70
                ) { point in
                    ChartScrubCard(date: point.date) {
                        ChartScrubRow(
                            color: DiskStyle.read, name: t("Read"),
                            value: ByteFormat.rate(
                                TrendPoint.value(at: point.date, in: readPoints) ?? 0))
                        ChartScrubRow(
                            color: DiskStyle.write, name: t("Write"),
                            value: ByteFormat.rate(
                                TrendPoint.value(at: point.date, in: writePoints) ?? 0))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Physical disk throughput trend")
        .accessibilityValue(accessibilitySummary)
    }
}
