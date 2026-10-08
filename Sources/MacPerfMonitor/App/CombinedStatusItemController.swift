import AppKit
import Combine
import MacPerfMonitorCore
import SwiftUI

@MainActor
final class CombinedStatusItemController: NSObject {
    var onPopoverOpened: (() -> Void)?

    private static let panelDefaultsKey = "combinedMenuBarPanel"
    /// Stable identity for the status item, so macOS remembers where the user
    /// Command-dragged it. Without one, every relaunch (an update, a login)
    /// inserts the item at the default slot beside the notch, where a crowded
    /// menu bar hides it with no indication (#120).
    static let statusItemAutosaveName = "MacPerfMonitorCombined"
    private static let alarmImage: NSImage = {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            guard
                let base = NSImage(
                    systemSymbolName: "exclamationmark.triangle.fill",
                    accessibilityDescription: nil),
                let symbol = base.withSymbolConfiguration(
                    .init(pointSize: 10, weight: .semibold))
            else { return false }
            symbol.draw(in: rect)
            NSColor.systemRed.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }()

    private let model: SamplerModel
    private let appState: AppState
    private let helperManager: HelperManager
    private let updateController: UpdateController
    private let components: AppComponentsManager
    private let languageManager: AppLanguageManager
    private let configuration: CombinedMenuBarConfiguration
    private let notchDisplay: NotchDisplayController

    /// The single item that `focus` and `strip` draw into. Nil in `separate`.
    private var statusItem: NSStatusItem?
    /// One item per read-out in `separate` mode, keyed by metric. Empty otherwise.
    private var separateItems: [MenuBarMetric: NSStatusItem] = [:]
    /// What each separate item currently shows, so an unchanged tick is a no-op
    /// for that item alone rather than for the whole bar.
    private var separateSignatures: [MenuBarMetric: String] = [:]
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var shownSignature: String?
    private var activeConsumer: MenuListKind?
    private var gpuSamplingActive = false
    /// Whether the open popover is showing the GPU panel, which is registered
    /// as a live GPU surface so the device is read every tick while it shows.
    private var gpuPanelLive = false
    private var currentPanel: CombinedMenuBarPanel
    private lazy var panelSelection = CombinedMenuBarPanelSelection(panel: currentPanel)
    /// The menu bar item switch (`AppComponentsManager`). Off removes every item
    /// this controller owns, whatever the presentation.
    private var itemsVisible = true
    /// Drives `MenuBarPanelGate`: the panel's content subtree exists only while
    /// the popover is on screen.
    private let panelVisibility = MenuBarPanelVisibility()

    private lazy var menuClock = MenuClock(
        source: model.liveTick.eraseToAnyPublisher(),
        onOpen: { [model] in model.requestImmediateTick() },
        onActiveChange: { [weak self] active in self?.popoverActivityChanged(active) })

    init(
        model: SamplerModel, appState: AppState, helperManager: HelperManager,
        updateController: UpdateController, components: AppComponentsManager,
        languageManager: AppLanguageManager,
        configuration: CombinedMenuBarConfiguration, notchDisplay: NotchDisplayController
    ) {
        self.model = model
        self.appState = appState
        self.helperManager = helperManager
        self.updateController = updateController
        self.components = components
        self.languageManager = languageManager
        self.configuration = configuration
        self.notchDisplay = notchDisplay
        currentPanel = .metric(
            UserDefaults.standard.string(forKey: Self.panelDefaultsKey)
                .flatMap(MenuBarMetric.init(rawValue:)) ?? configuration.focusedMetric)
        super.init()
    }

