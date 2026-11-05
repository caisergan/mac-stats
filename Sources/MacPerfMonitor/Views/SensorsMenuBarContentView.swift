import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Sensors panel: every reading the machine exposes, arranged by what it
/// answers rather than listed by unit (see `SensorsPanelLayout`).
///
/// A Mac reports around forty readings and no two of them share a scale. What
/// keeps that readable is:
///
/// * The figures people came for lead, in a card of their own.
/// * The per-core die sensors, which track each other within a degree or two,
///   stay folded behind their average. CPU and GPU open separately, and both
///   are closed whenever the panel opens.
/// * An open core set is a heat grid rather than a list, so twenty sensors cost
///   a row or two and a hot core is findable without reading a number. The
///   tints use the app's own thermal wording: warm from 70, hot from 85.
/// * Nothing carries a control. A reading is a button; clicking it pins that
///   sensor to the menu bar and a dot marks the pinned ones.
struct SensorsMenuBarContentView: View {
    @EnvironmentObject private var menuClock: MenuClock
    @StateObject private var store = SensorsStore.shared

    @State private var openCores: Set<SensorDomain> = []

    /// The most tiles on one row of a core grid before it wraps, so the digits
    /// stay readable on a chip with many cores.
    private static let coresPerRow = 12

    var body: some View {
        _ = menuClock.tick
        store.refreshIfDue()
        return
            panel
            .onAppear { store.refreshIfDue(floor: 0) }
            .onDisappear { openCores = [] }
    }

    @ViewBuilder private var panel: some View {
        let layout = SensorsPanelLayout(readings: store.readings)
        if store.readings.isEmpty {
            MenuPanelCard {
                Text("Reading sensors\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
                summaryCard(layout)
                temperatureCard(layout)
                powerCard(layout)
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder private func summaryCard(_ layout: SensorsPanelLayout) -> some View {
        let tiles = layout.hottest + layout.fans
        if layout.systemTotal != nil || !tiles.isEmpty {
            MenuPanelCard {
                if let total = layout.systemTotal {
                    pinButton(total) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            MenuPanelFigure(text: "\(figure(total, digits: 1)) W")
                            Text(total.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if !tiles.isEmpty {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8
                    ) {
                        ForEach(tiles) { reading in
                            pinButton(reading) { summaryTile(reading) }
                        }
                    }
                    .padding(.top, layout.systemTotal == nil ? 0 : 8)
                }
            }
        }
    }

    private func summaryTile(_ reading: SensorReadingValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reading.name)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(
                reading.kind == .temperature ? "\(reading.figure)\u{00B0}" : reading.formattedValue
            )
            .font(MenuPanelStyle.valueFont(size: 14))
            .foregroundStyle(temperatureColor(reading) ?? .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let fan = reading.fan, fan.percentage > 0 {
                MenuMeter(
                    parts: [
                        (
                            fraction: Double(fan.percentage) / 100,
                            color: MenuPanelStyle.accent(.sensors)
                        )
                    ], height: 3)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MenuPanelStyle.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Temperature

    @ViewBuilder private func temperatureCard(_ layout: SensorsPanelLayout) -> some View {
        let hasCores = !layout.cpuCores.isEmpty || !layout.gpuCores.isEmpty
        if hasCores || !layout.otherTemperatures.isEmpty {
            MenuPanelCard {
                HStack(spacing: 6) {
                    MenuPanelHeading(title: "Temperature")
                    Text(verbatim: "\u{00B0}C")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 4)
                coreSection("CPU", domain: .cpu, cores: layout.cpuCores, average: layout.cpuAverage)
                coreSection("GPU", domain: .gpu, cores: layout.gpuCores, average: layout.gpuAverage)
                if !layout.otherTemperatures.isEmpty {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 6), count: 3),
                        alignment: .leading, spacing: 1
                    ) {
                        ForEach(layout.otherTemperatures) { reading in
                            readingRow(reading, value: reading.figure)
                        }
                    }
                    .padding(.top, hasCores ? 6 : 0)
                }
            }
        }
    }

    /// One CPU or GPU row: its core count and average, opening onto its heat
    /// grid. A Mac with no per-core sensors for the domain has nothing to open
    /// and shows nothing here; its average, if any, stays reachable by pinning
    /// from the summary's hottest reading.
    @ViewBuilder private func coreSection(
        _ title: String, domain: SensorDomain, cores: [SensorReadingValue],
        average: SensorReadingValue?
    ) -> some View {
        if !cores.isEmpty {
            let isOpen = openCores.contains(domain)
            HStack(spacing: 6) {
                Button {
                    openCores.formSymmetricDifference([domain])
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 10)
                        Text(verbatim: title)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(t("%@ cores", String(cores.count)))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("%@ cores", String(cores.count)))
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                if let average {
                    pinButton(average) {
                        HStack(spacing: 3) {
                            Text("avg")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(average.figure)
                                .font(MenuPanelStyle.valueFont(size: 11.5))
                                .foregroundStyle(temperatureColor(average) ?? .primary)
                        }
                        .padding(.trailing, 8)
                    }
                    .fixedSize()
                }
            }
            if isOpen {
                coreGrid(cores)
                    .padding(.bottom, 4)
            }
        }
    }

    private func coreGrid(_ cores: [SensorReadingValue]) -> some View {
        let rows = stride(from: 0, to: cores.count, by: Self.coresPerRow).map {
            Array(cores[$0..<min($0 + Self.coresPerRow, cores.count)])
        }
        return VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(row) { reading in
                        pinButton(reading) { coreTile(reading) }
                    }
                }
            }
        }
    }

