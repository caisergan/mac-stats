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
    /// Transferred amounts over the period, stitched across the storage tiers
    /// the same way the read path stitches them: each tier owns the range its
    /// watermark has finalised, the raw tier owns everything newer. The
    /// watermarks come from `meta`, so a period that spans a rollup boundary
    /// never double-counts a bucket.
    public func networkBytesTransferred(
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> NetworkHistoryTotals {
        let since = period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast
        return try databasePool.read { db in
            let minuteWatermark = try Self.watermark(db, "minute_watermark")
            let hourWatermark = try Self.watermark(db, "hour_watermark")

            // Raw owns [minuteWatermark, now); the minute tier
            // [hourWatermark, minuteWatermark); the hour tier everything older.
            let rawSince = max(since, minuteWatermark)
            var downloaded =
                try Double.fetchOne(
                    db,
                    sql: Self.rawBytesSumSQL(
                        column: "net_in", timeColumn: "timestamp",
                        until: now.timeIntervalSince1970),
                    arguments: [now.timeIntervalSince1970, rawSince.timeIntervalSince1970]) ?? 0
            var uploaded =
                try Double.fetchOne(
                    db,
                    sql: Self.rawBytesSumSQL(
                        column: "net_out", timeColumn: "timestamp",
                        until: now.timeIntervalSince1970),
                    arguments: [now.timeIntervalSince1970, rawSince.timeIntervalSince1970]) ?? 0

            if since < minuteWatermark {
                let minuteSince = max(since, hourWatermark)
                downloaded += try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_in_sum",
                    since: minuteSince, until: minuteWatermark)
                uploaded += try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_out_sum",
                    since: minuteSince, until: minuteWatermark)
            }
            if since < hourWatermark {
                // Hour buckets align to the hour grid; the window's left edge
                // usually does not. Counting only buckets at or after `since`
                // would drop the bucket the edge lands in, silently losing up
                // to an hour of traffic (measured: a ~52-minute hole). Count
                // from the edge bucket's grid start, then subtract the minute
                // tier's portion of that bucket that precedes `since` — the
                // minute tier retains it (7 days), so the subtraction range is
                // never older than an hour and always present.
                let edge = Date(
                    timeIntervalSince1970: (since.timeIntervalSince1970 / 3600).rounded(.down)
                        * 3600)
                downloaded += try Self.bucketedBytesSum(
                    db, table: "system_hour", column: "net_in_sum",
                    since: edge, until: hourWatermark)
                downloaded -= try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_in_sum",
                    since: edge, until: since)
                uploaded += try Self.bucketedBytesSum(
                    db, table: "system_hour", column: "net_out_sum",
                    since: edge, until: hourWatermark)
                uploaded -= try Self.bucketedBytesSum(
                    db, table: "system_minute", column: "net_out_sum",
                    since: edge, until: since)
            }
            return NetworkHistoryTotals(
                downloaded: UInt64(max(0, downloaded).rounded()),
                uploaded: UInt64(max(0, uploaded).rounded()))
        }
    }

    /// The transferred-amount series for the chart, oldest first, one point per
    /// `period.seriesBucketWidth` grid bucket. Buckets read from a single tier
    /// (the period's own), so a point is exact at that tier's resolution.
    public func networkUsageSeries(
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> [NetworkUsagePoint] {
        let since = (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let width = period.seriesBucketWidth
        return try databasePool.read { db in
            switch period.granularity {
            case .raw:
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT CAST(timestamp / \(width) AS INTEGER) * \(width) AS b,
                               SUM(net_in * dt) AS din, SUM(net_out * dt) AS dout
                        FROM (
                            SELECT timestamp, net_in, net_out,
                                   COALESCE(
                                     LEAD(timestamp) OVER (ORDER BY timestamp),
                                     ?) - timestamp AS dt
                            FROM system_samples
                            WHERE timestamp >= ?
                        )
                        GROUP BY b ORDER BY b
                        """, arguments: [now.timeIntervalSince1970, since])
                return rows.map {
                    NetworkUsagePoint(
                        date: Date(timeIntervalSince1970: $0["b"] as Double),
                        downloaded: ($0["din"] as Double?) ?? 0,
                        uploaded: ($0["dout"] as Double?) ?? 0)
                }
            case .minute:
                return try Self.aggregateUsagePoints(
                    db, table: "system_minute", since: since, width: width)
            case .hour:
                return try Self.aggregateUsagePoints(
                    db, table: "system_hour", since: since, width: width)
            }
        }
    }

    /// Per-app transferred amounts over the period, heaviest total first. Reads
    /// the tier the period maps to; the 1 h period integrates the raw tier's
    /// per-tick rates the same way the raw rollup does.
    public func networkAppUsage(
        _ period: NetworkHistoryPeriod, now: Date = Date(), limit: Int = 100
    ) throws -> [NetworkAppUsage] {
        let since = (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        return try databasePool.read { db in
            let rows: [Row]
            switch period.granularity {
            case .raw:
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT p.executable_path, p.bundle_id, MAX(p.name) AS name,
                               CAST(SUM(net_in * dt) AS INTEGER) AS din,
                               CAST(SUM(net_out * dt) AS INTEGER) AS dout
                        FROM (
                            SELECT ps.process_id, ps.net_in, ps.net_out,
                                   COALESCE(
                                     LEAD(ps.timestamp) OVER (
                                       PARTITION BY ps.process_id ORDER BY ps.timestamp),
                                     MIN(?, (CAST(ps.timestamp / 60 AS INTEGER) + 1) * 60.0))
                                     - ps.timestamp AS dt
                            FROM process_samples ps
                            WHERE ps.timestamp >= ?
                        ) s
                        JOIN processes p ON p.id = s.process_id
                        GROUP BY p.executable_path, p.bundle_id
                        HAVING din + dout > 0
                        ORDER BY din + dout DESC LIMIT \(limit)
                        """, arguments: [now.timeIntervalSince1970, since])
            case .minute, .hour:
                let table = period.granularity == .minute ? "process_minute" : "process_hour"
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT p.executable_path, p.bundle_id,
                               MAX(p.name) AS name,
                               CAST(SUM(s.net_in_sum) AS INTEGER) AS din,
                               CAST(SUM(s.net_out_sum) AS INTEGER) AS dout
                        FROM \(table) s
                        JOIN processes p ON p.id = s.process_id
                        WHERE s.bucket >= ?
                        GROUP BY p.executable_path, p.bundle_id
                        HAVING din + dout > 0
                        ORDER BY din + dout DESC LIMIT \(limit)
                        """, arguments: [since])
            }
            return rows.map {
                NetworkAppUsage(
                    executablePath: $0["executable_path"] as String?,
                    bundleID: $0["bundle_id"] as String?,
                    name: $0["name"] as String? ?? "",
                    downloaded: SQLInt.read($0["din"] as Int64? ?? 0),
                    uploaded: SQLInt.read($0["dout"] as Int64? ?? 0))
            }
        }
    }

    /// One app's transferred-amount series, for the expanded per-app row.
    /// Reads the same tier as `networkUsageSeries`, summed across every launch
    /// of the executable.
    public func networkAppUsageSeries(
        executablePath: String?, bundleID: String?,
        _ period: NetworkHistoryPeriod, now: Date = Date()
    ) throws -> [NetworkUsagePoint] {
        let since = (period.seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast)
            .timeIntervalSince1970
        let width = period.seriesBucketWidth
        return try databasePool.read { db in
            switch period.granularity {
            case .raw:
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT CAST(timestamp / \(width) AS INTEGER) * \(width) AS b,
                               SUM(net_in * dt) AS din, SUM(net_out * dt) AS dout
                        FROM (
                            SELECT ps.timestamp, ps.net_in, ps.net_out,
                                   COALESCE(
                                     LEAD(ps.timestamp) OVER (
                                       PARTITION BY ps.process_id ORDER BY ps.timestamp),
                                     MIN(?, (CAST(ps.timestamp / 60 AS INTEGER) + 1) * 60.0))
                                     - ps.timestamp AS dt
                            FROM process_samples ps
                            JOIN processes p ON p.id = ps.process_id
                            WHERE ps.timestamp >= ? AND \(Self.appFilter(
                                executablePath: executablePath, bundleID: bundleID))
                        )
                        GROUP BY b ORDER BY b
                        """, arguments: [now.timeIntervalSince1970, since])
                return rows.map {
                    NetworkUsagePoint(
                        date: Date(timeIntervalSince1970: $0["b"] as Double),
                        downloaded: ($0["din"] as Double?) ?? 0,
                        uploaded: ($0["dout"] as Double?) ?? 0)
                }
            case .minute, .hour:
                let table = period.granularity == .minute ? "process_minute" : "process_hour"
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT CAST(bucket / \(width) AS INTEGER) * \(width) AS b,
                               SUM(net_in_sum) AS din, SUM(net_out_sum) AS dout
                        FROM \(table) s
                        JOIN processes p ON p.id = s.process_id
                        WHERE s.bucket >= ? AND \(Self.appFilter(
                            executablePath: executablePath, bundleID: bundleID))
                        GROUP BY b ORDER BY b
                        """, arguments: [since])
                return rows.map {
                    NetworkUsagePoint(
                        date: Date(timeIntervalSince1970: $0["b"] as Double),
                        downloaded: ($0["din"] as Double?) ?? 0,
                        uploaded: ($0["dout"] as Double?) ?? 0)
                }
            }
        }
    }

    /// Deletes the network byte totals, keeping every other metric's history.
    /// Backs the history panel's Clear action.
    public func clearNetworkHistory() throws {
        try databasePool.write { db in
            try db.execute(
                sql: "UPDATE system_minute SET net_in_sum = 0, net_out_sum = 0")
            try db.execute(
                sql: "UPDATE system_hour SET net_in_sum = 0, net_out_sum = 0")
            try db.execute(
                sql: "UPDATE process_minute SET net_in_sum = 0, net_out_sum = 0")
            try db.execute(
                sql: "UPDATE process_hour SET net_in_sum = 0, net_out_sum = 0")
        }
    }

    // MARK: - Internals

    private static func watermark(_ db: Database, _ key: String) throws -> Date {
        let value =
            try Double.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) ?? 0
        return Date(timeIntervalSince1970: value)
    }

    /// Time-integrated bytes on the raw tier since `since`. A row's rate was in
    /// effect until the next row, or until `until` for the trailing row (the
    /// query instant, so the still-active tail of traffic is not dropped), so
    /// SUM(rate * dt) is the transferred amount.
    private static func rawBytesSumSQL(
        column: String, timeColumn: String, until: Double
    )
        -> String
    {
        """
        SELECT SUM(\(column) * dt) FROM (
            SELECT \(column),
                   COALESCE(
                                            LEAD(timestamp) OVER (ORDER BY timestamp),
                     ?) - timestamp AS dt
            FROM system_samples
            WHERE \(timeColumn) >= ?
        )
        """
    }

    private static func bucketedBytesSum(
        _ db: Database, table: String, column: String,
        since: Date, until: Date
    ) throws -> Double {
        try Double.fetchOne(
            db,
            sql: "SELECT SUM(\(column)) FROM \(table) WHERE bucket >= ? AND bucket < ?",
            arguments: [since.timeIntervalSince1970, until.timeIntervalSince1970]) ?? 0
    }

    private static func aggregateUsagePoints(
        _ db: Database, table: String, since: Double, width: Double
    ) throws -> [NetworkUsagePoint] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT CAST(bucket / \(width) AS INTEGER) * \(width) AS b,
                       SUM(net_in_sum) AS din, SUM(net_out_sum) AS dout
                FROM \(table)
                WHERE bucket >= ?
                GROUP BY b ORDER BY b
                """, arguments: [since])
        return rows.map {
            NetworkUsagePoint(
                date: Date(timeIntervalSince1970: $0["b"] as Double),
                downloaded: ($0["din"] as Double?) ?? 0,
                uploaded: ($0["dout"] as Double?) ?? 0)
        }
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
    /// Accrue one interval of per-interface rates into the current minute
    /// bucket. Called on the persist cadence; the deltas add up, so a bucket
    /// holds the interface's transferred bytes regardless of cadence.
    public func recordInterfaceUsage(
        _ rates: [String: (inBytesPerSec: Double, outBytesPerSec: Double)],
        dt: TimeInterval, at now: Date = Date()
    ) throws {
        guard dt > 0, !rates.isEmpty else { return }
        let bucket = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        try databasePool.write { db in
            for (name, rate) in rates {
                try db.execute(
                    sql: """
                        INSERT INTO interface_minute (interface, bucket, net_in_sum, net_out_sum)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(interface, bucket) DO UPDATE SET
                            net_in_sum = net_in_sum + excluded.net_in_sum,
                            net_out_sum = net_out_sum + excluded.net_out_sum
                        """,
                    arguments: [
                        name, bucket, rate.inBytesPerSec * dt, rate.outBytesPerSec * dt,
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
                    firstTransfer: Date(timeIntervalSince1970: $0["first"] as Double ?? 0),
                    lastTransfer: Date(timeIntervalSince1970: $0["last"] as Double ?? 0))
            }
        }
    }
}
