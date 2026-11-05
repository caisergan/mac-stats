import AppKit
import MacPerfMonitorCore
import SwiftUI

enum CombinedMenuBarPanel: Hashable {
    case metric(MenuBarMetric)
    case alerts
}

@MainActor
final class CombinedMenuBarPanelSelection: ObservableObject {
    @Published var panel: CombinedMenuBarPanel

    init(panel: CombinedMenuBarPanel) {
        self.panel = panel
    }
}

struct CombinedMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configuration: CombinedMenuBarConfiguration
    @EnvironmentObject private var updateController: UpdateController
    @EnvironmentObject private var menuClock: MenuClock
    @EnvironmentObject private var components: AppComponentsManager
    @EnvironmentObject private var notchDisplay: NotchDisplayController
    @AppStorage(AskAvailability.enabledKey) private var askEnabled = true

    @ObservedObject var selection: CombinedMenuBarPanelSelection

    let selectionChanged: (CombinedMenuBarPanel) -> Void
    let dismiss: () -> Void

    init(
        selection: CombinedMenuBarPanelSelection,
        selectionChanged: @escaping (CombinedMenuBarPanel) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.selection = selection
        self.selectionChanged = selectionChanged
        self.dismiss = dismiss
    }

    var body: some View {
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            metricSelector
            alertBanner
            content
                .id(selection.panel)
            commandBar
        }
        .padding(MenuPanelStyle.padding)
        .frame(width: MenuPanelStyle.width)
        .onAppear {
            menuClock.open()
            selectionChanged(selection.panel)
        }
        .onDisappear { menuClock.close() }
        .onChange(of: selection.panel) { _, panel in selectionChanged(panel) }
    }

    private var metricSelector: some View {
        let readouts = Dictionary(
            // The selector only prints the figures, so it asks for the default
            // shapes rather than the user's: none of them pull in chart history.
            uniqueKeysWithValues: CombinedMenuBarReadouts.current(
                for: MenuBarMetric.allCases, styles: [:], model: model
            ).map { ($0.metric, $0) })
        return HStack(spacing: 2) {
            ForEach(Self.selectorMetrics) { metric in
                let readout = readouts[metric]
                // Pressure has no chip of its own, so its alarms and its
                // highlight ride on RAM: the two open the same panel.
                let showsAlarm =
                    readout?.isAlarm == true
                    || (metric == .ram && readouts[.pressure]?.isAlarm == true)
                Button {
                    selection.panel = .metric(metric)
                } label: {
                    chip(
                        metric: metric, readout: readout, showsAlarm: showsAlarm,
                        isCurrent: selectedMetric.map(Self.selectorMetric(for:)) == metric)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                // Built with t() rather than interpolated: `metric.title` is a
                // String, so the ternary types as String and the interpolated
                // literal would never be looked up, leaving ", shown in the menu
                // bar" in English beside an already-translated title.
                .help(
                    configuration.isSelected(metric)
                        ? t("%@, shown in the menu bar", metric.title)
                        : metric.title
                )
                .accessibilityLabel(metric.title)
                .accessibilityValue(readout?.value ?? "Unavailable")
            }
        }
        .padding(3)
        .background(
            MenuPanelStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// One cell of the selector: the metric's symbol with its live figure, or a
    /// throughput read-out's two figures, directly under it.
    ///
    /// The cell states its height and pins its symbol to the top, so one row of
    /// symbols and one row of figures hold however many figures a cell carries.
    /// A figure too wide for the cell shrinks to fit rather than truncating.
    private func chip(
        metric: MenuBarMetric, readout: CombinedMenuBarReadout?, showsAlarm: Bool,
        isCurrent: Bool
    ) -> some View {
        let rows = readout?.directionRows ?? [(text: "--", isInbound: true)]
        return VStack(spacing: 2) {
            Image(systemName: Self.selectorSymbol(for: metric))
                .font(.system(size: 13))
                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                .frame(height: 15)
            Group {
                if rows.count > 1 {
                    VStack(alignment: .leading, spacing: -1) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 1) {
                                Image(systemName: row.isInbound ? "arrow.down" : "arrow.up")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(
                                        isCurrent
                                            ? Color.white
                                            : Self.directionColor(metric, row.isInbound))
                                Text(MenuFigureText.compactRate(row.text))
                            }
                        }
                    }
                    .font(MenuPanelStyle.valueFont(size: 10))
                } else {
                    Text(rows[0].text)
                        .font(MenuPanelStyle.valueFont(size: 13))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(isCurrent ? Color.white : Color.primary)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
        .frame(height: Self.chipHeight, alignment: .top)
        .background(
            isCurrent ? MenuPanelStyle.selectedFill(metric) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            if showsAlarm {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    /// The height every chip gets: enough for the symbol and the two figures a
    /// throughput read-out stacks under it, which is the tallest a chip can be.
    ///
    /// Stated rather than taken from the tallest chip, because a chip that asks
    /// for whatever height is going is a chip that takes it.
    private static let chipHeight: CGFloat = 50

    /// The symbol a chip wears. Energy and Sensors differ from their menu bar
    /// read-outs here: side by side in one row, a bolt says less than a battery
    /// and two thermometers cannot be told apart.
    static func selectorSymbol(for metric: MenuBarMetric) -> String {
        switch metric {
        case .energy: return "battery.75percent"
        case .sensors: return "gauge.with.dots.needle.50percent"
        default: return metric.symbolName
        }
    }

    /// The colour of a chip's direction arrow: the same as the metric's chart.
    private static func directionColor(_ metric: MenuBarMetric, _ isInbound: Bool) -> Color {
        if metric == .disk { return isInbound ? DiskStyle.read : DiskStyle.write }
        return isInbound ? NetworkStyle.download : NetworkStyle.upload
    }

    /// The chips the panel offers.
    ///
    /// Memory pressure is deliberately absent. It is still a read-out in its
    /// own right and still gets its own menu bar item, but as a chip it earned
    /// nothing: it opens the same memory panel RAM opens, and that panel already
    /// leads with the pressure verdict and the index itself. Two chips for one
    /// destination cost every other chip the width it needed, which is what
    /// broke "RAM" onto two lines once Sensors joined the row.
    static let selectorMetrics: [MenuBarMetric] = MenuBarMetric.allCases.filter {
        $0 != .pressure
    }

    /// The chip that stands for a metric. Opening the panel on the pressure
    /// read-out highlights RAM, since that is where pressure now lives.
    static func selectorMetric(for metric: MenuBarMetric) -> MenuBarMetric {
        metric == .pressure ? .ram : metric
    }

    /// The metric panel on show, nil on the Alerts panel.
    private var selectedMetric: MenuBarMetric? {
        if case .metric(let metric) = selection.panel { return metric }
        return nil
    }

    /// What is active, shown only while something is, and one click from the
    /// alerts themselves. The bell in the footer is the way there at other times.
    @ViewBuilder private var alertBanner: some View {
        if let first = model.activeAlerts.first, selection.panel != .alerts {
            Button {
                selection.panel = .alerts
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(first.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if model.activeAlerts.count > 1 {
                        Text(t("+%@ more", String(model.activeAlerts.count - 1)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    Color.orange.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the active alerts")
        }
    }

    /// The tab's content. Metric tabs scroll inside a height clamp, so a short
    /// tab costs no empty space and a long one stays on the screen; the Alerts
    /// panel keeps its own bounded scroller.
    @ViewBuilder private var content: some View {
        if selection.panel == .alerts {
            MenuPanelCard(horizontal: 12, vertical: 4) { metricContent }
        } else {
            MenuPanelHeightClamp(
                maximum: MenuPanelStyle.maximumContentHeight(
                    screenHeight: NSScreen.main?.visibleFrame.height ?? 900)
            ) {
                ScrollView(.vertical) { metricContent }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    @ViewBuilder private var metricContent: some View {
        switch selection.panel {
        case .alerts:
            AlertsMenuBarContentView(
                alerts: model.activeAlerts, processes: model.displayProcesses,
                observations: model.alertObservations,
                inspectAlert: { alert in
                    guard let request = AlertInvestigation(alerts: [alert]) else { return }
                    dismiss()
                    appState.alertInvestigation = request
                    appState.requestedMainTab = .analytics
                    NotificationCenter.default.post(
                        name: .macperfmonitorShowMainWindow, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }, snooze: { id, seconds in model.snoozeAlert(id, seconds: seconds) }
            ) { identity in
                dismiss()
                appState.navigationTarget = identity
                appState.requestedMainTab = .processes
                NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        case .metric(.pressure), .metric(.ram):
            MenuBarContentView()
        case .metric(.cpu):
            CPUMenuBarContentView()
        case .metric(.gpu):
            GPUMenuBarContentView()
        case .metric(.energy):
            BatteryMenuBarContentView()
        case .metric(.network):
            NetworkMenuBarContentView(openSettings: openSettings)
        case .metric(.disk):
            DiskMenuBarContentView()
        case .metric(.temperature):
            TemperatureMenuBarContentView()
        case .metric(.sensors):
            SensorsMenuBarContentView()
        }
    }

    /// Open the tab's own place in the main window, then the three things that
    /// are not about this tab: alerts, settings and everything else.
    private var commandBar: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
                appState.requestedMainTab = openDestination
                NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(openTitle, systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuFooterButtonStyle())

            Button {
                selection.panel = .alerts
            } label: {
                Image(systemName: "bell")
                    .frame(width: 26)
                    .overlay(alignment: .topTrailing) { alertBadge }
            }
            .buttonStyle(MenuFooterButtonStyle(isActive: selection.panel == .alerts))
            .help("Alerts")
            .accessibilityLabel("Alerts")
            .accessibilityValue(String(model.activeAlerts.count))
            .accessibilityIdentifier("menubar.alerts.open")

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 26)
            }
            .buttonStyle(MenuFooterButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")

            moreMenu
        }
    }

    /// The count of active alerts, or a quiet dot when the app is only watching
    /// something, so the bell says there is something to read either way.
    @ViewBuilder private var alertBadge: some View {
        if !model.activeAlerts.isEmpty {
            Text(model.activeAlerts.count, format: .number)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 13, minHeight: 13)
                .background(Color.red, in: Capsule())
                .offset(x: -1, y: -6)
                .accessibilityHidden(true)
        } else if !model.alertObservations.isEmpty {
            Circle()
                .fill(Color.secondary)
                .frame(width: 6, height: 6)
                .offset(x: -5, y: -1)
                .accessibilityHidden(true)
        }
    }

    private func openSettings() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .macperfmonitorShowSettings, object: nil)
    }

    private var moreMenu: some View {
        Menu {
            if AskAvailability.isOffered(enabled: askEnabled) {
                Button("Ask About This Mac", systemImage: "sparkles") {
                    dismiss()
                    WindowOpenBridge.shared.open(id: WindowID.ask)
                }
                Divider()
            }
            Button(
                LocalizedStringKey(
                    components.historyLogging
                        ? "Pause history logging" : "Resume history logging"),
                systemImage: components.historyLogging ? "pause.circle" : "record.circle"
            ) {
                components.historyLogging.toggle()
            }
            // Only on Macs that have a notch to hide. Status items are confined
            // to the menu bar right of it, so on a crowded bar this is what
            // makes room for them; see `NotchDisplayController`.
            if notchDisplay.isSupported {
                Button(
                    LocalizedStringKey(
                        notchDisplay.isNotchHidden ? "Show Notch" : "Hide Notch"),
                    systemImage: "menubar.rectangle"
                ) {
                    dismiss()
                    notchDisplay.setNotchHidden(!notchDisplay.isNotchHidden)
                }
                .help(
                    notchDisplay.isNotchHidden
                        ? "Use the full height of the display again, with the menu bar either side of the camera housing."
                        : "Drop the menu bar below the camera housing so it runs edge to edge and fits more items. Costs a little screen height, and applies to every app."
                )
            }
            Divider()
            Button("About \(AppInfo.displayName)", systemImage: "info.circle") {
                dismiss()
                showStandardAboutPanel()
            }
            Button("Check for Updates\u{2026}", systemImage: "arrow.down.circle") {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
            Divider()
            Button("Quit \(AppInfo.displayName)", systemImage: "power") {
                NSApp.terminate(nil)
            }
            Divider()
            Text(t("Version %1$@, build %2$@", AppInfo.version, AppInfo.build))
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 26, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 38, height: 32)
        .background(
            MenuPanelStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private var openDestination: MainWindowTab {
        switch selection.panel {
        case .alerts: return .insights
        case .metric(.cpu): return .processes
        case .metric(.energy): return .battery
        case .metric(.network): return .network
        case .metric(.disk): return .diskUsage
        case .metric(.gpu): return .gpu
        case .metric(.pressure), .metric(.ram): return .dashboard
        // The Thermals section lives on the Energy tab, and so does the rest of
        // what the sensors panel measures.
        case .metric(.temperature), .metric(.sensors): return .battery
        }
    }

    private var openTitle: LocalizedStringKey {
        switch openDestination {
        case .processes: return "Open Processes"
        case .battery: return "Open Energy"
        case .network: return "Open Network"
        case .diskUsage: return "Open Disk"
        case .gpu: return "Open GPU"
        case .dashboard: return "Open Dashboard"
        case .insights: return "Open Insights"
        default: return "Open"
        }
    }
}

/// A filled footer button. The fill deepens under the pointer and while the
/// panel it leads to is the one on show.
private struct MenuFooterButtonStyle: ButtonStyle {
    var isActive = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(
                hovering || isActive ? MenuPanelStyle.hover.opacity(2) : MenuPanelStyle.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
