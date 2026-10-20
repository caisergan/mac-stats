import MacPerfMonitorCore
import SwiftUI

/// The Temperature panel in the combined menu bar item: the hottest CPU die
/// sensor as the headline, tinted by macOS's thermal pressure verdict, a live
/// sparkline, and the per-domain readings. No process list: temperatures
/// belong to domains, and the Energy tab's Thermals section holds the history.
struct TemperatureMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuClock: MenuClock

    var embedded = false

    var body: some View {
        _ = menuClock.tick
        return
            panel
            .onAppear { if !embedded { menuClock.open() } }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let system = model.liveSystem, system.cpuDieC != nil {
                header(system)
                sparkline
                Divider()
                details(system)
            } else {
                Text("Reading sensors\u{2026}")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            }
            if !embedded { MenuVersionFooter() }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 300)
    }

    private func header(_ system: SystemSample) -> some View {
        let pressure = system.thermalPressure ?? .nominal
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("CPU die").font(.caption).foregroundStyle(.secondary)
                Text(pressure.isThrottling ? t("Throttling (%@)", pressure.label) : pressure.label)
                    .font(.headline)
                    .foregroundStyle(pressure.isThrottling ? pressure.color : .primary)
            }
            Spacer()
            Text((system.cpuDieC).map { TemperatureFormat.string($0) } ?? "--")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(pressure.color)
                .monospacedDigit()
        }
    }

    /// The CPU die trend over the panel's chart range, the same shape as the
    /// GPU panel's utilization sparkline.
    private var sparkline: some View {
        let series = model.menuTrend(.cpuDie, range: chartRange)
        let top = max(60, ((series.top ?? 60) / 10).rounded(.up) * 10 + 10)
        return MenuSparklineChart(
            series: series, color: ThermalStyle.cpu, domain: 20...top, name: t("CPU die"),
            format: { TemperatureFormat.string($0) })
    }

    private func details(_ system: SystemSample) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            if let gpu = system.gpuDieC {
                detail("GPU die", TemperatureFormat.string(gpu))
            }
            if let ssd = system.ssdTemperatureC {
                detail("SSD", TemperatureFormat.string(ssd))
            }
            if system.batteryPresent, system.batteryTemperatureCelsius > 0 {
                detail("Battery", TemperatureFormat.string(system.batteryTemperatureCelsius))
            }
            if let fan = system.fanRPM {
                detail("Fans", fan == 0 ? t("Off") : t("%@ rpm", String(Int(fan.rounded()))))
            }
            detail("Thermal pressure", (system.thermalPressure ?? .nominal).label)
        }
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit()).gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
