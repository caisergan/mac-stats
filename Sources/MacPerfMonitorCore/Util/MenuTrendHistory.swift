import Foundation

/// How much history the menu bar panel's header charts cover. One choice for
/// every tab, so moving from CPU to RAM never silently changes the time scale.
///
/// The shortest range is the detail view: every live sample, as it arrived.
/// The longer ones are the overview: fixed-width buckets, each drawn as its
/// mean inside a band from its minimum to its maximum, so an hour still fits
/// the panel's width without a brief spike being averaged away.
public enum MenuChartRange: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    /// The UserDefaults key the panel's picker and Settings share.
    public static let defaultsKey = "menuChartRange"
    public static let `default`: MenuChartRange = .oneMinute

    public var id: String { rawValue }

    /// Span of the range in seconds.
    public var seconds: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 3600
        }
    }

    /// Width of one plotted bucket, or nil for the raw detail view. Each is a
    /// whole multiple of `MenuTrendHistory.baseBucket`, and each range comes
    /// to 60 to 120 buckets: enough to read a shape in a 350 point plot
    /// without drawing several points per pixel.
    public var bucketSeconds: TimeInterval? {
        switch self {
        case .oneMinute: return nil
        case .fiveMinutes: return 5
        case .fifteenMinutes: return 10
        case .oneHour: return 30
        }
    }

    /// Short label for the picker.
    public var label: String {
        switch self {
        case .oneMinute: return t("1 min")
        case .fiveMinutes: return t("5 min")
        case .fifteenMinutes: return t("15 min")
        case .oneHour: return t("1 hr")
        }
    }
}

/// One series ready for a menu bar chart: values oldest first, each placed in
/// one of `capacity` equal slots across the plot (see
/// `LiveChartGeometry.normalizedSlot`).
public struct MenuTrendSeries: Equatable, Sendable {
    /// The plotted value per slot: the sample itself, or a bucket's mean. NaN
    /// marks a bucket with no reading (the Mac was asleep, the app was not
    /// running), which the charts leave as a gap rather than bridging.
    public var values: [Double]
    /// Bucket minima and maxima, parallel to `values`. Nil for raw samples,
    /// where the extremes are the value and there is no band to draw.
    public var minima: [Double]?
    public var maxima: [Double]?
    /// When each sample was taken, or when each bucket starts.
    public var dates: [Date]
    /// How many slots the range spans.
    public var capacity: Int

    public init(
        values: [Double], minima: [Double]? = nil, maxima: [Double]? = nil, dates: [Date],
        capacity: Int
    ) {
        self.values = values
        self.minima = minima
        self.maxima = maxima
        self.dates = dates
        self.capacity = capacity
    }

    public static let empty = MenuTrendSeries(values: [], dates: [], capacity: 1)

    /// The highest point the chart draws: the top of the band where there is
    /// one, so an auto-scaled axis never clips a peak.
    public var top: Double? {
        (maxima ?? values).filter(\.isFinite).max()
    }

    /// A raw series of the samples inside `range`, ending at the newest one.
    /// `interval` is the live sampling cadence, which sets how many slots the
    /// range holds.
    public static func raw(
        dates: [Date], values: [Double], range: MenuChartRange, interval: TimeInterval
    ) -> MenuTrendSeries {
        precondition(dates.count == values.count)
        let capacity = max(1, Int((range.seconds / max(interval, 0.01)).rounded()))
        guard let newest = dates.last else {
            return MenuTrendSeries(values: [], dates: [], capacity: capacity)
        }
        let cutoff = newest.addingTimeInterval(-range.seconds)
        let start = dates.firstIndex { $0 > cutoff } ?? dates.count
        // A cadence change can leave more samples in the window than slots;
        // the newest win, so the right edge stays "now".
        let first = max(start, dates.count - capacity)
        return MenuTrendSeries(
            values: Array(values[first...]), dates: Array(dates[first...]), capacity: capacity)
    }
}

/// The last hour of the menu bar panel's chart metrics, folded into five
/// second buckets as the samples arrive.
///
/// The live ring keeps full samples for only a few minutes, and the on-disk
/// history exists only when logging is on, so neither can back an hour long
/// panel chart on its own. Each bucket keeps a sum, a count, a minimum and a
/// maximum per metric, which merge exactly into the wider buckets a range
/// draws: means stay true means and the extremes stay the real extremes.
/// An hour is 720 buckets, a few hundred kilobytes at most.
public struct MenuTrendHistory {
    /// What the panel charts plot.
    public enum Metric: Int, CaseIterable, Sendable {
        case cpuLoad
        case memoryPressure
        case batteryCharge
        case systemPower
        case networkIn
        case networkOut
        case diskRead
        case diskWrite
        case cpuDie
        case gpuUtilization
        case aneTime
        case anePower
    }

