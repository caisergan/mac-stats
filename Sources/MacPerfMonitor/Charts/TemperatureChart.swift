import MacPerfMonitorCore
import SwiftUI

/// Shared colors for the thermal surfaces, so the Energy tab and the menu bar
/// panel tell the same story.
enum ThermalStyle {
    static let cpu = Color.orange
    static let gpu = Color.red
    static let fan = Color.teal
}

extension ThermalPressureState {
    /// Display tint keyed to macOS's verdict, never to a degree threshold: a
    /// hot number in green is a Mac working as designed; an orange or red one
    /// is macOS actually slowing work down.
    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }
}

/// CPU and GPU die temperature over the selected window. The thermal fields
/// are optional (nil marks a tick that did not read the SMC), so each series
/// carries only the points that have a value: `TrendChart`'s gap splitting
/// leaves unsampled stretches blank instead of drawing a misleading 0 degree
/// floor. On aggregate ranges the points already carry the bucket max, so the
/// line is "how hot did it get", never a smoothed average.
struct TemperatureChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false
    /// Hovering the plot pins a marker and reads out both dies at that sample.
    var scrubbable = false

    /// The scrubbed point reported by `TrendChart`, nil when the pointer
    /// leaves. Only its time is used: the read-out quotes both series at that
    /// sample, which the chart's own single-value read-out cannot do.
    @State private var scrubPoint: TrendScrubPoint?

    private var cpuPoints: [TrendPoint] {
        points.compactMap { point in
            point.cpuDieC.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var gpuPoints: [TrendPoint] {
        points.compactMap { point in
            point.gpuDieC.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var accessibilitySummary: String {
        guard let cpu = cpuPoints.last else {
            return t("No temperature samples in the shown window.")
        }
        let peak = cpuPoints.map(\.value).max() ?? cpu.value
        let cpuValue = String(format: "%.0f", cpu.value)
        let peakValue = String(format: "%.0f", peak)
        if let gpu = gpuPoints.last {
            return t(
                "Latest CPU die %1$@ degrees, GPU die %2$@ degrees, window peak %3$@ degrees.",
                cpuValue, String(format: "%.0f", gpu.value), peakValue)
        }
        return t("Latest CPU die %1$@ degrees, window peak %2$@ degrees.", cpuValue, peakValue)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrendChart(
                series: [
                    TrendSeries(points: cpuPoints, color: ThermalStyle.cpu, filled: true),
                    TrendSeries(
                        points: gpuPoints, color: ThermalStyle.gpu, filled: false, lineWidth: 1.8),
                ],
                xDomain: xDomain,
                yDomain: temperatureDomain,
                yFormat: { Self.degrees($0) },
                showsTimeAxis: showsTimeAxis,
                scrubbable: scrubbable,
                scrubReporting: { scrubPoint = $0 },
                scrubReadout: false
            )
            if scrubbable { scrubReadout }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Die temperature trend")
        .accessibilityValue(accessibilitySummary)
    }

    /// Floating read-out beside the scrub marker, placed with the same geometry
    /// `TrendChart` draws the marker from so the card tracks it exactly. Both
    /// dies are listed, because the marker alone cannot say which line it sits
    /// on.
    @ViewBuilder private var scrubReadout: some View {
        TrendScrubReadout(
            point: scrubPoint,
            geometry: TrendChartGeometry(leftGutter: 38, showsTimeAxis: showsTimeAxis),
            inset: 52
        ) { point in
            if let reading = reading(at: point.date) {
                ChartScrubCard(date: reading.date) {
                    if let cpu = reading.cpuDieC {
                        ChartScrubRow(
                            color: ThermalStyle.cpu, name: "CPU", value: Self.degrees(cpu))
                    }
                    if let gpu = reading.gpuDieC {
                        ChartScrubRow(
                            color: ThermalStyle.gpu, name: "GPU", value: Self.degrees(gpu))
                    }
                }
            }
        }
    }

    /// The sample the marker sits on: the nearest one that read the SMC at all,
    /// so scrubbing across a gap still quotes a real reading.
    private func reading(at date: Date) -> SystemHistoryPoint? {
        var best: SystemHistoryPoint?
        var bestDelta = Double.greatestFiniteMagnitude
        for point in points where point.cpuDieC != nil || point.gpuDieC != nil {
            let delta = abs(point.date.timeIntervalSince(date))
            if delta < bestDelta {
                bestDelta = delta
                best = point
            }
        }
        return best
    }

    /// Whole degrees, matching the axis labels and the status line beneath.
    static func degrees(_ value: Double) -> String { String(format: "%.0f°C", value) }

    /// A stable floor-to-headroom domain: starting the axis at 0 wastes half
    /// the plot (die sensors never read near 0), while a tight auto-fit makes
    /// idle noise look dramatic. 20 to a rounded-up peak keeps small wiggles
    /// small and real spikes visible.
    private var temperatureDomain: ClosedRange<Double>? {
        let values = cpuPoints.map(\.value) + gpuPoints.map(\.value)
        guard let peak = values.max() else { return nil }
        let top = max(60, (peak / 10).rounded(.up) * 10 + 10)
        return 20...top
    }
}

/// Fan speed over the selected window, gap-aware like the temperature chart.
/// Fanless Macs simply never produce points, and the panel hides this chart.
struct FanChart: View {
    let points: [SystemHistoryPoint]
    var xDomain: ClosedRange<Date>? = nil
    var showsTimeAxis = false
    /// Hovering the plot pins a marker and reads out the sample under it.
    var scrubbable = false

    private var fanPoints: [TrendPoint] {
        points.compactMap { point in
            point.fanRPM.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    private var accessibilitySummary: String {
        guard let latest = fanPoints.last else {
            return t("No fan samples in the shown window.")
        }
        if latest.value == 0 { return t("Fans currently off.") }
        return t("Fans currently %@ rpm.", String(format: "%.0f", latest.value))
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(points: fanPoints, color: ThermalStyle.fan, filled: true)
            ],
            xDomain: xDomain,
            yFormat: { t("%@ rpm", String(format: "%.0f", max($0, 0))) },
            showsTimeAxis: showsTimeAxis,
            scrubbable: scrubbable,
            leftGutter: 56
        )
        .accessibilityLabel("Fan speed trend")
        .accessibilityValue(accessibilitySummary)
    }
}
