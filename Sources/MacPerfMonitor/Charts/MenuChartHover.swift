import MacPerfMonitorCore
import SwiftUI

/// One line of a menu bar panel chart's hover read-out: what the series is
/// called, the colour it is drawn in, the samples behind it, and how one of
/// those samples prints.
struct MenuChartSeries {
    /// Already localised: the read-out is a custom view, so a raw key handed to
    /// it would never be looked up.
    let name: String
    let color: Color
    let values: [Double]
    let format: (Double) -> String

    init(name: String, color: Color, values: [Double], format: @escaping (Double) -> String) {
        self.name = name
        self.color = color
        self.values = values
        self.format = format
    }
}

/// How a menu bar panel chart places a value vertically, so a hover marker
/// lands on the line rather than beside it.
enum MenuChartScale {
    /// Plotted upward from the bottom of the plot against a fixed domain: the
    /// shape every single-series header chart draws (CPU, pressure, charge,
    /// power, GPU, temperature).
    case domain(ClosedRange<Double>)
    /// Two directions mirrored about the plot's centre line against a shared
    /// upper bound, the first rising and the second dropping: the network and
    /// disk throughput charts.
    case mirrored(upper: Double)
}

/// The hover read-out the menu bar panel's header charts share: a rule pinned to
/// the sample under the pointer, a dot on each series' line, and a card quoting
/// every series at that sample.
///
/// The panels draw their traces in a `Canvas` (or, for GPU and temperature, in a
/// Swift Chart with both axes hidden), so there is no chart proxy to ask what
/// lies under the pointer. This overlay repeats the placement the charts
/// themselves use (the fixed live slots of `LiveChartGeometry.normalizedSlot`
/// inside the chart's plot rectangle), snaps the pointer to the nearest sample,
/// and reads it back. The pointer position is what is kept, not the sample
/// index: the trace shifts one slot left every tick, so a held index would
/// quote a different sample every second while the marker sat still.
struct MenuChartHoverOverlay: View {
    /// The lines the card quotes, in the order the chart drew them. For a
    /// mirrored scale the first rises and the second drops.
    let series: [MenuChartSeries]
    /// Timestamps parallel to the series' values. Empty, or out of step with
    /// them, leaves the card's time line off rather than dating a reading
    /// wrongly.
    var dates: [Date] = []
    /// The live window's slot count, matching what the chart plotted with, so
    /// the marker sits exactly on the sample it names.
    var sampleCapacity: Int? = nil
    let scale: MenuChartScale
    /// The rectangle the chart drew its trace into. The default is the gutter
    /// layout `MenuTrendChart` uses; the Swift Chart panels plot edge to edge.
    var plotRect: (CGSize) -> CGRect = { MenuChart.plotRect(in: $0) }

    /// Where the pointer is, in the overlay's own space. Nil once it leaves.
    @State private var pointerX: CGFloat?
    /// Measured, so the card can be held inside the chart's width whatever the
    /// figures and names in it turn out to be.
    @State private var cardSize: CGSize = .zero

    /// How far past either end of the plot still counts as pointing at the
    /// trace, so the newest sample stays readable at the very edge.
    private static let edgeSlack: CGFloat = 6
    /// A plot at least this tall holds the card itself; a shorter one (the 48pt
    /// header charts) floats it just above, over the header it belongs to.
    private static let inlineCardMinimumHeight: CGFloat = 70

