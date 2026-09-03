import AppKit
import MacPerfMonitorCore

@MainActor
enum CombinedMenuBarReadouts {
    /// `colors` is the per-read-out colour switch; a metric with no entry is
    /// coloured. `isDark` is the menu bar's own appearance, which the read-out
    /// needs for the colours it resolves for itself.
    static func current(
        for metrics: [MenuBarMetric], styles: [MenuBarMetric: MenuBarWidgetStyle],
        model: SamplerModel, colors: [MenuBarMetric: Bool] = [:], isDark: Bool = true
    ) -> [CombinedMenuBarReadout] {
        metrics.map { metric in
            buildReadout(
                for: metric, style: styles[metric] ?? .default(for: metric), model: model,
                isColored: colors[metric] ?? true, isDark: isDark)
        }
    }

    private static func buildReadout(
        for metric: MenuBarMetric, style: MenuBarWidgetStyle, model: SamplerModel,
        isColored: Bool, isDark: Bool
    ) -> CombinedMenuBarReadout {
        var readout = baseReadout(for: metric, model: model)
        readout.isColored = isColored
        readout.isDarkMenuBar = isDark
        readout.valueTemplate = metric.menuBarValueTemplate
        enrich(&readout, style: style, model: model)
        return readout
    }

    private static func baseReadout(
        for metric: MenuBarMetric, model: SamplerModel
    ) -> CombinedMenuBarReadout {
        let isAlarm = metric.isAlarm(in: model.activeAlertKinds)
        switch metric {
        case .pressure:
            let system = model.liveSystem
            let pct = system.map { Int($0.pressurePercent.rounded()) }
            let val = pct.map { "\($0)%" } ?? "--%"
            return CombinedMenuBarReadout(
                metric: metric, value: val, secondaryValue: nil,
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "PRS",
                fraction: (system?.pressurePercent ?? 0) / 100,
                pressureLevel: system?.pressureLevel ?? .normal)

        case .ram:
            let usage = memoryUsage(model: model)
            let val = usage.map { "\(Int(($0.fraction * 100).rounded()))%" } ?? "--%"
            return CombinedMenuBarReadout(
                metric: metric, value: val, secondaryValue: nil,
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "RAM",
                fraction: usage?.fraction ?? 0,
                pressureLevel: model.liveSystem?.pressureLevel ?? .normal)

        case .cpu:
            let usage = model.smoothedCPU.map(\.totalUsage)
            let pct = usage.map { Int(($0 * 100).rounded()) }
            let val = pct.map { "\($0)%" } ?? "--%"
            return CombinedMenuBarReadout(
                metric: metric, value: val, secondaryValue: nil,
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "CPU",
                fraction: usage ?? 0)

        case .gpu:
            let usage = model.smoothedGPUUtilization
            let pct = usage.map { Int($0.rounded()) }
            let val = pct.map { "\($0)%" } ?? "--%"
            return CombinedMenuBarReadout(
                metric: metric, value: val, secondaryValue: nil,
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "GPU",
                fraction: (usage ?? 0) / 100)

        case .temperature:
            let temp = model.liveSystem?.cpuDieC
            let val = temp.map { "\(Int($0.rounded()))°" } ?? "--°"
            return CombinedMenuBarReadout(
                metric: metric, value: val, secondaryValue: nil,
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "TMP",
                // 100 °C is the top of the die's own scale, so the gauges read as
                // a share of "as hot as this part ever gets".
                fraction: min(max((temp ?? 0) / 100, 0), 1))

        case .energy:
            if let battery = model.latestBattery, battery.isPresent {
                let charge = battery.chargePercent / 100.0
                let isCharging = battery.isCharging || battery.isOnAC
                let percentStr = "\(Int(battery.chargePercent.rounded()))%"
                return CombinedMenuBarReadout(
                    metric: metric, value: percentStr, secondaryValue: nil,
                    isAlarm: isAlarm, batteryCharge: charge, isBatteryCharging: battery.isCharging,
                    isBatteryPresent: true, isOnAC: isCharging,
                    isLowPowerMode: battery.isLowPowerMode,
                    batteryTimeText: batteryTimeText(battery), customLabel: "BAT",
                    fraction: charge)
            } else {
                let watts = model.latestBattery?.systemPowerWatts ?? 0
                let val = watts > 0 ? "\(Int(watts.rounded()))W" : "--"
                return CombinedMenuBarReadout(
                    metric: metric, value: val, secondaryValue: nil,
                    isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                    isBatteryPresent: false, customLabel: "Sensor")
            }

        case .network:
            let rates = model.networkRates
            let down = rates?.inBytesPerSec ?? 0
            let up = rates?.outBytesPerSec ?? 0
            return CombinedMenuBarReadout(
                metric: metric, value: formatSpeed(down), secondaryValue: formatSpeed(up),
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "NET",
                primaryBytesPerSec: down, secondaryBytesPerSec: up)

        case .disk:
            let rates = model.diskRates
            let read = rates?.readBytesPerSec ?? 0
            let write = rates?.writeBytesPerSec ?? 0
            return CombinedMenuBarReadout(
                metric: metric, value: formatSpeed(read), secondaryValue: formatSpeed(write),
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "DSK",
                primaryBytesPerSec: read, secondaryBytesPerSec: write)

        case .sensors:
            // The figures come from the sensors store, not the sampler: the SMC
            // sweep is its own reader on its own queue (see `SensorsStore`).
            let chosen = SensorsStore.shared.menuBarReadings
            // With nothing chosen the cell still has to be visible and
            // clickable, or there is no way back to the panel that chooses.
            let rows = chosen.isEmpty ? [metric.shortTitle] : chosen.map(\.menuBarValue)
            var readout = CombinedMenuBarReadout(
                metric: metric, value: chosen.first?.menuBarValue ?? "--",
                secondaryValue: nil,
                isAlarm: isAlarm, batteryCharge: nil, isBatteryCharging: false,
                isBatteryPresent: false, customLabel: "SNS",
                stackRows: rows)
            readout.stackTemplates =
                chosen.isEmpty ? rows.map { [$0] } : chosen.map(\.menuBarTemplates)
            return readout
        }
    }

