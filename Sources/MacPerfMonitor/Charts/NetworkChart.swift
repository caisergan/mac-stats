import MacPerfMonitorCore
import SwiftUI

/// A compact network-throughput trend: download as a filled teal band, upload as
/// an orange line over it. Bytes-per-second on the Y axis, in human rate units.
/// Drawn with the lightweight Canvas `TrendChart`.
struct NetworkChart: View {
    let download: LiveColumn
    let upload: LiveColumn
    var xDomain: ClosedRange<Date>? = nil
    var yDomain: ClosedRange<Double>? = nil
    var showsTimeAxis: Bool = false
    /// Hovering the plot pins a marker and reads out both directions at that
    /// sample.
    var scrubbable: Bool = false

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
            download: LiveColumn(points) { $0.networkInBytesPerSec },
            upload: LiveColumn(points) { $0.networkOutBytesPerSec },
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
            download: LiveColumn(window, .networkInBytesPerSec),
            upload: LiveColumn(window, .networkOutBytesPerSec),
            xDomain: xDomain, yDomain: yDomain, showsTimeAxis: showsTimeAxis,
            scrubbable: scrubbable)
    }

    private init(
        download: LiveColumn, upload: LiveColumn, xDomain: ClosedRange<Date>?,
        yDomain: ClosedRange<Double>?, showsTimeAxis: Bool, scrubbable: Bool
    ) {
        self.download = download
        self.upload = upload
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.showsTimeAxis = showsTimeAxis
        self.scrubbable = scrubbable
    }

    private var accessibilitySummary: String {
        guard let latestIn = download.lastValue, let latestOut = upload.lastValue else {
            return t("No data yet.")
        }
        let peak = max(download.range?.max ?? 0, upload.range?.max ?? 0)
        if peak < 1 { return t("No network traffic over the shown window.") }
        return t(
            "Currently %1$@ down, %2$@ up. Peak %3$@ over the shown window.",
            ByteFormat.rate(latestIn), ByteFormat.rate(latestOut), ByteFormat.rate(peak))
    }

    var body: some View {
        let downPoints = LiveTrend.points(download, xDomain: xDomain)
        let upPoints = LiveTrend.points(upload, xDomain: xDomain)
        ZStack(alignment: .topLeading) {
            TrendChart(
                series: [
                    TrendSeries(
                        points: downPoints, color: NetworkStyle.download, filled: true),
                    TrendSeries(
                        points: upPoints, color: NetworkStyle.upload, filled: false,
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
                    inset: 76
                ) { point in
                    ChartScrubCard(date: point.date) {
                        ChartScrubRow(
                            color: NetworkStyle.download, name: t("Download"),
                            value: ByteFormat.rate(Self.value(at: point.date, in: downPoints)))
                        ChartScrubRow(
                            color: NetworkStyle.upload, name: t("Upload"),
                            value: ByteFormat.rate(Self.value(at: point.date, in: upPoints)))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network throughput trend")
        .accessibilityValue(accessibilitySummary)
    }

    /// A series' rate at the scrubbed sample. Both series are sampled on the
    /// same ticks, so the marker's time matches a point of each exactly; the
    /// nearest one is taken anyway, in case one direction ever gaps.
    private static func value(at date: Date, in points: [TrendPoint]) -> Double {
        var best = 0.0
        var bestDelta = Double.greatestFiniteMagnitude
        for point in points {
            let delta = abs(point.date.timeIntervalSince(date))
            if delta < bestDelta {
                bestDelta = delta
                best = point.value
            }
        }
        return best
    }
}
