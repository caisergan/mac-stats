import MacPerfMonitorCore
import SwiftUI

/// A compact mirrored throughput chart for the menu bar panel: the first
/// direction rises from a centre line, the second drops below it, both scaled
/// to their shared peak so the smaller one stays readable instead of vanishing
/// under the larger, as it would on one overlaid axis. Network plots download
/// over upload, disk plots read over write. Uses the same line and soft-area
/// body as `MenuTrendChart`, with the shared peak captioned at the top-left as
/// the marked axis. On the overview ranges each side draws its bucket means
/// inside a band reaching the bucket maxima, and the scale and caption follow
/// the band, so a burst is never cut off or understated. Canvas-drawn, cheap
/// to redraw at 1 Hz.
struct MenuMirroredChart: View {
    struct Side {
        let series: MenuTrendSeries
        /// Already localised, for the hover read-out.
        let name: String
        let color: Color
    }

    let up: Side
    let down: Side

    /// The scale both directions share, stated here as well as in the drawing
    /// so the hover marker lands on the trace rather than beside it.
    private var upper: Double { peak * 1.2 }

    private var peak: Double {
        max(up.series.top ?? 0, down.series.top ?? 0, 1)
    }

    /// The slot count both sides share. They are cut from the same samples, so
    /// they agree; the larger wins should they ever not.
    private var capacity: Int {
        max(up.series.capacity, down.series.capacity)
    }

    var body: some View {
        canvas
            .overlay(
                MenuChartHoverOverlay(
                    series: [up, down].map { side in
                        MenuChartSeries(
                            name: side.name, color: side.color, values: side.series.values,
                            peaks: side.series.maxima, format: { ByteFormat.rate(max($0, 0)) })
                    },
                    dates: up.series.dates, sampleCapacity: capacity,
                    scale: .mirrored(upper: upper),
                    plotRect: { MenuChart.plotRect(in: $0, reserveGutter: false) })
            )
    }

    private var canvas: some View {
        Canvas { ctx, size in
            // No gutter: the throughput labels are too wide for one, so the shared
            // peak is captioned at the top-left instead.
            let plot = MenuChart.plotRect(in: size, reserveGutter: false)
            let mid = plot.midY
            let halfHeight = plot.height / 2
            // Scale tight to the visible peak (a little headroom so it doesn't clip),
            // not the coarse 1, 2, 5 rounding: the trace then fills the height and the
            // axis adapts as throughput changes, instead of low traffic reading flat.
            let upper = self.upper

            // Centre line + peak caption: the marked axis for both directions.
            var centre = Path()
            centre.move(to: CGPoint(x: plot.minX, y: mid))
            centre.addLine(to: CGPoint(x: plot.maxX, y: mid))
            ctx.stroke(centre, with: .color(MenuChart.gridColor), lineWidth: 0.5)
            ctx.draw(
                Text(t("%@ peak", ByteFormat.rate(peak))).font(MenuChart.labelFont)
                    .foregroundColor(MenuChart.labelColor),
                at: CGPoint(x: plot.minX, y: plot.minY + 4), anchor: .topLeading)

            for (side, rising) in [(up, true), (down, false)] {
                let series = side.series
                MenuChart.drawSeries(
                    ctx, values: series.values, minima: series.minima, maxima: series.maxima,
                    point: { index, value in
                        let height = CGFloat(min(1, max(0, value / upper))) * halfHeight
                        return CGPoint(
                            x: MenuChart.x(
                                index: index, count: series.values.count, capacity: capacity,
                                plot: plot),
                            y: rising ? mid - height : mid + height)
                    }, baselineY: mid, color: side.color,
                    gradientTop: rising ? plot.minY : plot.maxY, gradientBottom: mid)
            }
        }
        .accessibilityHidden(true)
    }
}
