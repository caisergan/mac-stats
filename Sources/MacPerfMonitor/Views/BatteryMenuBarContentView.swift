import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Energy tab of the menu bar panel. On a laptop: charge with its state and
/// trend, the power draw, battery health, and the top energy users. On a desktop
/// (no battery): the system's draw and trend, and the top energy users.
struct BatteryMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock

    var body: some View {
        // Re-render once a second while the panel is open, independently of the
        // main window's refresh rate.
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            if let battery = model.latestBattery, battery.isPresent {
                MenuPanelCard {
                    header(battery)
                    MenuChartHeader(title: "Charge")
                    chargeChart(battery)
                }
                powerCard(battery)
                topEnergy
            } else if model.liveSystem == nil {
                MenuPanelCard {
                    Text("Reading energy\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            } else {
                // Desktop: no battery, but the energy leaderboard still matters.
                MenuPanelCard {
                    desktopHeader
                    powerChart
                }
                topEnergy
            }
        }
    }

    /// The header for a Mac with no battery: the measured system power (or just a
    /// bolt before the first reading), with an "on power adapter" note.
    private var desktopHeader: some View {
        let watts = model.latestBattery?.systemPowerWatts ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if watts > 0 {
                MenuPanelFigure(text: BatteryFormat.watts(watts))
                Text("system power")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("Energy").font(.headline)
            }
            Spacer(minLength: 4)
            Text("On power adapter")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Trend charts

    /// Charge over the recent window as a line on a fixed 0–100 scale — matching
    /// the CPU/memory/network header style. Absolute (not peak-relative) so a
    /// steady 80 % reads as a flat line near the top, sloping down while draining /
    /// up while charging.
    @ViewBuilder private func chargeChart(_ battery: BatterySample) -> some View {
        let level = BatteryLevel(percent: battery.chargePercent)
        MenuTrendChart(
            series: model.menuTrend(.batteryCharge, range: chartRange),
            color: battery.isCharging ? BatteryStyle.battery : level.color,
            domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" },
            readoutName: t("Charge"), readoutValue: { "\(Int($0.rounded()))%" }
        )
        .frame(height: MenuChart.height)
    }

    /// Whole-machine power draw as a line on a rounded auto-peak scale, matching
    /// the CPU/memory/network header style. Shown on the desktop (no-battery)
    /// header, where the charge line has nothing to plot; hidden when the SMC
    /// exposes no telemetry.
    @ViewBuilder private var powerChart: some View {
        let watts = model.menuTrend(.systemPower, range: chartRange)
        if let peak = watts.top, peak > 0 {
            let upper = MenuChart.niceUpperBound(peak)
            MenuTrendChart(
                series: watts, color: BatteryStyle.consumer,
                domain: 0...upper, ticks: [0, upper], label: { "\(Int($0.rounded())) W" },
                readoutName: t("System power"), readoutValue: { BatteryFormat.watts($0) }
            )
            .frame(height: MenuChart.height)
        }
    }

    // MARK: - Header

    private func header(_ battery: BatterySample) -> some View {
        let level = BatteryLevel(percent: battery.chargePercent)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            MenuPanelFigure(text: BatteryFormat.percent(battery.chargePercent))
            MenuStatusPill(
                text: stateWord(battery),
                color: battery.isCharging ? BatteryStyle.battery : level.color)
            Spacer(minLength: 4)
            Text(timeRemaining(battery))
                .font(MenuPanelStyle.valueFont(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func stateWord(_ battery: BatterySample) -> String {
        if battery.isCharging { return t("Charging") }
        if battery.isOnAC {
            return battery.chargePercent >= 99 ? t("Battery full") : t("Plugged in")
        }
        return t("On battery")
    }

    private func timeRemaining(_ battery: BatterySample) -> String {
        if battery.isCharging, let m = battery.timeToFullMinutes, m > 0 {
            return t("%@ to full", BatteryFormat.duration(minutes: m))
        }
        if !battery.isOnAC, let m = battery.timeToEmptyMinutes, m > 0 {
            return t("%@ left", BatteryFormat.duration(minutes: m))
        }
        return ""
    }

    // MARK: - Power

    private func powerCard(_ battery: BatterySample) -> some View {
        MenuPanelCard {
            HStack(spacing: 7) {
                Image(systemName: "bolt.horizontal")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(powerLine(battery))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            let tiles = healthTiles(battery)
            if !tiles.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                        MenuStatTile(label: tile.label, value: tile.value)
                    }
                }
                .padding(.top, 9)
            }
        }
    }

    private func healthTiles(_ battery: BatterySample) -> [(label: String, value: String)] {
        var tiles: [(label: String, value: String)] = []
        if let health = battery.healthPercent {
            tiles.append((t("Health"), "\(Int(health.rounded()))%"))
        }
        if let cycles = battery.cycleCount {
            tiles.append((t("Cycles"), String(cycles)))
        }
        if let temp = battery.temperatureCelsius {
            tiles.append((t("Temperature"), BatteryFormat.celsius(temp)))
        }
        return tiles
    }

    private func powerLine(_ battery: BatterySample) -> String {
        if battery.isCharging {
            let base = t("+%@ into battery", BatteryFormat.watts(battery.powerWatts))
            if let w = battery.adapterWatts {
                return [base, t("%@ W adapter", String(w))].joined(separator: " · ")
            }
            return base
        }
        if battery.isOnAC {
            if let w = battery.adapterWatts { return t("On %@ W adapter", String(w)) }
            return t("On power adapter")
        }
        return t("%@ drawing from battery", BatteryFormat.watts(battery.powerWatts))
    }

    // MARK: - Top energy

    private var topEnergy: some View {
        MenuRankedList(
            title: "Top energy users",
            metric: MenuRankedMetric(
                parts: { [$0.energyImpact] }, colors: [MenuPanelStyle.accent(.energy)],
                format: { String(format: "%.0f", $0) }, valueWidth: 36,
                trail: { [model] in model.energyTrail(for: $0) }),
            apps: Array(menuLists.topEnergyApps.prefix(6)),
            processes: Array(menuLists.topEnergy.prefix(6)))
    }
}
