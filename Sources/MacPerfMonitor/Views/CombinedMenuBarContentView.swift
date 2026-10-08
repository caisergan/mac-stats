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
        return VStack(alignment: .leading, spacing: 10) {
            metricSelector
            alarmSummary
            Divider()
            metricContent
                .id(selection.panel)
            Divider()
            commandBar
            // The sensors list is long enough without a version number under
            // it; every other tab is short enough to carry one.
            if selection.panel != .metric(.sensors) {
                MenuVersionFooter()
            }
        }
        .padding(12)
        .frame(width: 404)
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
        return HStack(spacing: 0) {
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.22)))
    }

    /// One cell of the selector: the three-letter title with the metric's figure
    /// (or a throughput read-out's two figures) directly under it.
    ///
    /// Every part of this is about keeping one row of titles and one row of
    /// figures. The stack is pinned to the top of a cell tall enough for the
    /// tallest of them, so NET and DSK cannot push their own titles up out of
    /// line with their neighbours' the way they did when each cell centred
    /// whatever it happened to hold.
    /// The alarm triangle hangs off the title as an overlay rather than sitting
    /// in the row with it: inline it shoved the title off centre, and reserving
    /// its width on both sides to stop that left a three-letter title nothing to
    /// sit in. Hung off the end it still reads as "RAM, warning" and still
    /// clears the cell edge, because a centred three-letter title leaves more
    /// room beside it than the triangle needs.
    private func chip(
        metric: MenuBarMetric, readout: CombinedMenuBarReadout?, showsAlarm: Bool,
        isCurrent: Bool
    ) -> some View {
        let rows = readout.map { $0.directionRows.map(\.text) } ?? ["--"]
        return VStack(spacing: 2) {
            // Nine read-outs share this row, so the title must never wrap:
            // "RAM" broke onto two lines once Sensors joined and each cell lost
            // a few points.
            Text(metric.shortTitle)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .overlay(alignment: .trailing) {
                    if showsAlarm {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.red)
                            .fixedSize()
                            .offset(x: 11)
                            .accessibilityHidden(true)
                    }
                }
            // One figure gets the room two would have taken, which is most of
            // the cell; two have to be small enough to stack in it. Either way
            // a figure too wide for the cell shrinks to fit rather than
            // truncating: "48.7 MB/s" used to arrive as "48.7 M...".
            VStack(spacing: -2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                }
            }
            .font(
                (rows.count > 1 ? Font.caption2 : Font.body)
                    .weight(.semibold).monospacedDigit()
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 2)
        }
        .foregroundStyle(Color.primary)
        .padding(.top, 5)
        .frame(maxWidth: .infinity)
        .frame(height: Self.chipHeight, alignment: .top)
        .background(isCurrent ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
    }

    /// The height every chip gets: enough for the title and the two figures a
    /// throughput read-out stacks under it, which is the tallest a chip can be.
    ///
    /// Stated rather than taken from the tallest chip, because a chip that asks
    /// for whatever height is going is a chip that takes it: on the Sensors tab,
    /// whose panel is long enough to be given a height rather than asked for
    /// one, the selector grew to fill half the screen.
    private static let chipHeight: CGFloat = 48

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

    private var alarmSummary: some View {
        Button {
            selection.panel = .alerts
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: model.activeAlerts.isEmpty
                        ? (model.alertObservations.isEmpty ? "checkmark.circle" : "eye")
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.activeAlerts.isEmpty ? Color.secondary : .red)
                Text("Alerts")
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if !model.alertObservations.isEmpty {
                    Text(t("Observations: %@", String(model.alertObservations.count)))
                        .foregroundStyle(.secondary)
                }
                Text(model.activeAlerts.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selection.panel == .alerts
                ? Color.accentColor.opacity(0.12)
                : Color.red.opacity(model.activeAlerts.isEmpty ? 0 : 0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityIdentifier("menubar.alerts.open")
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
            MenuBarContentView(embedded: true)
        case .metric(.cpu):
            CPUMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.gpu):
            GPUMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.energy):
            BatteryMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.network):
            NetworkMenuBarContentView(dismiss: dismiss, embedded: true)
        case .metric(.disk):
            DiskMenuBarContentView(dismiss: dismiss)
        case .metric(.temperature):
            TemperatureMenuBarContentView(embedded: true)
        case .metric(.sensors):
            SensorsMenuBarContentView(embedded: true)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                appState.requestedMainTab = openDestination
                NotificationCenter.default.post(name: .macperfmonitorShowMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(openTitle, systemImage: "macwindow")
            }

            Button {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .macperfmonitorShowSettings, object: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Spacer()

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
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .help("More actions")
        }
        .buttonStyle(.borderless)
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
