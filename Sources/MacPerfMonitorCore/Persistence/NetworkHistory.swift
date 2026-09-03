import Foundation
import GRDB

/// A selectable period for the Network page's history panel. Deliberately
/// separate from `HistoryWindow`: the app-wide window enum is iterated by every
/// page's range picker, and the network periods intentionally exceed it (30 d,
/// all retained history). Each period reads the finest storage tier whose
/// retention still covers it, exactly like the `HistoryWindow` queries do.
public enum NetworkHistoryPeriod: String, Sendable, CaseIterable, Identifiable {
    /// The raw tier's whole window (2 h by default).
    case lastHour
    case oneDay
    case sevenDays
    case thirtyDays
    /// Everything retained: the hour tier's full window (90 d by default).
    case all

    public var id: String { rawValue }

    /// Span of the period in seconds; nil means "as far back as the data goes".
    public var seconds: TimeInterval? {
        switch self {
        case .lastHour: return 3600
        case .oneDay: return 86_400
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .all: return nil
        }
    }

    public enum Granularity: Sendable, Equatable { case raw, minute, hour }

    /// Which stored tier backs this period. The raw tier only holds the raw
    /// retention window; the minute tier a week; everything longer reads the
    /// hour aggregates.
    public var granularity: Granularity {
        switch self {
        case .lastHour: return .raw
        case .oneDay, .sevenDays: return .minute
        case .thirtyDays, .all: return .hour
        }
    }

    public var label: String {
        switch self {
        case .lastHour: return t("Hour")
        case .oneDay: return t("24 h")
        case .sevenDays: return t("7 d")
        case .thirtyDays: return t("30 d")
        case .all: return t("All")
        }
    }

    /// Chart bucket width for the period, in seconds: the tier's own bucket
    /// where that is already coarse enough, otherwise a width that keeps the
    /// series around a few hundred points.
    public var seriesBucketWidth: TimeInterval {
        switch self {
        case .lastHour: return 60
        case .oneDay: return 300
        case .sevenDays: return 3600
        case .thirtyDays: return 6 * 3600
        case .all: return 86_400
        }
    }
}

/// Transferred amounts (not rates) over a period, in bytes.
public struct NetworkHistoryTotals: Sendable, Equatable {
    public var downloaded: UInt64
    public var uploaded: UInt64

    public init(downloaded: UInt64, uploaded: UInt64) {
        self.downloaded = downloaded
        self.uploaded = uploaded
    }
}

/// One bucket of the transferred-amount series, dated to the bucket start.
public struct NetworkUsagePoint: Sendable, Identifiable, Equatable {
    public var date: Date
    public var downloaded: Double
    public var uploaded: Double

    public var id: Date { date }

    public init(date: Date, downloaded: Double, uploaded: Double) {
        self.date = date
        self.downloaded = downloaded
        self.uploaded = uploaded
    }
}

/// One app's transferred amounts over a period, aggregated across every
/// launch of the executable (grouped by executable path, the same stable
/// identity the group history queries group by).
public struct NetworkAppUsage: Sendable, Identifiable, Equatable {
    public var executablePath: String?
    public var bundleID: String?
    public var name: String
    public var downloaded: UInt64
    public var uploaded: UInt64

    public var id: String { executablePath ?? name }

    /// The display name resolved exactly as the live process list resolves it,
    /// so a truncated kernel `p_comm` never leaks into the table.
    public var displayName: String {
        ProcessSample.resolvedDisplayName(name: name, executablePath: executablePath)
    }

    public var totalBytes: UInt64 { downloaded + uploaded }
}

extension SampleStore {
    /// The storage ranges each tier owns for one period. Disjoint and, taken
    /// together, covering `[since, now)`: the period's own tier owns everything
    /// its rollup has finalised, each finer tier owns the range above the
    /// coarser tier's watermark, and the raw tier owns the tail no rollup has
    /// reached yet.
    ///
    /// Every network history read walks these, so the chart, the per-app table
    /// and the totals read-out always describe the same range. Reading a single
    /// tier instead (what the first cut did) left the freshest slice out of the
    /// chart and the table but not the totals: on the 30 d and All periods the
    /// hour tier finalises only completed hours, so a fresh database showed a
    /// real "X down, Y up" beside an empty chart and an empty app list for the
    /// first hour, and thereafter a right edge up to an hour behind.
    ///
    /// A tier coarser than the period's own granularity is never used, so an
    /// hour aggregate can never collapse onto a one-minute chart bucket.
    struct TierSpans {
        var hour: (since: Double, until: Double)?
        var minute: (since: Double, until: Double)?
        var raw: (since: Double, until: Double)?
    }

