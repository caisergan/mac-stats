import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The menu bar panel's visual language: neutral translucent cards on the
/// popover's own material, rounded tabular figures with a quieter unit, and one
/// accent per metric. Colour marks the metric on show and a reading that needs
/// attention, and otherwise stays out of the way, so a dense panel stays calm.
enum MenuPanelStyle {
    static let width: CGFloat = 404
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 8
    static let cardRadius: CGFloat = 14

    /// Card fills are the label colour at low opacity rather than fixed greys,
    /// so they read as one surface over the popover material in either
    /// appearance and whatever is behind the panel.
    static let surface = Color.primary.opacity(0.055)
    static let well = Color.primary.opacity(0.07)
    static let hover = Color.primary.opacity(0.08)

    /// The height the scrolling part of the panel may take on a display of
    /// `screenHeight`. What is subtracted is the panel around it (selector,
    /// alert banner, footer, padding) and the menu bar, so the popover stays in
    /// the visible frame; the clamp keeps it a panel on a very tall display and
    /// usable on a short one.
    static func maximumContentHeight(screenHeight: CGFloat) -> CGFloat {
        min(620, max(200, screenHeight - 210))
    }

    static func figureFont(size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    static func valueFont(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// The colour that stands for a metric in its charts, meters and headings.
    /// Network and Disk use the direction colours the rest of the app gives
    /// them, so a tab means the same thing here as in the main window.
    static func accent(_ metric: MenuBarMetric) -> Color {
        switch metric {
        case .pressure, .ram: return dynamic(light: 0x7E52DC, dark: 0xA97BF5)
        case .cpu: return dynamic(light: 0x2F7BEA, dark: 0x4E9BFF)
        case .gpu: return dynamic(light: 0xBE3BA4, dark: 0xE060C4)
        case .energy: return dynamic(light: 0x1F9A4E, dark: 0x3FBF6B)
        case .temperature: return dynamic(light: 0xCF5C2E, dark: 0xEE7D52)
        case .network: return NetworkStyle.download
        case .disk: return DiskStyle.read
        case .sensors: return dynamic(light: 0x85755A, dark: 0xB3A184)
        }
    }

    /// The solid fill behind a selected tab, dark enough in either appearance to
    /// carry a white symbol and figure.
    static func selectedFill(_ metric: MenuBarMetric) -> Color {
        switch metric {
        case .pressure, .ram: return rgb(0x7E52DC)
        case .cpu: return rgb(0x2F7BEA)
        case .gpu: return rgb(0xBE3BA4)
        case .energy: return rgb(0x1F9A4E)
        case .temperature: return rgb(0xCF5C2E)
        case .network: return rgb(0x1E9E47)
        case .disk: return rgb(0x1E6FD9)
        case .sensors: return rgb(0x85755A)
        }
    }

    private static func rgb(_ hex: Int) -> Color { Color(nsColor: nsColor(hex)) }

    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return nsColor(isDark ? dark : light)
            })
    }
}

/// Splits a formatted reading into its figure and unit, so the unit can be set
/// smaller beside the number: "15.4 GB", "16.0 W", "80%", "57°C". A reading with
/// no unit comes back whole. Formatters decide the text, including the locale's
/// decimal mark, so this only looks for where the number stops.
enum MenuFigureText {
    static func split(_ text: String) -> (figure: String, unit: String) {
        if let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" })
        {
            return (String(text[..<space]), String(text[text.index(after: space)...]))
        }
        guard let lastDigit = text.lastIndex(where: \.isNumber) else { return (text, "") }
        let next = text.index(after: lastDigit)
        return (String(text[..<next]), String(text[next...]))
    }

    /// A throughput figure short enough for a selector cell, where the unit is
    /// understood: "557 KB/s" becomes "557K". The accessibility value and the
    /// panel itself still say it in full.
    static func compactRate(_ text: String) -> String {
        let parts = split(text)
        guard let letter = parts.unit.first, parts.unit.hasSuffix("/s") else { return text }
        return parts.figure + String(letter)
    }
}

/// One rounded surface of the panel. Lists pass a narrower horizontal padding
/// so a row's hover fill can reach close to the card's edge.
struct MenuPanelCard<Content: View>: View {
    var horizontal: CGFloat = 14
    var vertical: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                MenuPanelStyle.surface,
                in: RoundedRectangle(cornerRadius: MenuPanelStyle.cardRadius, style: .continuous))
    }
}

/// A small uppercase heading at the top of a card.
struct MenuPanelHeading: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            // Capitalise by the language the text is in, not the system's region:
            // on a Mac set to Turkey, "Activity" would otherwise become "ACTİVİTY".
            .environment(
                \.locale, Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            )
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The panel's headline: a large figure with its unit set smaller beside it.
struct MenuPanelFigure: View {
    let text: String
    var size: CGFloat = 30

    var body: some View {
        let parts = MenuFigureText.split(text)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.figure)
                .font(MenuPanelStyle.figureFont(size: size))
                .tracking(-0.5)
            if !parts.unit.isEmpty {
                Text(parts.unit)
                    .font(MenuPanelStyle.valueFont(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }
}

/// A verdict beside a figure: "Light", "Normal", "On battery".
struct MenuStatusPill: View {
    let text: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(color.opacity(0.16), in: Capsule())
    }

    /// The system greens and oranges are tuned to sit on dark; as small text on
    /// a pale tint they need taking down a step to stay readable.
    private var textColor: Color {
        guard colorScheme == .light, let base = NSColor(color).usingColorSpace(.sRGB),
            let darker = base.blended(withFraction: 0.35, of: .black)
        else { return color }
        return Color(nsColor: darker)
    }
}

/// The caption above a chart, with the range every tab's charts share.
struct MenuChartHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            MenuChartRangePicker()
        }
        .frame(height: 20)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }
}

/// A labelled figure on a slightly raised surface, for readings that deserve
/// more than a row and less than the headline.
struct MenuStatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(MenuPanelStyle.valueFont(size: 14))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MenuPanelStyle.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Label and value on one line, the panel's basic detail row.
struct MenuDetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(
                    monospaced
                        ? .system(size: 11, design: .monospaced)
                        : MenuPanelStyle.valueFont(size: 11.5)
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
                .help(value)
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .combine)
    }
}

/// Detail rows in two columns, so a handful of readings costs half the height.
/// A row with no partner takes the left column and leaves the right one empty,
/// which keeps every figure on the column it would have had.
struct MenuDetailGrid: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                GridRow {
                    MenuDetailRow(label: rows[index].label, value: rows[index].value)
                    if index + 1 < rows.count {
                        MenuDetailRow(label: rows[index + 1].label, value: rows[index + 1].value)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
            }
        }
    }
}

/// A slim horizontal meter on a tint of its own colour.
struct MenuMeter: View {
    /// The fractions filled, each with its colour, drawn end to end. One part
    /// for a plain meter; two when a figure splits into directions.
    let parts: [(fraction: Double, color: Color)]
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let track = parts.first?.color ?? .secondary
            ZStack(alignment: .leading) {
                Capsule().fill(track.opacity(0.16))
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: geometry.size.width * Self.clamped(part.fraction))
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Holds its content at the height it asks for, up to `maximum`. Between them,
/// a scroll view inside it costs no empty space on a short tab and scrolls on a
/// long one, and the popover can follow the tab's height without a measuring
/// pass of its own.
struct MenuPanelHeightClamp: Layout {
    var maximum: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maximum))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
