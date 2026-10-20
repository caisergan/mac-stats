import MacPerfMonitorCore
import SwiftUI

/// Shared geometry, styling and drawing for the menu-bar dropdown header charts,
/// so CPU, memory, battery, power and network all read as one consistent family:
/// a thin line with a soft area fill on a marked (gridline + labelled) axis. The
/// fixed, labelled scale is what keeps a steady series readable — a flat line at
/// its true level instead of the solid block a baseline-filled bar chart became.
enum MenuChart {
    /// One height for every menu-bar header chart.
    static let height: CGFloat = 48
    /// The network chart is mirrored (download rises up / upload drops down from a
    /// centre line), so it gets roughly double the height — otherwise each direction
    /// only has ~22px and the trace is unreadable.
    static let networkHeight: CGFloat = 104
    /// Width reserved at the left for the axis tick labels.
    static let gutter: CGFloat = 30
    static let lineWidth: CGFloat = 1.5

    static let gridColor = Color.secondary.opacity(0.18)
    static let labelColor = Color.secondary
    static let labelFont = Font.system(size: 8, weight: .medium).monospacedDigit()

    /// Round a raw peak up to a "nice" 1–2–5×10ⁿ value, so an auto-scaled axis
    /// (power, network) only changes when the data crosses a magnitude rather than
    /// jittering its labels every tick.
    static func niceUpperBound(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        let fraction = raw / base
        let step: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
        return step * base
    }

    /// The plot rectangle inside a canvas of `size`: a left gutter for axis labels
    /// and a little vertical breathing room so the line never clips the edge.
    static func plotRect(in size: CGSize, reserveGutter: Bool = true) -> CGRect {
        let left = reserveGutter ? gutter : 2
        return CGRect(
            x: left, y: 2,
            width: max(1, size.width - left - 2), height: max(1, size.height - 4))
    }

    /// Stroke a polyline and fill the band between it and `baselineY` with a soft
    /// vertical gradient — the shared body of every menu-bar trend chart. The
    /// gradient runs from `gradientTop` (opaque end) to `gradientBottom` (faded).
    static func drawTrend(
        _ ctx: GraphicsContext, points: [CGPoint], baselineY: CGFloat,
        color: Color, gradientTop: CGFloat, gradientBottom: CGFloat, filled: Bool = true
    ) {
        guard let first = points.first else { return }
        guard points.count >= 2 else {
            // A single sample still shows as a short flat tick at its level.
            var tick = Path()
            tick.move(to: CGPoint(x: first.x - 2, y: first.y))
            tick.addLine(to: CGPoint(x: first.x + 2, y: first.y))
            ctx.stroke(tick, with: .color(color), lineWidth: lineWidth)
            return
        }

        guard filled else {
            ctx.stroke(
                Path(MonotoneCurve.path(points)), with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            return
        }

        // The same monotone curve the main charts draw (docs/chart-rules.md):
        // smooth, and it cannot overshoot a sample.
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: first.x, y: baselineY))
        MonotoneCurve.add(points, to: outline, move: false)
        outline.addLine(to: CGPoint(x: points[points.count - 1].x, y: baselineY))
        outline.closeSubpath()
        let area = Path(outline)
        // A light fill gives the line body without becoming a solid block: it
        // fades to fully transparent, so even a steady high line reads as a line
        // with a soft glow under it rather than a filled rectangle.
        ctx.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: gradientTop),
                endPoint: CGPoint(x: 0, y: gradientBottom)))

        let line = Path(MonotoneCurve.path(points))
        ctx.stroke(
            line, with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

extension MenuChart {
    /// Fill the band between a bucketed series' minima and maxima in a light
    /// tint of its colour. The overview ranges draw each bucket's mean as the
    /// line, and this band is where the samples the mean smooths over went:
    /// a one second spike in an hour long chart still reaches the top.
    /// Straight segments, not the monotone curve, since the edges are bucket
    /// extremes rather than a signal to interpolate.
    static func drawBand(
        _ ctx: GraphicsContext, lower: [CGPoint], upper: [CGPoint], color: Color
    ) {
        guard lower.count == upper.count, let first = upper.first else { return }
        var band = Path()
        band.move(to: first)
        for point in upper.dropFirst() { band.addLine(to: point) }
        for point in lower.reversed() { band.addLine(to: point) }
        band.closeSubpath()
        ctx.fill(band, with: .color(color.opacity(0.2)))
        if upper.count == 1 {
            // A lone bucket has no width to fill; mark its range instead.
            var tick = Path()
            tick.move(to: first)
            tick.addLine(to: lower[0])
            ctx.stroke(tick, with: .color(color.opacity(0.35)), lineWidth: 3)
        }
    }

    /// Draw one series, split into runs at its gaps (non-finite values, where
    /// nothing was read): each run's band where the series has one, then its
    /// line. A band replaces the soft area under the line, which would only
    /// muddy it. `point` places a value at a slot.
    static func drawSeries(
        _ ctx: GraphicsContext, values: [Double], minima: [Double]?, maxima: [Double]?,
        point: (Int, Double) -> CGPoint, baselineY: CGFloat, color: Color,
        gradientTop: CGFloat, gradientBottom: CGFloat
    ) {
        let hasBand = minima?.count == values.count && maxima?.count == values.count
        for run in runs(values) {
            if hasBand, let minima, let maxima {
                drawBand(
                    ctx, lower: run.map { point($0, minima[$0]) },
                    upper: run.map { point($0, maxima[$0]) }, color: color)
            }
            drawTrend(
                ctx, points: run.map { point($0, values[$0]) }, baselineY: baselineY,
                color: color, gradientTop: gradientTop, gradientBottom: gradientBottom,
                filled: !hasBand)
        }
    }

    /// The stretches of a series with a reading in every slot.
    static func runs(_ values: [Double]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, value) in values.enumerated() {
            if value.isFinite {
                if start == nil { start = index }
            } else if let first = start {
                runs.append(first..<index)
                start = nil
            }
        }
        if let first = start { runs.append(first..<values.count) }
        return runs
    }

    /// Where slot `index` of `count` sits across `plot`, the placement every
    /// header chart and its hover overlay share.
    static func x(index: Int, count: Int, capacity: Int?, plot: CGRect) -> CGFloat {
        if let capacity, capacity > 0 {
            let fraction = LiveChartGeometry.normalizedSlot(
                index: index, count: count, capacity: capacity)
            return plot.minX + CGFloat(fraction) * plot.width
        }
        let step = count >= 2 ? plot.width / CGFloat(count - 1) : 0
        return plot.minX + CGFloat(index) * step
    }
}

