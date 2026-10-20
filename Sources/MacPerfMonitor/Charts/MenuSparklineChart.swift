import Charts
import MacPerfMonitorCore
import SwiftUI

/// The borderless trend the GPU and temperature panels draw under their
/// headline: a Swift Chart with both axes hidden, plotted edge to edge in the
/// live slots of `LiveChartGeometry.normalizedSlot`. On the overview ranges
/// the soft area becomes a band from each bucket's minimum to its maximum,
/// with the mean as the line, the same reading `MenuTrendChart` gives.
struct MenuSparklineChart: View {
    let series: MenuTrendSeries
    let color: Color
    let domain: ClosedRange<Double>
    /// What the hover read-out calls the series, already localised.
    let name: String
    let format: (Double) -> String

    var body: some View {
        let values = series.values
        let capacity = series.capacity
        // Each run of readings is its own Swift Charts series, so a gap where
        // nothing was read stays open instead of being bridged by the line.
        let points = MenuChart.runs(values).enumerated().flatMap { run, indices in
            indices.map { (offset: $0, element: values[$0], run: run) }
        }
        let band: (lower: [Double], upper: [Double])? = {
            guard let minima = series.minima, let maxima = series.maxima,
                minima.count == values.count, maxima.count == values.count
            else { return nil }
            return (minima, maxima)
        }()
        return Chart(points, id: \.offset) { point in
            let x = LiveChartGeometry.normalizedSlot(
                index: point.offset, count: values.count, capacity: capacity)
            if let band {
                AreaMark(
                    x: .value("t", x), yStart: .value("min", band.lower[point.offset]),
                    yEnd: .value("max", band.upper[point.offset]),
                    series: .value("run", point.run)
                )
                .foregroundStyle(color.opacity(0.2))
            } else {
                AreaMark(
                    x: .value("t", x), y: .value("v", point.element),
                    series: .value("run", point.run)
                )
                .foregroundStyle(color.opacity(0.18))
            }
            LineMark(
                x: .value("t", x), y: .value("v", point.element),
                series: .value("run", point.run)
            )
            .foregroundStyle(color)
            .interpolationMethod(.linear)
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 38)
        .overlay {
            if values.count > 1 {
                MenuChartHoverOverlay(
                    series: [
                        MenuChartSeries(
                            name: name, color: color, values: values, peaks: series.maxima,
                            format: format)
                    ],
                    dates: series.dates, sampleCapacity: capacity,
                    scale: .domain(domain),
                    // Both axes are hidden, so this chart plots edge to edge.
                    plotRect: { CGRect(origin: .zero, size: $0) })
            }
        }
        .opacity(points.count > 1 ? 1 : 0)
    }
}