    private struct Stat {
        var sum = 0.0
        var count = 0
        var minimum = Double.infinity
        var maximum = -Double.infinity

        mutating func add(_ value: Double) {
            sum += value
            count += 1
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }

        mutating func merge(_ other: Stat) {
            sum += other.sum
            count += other.count
            minimum = min(minimum, other.minimum)
            maximum = max(maximum, other.maximum)
        }
    }

    private struct Bucket {
        /// `floor(time / baseBucket)` in reference-date seconds.
        var key: Int
        var stats: [Stat]
    }

    public static let baseBucket: TimeInterval = 5
    public static let span: TimeInterval = 3600

    /// Oldest first, keys strictly increasing. Buckets with no sample at all
    /// (the Mac was asleep) are simply absent.
    private var buckets: [Bucket] = []

    /// The oldest key still inside the span, measured back from the newest
    /// bucket.
    private var oldestKeptKey: Int? {
        buckets.last.map { $0.key - Int(Self.span / Self.baseBucket) + 1 }
    }

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty }

    /// Fold in one sample. `value` returns nil for a metric the sample does not
    /// carry (no battery, GPU sampling off); a non-finite value counts as nil.
    /// A sample older than the newest bucket is ignored.
    public mutating func append(at date: Date, value: (Metric) -> Double?) {
        let key = Int((date.timeIntervalSinceReferenceDate / Self.baseBucket).rounded(.down))
        if let last = buckets.last, key < last.key { return }
        if buckets.last?.key != key {
            buckets.append(
                Bucket(key: key, stats: Array(repeating: Stat(), count: Metric.allCases.count)))
        }
        let index = buckets.count - 1
        for metric in Metric.allCases {
            guard let v = value(metric), v.isFinite else { continue }
            buckets[index].stats[metric.rawValue].add(v)
        }
        trim()
    }

    /// Put an earlier history in front of this one: the recorded samples from
    /// before launch, read back from the database while the live ones were
    /// already arriving. Only buckets older than the first live one are taken,
    /// so a bucket the two share keeps its live readings.
    public mutating func prepend(_ older: MenuTrendHistory) {
        guard let first = buckets.first else {
            buckets = older.buckets
            trim()
            return
        }
        let earlier = older.buckets.prefix { $0.key < first.key }
        guard !earlier.isEmpty else { return }
        buckets.insert(contentsOf: earlier, at: 0)
        trim()
    }

    private mutating func trim() {
        guard let oldest = oldestKeptKey else { return }
        if let drop = buckets.firstIndex(where: { $0.key >= oldest }), drop > 0 {
            buckets.removeFirst(drop)
        }
    }

    public mutating func removeAll() {
        buckets.removeAll()
    }

    /// One metric over `range`, merged into the range's bucket width and
    /// ending with the bucket that holds the newest sample (still filling).
    /// It starts at the first bucket with a reading, and every bucket from
    /// there on has a slot, NaN where nothing was read, so a gap in the record
    /// stays a gap in the chart instead of drawing two hours as adjacent.
    /// A raw range has no bucket width; asking for one here is a caller error.
    public func series(_ metric: Metric, range: MenuChartRange) -> MenuTrendSeries {
        guard let width = range.bucketSeconds else {
            preconditionFailure("MenuTrendHistory only serves bucketed ranges")
        }
        let factor = max(1, Int((width / Self.baseBucket).rounded()))
        let capacity = max(1, Int((range.seconds / width).rounded()))
        guard let newest = buckets.last else {
            return MenuTrendSeries(values: [], dates: [], capacity: capacity)
        }
        func group(_ key: Int) -> Int { Int((Double(key) / Double(factor)).rounded(.down)) }
        let firstGroup = group(newest.key) - capacity + 1

        // Merge into one stat per group, a slot each, then trim the slots before
        // the first reading.
        var stats = Array(repeating: Stat(), count: capacity)
        for bucket in buckets {
            let slot = group(bucket.key) - firstGroup
            guard slot >= 0 else { continue }
            stats[slot].merge(bucket.stats[metric.rawValue])
        }
        guard let start = stats.firstIndex(where: { $0.count > 0 }) else {
            return MenuTrendSeries(values: [], dates: [], capacity: capacity)
        }

        var values: [Double] = []
        var minima: [Double] = []
        var maxima: [Double] = []
        var dates: [Date] = []
        for slot in start..<capacity {
            let stat = stats[slot]
            let empty = stat.count == 0
            values.append(empty ? .nan : stat.sum / Double(stat.count))
            minima.append(empty ? .nan : stat.minimum)
            maxima.append(empty ? .nan : stat.maximum)
            dates.append(
                Date(timeIntervalSinceReferenceDate: Double(firstGroup + slot) * width))
        }
        return MenuTrendSeries(
            values: values, minima: minima, maxima: maxima, dates: dates, capacity: capacity)
    }
}
