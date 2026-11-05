import AppKit
import MacPerfMonitorCore
import SwiftUI

struct ANEMenuHistory {
    static let duration: TimeInterval = MenuChartRange.oneMinute.seconds

    let domain: ClosedRange<Date>
    let time: [TrendPoint]
    let power: [TrendPoint]
    let hasPartialTime: Bool
    /// The bucket width on the overview ranges, nil for raw samples. Sets how
    /// far apart two points may sit before the line breaks into a gap.
    private var bucket: TimeInterval?

    init(samples: some Sequence<SystemSample>, now: Date) {
        let domain = now.addingTimeInterval(-Self.duration)...now
        self.domain = domain
        let recent = samples.filter { domain.contains($0.timestamp) }
        time = recent.map { sample in
            let value = sample.aneTimeMillisecondsPerSecond
            return TrendPoint(
                date: sample.timestamp,
                value: value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? .nan)
        }
        power = recent.map {
            TrendPoint(date: $0.timestamp, value: $0.reportedANEPowerWatts ?? .nan)
        }
        hasPartialTime = recent.contains {
            guard let value = $0.aneTimeMillisecondsPerSecond, value.isFinite, value >= 0 else {
                return false
            }
            return $0.aneSampleIsPartial != false
        }
    }

    /// The overview ranges: bucket means over `range`. Coverage is a fact about
    /// the readings arriving now, so it comes from the raw window either way.
    init(
        time: MenuTrendSeries, power: MenuTrendSeries, range: MenuChartRange, now: Date,
        hasPartialTime: Bool
    ) {
        domain = now.addingTimeInterval(-range.seconds)...now
        func points(_ series: MenuTrendSeries) -> [TrendPoint] {
            zip(series.dates, series.values).map { TrendPoint(date: $0, value: $1) }
        }
        self.time = points(time)
        self.power = points(power)
        self.hasPartialTime = hasPartialTime
        bucket = range.bucketSeconds
    }

    var timeChart: TrendModel {
        chart(
            points: time, name: t("ANE time"), unit: .millisecondsPerSecond,
            color: MenuPanelStyle.accent(.gpu),
            minimumTop: 1000)
    }

    var powerChart: TrendModel {
        chart(
            points: power, name: t("ANE power"), unit: .watts, color: MenuPanelStyle.accent(.gpu),
            minimumTop: 1)
    }

    private func chart(
        points: [TrendPoint], name: String, unit: MetricUnit, color: Color, minimumTop: Double
    ) -> TrendModel {
        let peak = points.map(\.value).filter(\.isFinite).max() ?? 0
        let top = MenuChart.niceUpperBound(max(minimumTop, peak * 1.1))
        var model = TrendModel()
        model.series = [
            TrendSurfaceSeries(
                column: LiveColumn(
                    times: points.map { $0.date.timeIntervalSinceReferenceDate }[...],
                    values: points.map(\.value)[...]),
                color: color, lineWidth: MenuChart.lineWidth, name: name)
        ]
        model.xDomain = domain
        model.yDomain = 0...top
        model.yTicks = [0, top / 2, top]
        model.yFormat = unit.format
        model.detailFormat = unit.format
        model.leftGutter = 58
        model.statisticsInterval = bucket ?? 1
        model.gapThreshold = (bucket ?? 1) * 3
        model.accessibilityLabel = name
        return model
    }
}

struct ANEMenuCharts: View {
    let history: ANEMenuHistory
    let gpu: GPUSample

    var body: some View {
        // Side by side: the two share an engine and a time axis, and a stack
        // would make this the tallest card on the tab.
        HStack(alignment: .top, spacing: 14) {
            metric(
                "ANE time", value: ANEActivityPresentation.value(gpu) ?? t("Unavailable"),
                status: history.hasPartialTime
                    ? t("Partial coverage") : ANEActivityPresentation.status(gpu),
                chart: history.timeChart
            )
            .help(
                "Accounted ANE time per second, not percent of compute capacity. Partial readings are lower bounds. Missing readings are gaps."
            )
            metric(
                "ANE power", value: ANEPowerPresentation.value(gpu) ?? t("Unavailable"),
                status: ANEPowerPresentation.status(gpu), chart: history.powerChart
            )
            .help("ANE power requires elevated coverage. ANE Time works without it.")
        }
    }

    private func metric(
        _ title: LocalizedStringKey, value: String, status: String, chart: TrendModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 2)
                Text(value)
                    .font(MenuPanelStyle.valueFont(size: 11))
                    .multilineTextAlignment(.trailing)
            }
            .frame(height: 16)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            TrendSnapshotChart(model: chart)
                .frame(height: 44)
                .overlay {
                    if !chart.series.contains(where: {
                        $0.column.values.contains(where: \.isFinite)
                    }) {
                        Text("Unavailable").font(.caption2).foregroundStyle(.secondary)
                            .padding(.leading, chart.leftGutter)
                    }
                }
            Text(status)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The GPU tab of the menu bar panel: utilization with its verdict and trend,