    /// Fill in only the extra data the chosen shape actually draws: history for
    /// the charts, bars for the bar chart, split figures for memory, and the row
    /// strings for the stack and text shapes.
    private static func enrich(
        _ readout: inout CombinedMenuBarReadout, style: MenuBarWidgetStyle, model: SamplerModel
    ) {
        switch style {
        case .lineChart:
            readout.trail = trail(for: readout.metric, model: model)

        case .networkChart:
            readout.trail = trail(for: readout.metric, model: model)
            readout.secondaryTrail = secondaryTrail(for: readout.metric, model: model)

        case .barChart:
            readout.bars = bars(for: readout, model: model)

        case .pieChart, .tachometer:
            if readout.metric == .cpu { readout.bars = bars(for: readout, model: model) }
            normalizeThroughput(&readout, model: model)

        case .state:
            normalizeThroughput(&readout, model: model)

        case .memory:
            readout.memoryRows = memoryRows(model: model)

        case .stack:
            // Sensors filled its own rows in `baseReadout`: one per chosen
            // sensor, which is the whole point of the read-out.
            if readout.metric != .sensors {
                readout.stackRows = [readout.value, readout.secondaryValue].compactMap { $0 }
            }

        case .text:
            readout.textValue = [readout.value, readout.secondaryValue]
                .compactMap { $0 }.joined(separator: " / ")

        case .mini, .speed, .battery, .batteryDetails, .label:
            break
        }
    }

    /// The two-direction metrics have no natural 0...1 level, so the gauges scale
    /// the combined rate against the busiest moment in recent history and split
    /// the arc by direction.
    private static func normalizeThroughput(
        _ readout: inout CombinedMenuBarReadout, model: SamplerModel
    ) {
        guard readout.metric.hasSecondaryValue else { return }
        let combined = readout.primaryBytesPerSec + readout.secondaryBytesPerSec
        let peak = max(trail(for: readout.metric, model: model).max() ?? 0, 1)
        readout.fraction = min(combined / peak, 1)
        readout.inShare = combined > 0 ? readout.primaryBytesPerSec / combined : 0.5
    }

