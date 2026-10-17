import Foundation
import MacPerfMonitorCore

/// The menu bar widget shapes, ported from Stats (github.com/exelban/stats, MIT).
///
/// Stats builds its menu bar out of interchangeable widgets: each module picks a
/// widget type and the bar composes them left to right. The cases here mirror
/// Stats' `widget_t` one for one, so a reader who knows that project finds the
/// same vocabulary. What differs is the plumbing: Stats instantiates an `NSView`
/// subclass per widget and lets AppKit lay them out, whereas this app composites
/// one bitmap for the single combined status item, so each case maps to a
/// drawing routine in `StatsMenuBarWidgets` instead of a view class.
///
/// See `docs/menu-bar-widgets.md` for the shape-by-shape description.
///
/// `compact` is this app's own shape rather than a Stats port: an SF Symbol and
/// the value on one line in the menu bar's own font, so the read-outs sit
/// beside the clock and Wi-Fi like system items. It is not offered per
/// read-out. The Compact menu bar design draws every read-out in it, and the
/// Classic design draws each in the shape chosen from the others.
enum MenuBarWidgetStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The metric's symbol and its value on one line. Network and disk stack
    /// their two directions behind arrows or letters; the battery adds its
    /// time estimate; sensors pair each figure with the symbol of its kind.
    case compact
    /// A three-letter caption above the value. Stats' default for most modules.
    case mini
    /// A filled sparkline of recent history, optionally boxed.
    case lineChart
    /// One vertical bar per recent reading.
    case barChart
    /// A filled ring.
    case pieChart
    /// A mirrored sparkline: download above the axis, upload below.
    case networkChart
    /// Two stacked rates with direction dots, arrows or letters.
    case speed
    /// A battery outline that fills with charge.
    case battery
    /// The battery outline with the charge and the time estimate beside it.
    case batteryDetails
    /// Free over used, each on its own row.
    case memory
    /// Free-form label/value pairs packed into one or two rows.
    case stack
    /// A half ring, filling clockwise like a dial.
    case tachometer
    /// A single coloured dot.
    case state
    /// The value alone, no caption.
    case text
    /// The three-letter caption alone, stacked vertically.
    case label

    var id: String { rawValue }

    /// The name shown in the Settings picker.
    var title: String {
        switch self {
        case .compact: return t("Compact")
        case .mini: return t("Mini")
        case .lineChart: return t("Line chart")
        case .barChart: return t("Bar chart")
        case .pieChart: return t("Pie chart")
        case .networkChart: return t("Network chart")
        case .speed: return t("Transfer speed")
        case .battery: return t("Battery")
        case .batteryDetails: return t("Battery details")
        case .memory: return t("Memory")
        case .stack: return t("Stack")
        case .tachometer: return t("Tachometer")
        case .state: return t("State dot")
        case .text: return t("Text")
        case .label: return t("Label")
        }
    }

    /// Whether this shape can show `metric`.
    ///
    /// Stats encodes the same thing per module in `config.plist`: the Network
    /// module offers speed and network chart, Battery offers the battery
    /// shapes, and so on. A shape is offered only where it has data to draw:
    /// the two-direction shapes need a metric with a second value, the battery
    /// shapes need a battery, and Memory needs a free/used split.
    func supports(_ metric: MenuBarMetric) -> Bool {
        switch self {
        case .compact:
            // Every read-out has a compact form, which the Compact design uses.
            return true
        case .networkChart, .speed:
            return metric.hasSecondaryValue
        case .battery, .batteryDetails:
            return metric == .energy
        case .memory:
            // The free/used rows read from the same sample either way.
            return metric == .ram || metric == .pressure
        case .stack:
            return true
        case .mini, .lineChart, .barChart, .pieChart, .tachometer, .state, .text, .label:
            // Sensors is a set of readings, not one figure: there is no level
            // for a gauge to fill and no single history to chart, so Stats
            // offers it the stack alone and so does this app.
            return metric != .sensors
        }
    }

    /// The shapes the Classic design offers for `metric`, in Stats' menu
    /// order. Compact is a design of its own rather than one of these.
    static func supported(for metric: MenuBarMetric) -> [MenuBarWidgetStyle] {
        allCases.filter { $0 != .compact && $0.supports(metric) }
    }

    /// The shape a metric starts on in the Classic design, matching the
    /// `Default: true` widget in the matching Stats module config: mini for the
    /// percentage readouts, speed for the throughput ones, battery for the
    /// battery.
    static func `default`(for metric: MenuBarMetric) -> MenuBarWidgetStyle {
        switch metric {
        case .pressure, .ram, .cpu, .gpu, .temperature: return .mini
        case .energy: return .battery
        case .network, .disk: return .speed
        case .sensors: return .stack
        }
    }
}

extension MenuBarMetric {
    /// Whether the metric carries two figures (in/out, read/write) rather than
    /// one. Drives which widget shapes are offered and how the readout is built.
    var hasSecondaryValue: Bool {
        switch self {
        case .network, .disk: return true
        case .pressure, .ram, .cpu, .gpu, .energy, .temperature, .sensors: return false
        }
    }
}
