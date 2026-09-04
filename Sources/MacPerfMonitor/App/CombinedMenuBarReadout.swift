import AppKit
import MacPerfMonitorCore

/// Everything one menu bar cell needs to draw itself, in whichever shape the
/// user picked for that metric.
///
/// The figures the old three cell shapes needed (`value`, `secondaryValue`,
/// battery state) are joined by what the widget shapes ported from Stats want:
/// a 0...1 level for the gauges, recent history for the charts, and the split
/// figures for the memory and speed shapes. Each is filled only when the chosen
/// shape reads it, so a strip of plain mini cells still costs one struct per
/// metric per tick.
struct CombinedMenuBarReadout {
    var metric: MenuBarMetric
    var value: String
    var secondaryValue: String?
    var isAlarm: Bool
    var batteryCharge: Double?
    var isBatteryCharging: Bool
    var isBatteryPresent: Bool
    var isOnAC: Bool = false
    var isLowPowerMode: Bool = false
    var batteryTimeText: String?
    var customLabel: String?

    /// The metric's level, 0...1, for the gauge and bar shapes.
    var fraction: Double = 0
    /// Memory pressure, for the shapes that colour by it.
    var pressureLevel: PressureLevel = .normal
    /// Recent history, oldest first, in the metric's own units. Empty unless the
    /// chosen shape draws a chart.
    var trail: [Double] = []
    /// The second direction's history (upload, write), oldest first.
    var secondaryTrail: [Double] = []
    /// The bar chart's bars, each a bottom-up stack of segments.
    var bars: [[MenuBarWidgetSegment]] = []
    /// Free and used, already formatted, for the memory shape.
    var memoryRows: (free: String, used: String)?
    /// The rows the stack shape prints, top first.
    var stackRows: [String] = []
    /// What the text shape prints.
    var textValue: String = ""

    /// The three-letter caption the mini, label and chart shapes draw.
    var captionText: String { customLabel ?? metric.shortTitle }

    /// The direction letters the speed shape draws, matching the symbols in the
    /// matching Stats module config.
    var speedSymbols: (input: String, output: String) {
        metric == .disk ? ("R", "W") : ("D", "U")
    }

    /// The figures a two-direction read-out stacks, top row first, each paired
    /// with the direction it stands for so a marker drawn beside it can be
    /// coloured to match.
    ///
    /// Network prints upload over download: the two rows are unlabelled digits
    /// in the strip and in the panel's chips, so wherever they are drawn they
    /// have to agree on which one is on top, and one property is what makes
    /// that possible. Disk keeps read on top, where the R and W drawn beside
    /// the rows say which is which anyway.
    ///
    /// A single-figure read-out is one row, and nothing reads its direction.
    var directionRows: [(text: String, isInbound: Bool)] {
        guard let secondaryValue else { return [(value, true)] }
        return metric == .network
            ? [(secondaryValue, false), (value, true)]
            : [(value, true), (secondaryValue, false)]
    }

    /// The pie and tachometer segments. CPU splits into system over user the way
    /// Stats' CPU pie does; the two-direction metrics show both directions; the
    /// rest are a single arc coloured by the metric's own scale.
    func gaugeSegments(isDark: Bool) -> [MenuBarWidgetSegment] {
        guard isColored else {
            // Still an arc of the right length, just not a verdict about it.
            return [
                MenuBarWidgetSegment(min(fraction, 1), color: StatsMenuBarWidgets.textColor(isDark))
            ]
        }
        switch metric {
        case .cpu where !bars.isEmpty && bars[0].count > 1:
            return bars[0]
        case .network, .disk:
            let total = max(fraction, 0.0001)
            return [
                MenuBarWidgetSegment(min(fraction, 1) * (inShare / total), color: .systemBlue),
                MenuBarWidgetSegment(min(fraction, 1) * (1 - inShare / total), color: .systemRed),
            ]
        case .pressure:
            return [
                MenuBarWidgetSegment(min(fraction, 1), color: pressureLevel.menuBarPressureColor)
            ]
        case .ram:
            return [
                MenuBarWidgetSegment(
                    min(fraction, 1), color: StatsMenuBarWidgets.usageColor(fraction))
            ]
        case .energy:
            return [
                MenuBarWidgetSegment(
                    min(fraction, 1),
                    color: StatsMenuBarWidgets.usageColor(fraction, reversed: true))
            ]
        case .cpu, .gpu, .temperature, .sensors:
            return [
                MenuBarWidgetSegment(
                    min(fraction, 1), color: StatsMenuBarWidgets.usageColor(fraction))
            ]
        }
    }

    /// The inbound direction's share of the combined throughput, 0...1.
    var inShare: Double = 0.5

    /// The state dot's colour: red on an active alarm, otherwise the metric's own
    /// scale, so the dot reads like a traffic light rather than a fixed colour.
    var stateColor: NSColor {
        if isAlarm { return .systemRed }
        guard isColored else { return StatsMenuBarWidgets.textColor(isDarkMenuBar) }
        switch metric {
        case .pressure: return pressureLevel.menuBarPressureColor
        case .energy: return StatsMenuBarWidgets.usageColor(fraction, reversed: true)
        case .ram, .cpu, .gpu, .temperature, .network, .disk, .sensors:
            return StatsMenuBarWidgets.usageColor(fraction)
        }
    }

    /// The speed shape's direction marker. Stats fades an idle direction back to
    /// the bar's own colour and only tints it once traffic passes 1 KB/s.
    func speedIconColor(input: Bool, isDark: Bool) -> NSColor {
        let rate = input ? primaryBytesPerSec : secondaryBytesPerSec
        guard isColored, rate >= 1024 else { return StatsMenuBarWidgets.textColor(isDark) }
        return input ? .systemBlue : .systemRed
    }

    var primaryBytesPerSec: Double = 0
    var secondaryBytesPerSec: Double = 0

    /// The widest figure this read-out can show, so its cell can reserve that
    /// width once instead of resizing every time the number changes. Nil where
    /// there is no bounded form to reserve (a throughput figure has no ceiling),
    /// and those cells fall back to sizing themselves to their content.
    var valueTemplate: String?
    /// The forms each stack row's figure can take, in step with `stackRows`.
    /// A column reserves the widest of them.
    var stackTemplates: [[String]] = []

    /// Whether this read-out draws in colour, from the per-read-out switch in
    /// Settings. Off means every colour it would otherwise use becomes the menu
    /// bar's own text colour: the level tints, the chart accent, and the
    /// direction dots alike.
    ///
    /// An active alarm still shows red. That is the alarm speaking rather than
    /// the usage scale, and it has its own switch.
    var isColored: Bool = true
    /// The bar's appearance, needed by the colour helpers that have no `isDark`
    /// of their own to consult.
    var isDarkMenuBar: Bool = true
}

extension MenuBarMetric {
    func isAlarm(in activeKinds: Set<Alert.Kind>) -> Bool {
        switch self {
        case .pressure:
            return !activeKinds.isDisjoint(with: [
                .criticalPressure, .swap, .processCeiling, .leak,
            ])
        case .cpu:
            return activeKinds.contains(.highCPU)
        case .temperature:
            return activeKinds.contains(.thermalThrottle)
        // The memory alarms stay on the pressure readout, which is the health
        // signal. Firing them on `ram` too would just paint the same warning red
        // twice in one strip.
        // Sensors carries no alarm of its own: the thermal alarm already fires
        // on the temperature read-out, and a voltage rail has no threshold this
        // app would be right to assert.
        case .ram, .gpu, .energy, .network, .disk, .sensors:
            return false
        }
    }
}