    /// The inbound history (download, read) or the single-figure history.
    private static func trail(for metric: MenuBarMetric, model: SamplerModel) -> [Double] {
        let history = model.systemHistory.elements()
            .suffix(StatsMenuBarWidgets.historyPoints)
        switch metric {
        case .pressure: return history.map { $0.pressurePercent / 100 }
        case .ram:
            return history.map { sample in
                guard sample.totalRAM > 0 else { return 0 }
                let used = min(
                    sample.appMemory &+ sample.wired &+ sample.compressed, sample.totalRAM)
                return Double(used) / Double(sample.totalRAM)
            }
        case .cpu: return history.map(\.cpuLoad)
        case .gpu: return history.map { ($0.gpuUtilization ?? 0) / 100 }
        case .temperature: return history.map { $0.cpuDieC ?? 0 }
        case .energy: return history.map { $0.batteryCharge / 100 }
        case .network: return history.map(\.networkInBytesPerSec)
        case .disk: return history.map(\.diskReadBytesPerSec)
        // No single series: a sensors read-out is a set of unrelated figures.
        case .sensors: return []
        }
    }

    /// The outbound history (upload, write); empty for the single-figure metrics.
    private static func secondaryTrail(for metric: MenuBarMetric, model: SamplerModel) -> [Double] {
        let history = model.systemHistory.elements()
            .suffix(StatsMenuBarWidgets.historyPoints)
        switch metric {
        case .network: return history.map(\.networkOutBytesPerSec)
        case .disk: return history.map(\.diskWriteBytesPerSec)
        case .pressure, .ram, .cpu, .gpu, .temperature, .energy, .sensors: return []
        }
    }

    /// The bar chart's bars. CPU gets one bar per logical core, the way Stats
    /// draws it; every other metric gets the single bar its one figure supports.
    private static func bars(
        for readout: CombinedMenuBarReadout, model: SamplerModel
    ) -> [[MenuBarWidgetSegment]] {
        if readout.metric == .cpu, let sample = model.smoothedCPU, !sample.cores.isEmpty {
            return sample.cores.map { core in
                [
                    MenuBarWidgetSegment(
                        min(max(core.usage, 0), 1),
                        color: StatsMenuBarWidgets.usageColor(core.usage))
                ]
            }
        }
        return [readout.gaugeSegments(isDark: true)]
    }

    /// RAM in use, as the memory panel and Activity Monitor define it: app memory
    /// plus wired plus compressed, over the installed total. Cached files are
    /// deliberately NOT counted as used (they are reclaimable), which is what
    /// keeps this figure equal to the one the panel prints under its chart.
    ///
    /// Note this is a different measurement from `pressurePercent`, which is the
    /// 0...100 pressure index: a Mac can sit at 84% used and still report a calm
    /// pressure index, and the two readouts are separate for exactly that reason.
    static func memoryUsage(
        model: SamplerModel
    ) -> (used: UInt64, free: UInt64, fraction: Double)? {
        guard let system = model.liveSystem, system.totalRAM > 0 else { return nil }
        let used = min(
            system.appMemory &+ system.wired &+ system.compressed, system.totalRAM)
        return (
            used: used, free: system.totalRAM - used,
            fraction: Double(used) / Double(system.totalRAM)
        )
    }

    private static func memoryRows(model: SamplerModel) -> (free: String, used: String) {
        guard let usage = memoryUsage(model: model) else { return (free: "--", used: "--") }
        return (free: ByteFormat.string(usage.free), used: ByteFormat.string(usage.used))
    }

    /// Stats' short time format, `h:mm`, from whichever estimate applies.
    private static func batteryTimeText(_ battery: BatterySample) -> String? {
        guard
            let minutes = battery.isCharging
                ? battery.timeToFullMinutes : battery.timeToEmptyMinutes,
            minutes > 0
        else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        return "\(hours):\(remainder > 9 ? "\(remainder)" : "0\(remainder)")"
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b < 1_000 {
            return "0 KB/s"
        } else if b < 1_000_000 {
            let kb = Int((b / 1_000).rounded())
            return "\(kb) KB/s"
        } else if b < 100_000_000 {
            let mb = b / 1_000_000
            return String(format: "%.1f MB/s", locale: .current, mb)
        } else if b < 1_000_000_000 {
            let mb = Int((b / 1_000_000).rounded())
            return "\(mb) MB/s"
        } else {
            let gb = b / 1_000_000_000
            return String(format: "%.1f GB/s", locale: .current, gb)
        }
    }
}

