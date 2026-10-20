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
            points: time, name: t("ANE time"), unit: .millisecondsPerSecond, color: .purple,
            minimumTop: 1000)
    }

    var powerChart: TrendModel {
        chart(points: power, name: t("ANE power"), unit: .watts, color: .pink, minimumTop: 1)
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
        model.leftGutter = 68
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
        VStack(alignment: .leading, spacing: 10) {
            metric(
                "ANE time", value: ANEActivityPresentation.value(gpu) ?? t("Unavailable"),
                status: history.hasPartialTime
                    ? t("Partial coverage") : ANEActivityPresentation.status(gpu),
                chart: history.timeChart, color: .purple
            )
            .help(
                "Accounted ANE time per second, not percent of compute capacity. Partial readings are lower bounds. Missing readings are gaps."
            )
            metric(
                "ANE power", value: ANEPowerPresentation.value(gpu) ?? t("Unavailable"),
                status: ANEPowerPresentation.status(gpu), chart: history.powerChart, color: .pink
            )
            .help("ANE power requires elevated coverage. ANE Time works without it.")
        }
    }

    private func metric(
        _ title: LocalizedStringKey, value: String, status: String, chart: TrendModel, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(color)
                Spacer(minLength: 8)
                Text(value).monospacedDigit().multilineTextAlignment(.trailing)
            }
            .font(.caption)
            .frame(height: 17)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            TrendSnapshotChart(model: chart)
                .frame(height: 62)
                .overlay {
                    if !chart.series.contains(where: {
                        $0.column.values.contains(where: \.isFinite)
                    }) {
                        Text("Unavailable").font(.caption2).foregroundStyle(.secondary)
                            .padding(.leading, chart.leftGutter)
                    }
                }
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 14)
        }
    }
}

/// The GPU menubar dropdown. Headline utilization and a usage-history sparkline,
/// device / renderer / tiler / Neural-Engine activity bars, a details block
/// with GPU + ANE + CPU power (IOReport), in-use / allocated memory, die
/// temperature and fan (SMC), and the top GPU processes with the AI runtime
/// named where there is one. Apple-silicon only. Re-renders at the dial rate
/// while open via the shared `MenuClock`; the process list rides the popover
/// scan cadence its status item registers for.
struct GPUMenuBarContentView: View {
    @EnvironmentObject private var model: SamplerModel
    /// The panel charts' time range, shared by every tab (see `MenuChartRange`).
    @AppStorage(MenuChartRange.defaultsKey) private var chartRange = MenuChartRange.default
    @EnvironmentObject private var menuLists: MenuListsModel
    @EnvironmentObject private var menuClock: MenuClock

    /// Called after an action so the host (the AppKit popover) can dismiss.
    var dismiss: () -> Void = {}
    var embedded = false

    var body: some View {
        _ = menuClock.tick
        return
            panel
            .onAppear { if !embedded { menuClock.open() } }
            .onDisappear { if !embedded { menuClock.close() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let gpu = model.latestGPU {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        header(gpu)
                        sparkline
                        Divider()
                        bars(gpu)
                        Divider()
                        ANEMenuCharts(history: aneHistory, gpu: gpu)
                        Divider()
                        details(gpu)
                        Divider()
                        topProcesses
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    height: Self.contentHeight(
                        screenHeight: NSScreen.main?.visibleFrame.height ?? 900, embedded: embedded)
                )
            } else {
                Text("Reading GPU\u{2026}")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            }
            if !embedded { MenuVersionFooter() }
        }
        .padding(embedded ? 0 : 12)
        .frame(width: embedded ? nil : 300)
    }

    static func contentHeight(screenHeight: CGFloat, embedded: Bool) -> CGFloat {
        min(600, max(200, screenHeight - (embedded ? 210 : 70)))
    }

    // MARK: - Header + sparkline

    private func header(_ gpu: GPUSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GPU").font(.caption).foregroundStyle(.secondary)
                Text(gpu.name ?? t("Graphics")).font(.headline).lineLimit(1)
                if let cores = gpu.coreCount {
                    Text(t("%@-core", String(cores))).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(Int(gpu.utilization.rounded()))%")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(CPULevel(fraction: gpu.utilization / 100).color)
                .monospacedDigit()
        }
    }

    private var sparkline: some View {
        MenuSparklineChart(
            series: model.menuTrend(.gpuUtilization, range: chartRange), color: .accentColor,
            domain: 0...100, name: t("GPU"), format: { "\(Int($0.rounded()))%" })
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
        VStack(spacing: 8) {
            bar("Device", gpu.utilization)
            if let render = gpu.renderUtilization { bar("Renderer", render) }
            if let tiler = gpu.tilerUtilization { bar("Tiler", tiler) }
        }
    }

    private func bar(
        _ label: LocalizedStringKey, _ percent: Double, trailing: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
                Text("\(Int(percent.rounded()))%").font(.caption.monospacedDigit())
            }
            ProgressView(value: min(max(percent / 100, 0), 1))
                .tint(CPULevel(fraction: percent / 100).color)
        }
    }

    // MARK: - Details

    private func details(_ gpu: GPUSample) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            if let watts = gpu.gpuPowerWatts {
                detail("GPU power", wattsString(watts) ?? "—")
            }
            if let watts = gpu.cpuPowerWatts {
                detail("CPU power", wattsString(watts) ?? "—")
            }
            if gpu.inUseMemoryBytes != nil || gpu.allocatedMemoryBytes != nil {
                detail("Memory", memoryString(gpu))
            }
            if let temp = gpu.dieTemperatureC {
                detail("Die temperature", TemperatureFormat.string(temp))
            }
            if let rpm = gpu.fanRPM {
                detail("Fan", rpm == 0 ? "Off" : "\(rpm) rpm")
            }
        }
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value).font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Top processes

    private var topProcesses: some View {
        let top = Array(menuLists.topGPU.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Top GPU")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if top.isEmpty {
                Text(
                    menuLists.gpuListScanned ? t("Nothing is using the GPU") : t("Sampling\u{2026}")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
                ForEach(top) { process in
                    GPUMenuProcessRow(
                        process: process,
                        workload: model.gpuWorkload(for: process.id))
                }
            }
        }
    }

    private func wattsString(_ watts: Double?) -> String? {
        guard let watts else { return nil }
        return String(format: "%.2f W", watts)
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
}

/// One row of the GPU dropdown's top list: icon, name, the AI runtime when the
/// process is one (the reason to watch the GPU at all), and its share of the
/// device over the last scan interval.
struct GPUMenuProcessRow: View {
    let process: ProcessSample
    let workload: GPUWorkloadInfo?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
            HStack(spacing: 5) {
                Text(process.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let runtime = workload?.runtime {
                    Text(runtime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(CPUFormat.percent(process.gpuPercentValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            ProcessRowMenuButton(identity: process.id, bringWindowForward: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens this process in the main window")
        .processRowActions(identity: process.id, bringWindowForward: true, openOnSingleTap: true)
    }

    private var accessibilityLabel: String {
        let base = "\(process.displayName), \(CPUFormat.percent(process.gpuPercentValue)) GPU"
        guard let runtime = workload?.runtime else { return base }
        return "\(base), \(runtime)"
    }
}