/// A compact line + soft-area trend for the menu-bar dropdown headers, drawn on a
/// fixed, labelled Y axis (gridlines + ticks in a left gutter) so a steady series
/// reads as a clear flat line at its true level rather than a solid block.
/// Canvas-drawn, cheap to redraw at 1 Hz. CPU/memory/battery pass a fixed 0–100
/// domain; power passes a rounded auto-peak via `MenuChart.niceUpperBound`.
struct MenuTrendChart: View {
    var values: [Double]
    /// Bucket minima and maxima parallel to `values` on the overview ranges,
    /// drawn as a band around the mean line. Nil on the raw detail range.
    var minima: [Double]? = nil
    var maxima: [Double]? = nil
    /// Timestamps parallel to `values`, so the hover read-out can date the
    /// sample it quotes. Empty leaves the time line off the card.
    var dates: [Date] = []
    /// Number of equally spaced samples in the live window. While the buffer is
    /// filling and after it wraps, each new value moves the trace one fixed slot.
    var sampleCapacity: Int? = nil
    var color: Color
    /// The fixed Y range the line is plotted against (baseline at `lowerBound`).
    var domain: ClosedRange<Double>
    /// Y values to draw a gridline + axis label at (within `domain`).
    var ticks: [Double]
    /// Formats a tick value for its axis label, e.g. `{ "\(Int($0))" }`.
    var label: (Double) -> String
    /// What the hover read-out calls this series, already localised.
    var readoutName: String
    /// How the hover read-out prints a value. The axis labels are cramped enough
    /// to drop the unit; the card has room to say it, so it formats separately.
    var readoutValue: (Double) -> String

    var body: some View {
        canvas
            .overlay(
                MenuChartHoverOverlay(
                    series: [
                        MenuChartSeries(
                            name: readoutName, color: color, values: values, peaks: maxima,
                            format: readoutValue)
                    ],
                    dates: dates, sampleCapacity: sampleCapacity, scale: .domain(domain))
            )
    }

    private var canvas: some View {
        Canvas { ctx, size in
            let plot = MenuChart.plotRect(in: size)
            let lower = domain.lowerBound
            let span = max(domain.upperBound - lower, 0.0001)
            func y(_ value: Double) -> CGFloat {
                let fraction = min(1, max(0, (value - lower) / span))
                return plot.maxY - CGFloat(fraction) * plot.height
            }

            // Marked axis: a faint gridline at each tick, labelled in the gutter.
            for tick in ticks {
                let ty = y(tick)
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: ty))
                grid.addLine(to: CGPoint(x: plot.maxX, y: ty))
                ctx.stroke(grid, with: .color(MenuChart.gridColor), lineWidth: 0.5)
                ctx.draw(
                    Text(label(tick)).font(MenuChart.labelFont)
                        .foregroundColor(MenuChart.labelColor),
                    at: CGPoint(x: MenuChart.gutter - 4, y: min(max(ty, 5), size.height - 5)),
                    anchor: .trailing)
            }

            guard !values.isEmpty else { return }
            MenuChart.drawSeries(
                ctx, values: values, minima: minima, maxima: maxima,
                point: { index, value in
                    CGPoint(
                        x: MenuChart.x(
                            index: index, count: values.count, capacity: sampleCapacity,
                            plot: plot),
                        y: y(value))
                }, baselineY: plot.maxY, color: color, gradientTop: plot.minY,
                gradientBottom: plot.maxY)
        }
        .accessibilityHidden(true)
    }
}

extension MenuTrendChart {
    /// A chart of one panel series, band and all.
    init(
        series: MenuTrendSeries, color: Color, domain: ClosedRange<Double>, ticks: [Double],
        label: @escaping (Double) -> String, readoutName: String,
        readoutValue: @escaping (Double) -> String
    ) {
        self.init(
            values: series.values, minima: series.minima, maxima: series.maxima,
            dates: series.dates, sampleCapacity: series.capacity, color: color, domain: domain,
            ticks: ticks, label: label, readoutName: readoutName, readoutValue: readoutValue)
    }
}
