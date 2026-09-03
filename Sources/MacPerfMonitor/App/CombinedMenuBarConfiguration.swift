import Combine
import Foundation
import MacPerfMonitorCore

enum MenuBarMetric: String, CaseIterable, Codable, Identifiable {
    /// The 0...100 memory pressure index (see docs/pressure-index.md). This is a
    /// health signal, NOT the share of RAM in use: `ram` is that figure.
    case pressure
    /// Share of installed RAM in use, the figure Activity Monitor calls
    /// "Memory Used" (app memory + wired + compressed) over the installed total.
    case ram
    case cpu
    case gpu
    case energy
    case temperature
    case network
    case disk
    /// The individual SMC sensors the user picked, drawn side by side. Unlike
    /// every other read-out this one has no single figure of its own: it is
    /// whatever set of temperatures, voltages, currents and power rails the
    /// user chose in Settings, which is how Stats' Sensors module works.
    case sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pressure: return t("Memory Pressure")
        case .ram: return t("Memory Used")
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .energy: return t("Energy")
        case .temperature: return t("Temperature")
        case .network: return t("Network")
        case .disk: return t("Disk")
        case .sensors: return t("Sensors")
        }
    }

    var shortTitle: String {
        switch self {
        case .pressure: return "PRS"
        case .ram: return "RAM"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .energy: return "BAT"
        case .temperature: return "TMP"
        case .network: return "NET"
        case .disk: return "DSK"
        case .sensors: return "SNS"
        }
    }

    /// The widest figure this read-out shows, so its menu bar cell can reserve
    /// that width once rather than resize as the number changes. Nil for the
    /// throughput read-outs, whose figures have no ceiling to reserve for, and
    /// for Sensors, which reserves per pinned sensor instead.
    ///
    /// Two digits, not three: reserving for "100%" costs seven points of
    /// permanent width for a value that is nearly always two digits. The mini
    /// shape drops the unit when a figure will not fit, so 100% renders as
    /// "100" in the same cell, which is what Stats does when a figure outgrows
    /// its widget.
    var menuBarValueTemplate: String? {
        switch self {
        case .pressure, .ram, .cpu, .gpu, .energy: return "00%"
        case .temperature: return "00\u{00B0}"
        case .network, .disk, .sensors: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .pressure: return "gauge.with.dots.needle.bottom.50percent"
        case .ram: return "memorychip"
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .energy: return "bolt.fill"
        case .temperature: return "thermometer.medium"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .sensors: return "thermometer.variable.and.figure"
        }
    }
}

enum MenuBarPresentation: String, CaseIterable, Identifiable {
    case focus
    case strip
    /// One `NSStatusItem` per selected read-out, the way Stats lays its menu bar
    /// out. Each item is independently draggable, so macOS remembers the order
    /// the user puts them in rather than this app fixing it.
    case separate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return t("Focus")
        case .strip: return t("Strip")
        case .separate: return t("Separate")
        }
    }
}

final class CombinedMenuBarConfiguration: ObservableObject {
    static let selectionDefaultsKey = "combinedMenuBarMetrics"
    static let presentationDefaultsKey = "combinedMenuBarPresentation"
    static let focusDefaultsKey = "combinedMenuBarFocus"
    static let stylesDefaultsKey = "combinedMenuBarWidgetStyles"
    static let alarmMarkerDefaultsKey = "combinedMenuBarAlarmMarker"
    static let colorDefaultsKey = "combinedMenuBarLevelColors"
    static let orderDefaultsKey = "combinedMenuBarOrder"
    private static let ramMigrationDefaultsKey = "combinedMenuBarRAMMetricAdded"
    private static let legacyCPUKey = "showCPUMenuBar"
    private static let legacyGPUKey = "showGPUMenuBar"
    private static let legacyEnergyKey = "showBatteryMenuBar"
    private static let legacyNetworkKey = "showNetworkMenuBar"