    static func tierSpans(
        _ db: Database, period: NetworkHistoryPeriod, since: Double, now: Double
    ) throws -> TierSpans {
        let minuteWatermark = try watermarkValue(db, "minute_watermark")
        let hourWatermark = try watermarkValue(db, "hour_watermark")
        var spans = TierSpans()
        var covered = since
        if period.granularity == .hour, covered < hourWatermark {
            spans.hour = (since, hourWatermark)
            covered = hourWatermark
        }
        if period.granularity != .raw, covered < minuteWatermark {
            spans.minute = (covered, minuteWatermark)
            covered = minuteWatermark
        }
        if covered < now { spans.raw = (covered, now) }
        return spans
    }

    /// Transferred amounts over the period, summed across the tier spans, so a
    /// period that straddles a rollup boundary neither double-counts a bucket
    /// nor drops the not-yet-rolled tail.
    public func networkBytesTransferred(
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> NetworkHistoryTotals {
        let requested =
            (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        return try databasePool.read { db in
            let since = max(requested, try Self.clearedAt(db))
            let spans = try Self.tierSpans(
                db, period: period, since: since, now: now.timeIntervalSince1970)
            let bucket = try Self.minuteBucketSeconds(db)
            var downloaded = 0.0
            var uploaded = 0.0
            if let raw = spans.raw {
                downloaded += try Self.rawSystemBytes(
                    db, column: "net_in", span: raw, bucket: bucket)
                uploaded += try Self.rawSystemBytes(
                    db, column: "net_out", span: raw, bucket: bucket)
            }
            if let minute = spans.minute {
                downloaded += try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_in_sum", span: minute)
                uploaded += try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_out_sum", span: minute)
            }
            if let hour = spans.hour {
                // Hour buckets align to the hour grid; the window's left edge
                // usually does not. Counting only buckets at or after `since`
                // would drop the bucket the edge lands in, silently losing up
                // to an hour of traffic (measured: a ~52-minute hole). Count
                // from the edge bucket's grid start, then subtract the minute
                // tier's portion of that bucket that precedes `since`.
                //
                // The subtraction range is at most an hour wide but sits at the
                // window's left edge, so it is only *retained* while that edge
                // is inside the minute tier's window (7 days). For the 30 d and
                // All periods the minute rows are long gone, so the correction
                // is zero and the figure includes up to an hour of traffic from
                // before the edge. At those periods that is under 0.2% of the
                // window and always in the direction of "shows more history",
                // which beats a visible hole.
                let edge = (hour.since / 3600).rounded(.down) * 3600
                downloaded += try Self.bucketedBytesSum(
                    db, table: "system_hour", column: "net_in_sum",
                    span: (edge, hour.until))
                downloaded -= try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_in_sum",
                    span: (edge, hour.since))
                uploaded += try Self.bucketedBytesSum(
                    db, table: "system_hour", column: "net_out_sum",
                    span: (edge, hour.until))
                uploaded -= try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_out_sum",
                    span: (edge, hour.since))
            }
            return NetworkHistoryTotals(
                downloaded: UInt64(max(0, downloaded).rounded()),
                uploaded: UInt64(max(0, uploaded).rounded()))
        }
    }

