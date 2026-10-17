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
    var isBatteryCharging: Bool = false
    var isBatteryPresent: Bool = false
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
    /// The chosen sensors with their kinds, for the compact shape, which draws
    /// each figure beside the symbol of what it measures. The stack shape
    /// reads `stackRows` instead.
    var sensorCells: [MenuBarSensorCell] = []

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

    /// How much attention this reading asks for, which is all the compact
    /// shape colours: calm draws in the bar's own colour, elevated in orange,
    /// strained in red.
    ///
    /// An active alarm is strained whatever the figure. Memory goes by the
    /// pressure level, not the share of RAM in use: a healthy Mac can sit at
    /// 80% used. The battery only counts on battery power, because a low
    /// charge on a charger is already being fixed. Throughput and sensors
    /// other than temperatures carry no verdict: traffic and watts are
    /// information, not a problem.
    var verdict: MenuBarVerdict {
        if isAlarm { return .strained }
        switch metric {
        case .cpu, .gpu:
            return MenuBarVerdict(fraction, elevated: 0.7, strained: 0.9)
        case .ram, .pressure:
            switch pressureLevel {
            case .normal: return .calm
            case .warning: return .elevated
            case .critical: return .strained
            }
        case .temperature:
            // `fraction` is the die temperature over 100 °C.
            return MenuBarVerdict(fraction, elevated: 0.8, strained: 0.95)
        case .energy:
            guard isBatteryPresent, !isOnAC, let charge = batteryCharge else { return .calm }
            return charge <= 0.1 ? .strained : charge <= 0.2 ? .elevated : .calm
        case .network, .disk, .sensors:
            return .calm
        }
    }

    /// Whether a direction is moving enough to show a non-zero figure. The
    /// compact shape tints its arrow only then, so an idle direction drops
    /// back to the bar's own colour. 1000 bytes is where `formatSpeed` stops
    /// printing "0 KB/s", so the tint and the figure always agree.
    func isDirectionActive(input: Bool) -> Bool {
        (input ? primaryBytesPerSec : secondaryBytesPerSec) >= 1000
    }

    /// What the compact shape draws that the figures alone do not capture:
    /// the verdict colour, the arrow tints and each sensor's verdict. The
    /// status item repaints when this changes, so a reading that crosses a
    /// threshold without changing its rounded figure still changes colour.
    var compactSignature: String {
        let directions =
            "\(isDirectionActive(input: true) ? 1 : 0)\(isDirectionActive(input: false) ? 1 : 0)"
        let sensors = sensorCells.map { "\($0.verdict.rawValue)" }.joined()
        return "\(verdict.rawValue)\(directions)\(sensors)"
    }

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
    /// The compact shape's figure size, from the Text size setting.
    var compactTextSize = CGFloat(CombinedMenuBarConfiguration.defaultTextSize)
}

extension MenuBarMetric {
    func isAlarm(in activeKinds: Set<Alert.Kind>) -> Bool {
        switch self {
        case .pressure:
            return !activeKinds.isDisjoint(with: [
                .criticalPressure, .swap, .processCeiling, .leak,
            ])
        case .cpu:
            return !activeKinds.isDisjoint(with: [.highCPU, .sustainedProcessCPU])
        case .temperature:
            return activeKinds.contains(.thermalThrottle)
        case .gpu:
            return activeKinds.contains(.highGPU)
        // The memory alarms stay on the pressure readout, which is the health
        // signal. Firing them on `ram` too would just paint the same warning red
        // twice in one strip.
        // Sensors carries no alarm of its own: the thermal alarm already fires
        // on the temperature read-out, and a voltage rail has no threshold this
        // app would be right to assert.
        case .ram, .energy, .network, .disk, .sensors:
            return false
        }
    }
}

/// How much attention a menu bar reading asks for. The compact shape's only
/// use of colour.
enum MenuBarVerdict: Int, Comparable {
    case calm
    case elevated
    case strained

    /// The verdict for a level against its two thresholds.
    init(_ level: Double, elevated: Double, strained: Double) {
        self = level >= strained ? .strained : level >= elevated ? .elevated : .calm
    }

    static func < (lhs: MenuBarVerdict, rhs: MenuBarVerdict) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One chosen sensor as the compact shape draws it: the symbol for its kind,
/// its figure, and the forms that figure can take, so the cell can reserve
/// the widest of them.
struct MenuBarSensorCell {
    var kind: SensorKind
    var text: String
    var templates: [String]
    var value: Double

    /// Temperatures turn orange at 80 °C and red at 95 °C, the same as the
    /// Temperature read-out. Every other kind is information only. Judged on
    /// the rounded figure the cell prints, so the colour never disagrees with
    /// the number beside it.
    var verdict: MenuBarVerdict {
        guard kind == .temperature else { return .calm }
        return MenuBarVerdict(value.rounded(), elevated: 80, strained: 95)
    }

    /// The SF Symbol for the kind of reading.
    var symbolName: String {
        switch kind {
        case .temperature: return "thermometer.medium"
        case .power: return "bolt.fill"
        case .voltage: return "v.circle"
        case .current: return "a.circle"
        case .energy: return "bolt.circle"
        case .fan: return "fan"
        }
    }
}
