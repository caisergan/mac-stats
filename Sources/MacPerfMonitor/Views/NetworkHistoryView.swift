import Combine
import MacPerfMonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// The Network tab's History panel: long-term transferred amounts (not rates)
/// for the machine, per interface, per app, and (when connection tracking is
/// on) per remote host, over a selectable period. The data lives in the same
/// database as every other history metric; per-app amounts accrue only while
/// per-app tracking is on, connection rows only while that toggle is on.
struct NetworkHistoryPanel: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appMode: AppModeManager
    @EnvironmentObject private var appState: AppState
    @AppStorage(SamplerModel.perAppNetworkDefaultsKey) private var trackPerApp = true
    @AppStorage(SamplerModel.connectionHistoryDefaultsKey) private var trackConnections =
        false

    @State private var period: NetworkHistoryPeriod = .oneDay
    @State private var interfaceFilter: String?
    @State private var bundle = SamplerModel.NetworkHistoryBundle()
    @State private var interfaceSeries: [NetworkUsagePoint] = []
    /// Per-app series keyed by app id, for the per-app chart mode. Loaded with
    /// the bundle: six cheap aggregate queries, once per reload, not per frame.
    @State private var appSeries: [String: [NetworkUsagePoint]] = [:]
    @State private var chartMode: ChartMode = .total
    @State private var expandedApp: String?
    @State private var showClearConfirmation = false

    /// Lazily opened when the geo database is installed; nil otherwise, which
    /// is what hides the country column.
    @State private var geo: GeoLocator?

    /// The auto-refresh timer, recreated on appear. Matches the per-app
    /// sampling cadence (nettop produces a snapshot about every 5 s), so the
    /// panel tracks live traffic while it is on screen.
    static let refreshInterval: TimeInterval = 5
    @State private var refreshCancellable: AnyCancellable?

    private static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .yellow, .mint, .indigo, .teal,
    ]

    enum ChartMode: String, CaseIterable, Identifiable {
        case total, perApp
        var id: String { rawValue }
    }

    var body: some View {
        NetworkPanel("History", systemImage: "clock.arrow.circlepath") {
            controls
            chart
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 16) {
                appTable
                shareSidebar
                    .frame(width: 232)
            }
            if trackConnections {
                Divider().padding(.vertical, 4)
                connectionsTable
            }
        }
        .onAppear {
            if geo == nil { geo = GeoLocator(url: GeoLocator.defaultDatabaseURL()) }
            reload()
            startAutoRefresh()
        }
        .onDisappear { stopAutoRefresh() }
        .onChange(of: period) { _, _ in reload() }
        .onChange(of: trackPerApp) { _, _ in reload() }
        .onChange(of: trackConnections) { _, _ in reload() }
        .confirmationDialog(
            "Clear network history?", isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                model.clearNetworkHistoryData { reload(force: true) }
            }
        } message: {
            Text(
                "Deletes the recorded network byte totals, per-interface and connection history. Every other metric's history is kept."
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(NetworkHistoryPeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .historyRangeGate()

            Picker("Interface", selection: $interfaceFilter) {
                Text("All interfaces").tag(String?.none)
                ForEach(bundle.interfaces) { interface in
                    Text(interface.name).tag(Optional(interface.name))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .onChange(of: interfaceFilter) { _, _ in reload() }

            Spacer()

            Button {
                exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Picker("Show", selection: $chartMode) {
                    Text("Total").tag(ChartMode.total)
                    Text("Per-app").tag(ChartMode.perApp)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Text(totalsCaption)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            chartView
                .frame(height: 170)
        }
    }

    /// The scrubbed chart point (nil when the pointer is off the plot). The
    /// chart reports it via `scrubReporting`; the read-out card renders it.
    @State private var scrubPoint: TrendScrubPoint?

    @ViewBuilder private var chartView: some View {
        switch chartMode {
        case .total:
            scrubChart(
                series: [
                    TrendSeries(
                        points: totalPoints(.download), color: NetworkStyle.download,
                        filled: true),
                    TrendSeries(
                        points: totalPoints(.upload), color: NetworkStyle.upload,
                        lineWidth: 1.8),
                ],
                values: displayedSeries.flatMap { [$0.downloaded, $0.uploaded] },
                accessibility: "Network history"
            )
        case .perApp:
            if !trackPerApp {
                emptyHint(
                    "Per-app history accrues only while per-app tracking is on. Turn on Track per-app network usage in Settings."
                )
            } else if displayedApps.isEmpty {
                emptyHint("No app network history recorded for this period yet.")
            } else {
                scrubChart(
                    series: perAppTrendSeries,
                    values: perAppTrendSeries.flatMap { series in
                        series.points.map { $0.value }
                    },
                    accessibility: "Per-app network history"
                )
            }
        }
    }

    /// The history chart with scrubbing: the built-in TrendChart marker stays,
    /// its single-value read-out is replaced by this panel's read-out, which
    /// shows the bucket's time and usage (both directions, or each app's
    /// contribution in per-app mode).
    private func scrubChart(
        series: [TrendSeries], values: [Double], accessibility: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TrendChart(
                series: series,
                yDomain: yDomain(values),
                yFormat: { ByteFormat.string(UInt64(max(0, $0))) },
                showsTimeAxis: true,
                scrubbable: true,
                scrubReporting: { scrubPoint = $0 },
                scrubReadout: false,
                leftGutter: 56
            )
            .accessibilityLabel(accessibility)
            .accessibilityValue(totalsCaption)
            scrubReadout
        }
    }

    /// Floating read-out beside the scrub marker, mirroring TrendChart's own
    /// geometry so the card tracks the marker exactly.
    @ViewBuilder private var scrubReadout: some View {
        GeometryReader { geo in
            let plot = TrendChartGeometry(leftGutter: 56, showsTimeAxis: true).plotRect(
                in: geo.size)
            if let scrubPoint, chartHasData {
                let xx = plot.minX + scrubPoint.fraction * plot.width
                readoutCard(for: scrubPoint)
                    .fixedSize()
                    .allowsHitTesting(false)
                    .position(
                        x: min(max(xx, plot.minX + 90), plot.maxX - 90),
                        y: plot.minY + 18)
            }
        }
        .allowsHitTesting(false)
    }

    private var chartHasData: Bool {
        chartMode == .total ? !displayedSeries.isEmpty : !perAppTrendSeries.isEmpty
    }

    private func readoutCard(for point: TrendScrubPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(scrubTimeLabel(point.date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            switch chartMode {
            case .total:
                let bucket = nearestBucket(to: point.date, in: displayedSeries)
                HStack(spacing: 12) {
                    amount(bucket?.downloaded ?? 0, tint: NetworkStyle.download)
                    amount(bucket?.uploaded ?? 0, tint: NetworkStyle.upload)
                }
            case .perApp:
                let rows = scrubAppRows(at: point.date)
                if rows.isEmpty {
                    Text("No traffic at this time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.name) { row in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(row.color)
                                .frame(width: 6, height: 6)
                            Text(row.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 130, alignment: .leading)
                            Text(ByteFormat.string(row.downloaded))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(NetworkStyle.download.opacity(0.9))
                                .frame(width: 78, alignment: .trailing)
                            Text(ByteFormat.string(row.uploaded))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(NetworkStyle.upload.opacity(0.9))
                                .frame(width: 78, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }

    private struct ScrubAppRow {
        var name: String
        var color: Color
        var downloaded: UInt64
        var uploaded: UInt64
    }

    private func amount(_ bytes: Double, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: tint == NetworkStyle.download ? "arrow.down" : "arrow.up")
                .font(.caption2)
                .foregroundStyle(tint)
            Text(ByteFormat.string(UInt64(max(0, bytes))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    /// The nearest bucket at or before the scrubbed time, within the bucket
    /// width; nil when the pointer sits on an empty stretch of the plot.
    private func nearestBucket(
        to date: Date, in points: [NetworkUsagePoint]
    ) -> NetworkUsagePoint? {
        guard !points.isEmpty else { return nil }
        let target = date.timeIntervalSinceReferenceDate
        var best: NetworkUsagePoint?
        var bestDelta = Double.greatestFiniteMagnitude
        for point in points {
            let delta = abs(point.date.timeIntervalSinceReferenceDate - target)
            if delta < bestDelta {
                bestDelta = delta
                best = point
            }
        }
        guard let best, bestDelta < period.seriesBucketWidth / 2 else { return nil }
        return best
    }

    /// Each top app's usage at the scrubbed bucket, in the chart's color
    /// order, limited to apps with any traffic at that instant.
    private func scrubAppRows(at date: Date) -> [ScrubAppRow] {
        var rows: [ScrubAppRow] = []
        for (index, app) in displayedApps.prefix(6).enumerated() {
            guard let series = appSeries[app.id] else { continue }
            guard let bucket = nearestBucket(to: date, in: series) else { continue }
            let downloaded = UInt64(max(0, bucket.downloaded))
            let uploaded = UInt64(max(0, bucket.uploaded))
            guard downloaded > 0 || uploaded > 0 else { continue }
            rows.append(
                ScrubAppRow(
                    name: app.displayName,
                    color: Self.palette[index % Self.palette.count],
                    downloaded: downloaded, uploaded: uploaded))
        }
        return rows
    }

    /// Bucket start label for the period: time for intra-day buckets, a date
    /// for day-wide (or longer) buckets.
    private func scrubTimeLabel(_ date: Date) -> String {
        let style: Date.FormatStyle
        switch period {
        case .lastHour:
            style = .dateTime.hour().minute().second()
        case .oneDay:
            style = .dateTime.hour().minute()
        case .sevenDays:
            style = .dateTime.weekday(.abbreviated).hour().minute()
        case .thirtyDays:
            style = .dateTime.month(.abbreviated).day().hour().minute()
        case .all:
            style = .dateTime.month(.abbreviated).day()
        }
        return date.formatted(style)
    }

    private var displayedSeries: [NetworkUsagePoint] {
        interfaceFilter == nil ? bundle.series : interfaceSeries
    }

    private var displayedApps: [NetworkAppUsage] {
        guard trackPerApp else { return [] }
        return bundle.apps
    }

    /// The per-app chart: the top apps, each its own colored line of amounts.
    private var perAppTrendSeries: [TrendSeries] {
        displayedApps.prefix(6).enumerated().map { index, app in
            TrendSeries(
                points: (appSeries[app.id] ?? []).map {
                    TrendPoint(date: $0.date, value: $0.downloaded)
                },
                color: Self.palette[index % Self.palette.count], lineWidth: 1.8)
        }
    }

    private func totalPoints(_ side: ChartSide) -> [TrendPoint] {
        displayedSeries.map {
            TrendPoint(
                date: $0.date,
                value: side == .download ? $0.downloaded : $0.uploaded)
        }
    }

    private func yDomain(_ values: [Double]) -> ClosedRange<Double>? {
        let peak = max(values.max() ?? 0, 1)
        return 0...MenuChart.niceUpperBound(peak * 1.1)
    }

    private var totalsCaption: String {
        String(
            format: t("%1$@ down · %2$@ up"),
            ByteFormat.string(bundle.totals.downloaded),
            ByteFormat.string(bundle.totals.uploaded))
    }

    // MARK: - Per-app table

    @ViewBuilder private var appTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !trackPerApp {
                emptyHint(
                    "Per-app usage is off, so only the totals accrue. Enable Track per-app network usage in Settings."
                )
            } else if displayedApps.isEmpty {
                emptyHint("No app network history recorded for this period yet.")
            } else {
                ForEach(Array(displayedApps.enumerated()), id: \.element.id) { index, app in
                    AppUsageRow(
                        app: app,
                        downloadedShare: share(of: app, side: .download),
                        uploadedShare: share(of: app, side: .upload),
                        color: Self.palette[index % Self.palette.count],
                        isExpanded: expandedApp == app.id,
                        onToggle: { toggleExpand(app) })
                    if index < displayedApps.count - 1 { Divider() }
                }
            }
        }
    }

    private enum ChartSide { case download, upload }

    /// Shares are fractions of the COMBINED transferred total, so a row's
    /// download + upload shares sum to its overall share of traffic and the
    /// sidebar's percentage never exceeds 100%.
    private func share(of app: NetworkAppUsage, side: ChartSide) -> Double {
        let combined = bundle.totals.downloaded + bundle.totals.uploaded
        guard combined > 0 else { return 0 }
        let bytes = side == .download ? app.downloaded : app.uploaded
        return Double(bytes) / Double(combined)
    }

    private func toggleExpand(_ app: NetworkAppUsage) {
        if expandedApp == app.id {
            expandedApp = nil
        } else {
            expandedApp = app.id
            if appSeries[app.id] == nil {
                loadAppSeries(app)
            }
        }
    }

    private func loadAppSeries(_ app: NetworkAppUsage) {
        model.loadNetworkAppUsageSeries(
            executablePath: app.executablePath, bundleID: app.bundleID, period
        ) { points in
            appSeries[app.id] = points
        }
    }

    // MARK: - Share sidebar

    @ViewBuilder private var shareSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").foregroundStyle(NetworkStyle.download)
                Text("Download").font(.caption)
                Spacer()
                Text(ByteFormat.string(bundle.totals.downloaded))
                    .font(.callout.monospacedDigit())
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").foregroundStyle(NetworkStyle.upload)
                Text("Upload").font(.caption)
                Spacer()
                Text(ByteFormat.string(bundle.totals.uploaded))
                    .font(.callout.monospacedDigit())
            }
            Divider()
            let top = displayedApps.prefix(8)
            if top.isEmpty {
                Text("No per-app breakdown yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, app in
                    ShareRow(
                        app: app,
                        downloadedShare: share(of: app, side: .download),
                        uploadedShare: share(of: app, side: .upload),
                        color: Self.palette[index % Self.palette.count])
                }
                let topTotal = top.reduce(UInt64(0)) { $0 + $1.totalBytes }
                if bundle.totals.downloaded + bundle.totals.uploaded > topTotal {
                    ShareRow(
                        name: t("Other"), icon: nil,
                        downloaded: remainder(.download, topTotal),
                        uploaded: remainder(.upload, topTotal),
                        downloadedShare: remainderShare(.download, topTotal),
                        uploadedShare: remainderShare(.upload, topTotal),
                        color: .gray)
                }
            }
        }
    }

    private func remainder(_ side: ChartSide, _ topTotal: UInt64) -> UInt64 {
        let all = side == .download ? bundle.totals.downloaded : bundle.totals.uploaded
        let top =
            displayedApps.prefix(8).reduce(UInt64(0)) {
                $0 + (side == .download ? $1.downloaded : $1.uploaded)
            }
        return all > top ? all - top : 0
    }

    private func remainderShare(_ side: ChartSide, _ topTotal: UInt64) -> Double {
        let combined = bundle.totals.downloaded + bundle.totals.uploaded
        guard combined > 0 else { return 0 }
        return Double(remainder(side, topTotal)) / Double(combined)
    }

    // MARK: - Connections

    @ViewBuilder private var connectionsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connection history")
                .font(.subheadline.weight(.semibold))
            if !trackConnections {
                emptyHint(
                    "Turn on Record connection history in Settings to see which remote hosts each app talks to."
                )
            } else if bundle.connections.isEmpty {
                emptyHint("No connections recorded for this period yet.")
            } else {
                ForEach(bundle.connections) { connection in
                    ConnectionRow(connection: connection, geo: geo)
                }
            }
        }
    }

    // MARK: - Actions

    private func reload(force: Bool = false) {
        model.loadNetworkHistory(period, forceReload: force) { fresh in
            bundle = fresh
            // Refresh the top apps' series with every reload so the per-app
            // chart and the scrub read-out track live traffic; the queries are
            // small aggregate reads.
            for app in fresh.apps.prefix(6) {
                loadAppSeries(app)
            }
        }
        if let name = interfaceFilter {
            model.loadInterfaceUsageSeries(name, period) { points in
                interfaceSeries = points
            }
        } else {
            interfaceSeries = []
        }
    }

    /// Refresh the whole panel every `refreshInterval` seconds while the main
    /// window is visible. The panel disappears with the tab or window, which
    /// stops the timer; the visibility gate additionally covers a tab that the
    /// app keeps alive underneath another one.
    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshCancellable =
            Timer.publish(every: Self.refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                guard appState.mainWindowVisible else { return }
                reload()
            }
    }

    private func stopAutoRefresh() {
        refreshCancellable?.cancel()
        refreshCancellable = nil
    }

    private func exportCSV() {
        let csv = NetworkHistoryCSV.text(
            period: period, totals: bundle.totals, series: displayedSeries,
            apps: displayedApps, interfaces: bundle.interfaces,
            connections: bundle.connections)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "network-history-\(period.rawValue).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Rows

private struct AppUsageRow: View {
    let app: NetworkAppUsage
    let downloadedShare: Double
    let uploadedShare: Double
    let color: Color
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Image(nsImage: ProcessIconProvider.shared.icon(forPath: app.executablePath))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName).lineLimit(1).truncationMode(.middle)
                    Text(app.executablePath ?? app.bundleID ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                amount(app.downloaded, tint: NetworkStyle.download)
                amount(app.uploaded, tint: NetworkStyle.upload)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if isExpanded {
                AppDetail(app: app)
                    .padding(.bottom, 8)
            }
        }
    }

    private func amount(_ bytes: UInt64, tint: Color) -> some View {
        Text(ByteFormat.string(bytes))
            .font(.callout.monospacedDigit())
            .foregroundStyle(tint.opacity(0.9))
            .frame(width: 84, alignment: .trailing)
    }
}

/// The expanded per-app detail: the app's transferred-amount timeline over a
/// locally selected period (defaulting to 24 h, finer than the panel's own).
private struct AppDetail: View {
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appMode: AppModeManager
    @EnvironmentObject private var appState: AppState
    let app: NetworkAppUsage
    @State private var series: [NetworkUsagePoint] = []
    @State private var selectedPeriod: NetworkHistoryPeriod = .oneDay

    private enum Side { case download, upload }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Period", selection: $selectedPeriod) {
                ForEach(NetworkHistoryPeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .historyRangeGate()
            TrendChart(
                series: [
                    TrendSeries(
                        points: points(.download), color: NetworkStyle.download, filled: true),
                    TrendSeries(
                        points: points(.upload), color: NetworkStyle.upload, lineWidth: 1.8),
                ],
                yFormat: { ByteFormat.string(UInt64(max(0, $0))) },
                showsTimeAxis: true,
                leftGutter: 56
            )
            .frame(height: 90)
        }
        .padding(.leading, 34)
        .onAppear { load() }
        .onChange(of: selectedPeriod) { _, _ in load() }
        .onReceive(
            Timer.publish(every: NetworkHistoryPanel.refreshInterval, on: .main, in: .common)
                .autoconnect()
        ) { _ in
            guard appState.mainWindowVisible else { return }
            load()
        }
    }

    private func load() {
        model.loadNetworkAppUsageSeries(
            executablePath: app.executablePath, bundleID: app.bundleID, selectedPeriod
        ) { points in
            series = points
        }
    }

    private func points(_ side: Side) -> [TrendPoint] {
        series.map {
            TrendPoint(
                date: $0.date,
                value: side == .download ? $0.downloaded : $0.uploaded)
        }
    }
}

private struct ShareRow: View {
    let name: String
    let icon: NSImage?
    let downloaded: UInt64
    let uploaded: UInt64
    let downloadedShare: Double
    let uploadedShare: Double
    let color: Color

    init(app: NetworkAppUsage, downloadedShare: Double, uploadedShare: Double, color: Color) {
        self.name = app.displayName
        self.icon = ProcessIconProvider.shared.icon(forPath: app.executablePath)
        self.downloaded = app.downloaded
        self.uploaded = app.uploaded
        self.downloadedShare = downloadedShare
        self.uploadedShare = uploadedShare
        self.color = color
    }

    init(
        name: String, icon: NSImage?, downloaded: UInt64, uploaded: UInt64,
        downloadedShare: Double, uploadedShare: Double, color: Color
    ) {
        self.name = name
        self.icon = icon
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.downloadedShare = downloadedShare
        self.uploadedShare = uploadedShare
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Int((combinedShare * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    Capsule()
                        .fill(NetworkStyle.download)
                        .frame(width: max(2, proxy.size.width * normalizedShare(downloadedShare)))
                    Capsule()
                        .fill(NetworkStyle.upload)
                        .frame(width: max(0, proxy.size.width * normalizedShare(uploadedShare)))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 4)
            Text("\(ByteFormat.string(downloaded)) ↓ · \(ByteFormat.string(uploaded)) ↑")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The row's overall share of traffic, capped at 100%: per-app sums can
    /// exceed the system totals (nettop counts interfaces the system reader
    /// excludes, such as tunnels), and the percentage must never read past
    /// 100% or the bar overflow the row.
    private var combinedShare: Double { min(1, downloadedShare + uploadedShare) }

    /// Each segment as a fraction of the row width, so the two segments always
    /// fit side by side no matter how the raw shares add up.
    private func normalizedShare(_ share: Double) -> CGFloat {
        guard combinedShare > 0 else { return 0 }
        return CGFloat(min(1, share / combinedShare))
    }
}

private struct ConnectionRow: View {
    let connection: ConnectionUsage
    let geo: GeoLocator?
    @State private var hostname: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(flagText)
                .font(.callout)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(hostname ?? connection.remoteIP)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(connection.appName) · \(transferSpan)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(connection.downloaded))
                .font(.callout.monospacedDigit())
                .foregroundStyle(NetworkStyle.download.opacity(0.9))
                .frame(width: 84, alignment: .trailing)
            Text(ByteFormat.string(connection.uploaded))
                .font(.callout.monospacedDigit())
                .foregroundStyle(NetworkStyle.upload.opacity(0.9))
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .task(id: connection.remoteIP) {
            ReverseDNSResolver.shared.resolve(connection.remoteIP) { resolved in
                DispatchQueue.main.async { hostname = resolved }
            }
        }
    }

    private var transferSpan: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return String(
            format: t("first %@ · last %@"),
            formatter.string(from: connection.firstTransfer),
            formatter.string(from: connection.lastTransfer))
    }

    /// Country flag from the geo database when installed; a globe otherwise.
    private var flagText: String {
        guard let geo, let info = geo.lookup(connection.remoteIP),
            let code = info.countryCode, code.count == 2
        else { return "🌐" }
        let scalars = code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127_397 + $0.value)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct NetworkHistoryCSV {
    static func text(
        period: NetworkHistoryPeriod, totals: NetworkHistoryTotals,
        series: [NetworkUsagePoint], apps: [NetworkAppUsage],
        interfaces: [InterfaceUsage], connections: [ConnectionUsage]
    ) -> String {
        var lines: [String] = []
        lines.append("network history,\(period.rawValue)")
        lines.append("totals,down,up")
        lines.append(",\(totals.downloaded),\(totals.uploaded)")
        lines.append("")
        lines.append("per-app,executable,bundle,down bytes,up bytes")
        for app in apps {
            lines.append(
                "\(csv(app.displayName)),\(csv(app.executablePath ?? "")),\(csv(app.bundleID ?? "")),\(app.downloaded),\(app.uploaded)"
            )
        }
        lines.append("")
        lines.append("series,bucket start,down bytes,up bytes")
        let formatter = ISO8601DateFormatter()
        for point in series {
            lines.append(
                ",\(formatter.string(from: point.date)),\(Int(point.downloaded)),\(Int(point.uploaded))"
            )
        }
        lines.append("")
        lines.append("interfaces,name,down bytes,up bytes")
        for interface in interfaces {
            lines.append(",\(interface.name),\(interface.downloaded),\(interface.uploaded)")
        }
        if !connections.isEmpty {
            lines.append("")
            lines.append("connections,ip,app,down bytes,up bytes,first transfer,last transfer")
            for connection in connections {
                lines.append(
                    ",\(connection.remoteIP),\(csv(connection.appName)),\(connection.downloaded),\(connection.uploaded),\(formatter.string(from: connection.firstTransfer)),\(formatter.string(from: connection.lastTransfer))"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csv(_ value: String) -> String {
        value.contains(",") || value.contains("\"")
            ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" : value
    }
}

private func emptyHint(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
}