    /// The transferred-amount series for the chart, oldest first, one point per
    /// `period.seriesBucketWidth` grid bucket, summed across the tier spans so
    /// the series covers the same range the totals do.
    public func networkUsageSeries(
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> [NetworkUsagePoint] {
        let requested =
            (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let width = period.seriesBucketWidth
        return try databasePool.read { db in
            let since = max(requested, try Self.clearedAt(db))
            let spans = try Self.tierSpans(
                db, period: period, since: since, now: now.timeIntervalSince1970)
            let bucket = try Self.minuteBucketSeconds(db)
            var tiers: [[NetworkUsagePoint]] = []
            if let raw = spans.raw {
                tiers.append(
                    try Self.rawUsagePoints(
                        db, span: raw, width: width, bucket: bucket, appFilter: nil))
            }
            if let minute = spans.minute {
                tiers.append(
                    try Self.aggregateUsagePoints(
                        db, table: "system_minute", span: minute, width: width, appFilter: nil))
            }
            if let hour = spans.hour {
                tiers.append(
                    try Self.aggregateUsagePoints(
                        db, table: "system_hour", span: hour, width: width, appFilter: nil))
            }
            return Self.mergePoints(tiers)
        }
    }

    /// Per-app transferred amounts over the period, heaviest total first,
    /// summed across the tier spans and grouped by executable across launches.
    public func networkAppUsage(
        _ period: NetworkHistoryPeriod, now: Date = Date(), limit: Int = 100
    ) throws -> [NetworkAppUsage] {
        let requested =
            (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        return try databasePool.read { db in
            let since = max(requested, try Self.clearedAt(db))
            let spans = try Self.tierSpans(
                db, period: period, since: since, now: now.timeIntervalSince1970)
            let bucket = try Self.minuteBucketSeconds(db)
            var totals: [String: NetworkAppUsageAccumulator] = [:]
            func absorb(_ rows: [Row]) {
                for row in rows {
                    let path = row["executable_path"] as String?
                    let bundle = row["bundle_id"] as String?
                    let key = "\(path ?? "")\u{1}\(bundle ?? "")"
                    var entry =
                        totals[key]
                        ?? NetworkAppUsageAccumulator(
                            executablePath: path, bundleID: bundle,
                            name: row["name"] as String? ?? "")
                    entry.downloaded += (row["din"] as Double?) ?? 0
                    entry.uploaded += (row["dout"] as Double?) ?? 0
                    totals[key] = entry
                }
            }
            if let raw = spans.raw {
                absorb(try Self.rawAppTotals(db, span: raw, bucket: bucket))
            }
            if let minute = spans.minute {
                absorb(try Self.aggregateAppTotals(db, table: "process_minute", span: minute))
            }
            if let hour = spans.hour {
                absorb(try Self.aggregateAppTotals(db, table: "process_hour", span: hour))
            }
            return
                totals.values
                .map {
                    NetworkAppUsage(
                        executablePath: $0.executablePath, bundleID: $0.bundleID, name: $0.name,
                        downloaded: UInt64(max(0, $0.downloaded).rounded()),
                        uploaded: UInt64(max(0, $0.uploaded).rounded()))
                }
                .filter { $0.totalBytes > 0 }
                .sorted { $0.totalBytes > $1.totalBytes }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// One app's transferred-amount series, for the expanded per-app row.
    /// Same tier spans and grid as `networkUsageSeries`, summed across every
    /// launch of the executable.
    public func networkAppUsageSeries(
        executablePath: String?, bundleID: String?,
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> [NetworkUsagePoint] {
        let requested =
            (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let width = period.seriesBucketWidth
        let filter = Self.appFilter(executablePath: executablePath, bundleID: bundleID)
        return try databasePool.read { db in
            let since = max(requested, try Self.clearedAt(db))
            let spans = try Self.tierSpans(
                db, period: period, since: since, now: now.timeIntervalSince1970)
            let bucket = try Self.minuteBucketSeconds(db)
            var tiers: [[NetworkUsagePoint]] = []
            if let raw = spans.raw {
                tiers.append(
                    try Self.rawUsagePoints(
                        db, span: raw, width: width, bucket: bucket, appFilter: filter))
            }
            if let minute = spans.minute {
                tiers.append(
                    try Self.aggregateUsagePoints(
                        db, table: "process_minute", span: minute, width: width,
                        appFilter: filter))
            }
            if let hour = spans.hour {
                tiers.append(
                    try Self.aggregateUsagePoints(
                        db, table: "process_hour", span: hour, width: width, appFilter: filter))
            }
            return Self.mergePoints(tiers)
        }
    }

    /// Forget every recorded network amount, keeping every other metric's
    /// history. Backs the history panel's Clear action.
    ///
    /// The per-bucket sums, the interface tiers and the connection rows belong
    /// to this feature alone, so they are erased outright. The raw tier is
    /// shared: `system_samples.net_in/net_out` are the throughput *rates* the
    /// Dashboard's network chart draws, so they must survive. A cleared-at
    /// watermark covers them instead, and every network history read starts no
    /// earlier than it, which also stops the next rollup pass re-deriving the
    /// erased minute buckets from raw rows that are still on disk.
    public func clearNetworkHistory(at now: Date = Date()) throws {
        try databasePool.write { db in
            for table in ["system_minute", "system_hour", "process_minute", "process_hour"] {
                try db.execute(
                    sql: "UPDATE \(table) SET net_in_sum = 0, net_out_sum = 0")
            }
            try db.execute(sql: "DELETE FROM interface_minute")
            try db.execute(sql: "DELETE FROM interface_hour")
            try db.execute(sql: "DELETE FROM connection_stats")
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('network_cleared_at', ?)",
                arguments: [now.timeIntervalSince1970])
        }
    }

    // MARK: - Internals

    /// Per-app amounts accumulated across tiers before they are ranked.
    struct NetworkAppUsageAccumulator {
        var executablePath: String?
        var bundleID: String?
        var name: String
        var downloaded: Double = 0
        var uploaded: Double = 0
    }

    private static func metaValue(_ db: Database, _ key: String) throws -> Double? {
        try Double.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func watermarkValue(_ db: Database, _ key: String) throws -> Double {
        try metaValue(db, key) ?? 0
    }

    /// The instant the user last cleared network history, or the epoch.
    static func clearedAt(_ db: Database) throws -> Double {
        try metaValue(db, "network_cleared_at") ?? 0
    }

    /// The rollup's standard-resolution bucket width (user-configurable,
    /// default 60). The raw-tier integrals clamp each row's dt to its own
    /// bucket exactly as the rollup does, so the Hour period and the rolled
    /// minute tier report the same bytes for the same traffic.
    static func minuteBucketSeconds(_ db: Database) throws -> Double {
        let stored = try metaValue(db, "minute_bucket_seconds") ?? 60
        return stored > 0 ? stored : 60
    }

    /// A raw row's rate was in effect until the next row, until the query
    /// instant for the trailing row, or until the end of its own aggregate
    /// bucket, whichever comes first. The bucket clamp is what keeps a gap in
    /// the raw tier (a sleep, a quit, a paused sampler) from multiplying the
    /// last rate before the gap across the whole gap: without it, waking after
    /// eight hours booked eight hours of the pre-sleep rate as transferred
    /// bytes. It also matches the minute rollup's own weighting exactly, so a
    /// bucket reports the same amount before and after it is rolled up.
    private static func rawDtSQL(timeColumn: String, partition: String, bucket: Double) -> String {
        """
        MIN(
          COALESCE(
            LEAD(\(timeColumn)) OVER (\(partition)ORDER BY \(timeColumn)),
            ?),
          (CAST(\(timeColumn) / \(bucket) AS INTEGER) + 1) * \(bucket)
        ) - \(timeColumn)
        """
    }

    private static func rawSystemBytes(
        _ db: Database, column: String, span: (since: Double, until: Double), bucket: Double
    ) throws -> Double {
        try Double.fetchOne(
            db,
            sql: """
                SELECT SUM(\(column) * dt) FROM (
                    SELECT \(column),
                           \(rawDtSQL(timeColumn: "timestamp", partition: "", bucket: bucket))
                             AS dt
                    FROM system_samples
                    WHERE timestamp >= ? AND timestamp < ?
                )
                """,
            arguments: [span.until, span.since, span.until]) ?? 0
    }

    private static func bucketedBytesSum(
        _ db: Database, table: String, column: String, span: (since: Double, until: Double)
    ) throws -> Double {
        try Double.fetchOne(
            db,
            sql: "SELECT SUM(\(column)) FROM \(table) WHERE bucket >= ? AND bucket < ?",
            arguments: [span.since, span.until]) ?? 0
    }

    /// Grid-bucketed amounts from the raw tier. `appFilter` nil reads the
    /// system tier; otherwise the process tier, restricted to one app.
    private static func rawUsagePoints(
        _ db: Database, span: (since: Double, until: Double), width: Double, bucket: Double,
        appFilter: String?
    ) throws -> [NetworkUsagePoint] {
        let sql: String
        if let appFilter {
            sql = """
                SELECT CAST(s.timestamp / \(width) AS INTEGER) * \(width) AS b,
                       SUM(s.net_in * s.dt) AS din, SUM(s.net_out * s.dt) AS dout
                FROM (
                    SELECT timestamp, process_id, net_in, net_out,
                           \(rawDtSQL(
                               timeColumn: "timestamp",
                               partition: "PARTITION BY process_id ", bucket: bucket)) AS dt
                    FROM process_samples
                    WHERE timestamp >= ? AND timestamp < ?
                ) s
                JOIN processes p ON p.id = s.process_id
                WHERE \(appFilter)
                GROUP BY b ORDER BY b
                """
        } else {
            sql = """
                SELECT CAST(timestamp / \(width) AS INTEGER) * \(width) AS b,
                       SUM(net_in * dt) AS din, SUM(net_out * dt) AS dout
                FROM (
                    SELECT timestamp, net_in, net_out,
                           \(rawDtSQL(timeColumn: "timestamp", partition: "", bucket: bucket))
                             AS dt
                    FROM system_samples
                    WHERE timestamp >= ? AND timestamp < ?
                )
                GROUP BY b ORDER BY b
                """
        }
        return try Row.fetchAll(db, sql: sql, arguments: [span.until, span.since, span.until])
            .map(usagePoint)
    }

    /// Grid-bucketed amounts from an aggregate tier. `appFilter` nil reads a
    /// system tier; otherwise a process tier, restricted to one app.
    private static func aggregateUsagePoints(
        _ db: Database, table: String, span: (since: Double, until: Double), width: Double,
        appFilter: String?
    ) throws -> [NetworkUsagePoint] {
        let join = appFilter == nil ? "" : "JOIN processes p ON p.id = s.process_id"
        let filter = appFilter.map { "AND \($0)" } ?? ""
        return try Row.fetchAll(
            db,
            sql: """
                SELECT CAST(s.bucket / \(width) AS INTEGER) * \(width) AS b,
                       SUM(s.net_in_sum) AS din, SUM(s.net_out_sum) AS dout
                FROM \(table) s \(join)
                WHERE s.bucket >= ? AND s.bucket < ? \(filter)
                GROUP BY b ORDER BY b
                """,
            arguments: [span.since, span.until]
        ).map(usagePoint)
    }

    private static func usagePoint(_ row: Row) -> NetworkUsagePoint {
        NetworkUsagePoint(
            date: Date(timeIntervalSince1970: row["b"] as Double),
            downloaded: (row["din"] as Double?) ?? 0,
            uploaded: (row["dout"] as Double?) ?? 0)
    }

    /// Sum per-tier series onto one grid, oldest first. The tiers cover
    /// disjoint ranges, so a grid bucket that straddles a watermark simply
    /// receives both halves.
    private static func mergePoints(_ tiers: [[NetworkUsagePoint]]) -> [NetworkUsagePoint] {
        if tiers.count == 1 { return tiers[0] }
        var merged: [Double: (down: Double, up: Double)] = [:]
        for tier in tiers {
            for point in tier {
                let key = point.date.timeIntervalSince1970
                let existing = merged[key] ?? (0, 0)
                merged[key] = (
                    existing.down + point.downloaded, existing.up + point.uploaded
                )
            }
        }
        return merged.sorted { $0.key < $1.key }.map {
            NetworkUsagePoint(
                date: Date(timeIntervalSince1970: $0.key),
                downloaded: $0.value.down, uploaded: $0.value.up)
        }
    }

    private static func rawAppTotals(
        _ db: Database, span: (since: Double, until: Double), bucket: Double
    ) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT p.executable_path, p.bundle_id, MAX(p.name) AS name,
                       SUM(s.net_in * s.dt) AS din, SUM(s.net_out * s.dt) AS dout
                FROM (
                    SELECT timestamp, process_id, net_in, net_out,
                           \(rawDtSQL(
                               timeColumn: "timestamp",
                               partition: "PARTITION BY process_id ", bucket: bucket)) AS dt
                    FROM process_samples
                    WHERE timestamp >= ? AND timestamp < ?
                ) s
                JOIN processes p ON p.id = s.process_id
                GROUP BY p.executable_path, p.bundle_id
                HAVING din + dout > 0
                """,
            arguments: [span.until, span.since, span.until])
    }

    private static func aggregateAppTotals(
        _ db: Database, table: String, span: (since: Double, until: Double)
    ) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT p.executable_path, p.bundle_id, MAX(p.name) AS name,
                       SUM(s.net_in_sum) AS din, SUM(s.net_out_sum) AS dout
                FROM \(table) s
                JOIN processes p ON p.id = s.process_id
                WHERE s.bucket >= ? AND s.bucket < ?
                GROUP BY p.executable_path, p.bundle_id
                HAVING din + dout > 0
                """,
            arguments: [span.since, span.until])
    }

    /// App identity filter matched the way the group queries match: executable
    /// path when known, falling back to the bundle id for pathless rows.
    private static func appFilter(executablePath: String?, bundleID: String?) -> String {
        if let path = executablePath {
            return "p.executable_path = '\(path.replacingOccurrences(of: "'", with: "''"))'"
        }
        if let bundle = bundleID {
            return
                "p.executable_path IS NULL AND p.bundle_id = '\(bundle.replacingOccurrences(of: "'", with: "''"))'"
        }
        return "p.executable_path IS NULL AND p.bundle_id IS NULL"
    }
}

// MARK: - Interfaces and connections (v17)

/// One interface's transferred amounts over a period.
public struct InterfaceUsage: Sendable, Identifiable, Equatable {
    public var name: String
    public var downloaded: UInt64
    public var uploaded: UInt64

    public var id: String { name }
}

/// One remote endpoint's transferred amounts over a period, attributed to the
/// app that opened the connection. Grouped the way the Connection History
/// table shows rows: remote IP plus app, with the transfer instants.
public struct ConnectionUsage: Sendable, Identifiable, Equatable {
    public var remoteIP: String
    public var appName: String
    public var executablePath: String?
    public var downloaded: UInt64
    public var uploaded: UInt64
    public var firstTransfer: Date
    public var lastTransfer: Date

    public var id: String { "\(remoteIP)/\(executablePath ?? appName)" }
}

extension SampleStore {
    /// Accrue observed per-interface bytes into the current minute bucket.
    /// Called on the persist cadence with whatever the reader accumulated since
    /// the last call, so a bucket holds the interface's transferred bytes
    /// regardless of cadence and the breakdown adds up to the machine total.
    /// Bytes are dated to the drain instant, so a drain that straddles a minute
    /// boundary smears at most one persist interval (~2 s) into the newer
    /// bucket.
    public func recordInterfaceUsage(
        _ bytes: [String: (inBytes: UInt64, outBytes: UInt64)], at now: Date = Date()
    ) throws {
        guard !bytes.isEmpty else { return }
        let bucket = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        try databasePool.write { db in
            for (name, transferred) in bytes
            where transferred.inBytes > 0
                || transferred.outBytes > 0
            {
                try db.execute(
                    sql: """
                        INSERT INTO interface_minute (interface, bucket, net_in_sum, net_out_sum)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(interface, bucket) DO UPDATE SET
                            net_in_sum = net_in_sum + excluded.net_in_sum,
                            net_out_sum = net_out_sum + excluded.net_out_sum
                        """,
                    arguments: [
                        name, bucket, Double(transferred.inBytes), Double(transferred.outBytes),
                    ])
            }
        }
    }

    /// Persist one cycle's per-connection byte deltas, resolving each pid to
    /// the newest matching `processes` row (the pid cache lives for one call:
    /// a cycle's deltas are a few dozen, and resolution is one indexed probe).
    public func recordConnectionDeltas(
        _ deltas: [ConnectionHistoryReader.Delta]
    ) throws {
        guard !deltas.isEmpty else { return }
        try databasePool.write { db in
            var processIDs: [Int32: Int64?] = [:]
            for delta in deltas {
                if processIDs[delta.pid] == nil {
                    processIDs[delta.pid] = try Int64.fetchOne(
                        db,
                        sql: """
                            SELECT id FROM processes WHERE pid = ?
                            ORDER BY last_seen DESC LIMIT 1
                            """, arguments: [delta.pid])
                }
                guard let processID = processIDs[delta.pid] ?? nil else { continue }
                let timestamp = delta.timestamp.timeIntervalSince1970
                let day = (timestamp / 86_400).rounded(.down)
                try db.execute(
                    sql: """
                        INSERT INTO connection_stats
                            (process_id, remote_ip, remote_port, day, net_in_sum,
                             net_out_sum, first_transfer, last_transfer)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(process_id, remote_ip, remote_port, day) DO UPDATE SET
                            net_in_sum = net_in_sum + excluded.net_in_sum,
                            net_out_sum = net_out_sum + excluded.net_out_sum,
                            last_transfer = excluded.last_transfer
                        """,
                    arguments: [
                        processID, delta.remoteIP, delta.remotePort, day,
                        Double(delta.inBytes), Double(delta.outBytes), timestamp, timestamp,
                    ])
            }
        }
    }

    /// Per-interface transferred amounts over the period, heaviest first.
    public func interfaceUsage(
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> [InterfaceUsage] {
        let since = (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let table = period.granularity == .hour ? "interface_hour" : "interface_minute"
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT interface, SUM(net_in_sum) AS din, SUM(net_out_sum) AS dout
                    FROM \(table) WHERE bucket >= ?
                    GROUP BY interface ORDER BY din + dout DESC
                    """, arguments: [since]
            )
            .map {
                InterfaceUsage(
                    name: $0["interface"],
                    downloaded: UInt64(max(0, ($0["din"] as Double?) ?? 0).rounded()),
                    uploaded: UInt64(max(0, ($0["dout"] as Double?) ?? 0).rounded()))
            }
        }
    }

    /// One interface's transferred-amount series, for the interface picker's chart.
    public func interfaceUsageSeries(
        _ name: String, _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> [NetworkUsagePoint] {
        let since = (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let width = period.seriesBucketWidth
        let table = period.granularity == .hour ? "interface_hour" : "interface_minute"
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT CAST(bucket / \(width) AS INTEGER) * \(width) AS b,
                           SUM(net_in_sum) AS din, SUM(net_out_sum) AS dout
                    FROM \(table) WHERE interface = ? AND bucket >= ?
                    GROUP BY b ORDER BY b
                    """, arguments: [name, since]
            )
            .map {
                NetworkUsagePoint(
                    date: Date(timeIntervalSince1970: $0["b"] as Double),
                    downloaded: ($0["din"] as Double?) ?? 0,
                    uploaded: ($0["dout"] as Double?) ?? 0)
            }
        }
    }

    /// Connection-history rows over the period, heaviest total first, grouped
    /// by remote IP and app the way the Connection History table shows them.
    public func connectionUsage(
        _ period: NetworkHistoryPeriod, now: Date = Date(), limit: Int = 200
    ) throws -> [ConnectionUsage] {
        let since = (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let sinceDay = (since / 86_400).rounded(.down)
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.remote_ip,
                           MAX(p.name) AS name, MAX(p.executable_path) AS path,
                           CAST(SUM(c.net_in_sum) AS INTEGER) AS din,
                           CAST(SUM(c.net_out_sum) AS INTEGER) AS dout,
                           MIN(c.first_transfer) AS first, MAX(c.last_transfer) AS last
                    FROM connection_stats c
                    JOIN processes p ON p.id = c.process_id
                    WHERE c.day >= ?
                    GROUP BY c.remote_ip, p.executable_path
                    ORDER BY din + dout DESC LIMIT \(limit)
                    """, arguments: [sinceDay]
            )
            .map {
                ConnectionUsage(
                    remoteIP: $0["remote_ip"],
                    appName: $0["name"] as String? ?? "",
                    executablePath: $0["path"] as String?,
                    downloaded: SQLInt.read($0["din"] as Int64? ?? 0),
                    uploaded: SQLInt.read($0["dout"] as Int64? ?? 0),
                    firstTransfer: Date(timeIntervalSince1970: $0["first"] as Double),
                    lastTransfer: Date(timeIntervalSince1970: $0["last"] as Double))
            }
        }
    }
}
