import MacPerfMonitorCore
import SwiftUI

/// The caption above a popover's top-process list, with the switch between
/// one row per process and one row per app.
struct MenuProcessListHeader: View {
    let title: LocalizedStringKey
    @Binding var groupByApp: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                groupByApp.toggle()
            } label: {
                Image(systemName: groupByApp ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(groupByApp ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(groupByApp ? "Show every process" : "Group processes by app")
            .accessibilityLabel("Group by app")
            .accessibilityValue(groupByApp ? "On" : "Off")
        }
        .padding(.bottom, 2)
    }
}

/// One app in a popover's By App list: a disclosure row with the app's icon,
/// name, process count, summed trend and total, which opens to show its
/// processes highest first. An app with a single process shows that
/// process's own row, indented to line up with the app rows.
struct MenuAppGroupRow<Child: View>: View {
    let group: AppProcessGroup
    /// The app's total, formatted for the value column.
    let value: String
    let valueWidth: CGFloat
    let trail: [Double]
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let child: (ProcessSample) -> Child

    /// Members shown when open; Chrome alone can run a hundred helpers.
    static var memberLimit: Int { 10 }

    /// The chevron column, which members are indented by so their icons sit
    /// under the app's.
    static var indent: CGFloat { 18 }

    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    var body: some View {
        if group.processes.count == 1, let only = group.processes.first {
            child(only).padding(.leading, Self.indent)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    ForEach(group.processes.prefix(Self.memberLimit)) { process in
                        child(process).padding(.leading, Self.indent)
                    }
                    let hidden = group.processes.count - Self.memberLimit
                    if hidden > 0 {
                        Text(
                            hidden == 1
                                ? t("1 more process") : t("%@ more processes", String(hidden))
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.indent + 30)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Self.indent - 8)
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: group.iconPath))
                .resizable()
                .frame(width: 16, height: 16)
            HStack(spacing: 6) {
                Text(group.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(values: trail, sampleCapacity: SamplerModel.processTrailCapacity)
                .tint(.secondary)
                .frame(width: 34, height: 14)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
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
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: "\(group.name), \(countText), \(value)"))
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
}