    private func coreTile(_ reading: SensorReadingValue) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: SensorsPanelLayout.coreLabel(reading.name))
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            Text(reading.figure)
                .font(MenuPanelStyle.valueFont(size: 10.5))
                .minimumScaleFactor(0.8)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: 33)
        .background(heat(reading.value), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: - Power

    @ViewBuilder private func powerCard(_ layout: SensorsPanelLayout) -> some View {
        let hasColumns = !layout.supply.isEmpty || !layout.components.isEmpty
        if hasColumns || !layout.totals.isEmpty {
            MenuPanelCard {
                MenuPanelHeading(title: "Power and electrical")
                    .padding(.bottom, 4)
                if hasColumns {
                    HStack(alignment: .top, spacing: 12) {
                        powerColumn(
                            "Supply", layout.supply, total: layout.systemTotal?.value,
                            label: { layout.supplyLabel($0, kindName: $0.kind.sectionTitle) })
                        powerColumn(
                            "Components", layout.components, total: layout.systemTotal?.value,
                            label: { SensorsPanelLayout.componentLabel($0.name) })
                    }
                }
                if !layout.totals.isEmpty {
                    VStack(spacing: 1) {
                        ForEach(layout.totals) { reading in
                            readingRow(reading, value: reading.formattedValue)
                        }
                    }
                    .padding(.top, hasColumns ? 5 : 0)
                }
            }
        }
    }

    private func powerColumn(
        _ title: LocalizedStringKey, _ readings: [SensorReadingValue], total: Double?,
        label: @escaping (SensorReadingValue) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // The rails behind Components arrive with the second sweep, so the
            // heading waits for them rather than promising an empty column.
            if !readings.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 1)
            }
            ForEach(readings) { reading in
                pinButton(reading) {
                    HStack(spacing: 4) {
                        pinDot(reading)
                        Text(verbatim: label(reading))
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(reading.name)
                        Spacer(minLength: 2)
                        // Share of the machine's total, so the big draw shows
                        // without comparing figures. Rails have no share to give.
                        if reading.kind == .power, let total, total > 0 {
                            MenuMeter(
                                parts: [
                                    (
                                        fraction: reading.value / total,
                                        color: MenuPanelStyle.accent(.sensors)
                                    )
                                ]
                            )
                            .frame(width: 36)
                        }
                        Text(reading.formattedValue)
                            .font(MenuPanelStyle.valueFont(size: 11.5))
                            .foregroundStyle(reading.isComputed ? .secondary : .primary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(height: 20)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared pieces

    /// A reading as one line: the pinned marker, its name and its figure.
    private func readingRow(_ reading: SensorReadingValue, value: String) -> some View {
        pinButton(reading) {
            HStack(spacing: 4) {
                pinDot(reading)
                Text(verbatim: reading.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reading.name)
                Spacer(minLength: 2)
                Text(value)
                    .font(MenuPanelStyle.valueFont(size: 11.5))
                    .foregroundStyle(
                        temperatureColor(reading) ?? (reading.isComputed ? .secondary : .primary)
                    )
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 20)
        }
    }

    /// The pinned dot, or the space it would take, so a click does not nudge
    /// the name sideways.
    private func pinDot(_ reading: SensorReadingValue) -> some View {
        Circle()
            .fill(MenuPanelStyle.accent(.sensors))
            .frame(width: 5, height: 5)
            .opacity(store.isInMenuBar(reading.key) ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// A reading is a button, not a row with a control in it. Clicking anywhere
    /// on it pins or unpins the sensor; a tile with no room for a leading dot
    /// carries one in its corner.
    private func pinButton<Content: View>(
        _ reading: SensorReadingValue, @ViewBuilder content: () -> Content
    ) -> some View {
        let pinned = store.isInMenuBar(reading.key)
        return Button {
            store.setInMenuBar(reading.key, !pinned)
        } label: {
            content()
                .overlay(alignment: .topTrailing) {
                    if pinned, !Self.hasLeadingDot(reading) {
                        Circle()
                            .fill(MenuPanelStyle.accent(.sensors))
                            .frame(width: 5, height: 5)
                            .padding(3)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            pinned
                ? t("%@ is in the menu bar. Click to remove it.", reading.name)
                : t("Click to show %@ in the menu bar.", reading.name)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reading.name)
        .accessibilityValue(reading.formattedValue)
        .accessibilityAddTraits(pinned ? [.isButton, .isSelected] : .isButton)
    }

    /// Whether the reading is drawn as a line with room for the pinned dot in
    /// front of its name, rather than as a tile or a headline.
    private static func hasLeadingDot(_ reading: SensorReadingValue) -> Bool {
        switch reading.kind {
        case .voltage, .current, .energy: return true
        case .power: return reading.name != "System Total"
        case .fan: return false
        case .temperature:
            return !reading.isCore && reading.name != "Hottest CPU"
                && reading.name != "Hottest GPU" && reading.name != "Average CPU"
                && reading.name != "Average GPU"
        }
    }

    private func figure(_ reading: SensorReadingValue, digits: Int) -> String {
        String(format: "%.\(digits)f", reading.value)
    }

    /// A temperature past the point where a Mac is working hard is tinted, so a
    /// hot spot is findable without reading every number.
    private func temperatureColor(_ reading: SensorReadingValue) -> Color? {
        guard reading.kind == .temperature else { return nil }
        if reading.value >= 85 { return .red }
        if reading.value >= 70 { return .orange }
        return nil
    }

    /// A core tile's fill: neutral when cool, warming towards 70, then the same
    /// orange and red the figures use.
    private func heat(_ celsius: Double) -> Color {
        if celsius >= 85 { return Color.red.opacity(0.55) }
        if celsius >= 70 { return Color.orange.opacity(0.42) }
        let warmth = min(max((celsius - 40) / 30, 0), 1)
        return warmth > 0 ? Color.orange.opacity(0.08 + warmth * 0.14) : MenuPanelStyle.well
    }
}
