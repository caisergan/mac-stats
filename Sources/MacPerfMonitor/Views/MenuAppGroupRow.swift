import MacPerfMonitorCore
import SwiftUI

/// What one of the panel's ranked lists measures. Every tab's list is the same
/// list; this is the part that differs.
struct MenuRankedMetric {
    /// The figure a process is ranked by. One value for most metrics, or two
    /// for a list that splits into directions (disk reads and writes), which
    /// then prints both and splits its meter between them.
    var parts: (ProcessSample) -> [Double]
    /// The meter's colour for each part.
    var colors: [Color]
    var format: (Double) -> String
    var valueWidth: CGFloat = 50
    /// The trend behind a process's figure, read only while its row is hovered:
    /// nothing else looks at it, so a closed or idle list never pays for it.
    var trail: (ProcessIdentity) -> [Double]
    /// A tag beside the name, such as the AI runtime behind a GPU process.
    var badge: (ProcessSample) -> String? = { _ in nil }
    var isLeaking: (ProcessSample) -> Bool = { _ in false }

    func total(_ process: ProcessSample) -> Double {
        parts(process).reduce(0) { $0 + ($1.isFinite ? $1 : 0) }
    }

    /// A group's parts: each direction summed across its members.
    func parts(of group: AppProcessGroup) -> [Double] {
        var sums = [Double](repeating: 0, count: colors.count)
        for process in group.processes {
            for (index, value) in parts(process).enumerated() where index < sums.count {
                sums[index] += value.isFinite ? value : 0
            }
        }
        return sums
    }
}

/// A card listing the top consumers of one metric, by app or by process. The
/// choice is one setting across every tab, and each row keeps its quick figure
/// visible and its detail (the trend, the actions) under the pointer.
struct MenuRankedList<Accessory: View, Footer: View>: View {
    let title: LocalizedStringKey
    let metric: MenuRankedMetric
    let apps: [AppProcessGroup]
    let processes: [ProcessSample]
    /// Shown when the list on show is empty, already localised.
    var emptyText: String = t("Sampling\u{2026}")
    var rowLimit = 8
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var footer: Footer

    @AppStorage("menuProcessGroupByApp") private var groupByApp = true
    @State private var expandedApps: Set<String> = []

