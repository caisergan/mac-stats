import MacPerfMonitorCore
import SwiftUI

/// The Temperature tab of the menu bar panel: the hottest CPU die sensor as the
/// headline with macOS's thermal pressure verdict, its trend, and the
/// per-domain readings. No process list: temperatures belong to domains, and
/// the Energy tab's Thermals section holds the history.
struct TemperatureMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuClock: MenuClock

    var body: some View {
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            if let system = model.liveSystem, system.cpuDieC != nil {
                summaryCard(system)
                MenuPanelCard { MenuDetailGrid(rows: details(system)) }
            } else {
                MenuPanelCard {
                    Text("Reading sensors\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func summaryCard(_ system: SystemSample) -> some View {
        let pressure = system.thermalPressure ?? .nominal
        let series = model.menuTrend(.cpuDie, range: chartRange)
        let top = max(60, ((series.top ?? 60) / 10).rounded(.up) * 10 + 10)
        return MenuPanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MenuPanelFigure(text: system.cpuDieC.map { TemperatureFormat.string($0) } ?? "--")
                MenuStatusPill(
                    text: pressure.isThrottling
                        ? t("Throttling (%@)", pressure.label)
                        : t("Thermal pressure: %@", pressure.label),
                    color: pressure.color)
                Spacer(minLength: 0)
            }
            MenuChartHeader(title: "CPU die")
            MenuTrendChart(
                series: series,
                color: pressure.isThrottling ? pressure.color : MenuPanelStyle.accent(.temperature),
                domain: 20...top, ticks: [20, top], label: { TemperatureFormat.string($0) },
                readoutName: t("CPU die"), readoutValue: { TemperatureFormat.string($0) }
            )
            .frame(height: MenuChart.height)
        }
    }

    private func details(_ system: SystemSample) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let gpu = system.gpuDieC {
            rows.append((t("GPU die"), TemperatureFormat.string(gpu)))
        }
        if let ssd = system.ssdTemperatureC {
            rows.append((t("SSD"), TemperatureFormat.string(ssd)))
        }
        if system.batteryPresent, system.batteryTemperatureCelsius > 0 {
            rows.append((t("Battery"), TemperatureFormat.string(system.batteryTemperatureCelsius)))
        }
        if let fan = system.fanRPM {
            rows.append((t("Fans"), fan == 0 ? t("Off") : t("%@ rpm", String(Int(fan.rounded())))))
        }
        return rows
    }
}
