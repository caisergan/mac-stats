import MacPerfMonitorCore
import SwiftUI

/// The CPU tab of the menu bar panel: total CPU with its verdict and trend, the
/// per-core grid (badged P/E on Apple Silicon), and the top consumers.
struct CPUMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default

    private let topology = CPUTopology.current

    var body: some View {
        // Re-render once a second while the panel is open, so the live CPU %,
        // sparkline and core grid tick at 1 Hz independently of the main
        // window's refresh rate.
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            summaryCard
            coresCard
            MenuRankedList(
                title: "Top CPU", metric: metric, apps: menuLists.topCPUApps,
                processes: menuLists.topCPU)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        let cpu = model.smoothedCPU
        let usage = cpu?.totalUsage ?? 0
        let level = CPULevel(fraction: usage)
        return MenuPanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MenuPanelFigure(text: cpu == nil ? "--" : "\(Int((usage * 100).rounded()))%")
                MenuStatusPill(text: level.label, color: level.color)
                Spacer(minLength: 0)
            }
            MenuChartHeader(title: "CPU")
            MenuTrendChart(
                series: model.menuTrend(.cpuLoad, range: chartRange),
                color: level == .light ? MenuPanelStyle.accent(.cpu) : level.color,
                domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" },
                readoutName: t("CPU"), readoutValue: { "\(Int($0.rounded()))%" }
            )
            .frame(height: MenuChart.height)
        }
    }

    // MARK: - Cores

    private var coresCard: some View {
        MenuPanelCard {
            HStack(spacing: 8) {
                MenuPanelHeading(title: "Cores")
                Spacer(minLength: 0)
                Text(coreSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.bottom, 7)
            CoreGridView(cores: model.smoothedCPU?.cores ?? [], barHeight: 28)
        }
    }

    /// A static one-liner naming the chip and core layout, independent of the
    /// live sample so it reads even before the first delta lands.
    private var coreSummary: String {
        let total = topology.logicalCores
        if topology.efficiencyCoreCount > 0 && topology.performanceCoreCount > 0 {
            return
                "\(topology.brand) · \(total) cores (\(topology.performanceCoreCount)P + \(topology.efficiencyCoreCount)E)"
        }
        return "\(topology.brand) · \(total) core\(total == 1 ? "" : "s")"
    }

    // MARK: - Top consumers

    private var metric: MenuRankedMetric {
        MenuRankedMetric(
            parts: { [$0.cpuPercent] }, colors: [MenuPanelStyle.accent(.cpu)],
            format: CPUFormat.percent, trail: { [model] in model.cpuTrail(for: $0) })
    }
}

/// Shared CPU-percentage formatting (percent of one core, Activity-Monitor
/// convention): one decimal under 10% so small movers are legible, whole numbers
/// above.
enum CPUFormat {
    static func percent(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.1f%%", max(0, value))
        }
        return String(format: "%.0f%%", value)
    }
}
