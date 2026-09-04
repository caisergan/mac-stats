import Charts
import MacPerfMonitorCore
import SwiftUI

/// The battery charge timeline: a 0–100% area chart, with the "low" (20%) and
/// "full" (80%) bands marked, tinted by the current `BatteryLevel`. A direct
/// sibling of `CPUChart`/`PressureChart` so the dashboards read the same way.
/// Plots `SystemHistoryPoint.batteryCharge`; the line's slope already shows
/// whether the battery was charging or discharging. Hovering (or dragging)
/// across the plot pins the nearest sample and reads out its level and time.
struct BatteryChart: View {
    let points: [SystemHistoryPoint]
    let currentLevel: BatteryLevel
    var xDomain: ClosedRange<Date>? = nil
    /// Hovering the plot pins a marker and a read-out at the nearest sample.
    var scrubbable = false

    private var accessibilitySummary: String {
        guard let latest = points.last?.batteryCharge else { return t("No data yet.") }
        let values = points.map(\.batteryCharge)
        let lo = Int((values.min() ?? latest).rounded())
        let hi = Int((values.max() ?? latest).rounded())
        return t(
            "Currently %1$@ percent. Window range %2$@ to %3$@ percent.",
            String(Int(latest.rounded())), String(lo), String(hi))
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Low", 20))
                .foregroundStyle(.red.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("Low").font(.caption2).foregroundStyle(.red)
                }
            RuleMark(y: .value("Full", 80))
                .foregroundStyle(.green.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("80%").font(.caption2).foregroundStyle(.green)
                }

            ForEach(Array(points.splitIntoSegments().enumerated()), id: \.offset) {
                segIdx, segment in
                ForEach(segment) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Charge", point.batteryCharge),
                        series: .value("Segment", segIdx)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [
                                currentLevel.color.opacity(0.45), currentLevel.color.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Charge", point.batteryCharge),
                        series: .value("Segment", segIdx)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(currentLevel.color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXScale(domain: resolvedXDomain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 20, 50, 80, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)") }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            if scrubbable {
                BatteryScrubLayer(
                    points: points, domain: resolvedXDomain, color: currentLevel.color,
                    proxy: proxy)
            }
        }
        .accessibilityLabel("Battery charge timeline")
        .accessibilityValue(accessibilitySummary)
        .reducedMotionAware()
    }

    private var resolvedXDomain: ClosedRange<Date> {
        if let xDomain { return xDomain }
        let first = points.first?.date ?? .distantPast
        let last = points.last?.date ?? first.addingTimeInterval(1)
        return first < last ? first...last : first.addingTimeInterval(-1)...last
    }
}

/// Hover and drag tracking for `BatteryChart`: the marker rule, the dot on the
/// line, and the floating read-out.
///
/// A view of its own, rather than state on the chart, deliberately. Swift Charts
/// builds a SwiftUI view per mark, so holding the scrub position on the chart
/// re-ran the whole area-and-line series (two marks per sample, hundreds of
/// them) for every pointer move: the marker lagged the cursor badly and moves
/// were dropped. Owning the state here confines a move to redrawing this
/// overlay, and the plotted series is left alone.
private struct BatteryScrubLayer: View {
    let points: [SystemHistoryPoint]
    let domain: ClosedRange<Date>
    let color: Color
    let proxy: ChartProxy

    /// Time under the pointer, nil when it leaves the plot.
    @State private var scrubDate: Date?

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
            ZStack(alignment: .topLeading) {
                if let point = scrubDate.flatMap(nearest(to:)) {
                    marker(point, plot: plot)
                        .allowsHitTesting(false)
                }
                // The tracker goes above the marker, and the marker takes no
                // hits. The marker follows the cursor, so a hit-testable rule or
                // dot beneath it captured the pointer the moment it caught up:
                // this view then saw the hover end and cleared the read-out, and
                // it stayed cleared until the pointer moved again. That read as
                // the read-out refusing to appear on particular pixels, which
                // were in fact the sample positions themselves.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            scrubDate = date(atX: location.x, plot: plot)
                        case .ended:
                            scrubDate = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { scrubDate = date(atX: $0.location.x, plot: plot) }
                            .onEnded { _ in scrubDate = nil }
                    )
            }
        }
    }

    @ViewBuilder private func marker(_ point: SystemHistoryPoint, plot: CGRect) -> some View {
        let xx = plot.minX + x(of: point.date, in: plot)
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: plot.height)
            .position(x: xx, y: plot.midY)
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .position(x: xx, y: plot.minY + y(of: point.batteryCharge, in: plot))
        ChartScrubCard(date: point.date) {
            Text(BatteryFormat.percent(point.batteryCharge))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .position(x: min(max(xx, plot.minX + 46), plot.maxX - 46), y: plot.minY + 20)
    }

    /// The recorded sample nearest the pointer, ignoring any that fall outside
    /// the plotted window. Nearest-in-time rather than interpolated: the
    /// read-out should quote a level the battery actually reported.
    ///
    /// The window filter is what keeps the read-out from vanishing near the left
    /// edge. The loaded history is fetched once for a window ending at the
    /// fetch's "now", while the domain ends at the newest live sample and so
    /// slides forward with every tick: the oldest loaded samples drop out of the
    /// domain behind it, in a strip that widens the longer the tab stays open.
    /// Picking one of those left the marker with no position on the scale at all
    /// (`ChartProxy` answers nil off-domain), so the whole read-out silently
    /// disappeared for those pixels.
    private func nearest(to date: Date) -> SystemHistoryPoint? {
        var best: SystemHistoryPoint?
        var bestDelta = Double.greatestFiniteMagnitude
        for point in points where domain.contains(point.date) {
            let delta = abs(point.date.timeIntervalSince(date))
            if delta < bestDelta {
                bestDelta = delta
                best = point
            }
        }
        return best
    }

    /// The time under a pointer position in the overlay's coordinate space.
    /// `ChartProxy` measures from the plot's leading edge, the overlay from the
    /// chart's, so the gutter has to come off first.
    private func date(atX x: CGFloat, plot: CGRect) -> Date? {
        let offset = min(max(x, plot.minX), plot.maxX) - plot.minX
        if let date = proxy.value(atX: offset, as: Date.self) { return date }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return domain.lowerBound.addingTimeInterval(span * Double(offset / max(plot.width, 1)))
    }

    /// Plot-relative positions, falling back to the domain fraction whenever the
    /// proxy declines to place a value.
    private func x(of date: Date, in plot: CGRect) -> CGFloat {
        proxy.position(forX: date)
            ?? CGFloat(LiveChartGeometry.normalizedX(date, in: domain)) * plot.width
    }

    private func y(of value: Double, in plot: CGRect) -> CGFloat {
        proxy.position(forY: value)
            ?? (1 - CGFloat(LiveChartGeometry.normalizedY(value, in: 0...100))) * plot.height
    }
}