    @Published private(set) var selectedMetrics: [MenuBarMetric]
    @Published var presentation: MenuBarPresentation {
        didSet { defaults.set(presentation.rawValue, forKey: Self.presentationDefaultsKey) }
    }
    @Published var focusedMetric: MenuBarMetric {
        didSet { defaults.set(focusedMetric.rawValue, forKey: Self.focusDefaultsKey) }
    }
    /// Whether an active alarm adds the red marker beside the read-outs. On by
    /// default: an alarm the user never sees is not worth raising. Turning it
    /// off silences the marker only, not the alarm itself, which still shows in
    /// the panel and still fires its notification.
    @Published var showsAlarmMarker: Bool {
        didSet { defaults.set(showsAlarmMarker, forKey: Self.alarmMarkerDefaultsKey) }
    }
    /// The widget shape each metric draws itself in. A metric with no entry uses
    /// `MenuBarWidgetStyle.default(for:)`, so an existing install keeps the look
    /// it had before the shapes were selectable.
    @Published private(set) var widgetStyles: [MenuBarMetric: MenuBarWidgetStyle]
    /// Whether each read-out draws in colour. A metric with no entry is
    /// coloured, so an existing install keeps the look it had before the switch
    /// existed.
    @Published private(set) var colorStates: [MenuBarMetric: Bool]

    /// Every read-out in the user's order, selected or not.
    ///
    /// One list rather than two. The Settings list is the order editor as well
    /// as the on/off switch, and when the two were separate lists a read-out
    /// jumped between them the moment it was switched on or off: the row you
    /// just clicked moved out from under the pointer. A read-out now holds its
    /// place in the list whatever its state, and the menu bar takes the
    /// selected ones in this order.
    @Published private(set) var metricOrder: [MenuBarMetric]

    /// The read-outs actually on the menu bar right now: focus mode shows one,
    /// the other two show the whole selection.
    var shownMetrics: [MenuBarMetric] {
        presentation == .focus ? [focusedMetric] : selectedMetrics
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let loadedMetrics = Self.loadSelection(from: defaults)
        let savedFocus =
            defaults.string(forKey: Self.focusDefaultsKey)
            .flatMap(MenuBarMetric.init(rawValue:))
        self.defaults = defaults
        selectedMetrics = loadedMetrics
        metricOrder = Self.loadOrder(from: defaults, selection: loadedMetrics)
        widgetStyles = Self.loadStyles(from: defaults)
        colorStates = Self.loadColorStates(from: defaults)
        presentation =
            defaults.string(forKey: Self.presentationDefaultsKey)
            .flatMap(MenuBarPresentation.init(rawValue:)) ?? .strip
        showsAlarmMarker =
            defaults.object(forKey: Self.alarmMarkerDefaultsKey) as? Bool ?? true
        focusedMetric =
            savedFocus.flatMap { loadedMetrics.contains($0) ? $0 : nil }
            ?? loadedMetrics[0]
        persistSelection()
    }

    func setSelected(_ metric: MenuBarMetric, isSelected: Bool) {
        if isSelected {
            guard !selectedMetrics.contains(metric) else { return }
            // Inserted where the list already shows it, not appended, so
            // switching a read-out on does not also move it.
            selectedMetrics = metricOrder.filter {
                $0 == metric || selectedMetrics.contains($0)
            }
        } else {
            guard selectedMetrics.count > 1 else { return }
            selectedMetrics.removeAll { $0 == metric }
            if focusedMetric == metric {
                focusedMetric = selectedMetrics[0]
            }
        }
        persistSelection()
    }

    func isSelected(_ metric: MenuBarMetric) -> Bool {
        selectedMetrics.contains(metric)
    }

    /// The shape `metric` draws itself in, falling back to its default and
    /// ignoring a stored shape the metric cannot draw.
    func style(for metric: MenuBarMetric) -> MenuBarWidgetStyle {
        guard let style = widgetStyles[metric], style.supports(metric) else {
            return .default(for: metric)
        }
        return style
    }

    func setStyle(_ style: MenuBarWidgetStyle, for metric: MenuBarMetric) {
        guard style.supports(metric) else { return }
        guard widgetStyles[metric] != style else { return }
        widgetStyles[metric] = style
        persistStyles()
    }

    /// Whether `metric` draws in colour. Read-outs are coloured unless the
    /// user turned it off.
    func isColored(_ metric: MenuBarMetric) -> Bool {
        colorStates[metric] ?? true
    }

    func setColored(_ colored: Bool, for metric: MenuBarMetric) {
        guard colorStates[metric] != colored else { return }
        colorStates[metric] = colored
        defaults.set(
            colorStates.reduce(into: [String: Bool]()) { $0[$1.key.rawValue] = $1.value },
            forKey: Self.colorDefaultsKey)
    }

    /// Move a read-out one place in the list, past whatever is next to it,
    /// selected or not. The list is what the user sees, so it is what moves.
    func move(_ metric: MenuBarMetric, by offset: Int) {
        guard let source = metricOrder.firstIndex(of: metric) else { return }
        let destination = source + offset
        guard metricOrder.indices.contains(destination) else { return }
        metricOrder.swapAt(source, destination)
        defaults.set(metricOrder.map(\.rawValue), forKey: Self.orderDefaultsKey)
        selectedMetrics = metricOrder.filter(selectedMetrics.contains)
        persistSelection()
    }