    func start() {
        model.menuBarTick
            .sink { [weak self] _ in
                self?.refresh()
                self?.reconcileMenuClock()
            }
            .store(in: &cancellables)
        model.$activeAlerts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        configuration.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.configurationChanged()
                }
            }
            .store(in: &cancellables)
        components.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyVisibility(state.menuBarItem) }
            .store(in: &cancellables)
        applyVisibility(components.menuBarItem)
        reconcileGPUSampling()
    }

    /// Install or remove the status items to match the switch. Removing them is
    /// the same deregistration the quit path uses, so macOS records a deliberate
    /// removal rather than a vanished item.
    private func applyVisibility(_ shouldShow: Bool) {
        guard shouldShow != itemsVisible || (shouldShow && !hasItems) else { return }
        itemsVisible = shouldShow
        if shouldShow {
            AppLog.ui.notice("menu bar item shown")
        } else {
            AppLog.ui.notice("menu bar item hidden by preference")
            menuClock.close()
            popover?.performClose(nil)
            popover = nil
        }
        reconcileItems()
    }

    private var hasItems: Bool { statusItem != nil || !separateItems.isEmpty }

    /// Bring the bar in line with the chosen presentation: one combined item for
    /// `focus` and `strip`, or one item per selected read-out for `separate`.
    private func reconcileItems() {
        if !itemsVisible {
            for metric in separateItems.keys { removeSeparateItem(metric) }
            removeCombinedItem()
        } else if configuration.presentation == .separate {
            if statusItem != nil { removeCombinedItem() }
            let wanted = Set(configuration.selectedMetrics)
            for metric in separateItems.keys where !wanted.contains(metric) {
                removeSeparateItem(metric)
            }
            for metric in configuration.selectedMetrics where separateItems[metric] == nil {
                installSeparateItem(metric)
            }
        } else {
            for metric in separateItems.keys { removeSeparateItem(metric) }
            installCombinedItem()
        }
        refresh()
    }

    private func installCombinedItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.statusItemAutosaveName
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        statusItem = item
    }

    private func removeCombinedItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        shownSignature = nil
    }

    private func installSeparateItem(_ metric: MenuBarMetric) {
        // Restore the drag position BEFORE the item exists: AppKit reads the
        // preferred-position default when the autosave name is assigned.
        restoreItemPosition(for: metric)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        separateItems[metric] = item
        // Deferred exactly as Stats defers it (Kit/module/widget.swift): assigning
        // the autosave name in the same turn as creating the item loses the
        // restored position.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.separateItems[metric] else { return }
            item.autosaveName = Self.autosaveName(for: metric)
        }
    }

    private func removeSeparateItem(_ metric: MenuBarMetric) {
        guard let item = separateItems.removeValue(forKey: metric) else { return }
        // Removing an item clears its preferred-position default, so stash it
        // first and put it back on the next install. Adapted from Stats'
        // save/restoreNSStatusItemPosition (Kit/helpers.swift).
        saveItemPosition(for: metric)
        NSStatusBar.system.removeStatusItem(item)
        separateSignatures[metric] = nil
    }

    private static func autosaveName(for metric: MenuBarMetric) -> NSStatusItem.AutosaveName {
        "MacPerfMonitor_\(metric.rawValue)"
    }

    private static func positionKey(for metric: MenuBarMetric) -> String {
        "NSStatusItem Preferred Position \(autosaveName(for: metric))"
    }

    private static func savedPositionKey(for metric: MenuBarMetric) -> String {
        "NSStatusItem Restore Position \(autosaveName(for: metric))"
    }

    private func saveItemPosition(for metric: MenuBarMetric) {
        let defaults = UserDefaults.standard
        guard let position = defaults.object(forKey: Self.positionKey(for: metric)) else { return }
        defaults.set(position, forKey: Self.savedPositionKey(for: metric))
    }

    private func restoreItemPosition(for metric: MenuBarMetric) {
        let defaults = UserDefaults.standard
        guard let position = defaults.object(forKey: Self.savedPositionKey(for: metric)) else {
            return
        }
        defaults.set(position, forKey: Self.positionKey(for: metric))
        defaults.removeObject(forKey: Self.savedPositionKey(for: metric))
    }

    /// Any button this controller owns, preferring the combined item.
    private var anyButton: NSStatusBarButton? {
        statusItem?.button
            ?? configuration.selectedMetrics.compactMap { separateItems[$0]?.button }.first
    }

    /// Everything a close has to undo. Reached from the popover delegate the
    /// moment it dismisses, and from the tick reconciler as a backstop.
    private func panelClosed() {
        menuClock.close()
        // Drop the content subtree so the hidden panel observes nothing. The
        // popover itself, its window and its hosting controller stay, which is
        // what makes the next open cheap: rebuilding them costs a full layout
        // of the panel, and that is the whole of the open latency.
        //
        // Guarded, not assigned unconditionally: `reconcileMenuClock` calls this
        // on every menu bar tick while the panel is closed, and writing an
        // unchanged value to a `@Published` still publishes, which would
        // re-render the gate once a tick forever.
        if panelVisibility.isOpen { panelVisibility.isOpen = false }
    }

    func tearDownForQuit() {
        menuClock.close()
        if panelVisibility.isOpen { panelVisibility.isOpen = false }
        popover?.performClose(nil)
        popover = nil
        for metric in separateItems.keys { removeSeparateItem(metric) }
        removeCombinedItem()
        model.setGPUSamplingEnabled(false)
        gpuSamplingActive = false
        if gpuPanelLive {
            gpuPanelLive = false
            model.removeGPUConsumer()
        }
    }

    private func configurationChanged() {
        if !configuration.selectedMetrics.contains(configuration.focusedMetric),
            let first = configuration.selectedMetrics.first
        {
            configuration.focusedMetric = first
        }
        shownSignature = nil
        separateSignatures.removeAll()
        reconcileItems()
        reconcileGPUSampling()
    }

    private func refresh() {
        // The SMC sweep is the sensors store's own, on its own queue, so it
        // has to be asked. Only when a sensors read-out is actually on the bar:
        // an unused store never touches the SMC.
        if configuration.shownMetrics.contains(.sensors) {
            SensorsStore.shared.refreshIfDue()
        }
        if configuration.presentation == .separate {
            refreshSeparateItems()
        } else {
            refreshCombinedItem()
        }
    }

    /// Repaint each separate item from its own read-out. The alarm marker goes on
    /// exactly one item (the first that is alarming, else the leftmost), so the
    /// bar carries the same information as the combined item without repeating
    /// the same warning across every read-out.
    private func refreshSeparateItems() {
        let metrics = configuration.selectedMetrics
        let styles = configuration.widgetStyles
        // Each item has its own button, so each resolves the bar's appearance
        // for itself below; this seeds them with the first one's.
        let readouts = CombinedMenuBarReadouts.current(
            for: metrics, styles: styles, model: model, colors: configuration.colorStates,
            isDark: anyButton?.effectiveAppearance.isDarkMenuBar ?? true)
        let alarmCount = configuration.showsAlarmMarker ? model.activeAlerts.count : 0
        let alarmHost = readouts.first(where: \.isAlarm)?.metric ?? metrics.first

        for readout in readouts {
            let metric = readout.metric
            guard let item = separateItems[metric], let button = item.button else { continue }
            let style = CombinedMenuBarImage.style(for: metric, in: styles)
            let isDark = button.effectiveAppearance.isDarkMenuBar
            let showsAlarm = alarmCount > 0 && metric == alarmHost
            let signature =
                "\(isDark ? "dk" : "lt")|\(showsAlarm ? alarmCount : 0)|"
                + readoutSignature(readout, style: style)
            guard separateSignatures[metric] != signature else { continue }

            button.image = CombinedMenuBarImage.image(
                readout: readout, style: style, isDark: isDark)
            button.imagePosition = showsAlarm ? .imageLeading : .imageOnly
            button.attributedTitle = alarmTitle(count: showsAlarm ? alarmCount : 0)
            let summary = summaryText(for: readout)
            let alarmSuffix =
                showsAlarm ? ", " + t("Active alerts: %@", alarmCount.formatted()) : ""
            button.toolTip = summary + alarmSuffix
            button.setAccessibilityLabel("\(AppInfo.displayName), \(summary)\(alarmSuffix)")
            separateSignatures[metric] = signature
        }
    }

    private func summaryText(for readout: CombinedMenuBarReadout) -> String {
        if readout.metric == .sensors {
            let sensors = SensorsStore.shared.menuBarReadings
            guard !sensors.isEmpty else {
                return "\(readout.metric.title): \(t("none chosen"))"
            }
            return sensors.map { "\($0.name) \($0.formattedValue)" }
                .joined(separator: ", ")
        }
        if readout.metric == .network, let secondary = readout.secondaryValue {
            return "\(readout.metric.title): \(readout.value) down, \(secondary) up"
        } else if readout.metric == .disk, let secondary = readout.secondaryValue {
            return "\(readout.metric.title): \(readout.value) read, \(secondary) write"
        }
        return "\(readout.metric.title): \(readout.value)"
    }

    /// The chart shapes redraw whenever their history moves, which the displayed
    /// figures alone would not capture, so the trail's own shape joins this.
    private func readoutSignature(
        _ readout: CombinedMenuBarReadout, style: MenuBarWidgetStyle
    ) -> String {
        let trail = (readout.trail + readout.secondaryTrail)
            .map { String(format: "%.3g", $0) }.joined(separator: ",")
        let bars = readout.bars.flatMap { $0 }
            .map { String(format: "%.3g", $0.value) }.joined(separator: ",")
        let rows = readout.stackRows.joined(separator: ",")
        // `isColored` rides the signature so flipping the switch repaints at
        // once instead of waiting for a figure to move.
        return "\(readout.isColored ? "c" : "m"):"
            + "\(readout.metric.rawValue):\(style.rawValue):\(readout.value):\(readout.secondaryValue ?? ""):\(readout.isAlarm):\(readout.batteryCharge ?? -1):\(readout.isBatteryCharging):\(readout.isBatteryPresent):\(readout.isOnAC):\(readout.batteryTimeText ?? ""):\(readout.memoryRows?.free ?? "")/\(readout.memoryRows?.used ?? ""):\(trail):\(bars):\(rows)"
    }

    private func refreshCombinedItem() {
        guard let button = statusItem?.button else { return }
        let metrics =
            configuration.presentation == .focus
            ? [configuration.focusedMetric] : configuration.selectedMetrics
        let styles = configuration.widgetStyles
        let isDark = button.effectiveAppearance.isDarkMenuBar
        let readouts = CombinedMenuBarReadouts.current(
            for: metrics, styles: styles, model: model, colors: configuration.colorStates,
            isDark: isDark)
        let alarmCount = configuration.showsAlarmMarker ? model.activeAlerts.count : 0
        let signature =
            "\(configuration.presentation.rawValue)|\(alarmCount)|\(isDark ? "dk" : "lt")|"
            + readouts.map { readout in
                readoutSignature(
                    readout,
                    style: CombinedMenuBarImage.style(for: readout.metric, in: styles))
            }.joined(separator: "|")
        guard signature != shownSignature else { return }
        button.image = CombinedMenuBarImage.image(
            readouts: readouts, styles: styles, presentation: configuration.presentation,
            isDark: isDark)
        button.imagePosition = alarmCount > 0 ? .imageLeading : .imageOnly
        button.attributedTitle = alarmTitle(count: alarmCount)
        let summary = readouts.map { summaryText(for: $0) }.joined(separator: ", ")
        let alarmSuffix =
            alarmCount > 0 ? ", " + t("Active alerts: %@", alarmCount.formatted()) : ""
        button.toolTip = summary + alarmSuffix
        button.setAccessibilityLabel("\(AppInfo.displayName), \(summary)\(alarmSuffix)")
        shownSignature = signature
    }

    private func alarmTitle(count: Int) -> NSAttributedString {
        guard count > 0 else { return NSAttributedString(string: "") }
        let attachment = NSTextAttachment()
        attachment.image = Self.alarmImage
        attachment.bounds = NSRect(x: 0, y: -1, width: 12, height: 12)
        let title = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: attachment))
        if count > 1 {
            title.append(
                NSAttributedString(
                    string: "\(count)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                        .foregroundColor: NSColor.systemRed,
                        .baselineOffset: 1,
                    ]))
        }
        return title
    }

    @objc private func togglePopover(_ sender: Any?) {
        let button: NSStatusBarButton
        let panel: CombinedMenuBarPanel?
        if let clicked = sender as? NSStatusBarButton,
            let owner = separateItems.first(where: { $0.value.button === clicked })?.key
        {
            // Separate mode: the item that was clicked IS the read-out, so there
            // is nothing to hit test beyond the alarm badge it may carry.
            button = clicked
            if let badge = alertRect(in: clicked), let point = clickLocation(in: clicked),
                badge.contains(point)
            {
                panel = .alerts
            } else {
                panel = .metric(owner)
            }
        } else if let combined = statusItem?.button {
            button = combined
            panel = clickedPanel(in: combined)
        } else {
            return
        }
        if let popover, popover.isShown {
            if let panel, panel != currentPanel {
                panelSelection.panel = panel
                selectPanel(panel)
                if configuration.presentation == .separate {
                    popover.performClose(sender)
                    show(popover, from: button)
                }
                popover.contentViewController?.view.window?.makeKey()
                return
            }
            popover.performClose(sender)
            return
        }
        if let panel {
            panelSelection.panel = panel
            selectPanel(panel)
        }
        let popover = popover ?? makePopover()
        self.popover = popover
        show(popover, from: button)
        if popover.isShown { onPopoverOpened?() }
    }

    /// Raise the gate, then show. The order matters both ways round: the
    /// content has to exist before NSPopover measures it, or the window is
    /// sized from the closed placeholder; and closing lowers the gate through
    /// the delegate, so a close-then-show (the separate-mode tab switch) must
    /// raise it again or the panel comes back blank.
    private func show(_ popover: NSPopover, from button: NSStatusBarButton) {
        panelVisibility.isOpen = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let content = LocaleRootView(languageManager: languageManager) {
            MenuBarPanelGate(visibility: self.panelVisibility) {
                CombinedMenuBarContentView(
                    selection: self.panelSelection,
                    selectionChanged: { [weak self] panel in self?.selectPanel(panel) },
                    dismiss: { [weak popover] in popover?.performClose(nil) }
                )
            }
            .environmentObject(self.model)
            .environmentObject(self.model.menuLists)
            .environmentObject(self.appState)
            .environmentObject(self.helperManager)
            .environmentObject(self.updateController)
            .environmentObject(self.menuClock)
            .environmentObject(self.components)
            .environmentObject(self.configuration)
            .environmentObject(self.notchDisplay)
        }
        let hosting = PopoverHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        return popover
    }

    private func clickedPanel(in button: NSStatusBarButton) -> CombinedMenuBarPanel? {
        let metrics =
            configuration.presentation == .focus
            ? [configuration.focusedMetric] : configuration.selectedMetrics
        guard !metrics.isEmpty else { return nil }
        let styles = configuration.widgetStyles
        let readouts = CombinedMenuBarReadouts.current(
            for: metrics, styles: styles, model: model)
        guard let local = clickLocation(in: button) else {
            return configuration.presentation == .focus ? .metric(metrics[0]) : nil
        }

        let imageRect =
            (button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds)
            ?? NSRect(
                x: (button.bounds.width - (button.image?.size.width ?? 0)) / 2,
                y: 0, width: button.image?.size.width ?? button.bounds.width,
                height: button.bounds.height)
        return Self.panel(
            at: local, imageRect: imageRect, alertRect: alertRect(in: button),
            readouts: readouts, presentation: configuration.presentation, styles: styles)
    }

    /// Where the click that is being handled landed, in the button's own
    /// coordinates. Nil when there is no window to measure against.
    private func clickLocation(in button: NSStatusBarButton) -> NSPoint? {
        if let event = NSApp.currentEvent,
            event.type == .leftMouseDown || event.type == .leftMouseUp,
            event.window === button.window
        {
            return button.convert(event.locationInWindow, from: nil)
        } else if let window = button.window {
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            return button.convert(windowPoint, from: nil)
        }
        return nil
    }

    /// The alarm badge's area on a button, nil when the button carries none.
    private func alertRect(in button: NSStatusBarButton) -> NSRect? {
        guard !model.activeAlerts.isEmpty, button.imagePosition == .imageLeading else {
            return nil
        }
        return (button.cell as? NSButtonCell)?.titleRect(forBounds: button.bounds)
    }

    static func panel(
        at point: NSPoint, imageRect: NSRect, alertRect: NSRect?,
        readouts: [CombinedMenuBarReadout], presentation: MenuBarPresentation,
        styles: [MenuBarMetric: MenuBarWidgetStyle] = [:]
    ) -> CombinedMenuBarPanel? {
        if let alertRect, alertRect.contains(point) { return .alerts }
        let imageX = min(max(point.x - imageRect.minX, 0), imageRect.width)
        return CombinedMenuBarImage.metric(
            at: imageX, readouts: readouts, styles: styles, presentation: presentation
        ).map {
            .metric($0)
        }
    }

    private func selectPanel(_ panel: CombinedMenuBarPanel) {
        guard panel != currentPanel else {
            reconcileGPUSampling()
            return
        }
        currentPanel = panel
        if case .metric(let metric) = panel {
            UserDefaults.standard.set(metric.rawValue, forKey: Self.panelDefaultsKey)
        }
        if popover?.isShown == true {
            replaceActiveConsumer(with: consumerKind(for: panel))
            model.requestImmediateTick()
        }
        reconcileGPUSampling()
    }

    private func popoverActivityChanged(_ active: Bool) {
        if active {
            replaceActiveConsumer(with: consumerKind(for: currentPanel))
        } else {
            replaceActiveConsumer(with: nil)
        }
        reconcileGPUSampling()
    }

    private func replaceActiveConsumer(with kind: MenuListKind?) {
        if let activeConsumer { model.removePopoverProcessConsumer(activeConsumer) }
        activeConsumer = kind
        if let kind { model.addPopoverProcessConsumer(kind) }
    }

    private func consumerKind(for panel: CombinedMenuBarPanel) -> MenuListKind? {
        switch panel {
        case .alerts, .metric(.pressure), .metric(.ram): return .footprint
        case .metric(.cpu): return .cpu
        case .metric(.energy): return .energy
        case .metric(.network): return .network
        case .metric(.disk): return .disk
        case .metric(.gpu): return .gpu
        // Neither reads a process list: they are whole-machine figures.
        case .metric(.temperature), .metric(.sensors): return nil
        }
    }

    private func reconcileGPUSampling() {
        // Temperature rides the GPU/SMC read path, so a visible temperature
        // readout or panel keeps that path live exactly like the GPU ones.
        let panelLive =
            popover?.isShown == true
            && (currentPanel == .metric(.gpu) || currentPanel == .metric(.temperature))
        if panelLive != gpuPanelLive {
            gpuPanelLive = panelLive
            if panelLive { model.addGPUConsumer() } else { model.removeGPUConsumer() }
        }
        let shouldSample =
            configuration.selectedMetrics.contains(.gpu)
            || configuration.selectedMetrics.contains(.temperature) || panelLive
        guard shouldSample != gpuSamplingActive else { return }
        gpuSamplingActive = shouldSample
        model.setGPUSamplingEnabled(shouldSample)
    }

    private func reconcileMenuClock() {
        guard let popover else { return }
        if popover.isShown {
            menuClock.open()
        } else {
            panelClosed()
        }
        reconcileGPUSampling()
    }
}

extension CombinedStatusItemController: NSPopoverDelegate {
    /// Lower the gate as soon as the popover dismisses. `reconcileMenuClock`
    /// would also catch it, but only on the next menu bar tick, which leaves the
    /// hidden panel live (and re-rendering) for up to a full interval.
    func popoverDidClose(_ notification: Notification) {
        panelClosed()
        reconcileGPUSampling()
    }
}
