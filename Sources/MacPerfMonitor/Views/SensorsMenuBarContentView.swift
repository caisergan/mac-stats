import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Sensors panel: every reading the machine exposes, grouped the way Stats'
/// Sensors module groups them (fans, then temperature, voltage, current, power
/// and the accumulated energy).
///
/// A Mac reports around forty readings and no two of them share a scale, so
/// this is a list rather than a dashboard. What makes forty rows readable is
/// not bigger type:
///
/// * The unit goes in the section heading, so "TEMPERATURE (°C)" is said once
///   instead of a `°C` on every row.
/// * Readings pair into two columns, halving the height and putting each
///   figure beside its own name rather than across a gulf of empty panel.
/// * Each section breaks into its domain blocks, so the CPU cores, the GPU
///   clusters and the machine's own sensors read as three things to scan
///   rather than one run of thirty.
/// * Nothing carries a control. A row is text; clicking it pins that sensor to
///   the menu bar and a dot marks the pinned ones, which costs one glyph
///   instead of forty checkboxes.
/// * Temperatures past the point where a Mac is working hard are tinted, so a
///   hot spot is findable without reading every number.
struct SensorsMenuBarContentView: View {
    @EnvironmentObject private var menuClock: MenuClock
    @StateObject private var store = SensorsStore.shared

    var embedded = false

    /// How tall the scrolling list is allowed to be.
    ///
    /// Taken from the display rather than fixed: this panel has more rows than
    /// any other and a fixed 300 points wasted half a tall screen while still
    /// being too much of a laptop's. What is subtracted is the rest of the
    /// panel around the list (the chip row, the dividers, the command bar) plus
    /// the menu bar itself, so the popover stays inside the visible frame. The
    /// clamp keeps it a panel on a very tall display and keeps it usable on a
    /// short one, and the list scrolls past it either way.
    private var maximumListHeight: CGFloat {
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 220
        return min(620, max(260, available))
    }
    /// Reserved on every row so pinning a sensor marks it without shifting the
    /// name a few pixels sideways.
    private let markerWidth: CGFloat = 9

    var body: some View {
        _ = menuClock.tick
        store.refreshIfDue()
        return
            panel
            .onAppear {
                if !embedded { menuClock.open() }
                store.refreshIfDue(floor: 0)
            }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sections = store.sections()
            if sections.isEmpty {
                Text("Reading sensors\u{2026}")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: maximumListHeight)
            }
            if !embedded { MenuVersionFooter() }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 380)
    }

    // MARK: - Sections

    private func sectionView(_ section: SensorSection) -> some View {
        // A section that states its unit in the heading prints bare figures; a
        // section that mixes them lets each row say which it is.
        let showsUnit = section.unit == nil
        return VStack(alignment: .leading, spacing: 7) {
            sectionHeader(section)
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                // Fans carry a bar as well as a figure, so they get the full
                // width; everything else pairs into two columns.
                if block.first?.kind == .fan {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(block) { reading in fanRow(reading, showsUnit: showsUnit) }
                    }
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 14, alignment: .leading),
                            GridItem(.flexible(), spacing: 14, alignment: .leading),
                        ], alignment: .leading, spacing: 1
                    ) {
                        ForEach(block) { reading in row(reading, showsUnit: showsUnit) }
                    }
                }
            }
        }
    }

    /// The heading carries the unit, so no row has to repeat it, and for
    /// Temperature it also carries the switch between the core averages and
    /// every core. That belongs here rather than in a footer: it changes this
    /// section and nothing else, and a row of its own would read as another
    /// sensor.
    private func sectionHeader(_ section: SensorSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title.localizedUppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let unit = section.unit {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
            if section.showsCoreSwitch {
                Button {
                    store.showsAllCores.toggle()
                } label: {
                    Text(store.showsAllCores ? "Averages only" : "All cores")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(
                    "Every CPU and GPU core reports its own temperature, and they track each other closely. The averages stand in for them unless you ask for the detail."
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Rows

    private func row(_ reading: SensorReadingValue, showsUnit: Bool) -> some View {
        sensorButton(reading) {
            HStack(spacing: 5) {
                marker(reading)
                Text(reading.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                figure(reading, showsUnit: showsUnit)
            }
        }
    }

    private func fanRow(_ reading: SensorReadingValue, showsUnit: Bool) -> some View {
        sensorButton(reading) {
            HStack(spacing: 5) {
                marker(reading)
                Text(reading.name).font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                if let fan = reading.fan, fan.percentage > 0 {
                    fanBar(fan)
                }
                figure(reading, showsUnit: showsUnit)
            }
        }
    }

    /// A row is a button, not a row with a control in it. Clicking anywhere on
    /// it pins or unpins the sensor.
    private func sensorButton<Content: View>(
        _ reading: SensorReadingValue, @ViewBuilder content: () -> Content
    ) -> some View {
        let pinned = store.isInMenuBar(reading.key)
        return Button {
            store.setInMenuBar(reading.key, !pinned)
        } label: {
            content()
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(pinned ? Color.accentColor.opacity(0.12) : .clear))
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

    /// The pinned dot, or the space it would take. Reserved either way so a
    /// click does not nudge the name sideways.
    private func marker(_ reading: SensorReadingValue) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
            .opacity(store.isInMenuBar(reading.key) ? 1 : 0)
            .frame(width: markerWidth, alignment: .leading)
            .accessibilityHidden(true)
    }

    private func figure(_ reading: SensorReadingValue, showsUnit: Bool) -> some View {
        Text(showsUnit ? reading.formattedValue : reading.figure)
            .font(.caption.monospacedDigit())
            .foregroundStyle(figureColor(reading))
    }

    /// Derived figures read a shade back from measured ones, and a temperature
    /// past the point where a Mac is working hard is tinted so a hot spot is
    /// findable without reading every number. The thresholds are the same ones
    /// the app's own thermal wording uses: warm, then hot.
    private func figureColor(_ reading: SensorReadingValue) -> Color {
        if reading.kind == .temperature {
            if reading.value >= 85 { return .red }
            if reading.value >= 70 { return .orange }
        }
        return reading.isComputed ? .secondary : .primary
    }

    /// A fan's speed as a share of its rated maximum. Read only: setting a fan
    /// curve means writing to the SMC, which needs a privileged helper and is
    /// not something this app does.
    private func fanBar(_ fan: SensorFanFacts) -> some View {
        let fraction = min(max(Double(fan.percentage) / 100, 0), 1)
        return HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(width: 64, height: 4)
            Text("\(fan.percentage)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

}