    var body: some View {
        MenuPanelCard(horizontal: 6, vertical: 8) {
            header
            if groupByApp ? apps.isEmpty : processes.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else if groupByApp {
                let shown = Array(apps.prefix(rowLimit))
                let scale = shown.map { metric.parts(of: $0).reduce(0, +) }.max() ?? 0
                ForEach(shown) { app in
                    MenuAppGroupRow(
                        group: app, metric: metric, scale: scale,
                        isExpanded: expandedApps.contains(app.id),
                        toggle: { expandedApps.formSymmetricDifference([app.id]) })
                }
            } else {
                let shown = Array(processes.prefix(rowLimit))
                let scale = shown.map(metric.total).max() ?? 0
                ForEach(shown) { process in
                    MenuRankedProcessRow(process: process, metric: metric, scale: scale)
                }
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            MenuPanelHeading(title: title)
            Spacer(minLength: 0)
            accessory
            Button {
                groupByApp.toggle()
            } label: {
                Image(systemName: groupByApp ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(
                        groupByApp ? (metric.colors.first ?? .accentColor) : .secondary
                    )
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(groupByApp ? "Show every process" : "Group processes by app")
            .accessibilityLabel("Group by app")
            .accessibilityValue(groupByApp ? "On" : "Off")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.bottom, 3)
    }
}

extension MenuRankedList where Accessory == EmptyView, Footer == EmptyView {
    init(
        title: LocalizedStringKey, metric: MenuRankedMetric, apps: [AppProcessGroup],
        processes: [ProcessSample], emptyText: String = t("Sampling\u{2026}")
    ) {
        self.init(
            title: title, metric: metric, apps: apps, processes: processes, emptyText: emptyText,
            accessory: { EmptyView() }, footer: { EmptyView() })
    }
}

/// The layout every row of a ranked list shares: identity on the left, then a
/// meter that gives way to the trend under the pointer, the figure, and an
/// actions button that shows with the trend.
private struct MenuRankedRowLayout<Actions: View>: View {
    let name: String
    /// A process count or similar, quieter than the name.
    var detail: String? = nil
    var badge: String? = nil
    var isLeaking = false
    let iconPath: String?
    /// True or false draws the disclosure chevron; nil leaves its column blank
    /// for a row with nothing to open.
    var isExpanded: Bool? = nil
    /// How far the row sits in: a group's members line up under its name.
    var indent: CGFloat = 0
    let parts: [Double]
    let scale: Double
    let metric: MenuRankedMetric
    let trail: () -> [Double]
    @ViewBuilder var actions: Actions

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let isExpanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: iconPath))
                .resizable()
                .frame(width: 16, height: 16)
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .background(
                            MenuPanelStyle.well,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                if isLeaking { LeakIndicator() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            slot
            value
            // Nearly clear rather than clear: fully transparent views drop out
            // of hit testing and of VoiceOver, and this has to stay reachable.
            actions
                .frame(width: 18, height: 18)
                .opacity(hovering ? 1 : 0.001)
        }
        .padding(.leading, 6 + indent)
        .padding(.trailing, 4)
        .frame(height: parts.count > 1 ? 27 : 23)
        .background(
            hovering ? MenuPanelStyle.hover : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// The meter, or under the pointer the trend. Only the hovered row asks for
    /// its trail, so an open list does no per-row history work at 1 Hz.
    @ViewBuilder private var slot: some View {
        Group {
            if hovering {
                Sparkline(values: trail(), sampleCapacity: SamplerModel.processTrailCapacity)
                    .tint(metric.colors.first ?? .secondary)
            } else {
                MenuMeter(
                    parts: zip(parts, metric.colors).map { value, color in
                        (fraction: scale > 0 ? value / scale : 0, color: color)
                    })
            }
        }
        .frame(width: 40, height: 14)
    }

    @ViewBuilder private var value: some View {
        Group {
            if parts.count > 1 {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(zip(parts, metric.colors).enumerated()), id: \.offset) {
                        index, part in
                        HStack(spacing: 1) {
                            Image(systemName: index == 0 ? "arrow.down" : "arrow.up")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(part.1)
                            Text(metric.format(part.0))
                        }
                    }
                }
                .font(MenuPanelStyle.valueFont(size: 10.5))
            } else {
                Text(metric.format(parts.first ?? 0))
                    .font(MenuPanelStyle.valueFont(size: 12))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: metric.valueWidth, alignment: .trailing)
    }
}

/// One process in a ranked list. A click opens it in the main window; the
/// actions button and a right click carry Reveal, Force Quit and the rest.
struct MenuRankedProcessRow: View {
    let process: ProcessSample
    let metric: MenuRankedMetric
    let scale: Double
    var indent: CGFloat = 0

    var body: some View {
        MenuRankedRowLayout(
            name: process.displayName, badge: metric.badge(process),
            isLeaking: metric.isLeaking(process), iconPath: process.executablePath, indent: indent,
            parts: metric.parts(process), scale: scale, metric: metric,
            trail: { metric.trail(process.id) }
        ) {
            ProcessRowMenuButton(identity: process.id, bringWindowForward: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens this process in the main window")
        .processRowActions(identity: process.id, bringWindowForward: true, openOnSingleTap: true)
    }

    private var accessibilityLabel: String {
        let figures = metric.parts(process).map(metric.format).joined(separator: ", ")
        let base = "\(process.displayName), \(figures)"
        return metric.isLeaking(process) ? "\(base), possible memory leak" : base
    }
}

/// One app in a ranked list: a disclosure row with the app's icon, name,
/// process count and total, which opens to show its processes highest first. An
/// app with a single process shows that process's own row.
struct MenuAppGroupRow: View {
    let group: AppProcessGroup
    let metric: MenuRankedMetric
    let scale: Double
    let isExpanded: Bool
    let toggle: () -> Void

    /// Members shown when open; Chrome alone can run a hundred helpers.
    static var memberLimit: Int { 10 }

    /// How far members sit in, so their icons line up under the app's name.
    static var indent: CGFloat { 16 }

    @EnvironmentObject private var appState: AppState

    var body: some View {
        if group.processes.count == 1, let only = group.processes.first {
            MenuRankedProcessRow(process: only, metric: metric, scale: scale)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    ForEach(group.processes.prefix(Self.memberLimit)) { process in
                        MenuRankedProcessRow(
                            process: process, metric: metric, scale: scale, indent: Self.indent)
                    }
                    let hidden = group.processes.count - Self.memberLimit
                    if hidden > 0 {
                        Text(
                            hidden == 1
                                ? t("1 more process") : t("%@ more processes", String(hidden))
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 40 + Self.indent)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var header: some View {
        MenuRankedRowLayout(
            name: group.name, detail: countText,
            badge: group.processes.lazy.compactMap(metric.badge).first,
            isLeaking: group.processes.contains(where: metric.isLeaking),
            iconPath: group.iconPath, isExpanded: isExpanded, parts: metric.parts(of: group),
            scale: scale, metric: metric,
            trail: { MenuTrail.sum(group.processes.map { metric.trail($0.id) }) }
        ) {
            Menu {
                Button(role: .destructive) {
                    ProcessRowIntent.requestAppKill(
                        AppForceQuitTarget(group: group), appState: appState,
                        bringWindowForward: true)
                } label: {
                    Label(
                        t("Force Quit \u{201C}%@\u{201D}\u{2026}", group.name),
                        systemImage: "xmark.octagon")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for this app")
            .accessibilityLabel("App actions")
        }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            Text(
                verbatim:
                    "\(group.name), \(countText), \(metric.parts(of: group).map(metric.format).joined(separator: ", "))"
            )
        )
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the processes in this app")
    }

    private var countText: String {
        t("%@ processes", String(group.processes.count))
    }
}

enum MenuTrail {
    /// Member trails summed point by point, aligned on their latest sample, so
    /// an app's sparkline is the trend of its total.
    static func sum(_ trails: [[Double]]) -> [Double] {
        let length = trails.map(\.count).max() ?? 0
        var total = [Double](repeating: 0, count: length)
        for trail in trails {
            let offset = length - trail.count
            for (index, value) in trail.enumerated() { total[offset + index] += value }
        }
        return total
    }

    /// A rate per second between neighbouring points of a cumulative counter.
    /// A counter that went backwards (a reused identity, or a reset) is a zero
    /// rather than a negative spike, and two points at the same moment are
    /// skipped because they say nothing about a rate.
    static func rates(counters: [Double], dates: [Date]) -> [Double] {
        guard counters.count == dates.count, counters.count >= 2 else { return [] }
        var rates: [Double] = []
        rates.reserveCapacity(counters.count - 1)
        for index in 1..<counters.count {
            let elapsed = dates[index].timeIntervalSince(dates[index - 1])
            guard elapsed > 0 else { continue }
            rates.append(max(0, counters[index] - counters[index - 1]) / elapsed)
        }
        return rates
    }
}
