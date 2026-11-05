import AppKit
import MacPerfMonitorCore
import SwiftUI

/// The Disk tab of the menu bar panel: physical disk activity plus
/// task-attributed I/O. The two are deliberately labelled separately because
/// process counters do not exactly add up to block-device traffic across caching,
/// metadata, paging, and kernel work.
struct DiskMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuLists: MenuListsModel

    var body: some View {
        VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            activityCard
            MenuPanelCard {
                MenuPanelHeading(title: "Physical devices")
                    .padding(.bottom, 6)
                devices
            }
            topProcesses
        }
    }

    private var activityCard: some View {
        let rates = model.diskRates
        return MenuPanelCard {
            HStack(alignment: .lastTextBaseline, spacing: 22) {
                MenuRateFigure(
                    symbol: "arrow.down", tint: DiskStyle.read,
                    text: rates.map { ByteFormat.rate($0.readBytesPerSec) } ?? "--", label: "Read")
                MenuRateFigure(
                    symbol: "arrow.up", tint: DiskStyle.write,
                    text: rates.map { ByteFormat.rate($0.writeBytesPerSec) } ?? "--", label: "Write"
                )
                Spacer(minLength: 0)
                if let disk = model.latestDisk { iops(disk) }
            }
            MenuChartHeader(title: "Throughput")
            MenuMirroredChart(
                up: .init(
                    series: model.menuTrend(.diskRead, range: chartRange), name: t("Read"),
                    color: DiskStyle.read),
                down: .init(
                    series: model.menuTrend(.diskWrite, range: chartRange), name: t("Write"),
                    color: DiskStyle.write)
            )
            .frame(height: MenuChart.networkHeight)
        }
    }

    private func iops(_ disk: DiskSample) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(
                String(
                    format: String(localized: "%d read IOPS"),
                    Int(disk.readOperationsPerSec.rounded())))
            Text(
                String(
                    format: String(localized: "%d write IOPS"),
                    Int(disk.writeOperationsPerSec.rounded())))
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var devices: some View {
        let items = (model.latestDisk?.devices ?? []).sorted {
            if $0.bsdName == $1.bsdName { return $0.registryEntryID < $1.registryEntryID }
            return $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                Text("Reading storage devices...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: DiskMenuDeviceRow.height, alignment: .top)
            } else {
                ForEach(items) { device in
                    DiskMenuDeviceRow(device: device)
                }
            }
        }
    }

    private var topProcesses: some View {
        MenuRankedList(
            title: "Process-attributed I/O",
            metric: MenuRankedMetric(
                parts: { [$0.diskReadBytesPerSec, $0.diskWriteBytesPerSec] },
                colors: [DiskStyle.read, DiskStyle.write],
                format: { ByteFormat.rate($0) }, valueWidth: 62,
                trail: { [model] in model.diskTrail(for: $0) }),
            apps: menuLists.topDiskApps, processes: menuLists.topDisk
        ) {
            HStack(spacing: 3) {
                Text("Read").foregroundStyle(DiskStyle.read)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text("Write").foregroundStyle(DiskStyle.write)
            }
            .font(.system(size: 11))
        } footer: {
            Text("Process totals may differ from physical device activity.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
    }
}

struct DiskMenuDeviceRow: View {
    static let height: CGFloat = 92

    let device: DiskDeviceSample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(device.model)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(device.model)
                Text(device.bsdName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(height: 18)

            HStack(spacing: 6) {
                Text(metadata)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(metadata)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 14, height: 14)
                    .opacity(hasErrors ? 1 : 0)
                    .help(
                        counterSummary(
                            "%@ errors", read: device.readErrors, write: device.writeErrors)
                    )
                    .accessibilityLabel(
                        counterSummary(
                            "%@ errors", read: device.readErrors, write: device.writeErrors)
                    )
                    .accessibilityHidden(!hasErrors)
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .frame(width: 14, height: 14)
                    .opacity(hasRetries ? 1 : 0)
                    .help(
                        counterSummary(
                            "%@ retries", read: device.readRetries, write: device.writeRetries)
                    )
                    .accessibilityLabel(
                        counterSummary(
                            "%@ retries", read: device.readRetries, write: device.writeRetries)
                    )
                    .accessibilityHidden(!hasRetries)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(height: 16)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear.frame(height: 14)
                    Text("Throughput").frame(height: 14)
                    Text("Service time").frame(height: 14)
                }
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
                direction(
                    "Read", rate: device.readBytesPerSec,
                    serviceTime: device.averageReadTimeMilliseconds, tint: DiskStyle.read)
                direction(
                    "Write", rate: device.writeBytesPerSec,
                    serviceTime: device.averageWriteTimeMilliseconds, tint: DiskStyle.write)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(height: 50)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .top)
        .transaction { $0.animation = nil }
    }

    private var metadata: String {
        let parts = [
            device.sizeBytes.map { ByteFormat.string($0) },
            device.isInternal.map { $0 ? t("Internal") : t("External") },
            device.protocolName,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? t("Unavailable") : parts.joined(separator: " / ")
    }

    private var hasErrors: Bool { device.readErrors > 0 || device.writeErrors > 0 }
    private var hasRetries: Bool { device.readRetries > 0 || device.writeRetries > 0 }

    private func direction(
        _ title: LocalizedStringKey, rate: Double, serviceTime: Double?, tint: Color
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title).foregroundStyle(tint).frame(height: 14)
            Text(rate.isFinite && rate >= 0 ? ByteFormat.rate(rate) : "--")
                .foregroundStyle(tint)
                .frame(height: 14)
            Text(Self.serviceTimeText(serviceTime))
                .foregroundStyle(.secondary)
                .frame(height: 14)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    static func serviceTimeText(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "--" }
        return String(format: "%.2f ms", milliseconds)
    }

    private func counterSummary(_ key: String, read: UInt64, write: UInt64) -> String {
        [
            t("%1$@: %2$@", t("Read"), t(key, String(read))),
            t("%1$@: %2$@", t("Write"), t(key, String(write))),
        ].joined(separator: "\n")
    }
}
