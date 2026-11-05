import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Network tab of the menu bar panel: download and upload with a mirrored
/// throughput chart, the connection and session totals, then the top network
/// apps (when per-app tracking is on) or a prompt to turn it on.
struct NetworkMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock

    /// Shared with `SamplerModel`/Settings: whether per-app attribution is on.
    @AppStorage(SamplerModel.perAppNetworkDefaultsKey) private var trackPerApp = true

    /// Active ping-based latency/jitter, run ONLY while this tab is open.
    @StateObject private var latency = LatencyMonitor()

    /// Opens Settings from the per-app prompt; the panel owns how.
    let openSettings: () -> Void

    var body: some View {
        // Re-render once a second while the panel is open, independently of the
        // main window's refresh rate.
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            throughputCard
            MenuPanelCard {
                NetworkMenuSummary(
                    network: model.latestNetwork, latencyMs: latency.latencyMs,
                    jitterMs: latency.jitterMs,
                    packetLoss: latency.latencyMs != nil || latency.packetLoss > 0
                        ? latency.packetLoss : nil)
            }
            topApps
        }
        .onAppear { latency.start() }
        .onDisappear { latency.stop() }
    }

    // MARK: - Throughput

    private var throughputCard: some View {
        let rates = model.networkRates
        return MenuPanelCard {
            HStack(spacing: 22) {
                MenuRateFigure(
                    symbol: NetworkStyle.downSymbol, tint: NetworkStyle.download,
                    text: NetworkMenuSummary.rateText(rates?.inBytesPerSec), label: "Download")
                MenuRateFigure(
                    symbol: NetworkStyle.upSymbol, tint: NetworkStyle.upload,
                    text: NetworkMenuSummary.rateText(rates?.outBytesPerSec), label: "Upload")
                Spacer(minLength: 0)
            }
            MenuChartHeader(title: "Throughput")
            MenuMirroredChart(
                up: .init(
                    series: model.menuTrend(.networkIn, range: chartRange),
                    name: t("Download"), color: NetworkStyle.download),
                down: .init(
                    series: model.menuTrend(.networkOut, range: chartRange),
                    name: t("Upload"), color: NetworkStyle.upload)
            )
            .frame(height: MenuChart.networkHeight)
        }
    }

    // MARK: - Top apps

    @ViewBuilder private var topApps: some View {
        if !trackPerApp {
            perAppPrompt
        } else {
            MenuRankedList(
                title: "Top network apps",
                metric: MenuRankedMetric(
                    parts: { [$0.networkBytesPerSec] }, colors: [NetworkStyle.download],
                    format: NetworkMenuSummary.rateText, valueWidth: 58,
                    trail: { [model] in model.networkTrail(for: $0) }),
                apps: Array(menuLists.topNetworkApps.prefix(6)),
                processes: Array(menuLists.topNetwork.prefix(6)),
                emptyText: t("No app network activity right now."))
        }
    }

    /// Shown when per-app tracking is off: explains the opt-in and offers a path
    /// to Settings, since the system-wide rates above work without it.
    private var perAppPrompt: some View {
        MenuPanelCard {
            MenuPanelHeading(title: "Per-app network usage")
                .padding(.bottom, 6)
            Text(
                "Turn on per-app network tracking to see which apps are using the network. It is off by default because it runs an extra system tool."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings\u{2026}", action: openSettings)
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 6)
        }
    }
}

/// A live rate as a headline: its direction arrow, the figure with a quieter
/// unit, and what it measures. Shared by the Network and Disk tabs.
struct MenuRateFigure: View {
    let symbol: String
    let tint: Color
    let text: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                MenuPanelFigure(text: text, size: 26)
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct NetworkMenuSummary: View {
    static let height: CGFloat = 94

    let network: NetworkSample?
    let latencyMs: Double?
    let jitterMs: Double?
    let packetLoss: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    MenuDetailRow(
                        label: t("Interface"), value: network?.primaryInterface ?? "--",
                        monospaced: true)
                    MenuDetailRow(
                        label: t("IPv4"), value: network?.localIPv4 ?? "--", monospaced: true)
                }
                GridRow {
                    MenuDetailRow(
                        label: t("Session download"),
                        value: (network?.sessionInBytes).map { ByteFormat.string($0) } ?? "--")
                    MenuDetailRow(
                        label: t("Session upload"),
                        value: (network?.sessionOutBytes).map { ByteFormat.string($0) } ?? "--")
                }
            }
            HStack(spacing: 8) {
                MenuStatTile(label: t("Latency"), value: Self.millisecondsText(latencyMs))
                MenuStatTile(label: t("Jitter"), value: Self.millisecondsText(jitterMs))
                MenuStatTile(label: t("Packet loss"), value: Self.lossText(packetLoss))
                    .foregroundStyle((packetLoss ?? 0) > 0.01 ? Color.orange : Color.primary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .top)
        .transaction { $0.animation = nil }
    }

    static func millisecondsText(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "--" }
        return String(format: "%.1f ms", milliseconds)
    }

    static func lossText(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return "--" }
        return String(format: "%.0f%%", fraction * 100)
    }

    static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "--" }
        return ByteFormat.rate(bytesPerSecond)
    }
}