@MainActor
enum CombinedMenuBarImage {
    /// Uniform spacing between adjacent widget cells.
    /// The gap between read-outs in a strip.
    ///
    /// This, not the cells, is most of the space between "25%" and the "RAM"
    /// beside it: a cell is now sized to the figure it reserves, so what looked
    /// like padding inside the CPU read-out was the separator after it. Cells
    /// carry no margin of their own any more, so the separator is the whole
    /// gap and can be smaller than it was when they did.
    private static let cellSpacing: CGFloat = 5
    /// Shared menu bar item height so Focus and Strip cells align.
    private static let itemHeight: CGFloat = StatsMenuBarWidgets.Metrics.itemHeight

    /// One read-out on its own, for a `separate` mode status item (and for the
    /// Settings preview of that mode).
    static func image(
        readout: CombinedMenuBarReadout, style: MenuBarWidgetStyle, isDark: Bool = true
    ) -> NSImage {
        let cell = StatsMenuBarWidgets.cell(for: readout, style: style, isDark: isDark)
        let image = MenuBarReadoutImage.render(width: max(cell.width, 1), height: itemHeight) {
            _ in
            cell.draw(0)
        }
        image.isTemplate = false
        return image
    }

    static func image(
        readouts: [CombinedMenuBarReadout],
        styles: [MenuBarMetric: MenuBarWidgetStyle],
        presentation: MenuBarPresentation,
        isDark: Bool = true
    ) -> NSImage {
        let cells = layouts(for: readouts, styles: styles, isDark: isDark)
        let contentWidth =
            cells.reduce(0) { $0 + $1.width }
            + cellSpacing * CGFloat(max(0, cells.count - 1))

        let image = MenuBarReadoutImage.render(width: max(contentWidth, 1), height: itemHeight) {
            _ in
            var x: CGFloat = 0
            for (index, cell) in cells.enumerated() {
                cell.draw(x)
                x += cell.width
                if index < cells.count - 1 { x += cellSpacing }
            }
        }
        // Non-template so custom colored dots and battery gauges survive tinting.
        image.isTemplate = false
        return image
    }

    static func metric(
        at imageX: CGFloat, readouts: [CombinedMenuBarReadout],
        styles: [MenuBarMetric: MenuBarWidgetStyle],
        presentation: MenuBarPresentation
    ) -> MenuBarMetric? {
        guard let first = readouts.first else { return nil }
        guard presentation == .strip else { return first.metric }

        let cells = layouts(for: readouts, styles: styles, isDark: true)
        var x: CGFloat = 0
        for index in readouts.indices {
            let end = x + cells[index].width
            if imageX <= end { return readouts[index].metric }
            if index < readouts.count - 1 {
                let separatorEnd = end + cellSpacing
                if imageX < separatorEnd {
                    return imageX - end < cellSpacing / 2
                        ? readouts[index].metric : readouts[index + 1].metric
                }
                x = separatorEnd
            }
        }

        return readouts.last?.metric
    }

    private static func layouts(
        for readouts: [CombinedMenuBarReadout], styles: [MenuBarMetric: MenuBarWidgetStyle],
        isDark: Bool
    ) -> [StatsMenuBarWidgets.Cell] {
        readouts.map { readout in
            StatsMenuBarWidgets.cell(
                for: readout, style: style(for: readout.metric, in: styles), isDark: isDark)
        }
    }

    /// The shape chosen for `metric`, falling back to its default and refusing a
    /// stored shape the metric cannot draw (a battery widget on the CPU, say,
    /// from a preference written before a metric changed).
    static func style(
        for metric: MenuBarMetric, in styles: [MenuBarMetric: MenuBarWidgetStyle]
    ) -> MenuBarWidgetStyle {
        guard let style = styles[metric], style.supports(metric) else {
            return .default(for: metric)
        }
        return style
    }
}
