import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Memory tab of the menu bar panel: RAM in use with the pressure verdict
/// beside it, the pressure trend, what the memory is made of, and the top
/// consumers.
struct MenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock

    var body: some View {
        // Re-render once a second while the panel is open, so the live read-outs
        // tick at 1 Hz independently of the main window's refresh rate.
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            summaryCard
            if let system = model.liveSystem { compositionCard(system) }
            MenuRankedList(
                title: "Top memory", metric: metric, apps: menuLists.topFootprintApps,
                processes: menuLists.topFootprint)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        let system = model.liveSystem
        let level = system?.pressureLevel ?? .normal
        let accent = MenuPanelStyle.accent(.ram)
        return MenuPanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MenuPanelFigure(text: system.map { ByteFormat.string(usedBytes($0)) } ?? "--")
                if let system, system.totalRAM > 0 {
                    let share = Double(usedBytes(system)) / Double(system.totalRAM) * 100
                    Text(
                        verbatim:
                            "\(t("of %@", ByteFormat.string(system.totalRAM))) · \(Int(share.rounded()))%"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                // The verdict is named, not just stated. A bare "47" reads as a
                // share of something, one word from a RAM figure in the eighties:
                // two unlike numbers, and nothing to say which is which. The
                // pressure index is a 0 to 100 health signal
                // (docs/pressure-index.md), not a share of RAM.
                MenuStatusPill(text: pressureText(level, system), color: level.color)
                    .help(
                        "How hard the memory system is working, 0 to 100: compression, swap, and the trend. Not the share of RAM in use, which is below."
                    )
            }
            MenuChartHeader(title: "Memory pressure")
            MenuTrendChart(
                series: model.menuTrend(.memoryPressure, range: chartRange),
                color: level == .normal ? accent : level.color,
                domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" },
                readoutName: t("Memory pressure"), readoutValue: { "\(Int($0.rounded()))%" }
            )
            .frame(height: MenuChart.height)
        }
    }

    private func pressureText(_ level: PressureLevel, _ system: SystemSample?) -> String {
        guard let percent = system?.pressurePercent else {
            return t("Pressure: %@", level.label)
        }
        return t("Pressure: %@", "\(level.label) \(Int(percent.rounded()))")
    }

    // MARK: - Composition

    private func compositionCard(_ system: SystemSample) -> some View {
        let accent = MenuPanelStyle.accent(.ram)
        let total = Double(max(system.totalRAM, 1))
        let parts: [(label: String, bytes: UInt64, color: Color)] = [
            (t("App"), system.appMemory, accent),
            (t("Wired"), system.wired, accent.opacity(0.55)),
            (t("Compressed"), system.compressed, accent.opacity(0.3)),
        ]
        let used = usedBytes(system)
        let free = system.totalRAM > used ? system.totalRAM - used : 0
        return MenuPanelCard {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: geometry.size.width * Double(part.bytes) / total)
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(MenuPanelStyle.well)
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    legendRow(parts[0].color, parts[0].label, parts[0].bytes)
                    legendRow(parts[1].color, parts[1].label, parts[1].bytes)
                }
                GridRow {
                    legendRow(parts[2].color, parts[2].label, parts[2].bytes)
                    legendRow(nil, t("Free"), free)
                }
            }
            .padding(.top, 9)
            swapLine(system)
                .padding(.top, 8)
        }
    }

    private func legendRow(_ color: Color?, _ label: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color ?? Color.clear)
                .overlay {
                    if color == nil {
                        RoundedRectangle(cornerRadius: 2.5)
                            .strokeBorder(Color.secondary.opacity(0.6))
                    }
                }
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(ByteFormat.string(bytes))
                .font(MenuPanelStyle.valueFont(size: 11.5))
                .lineLimit(1)
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .combine)
    }

    /// How much memory has been pushed out to disk.
    ///
    /// It is none of the figures on the line above: swap lives on the SSD, not
    /// in RAM, so the same "82% used" means one thing with nothing swapped and
    /// something else entirely with gigabytes of it. The pressure index at the
    /// top of the panel already counts swap without ever saying how much of it
    /// there is, and this is the figure the heavy-swap alarm fires on.
    private func swapLine(_ system: SystemSample) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "internaldrive")
                .imageScale(.small)
            if system.swapUsed > 0 {
                // Formatted into a local first: the localisation audit reads the
                // key straight off the literal, and it cannot see through a call
                // with brackets of its own inside the interpolation.
                let swapped = ByteFormat.string(system.swapUsed)
                Text("\(swapped) swapped to disk")
            } else {
                Text("No swap in use")
            }
            Spacer()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .help(
            "Swap is memory moved out to disk. A flat line at zero is ideal; a sustained climb under pressure is the real warning sign."
        )
    }

    /// Activity Monitor's "Memory Used": app memory plus wired plus compressed.
    /// Cached files are reclaimable and excluded.
    private func usedBytes(_ system: SystemSample) -> UInt64 {
        system.appMemory &+ system.wired &+ system.compressed
    }

    // MARK: - Top consumers

    private var metric: MenuRankedMetric {
        MenuRankedMetric(
            parts: { [Double($0.physFootprint)] }, colors: [MenuPanelStyle.accent(.ram)],
            format: { ByteFormat.string(UInt64(max($0, 0))) }, valueWidth: 54,
            trail: { [model] in model.trail(for: $0) },
            isLeaking: { [model] in model.leakingProcessIDs.contains($0.id) })
    }
}

/// Show the standard macOS About panel — app name + icon, "Version X (build)"
/// from Info.plist, and the copyright line. Activates the app first so the panel
/// comes to the front from a menu-bar popover (an accessory app isn't frontmost).
@MainActor func showStandardAboutPanel() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [:])
}