    var body: some View {
        GeometryReader { geo in
            let plot = plotRect(geo.size)
            let index = pointerX.flatMap { sampleIndex(atX: $0, plot: plot) }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): pointerX = location.x
                        case .ended: pointerX = nil
                        }
                    }
                if let index {
                    marker(at: index, plot: plot)
                    card(at: index)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) {
                            $0.size
                        } action: {
                            cardSize = $0
                        }
                        .allowsHitTesting(false)
                        .position(cardCentre(at: index, plot: plot))
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Marker and card

    private func marker(at index: Int, plot: CGRect) -> some View {
        Canvas { ctx, _ in
            let markerX = x(at: index, plot: plot)
            var rule = Path()
            rule.move(to: CGPoint(x: markerX, y: plot.minY))
            rule.addLine(to: CGPoint(x: markerX, y: plot.maxY))
            ctx.stroke(rule, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            for (offset, line) in series.enumerated() where index < line.values.count {
                let dotY = y(line.values[index], series: offset, plot: plot)
                let radius: CGFloat = 2.5
                ctx.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: markerX - radius, y: dotY - radius,
                            width: radius * 2, height: radius * 2)),
                    with: .color(line.color))
            }
        }
        .allowsHitTesting(false)
    }

    private func card(at index: Int) -> some View {
        ChartScrubCard(date: date(at: index)) {
            ForEach(Array(series.enumerated()), id: \.offset) { _, line in
                if index < line.values.count {
                    ChartScrubRow(
                        color: line.color, name: line.name,
                        value: line.format(line.values[index]))
                }
            }
        }
    }

    /// Where the card sits: tracking the marker horizontally but never hanging
    /// off the plot, inside a tall chart and just above a short one.
    private func cardCentre(at index: Int, plot: CGRect) -> CGPoint {
        let half = cardSize.width / 2
        let markerX = x(at: index, plot: plot)
        let cardX =
            plot.width > cardSize.width
            ? min(max(markerX, plot.minX + half), plot.maxX - half)
            : plot.midX
        let cardY =
            plot.height >= Self.inlineCardMinimumHeight
            ? plot.minY + cardSize.height / 2 + 4
            : plot.minY - cardSize.height / 2 - 6
        return CGPoint(x: cardX, y: cardY)
    }

    // MARK: - Geometry

    private var sampleCount: Int { series.first?.values.count ?? 0 }

    private func date(at index: Int) -> Date? {
        guard dates.count == sampleCount, dates.indices.contains(index) else { return nil }
        return dates[index]
    }

    /// The sample under the pointer, or nil when there is none there: past
    /// either end of the plot, or left of the oldest sample while the ring is
    /// still filling and the trace covers only part of the width.
    private func sampleIndex(atX pointer: CGFloat, plot: CGRect) -> Int? {
        let count = sampleCount
        guard count > 0, plot.width > 0 else { return nil }
        guard pointer >= plot.minX - Self.edgeSlack, pointer <= plot.maxX + Self.edgeSlack else {
            return nil
        }
        let clamped = min(max(pointer, plot.minX), plot.maxX)
        let fraction = Double((clamped - plot.minX) / plot.width)
        guard let sampleCapacity, sampleCapacity > 0 else {
            guard count > 1 else { return 0 }
            return min(max(Int((fraction * Double(count - 1)).rounded()), 0), count - 1)
        }
        return LiveChartGeometry.slotIndex(
            atFraction: fraction, count: count, capacity: sampleCapacity)
    }

    /// Where a sample was drawn, repeating the charts' own placement exactly.
    private func x(at index: Int, plot: CGRect) -> CGFloat {
        let count = sampleCount
        guard count > 0 else { return plot.minX }
        if let sampleCapacity, sampleCapacity > 0 {
            let fraction = LiveChartGeometry.normalizedSlot(
                index: index, count: count, capacity: sampleCapacity)
            return plot.minX + CGFloat(fraction) * plot.width
        }
        let step = count >= 2 ? plot.width / CGFloat(count - 1) : 0
        return plot.minX + CGFloat(index) * step
    }

    private func y(_ value: Double, series index: Int, plot: CGRect) -> CGFloat {
        switch scale {
        case .domain(let domain):
            return plot.maxY
                - CGFloat(LiveChartGeometry.normalizedY(value, in: domain)) * plot.height
        case .mirrored(let upper):
            let fraction = CGFloat(min(1, max(0, value / max(upper, 0.0001))))
            let height = fraction * plot.height / 2
            return index == 0 ? plot.midY - height : plot.midY + height
        }
    }
}