/// device / renderer / tiler activity, the Neural Engine, power and memory, and
/// the top consumers with the AI runtime named where there is one. Apple-silicon
/// only. Re-renders at the dial rate while open via the shared `MenuClock`; the
/// process list rides the popover scan cadence its status item registers for.
struct GPUMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock

    var body: some View {
        _ = menuClock.tick
        return VStack(alignment: .leading, spacing: MenuPanelStyle.spacing) {
            if let gpu = model.latestGPU {
                summaryCard(gpu)
                MenuPanelCard {
                    MenuPanelHeading(title: "Activity")
                        .padding(.bottom, 7)
                    bars(gpu)
                }
                MenuPanelCard {
                    MenuPanelHeading(title: "Neural Engine")
                        .padding(.bottom, 7)
                    ANEMenuCharts(history: aneHistory, gpu: gpu)
                }
                MenuPanelCard { MenuDetailGrid(rows: details(gpu)) }
                MenuRankedList(
                    title: "Top GPU", metric: metric, apps: menuLists.topGPUApps,
                    processes: Array(menuLists.topGPU),
                    emptyText: menuLists.gpuListScanned
                        ? t("Nothing is using the GPU") : t("Sampling\u{2026}"))
            } else {
                MenuPanelCard {
                    Text("Reading GPU\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Summary

    private func summaryCard(_ gpu: GPUSample) -> some View {
        let level = CPULevel(fraction: gpu.utilization / 100)
        return MenuPanelCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MenuPanelFigure(text: "\(Int(gpu.utilization.rounded()))%")
                MenuStatusPill(text: level.label, color: level.color)
                Spacer(minLength: 4)
                Text(deviceName(gpu))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            MenuChartHeader(title: "GPU")
            MenuTrendChart(
                series: model.menuTrend(.gpuUtilization, range: chartRange),
                color: level == .light ? MenuPanelStyle.accent(.gpu) : level.color,
                domain: 0...100, ticks: [0, 50, 100], label: { "\(Int($0))" },
                readoutName: t("GPU"), readoutValue: { "\(Int($0.rounded()))%" }
            )
            .frame(height: MenuChart.height)
        }
    }

    private func deviceName(_ gpu: GPUSample) -> String {
        let name = gpu.name ?? t("Graphics")
        guard let cores = gpu.coreCount else { return name }
        return "\(name) · \(t("%@-core", String(cores)))"
    }

    private var aneHistory: ANEMenuHistory {
        let now = Date()
        let raw = ANEMenuHistory(samples: model.systemHistory.elements(), now: now)
        guard chartRange.bucketSeconds != nil else { return raw }
        return ANEMenuHistory(
            time: model.menuTrend(.aneTime, range: chartRange),
            power: model.menuTrend(.anePower, range: chartRange), range: chartRange, now: now,
            hasPartialTime: raw.hasPartialTime)
    }

    // MARK: - Activity bars

    private func bars(_ gpu: GPUSample) -> some View {
        VStack(spacing: 7) {
            bar("Device", gpu.utilization)
            if let render = gpu.renderUtilization { bar("Renderer", render) }
            if let tiler = gpu.tilerUtilization { bar("Tiler", tiler) }
        }
    }

    private func bar(_ label: LocalizedStringKey, _ percent: Double) -> some View {
        let color =
            CPULevel(fraction: percent / 100) == .light
            ? MenuPanelStyle.accent(.gpu) : CPULevel(fraction: percent / 100).color
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)
            MenuMeter(parts: [(fraction: percent / 100, color: color)], height: 5)
            Text(verbatim: "\(Int(percent.rounded()))%")
                .font(MenuPanelStyle.valueFont(size: 11.5))
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Details

    private func details(_ gpu: GPUSample) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let watts = gpu.gpuPowerWatts {
            rows.append((t("GPU power"), String(format: "%.2f W", watts)))
        }
        if let watts = gpu.cpuPowerWatts {
            rows.append((t("CPU power"), String(format: "%.2f W", watts)))
        }
        if let temp = gpu.dieTemperatureC {
            rows.append((t("Die temperature"), TemperatureFormat.string(temp)))
        }
        if let rpm = gpu.fanRPM {
            rows.append((t("Fan"), rpm == 0 ? t("Off") : t("%@ rpm", String(rpm))))
        }
        if gpu.inUseMemoryBytes != nil || gpu.allocatedMemoryBytes != nil {
            rows.append((t("Memory"), memoryString(gpu)))
        }
        return rows
    }

    private func memoryString(_ gpu: GPUSample) -> String {
        func fmt(_ b: UInt64?) -> String? {
            guard let b else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
        }
        let inUse = fmt(gpu.inUseMemoryBytes)
        let alloc = fmt(gpu.allocatedMemoryBytes)
        switch (inUse, alloc) {
        case (.some(let u), .some(let a)): return "\(u) / \(a)"
        case (.some(let u), nil): return u
        case (nil, .some(let a)): return a
        default: return "—"
        }
    }

    // MARK: - Top consumers

    private var metric: MenuRankedMetric {
        MenuRankedMetric(
            parts: { [$0.gpuPercentValue] }, colors: [MenuPanelStyle.accent(.gpu)],
            format: CPUFormat.percent, trail: { [model] in model.gpuTrail(for: $0) },
            badge: { [model] in model.gpuWorkload(for: $0.id)?.runtime })
    }
}