    /// Whether `metric` can still move in `direction` (-1 up, 1 down).
    func canMove(_ metric: MenuBarMetric, by offset: Int) -> Bool {
        guard let source = metricOrder.firstIndex(of: metric) else { return false }
        return metricOrder.indices.contains(source + offset)
    }

    private func persistSelection() {
        defaults.set(selectedMetrics.map(\.rawValue), forKey: Self.selectionDefaultsKey)
    }

    private func persistStyles() {
        let raw = widgetStyles.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value.rawValue
        }
        defaults.set(raw, forKey: Self.stylesDefaultsKey)
    }

    private static func loadStyles(
        from defaults: UserDefaults
    ) -> [MenuBarMetric:
        MenuBarWidgetStyle]
    {
        guard let raw = defaults.dictionary(forKey: stylesDefaultsKey) as? [String: String] else {
            return [:]
        }
        return raw.reduce(into: [MenuBarMetric: MenuBarWidgetStyle]()) { result, entry in
            guard let metric = MenuBarMetric(rawValue: entry.key),
                let style = MenuBarWidgetStyle(rawValue: entry.value), style.supports(metric)
            else { return }
            result[metric] = style
        }
    }

    private static func loadColorStates(from defaults: UserDefaults) -> [MenuBarMetric: Bool] {
        guard let raw = defaults.dictionary(forKey: colorDefaultsKey) as? [String: Bool] else {
            return [:]
        }
        return raw.reduce(into: [MenuBarMetric: Bool]()) { result, entry in
            guard let metric = MenuBarMetric(rawValue: entry.key) else { return }
            result[metric] = entry.value
        }
    }

    /// The stored order, repaired against the current case list: any read-out
    /// added since the order was saved is appended rather than lost, and one
    /// that no longer exists is dropped. A fresh install orders the selected
    /// read-outs first, then the rest.
    private static func loadOrder(
        from defaults: UserDefaults, selection: [MenuBarMetric]
    ) -> [MenuBarMetric] {
        let stored =
            (defaults.stringArray(forKey: orderDefaultsKey) ?? [])
            .compactMap(MenuBarMetric.init(rawValue:))
        var order = stored.isEmpty ? selection : stored
        for metric in selection where !order.contains(metric) { order.append(metric) }
        for metric in MenuBarMetric.allCases where !order.contains(metric) {
            order.append(metric)
        }
        return order
    }

    private static func loadSelection(from defaults: UserDefaults) -> [MenuBarMetric] {
        if let saved = defaults.stringArray(forKey: selectionDefaultsKey) {
            var metrics = saved.compactMap(MenuBarMetric.init(rawValue:))
            if !metrics.isEmpty {
                // The RAM readout was split out of the pressure one, which used to
                // caption itself "RAM" while showing the pressure index. Insert it
                // beside its old caption once, so the figure people thought they
                // were already reading is actually on the bar. Guarded by its own
                // flag: someone who then turns RAM off keeps it off.
                if !defaults.bool(forKey: ramMigrationDefaultsKey) {
                    defaults.set(true, forKey: ramMigrationDefaultsKey)
                    if !metrics.contains(.ram) {
                        let insertAt = metrics.firstIndex(of: .pressure).map { $0 + 1 } ?? 0
                        metrics.insert(.ram, at: insertAt)
                    }
                }
                return metrics
            }
        }

        var migrated: [MenuBarMetric] = [.pressure, .ram]
        if defaults.object(forKey: legacyCPUKey) as? Bool ?? true {
            migrated.append(.cpu)
        }
        if defaults.object(forKey: legacyGPUKey) as? Bool ?? true {
            migrated.append(.gpu)
        }
        if defaults.object(forKey: legacyEnergyKey) as? Bool ?? true {
            migrated.append(.energy)
        }
        if defaults.object(forKey: legacyNetworkKey) as? Bool ?? true {
            migrated.append(.network)
        }
        // Disk did not exist before the combined-item preference. Existing users
        // keep their chosen width; new users (no legacy keys at all) get Disk.
        let hasLegacySelection = [legacyCPUKey, legacyGPUKey, legacyEnergyKey, legacyNetworkKey]
            .contains { defaults.object(forKey: $0) != nil }
        if !hasLegacySelection { migrated.append(.disk) }
        return migrated
    }
}
