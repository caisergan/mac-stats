import Foundation

/// The per-domain power figures IOReport reports and the SMC does not.
///
/// On Apple silicon the interesting power rails are not SMC keys at all: they
/// are "Energy Model" counters. The sampler already differences them for the
/// GPU panel, so the sensors reader takes them as an input rather than opening
/// a second subscription of its own.
public struct EnergyModelPower: Sendable, Equatable {
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var aneWatts: Double?
    public var ramWatts: Double?
    public var pciWatts: Double?

    public init(
        cpuWatts: Double? = nil, gpuWatts: Double? = nil, aneWatts: Double? = nil,
        ramWatts: Double? = nil, pciWatts: Double? = nil
    ) {
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.ramWatts = ramWatts
        self.pciWatts = pciWatts
    }

    var isEmpty: Bool {
        cpuWatts == nil && gpuWatts == nil && aneWatts == nil && ramWatts == nil
            && pciWatts == nil
    }
}

/// A fan's rated range, carried alongside its current speed so the panel can
/// draw the share of its envelope rather than a bare RPM figure.
public struct SensorFanFacts: Sendable, Equatable {
    public var index: Int
    public var minSpeed: Double
    public var maxSpeed: Double

    /// Share of the rated maximum, 0 to 100. Zero when the SMC reports a
    /// placeholder range (Stats treats 0 and 1 as "not rated").
    public var percentage: Int
}

/// One sensor reading with everything a row needs to render itself.
public struct SensorReadingValue: Sendable, Equatable, Identifiable {
    public var key: String
    public var name: String
    public var kind: SensorKind
    public var domain: SensorDomain
    public var value: Double
    public var fan: SensorFanFacts?
    /// True for figures this app derives (the averages, the hottest readings,
    /// the accumulated energy, the IOReport power rails) rather than reads
    /// from a single SMC key.
    public var isComputed: Bool = false
    /// True for a per-core die sensor: one of the readings that feeds its
    /// domain's average. A modern chip has twenty or more of them, all saying
    /// much the same thing, so a list has good reason to show the average in
    /// their place and offer the detail on request.

    public var id: String { key }

    public var isCore: Bool = false

    public init(
        key: String, name: String, kind: SensorKind, domain: SensorDomain, value: Double,
        fan: SensorFanFacts? = nil, isComputed: Bool = false, isCore: Bool = false
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.domain = domain
        self.value = value
        self.fan = fan
        self.isComputed = isComputed
        self.isCore = isCore
    }

    /// The number alone, with Stats' precision per kind: one decimal for
    /// temperature, three for voltage (rails move in millivolts), two for the
    /// rest, and no decimals once a figure passes 100.
    ///
    /// Separate from `formattedValue` because a panel that groups readings by
    /// kind can put the unit in the section heading and print bare numbers,
    /// which is one column of noise removed from every row and lets the digits
    /// line up.
    public var figure: String {
        switch kind {
        case .temperature:
            return String(format: "%.1f", value)
        case .voltage:
            return value >= 100 ? "\(Int(value))" : String(format: "%.3f", value)
        case .power, .energy, .current:
            return value >= 100 ? "\(Int(value))" : String(format: "%.2f", value)
        case .fan:
            return "\(Int(value))"
        }
    }

    /// The figure with its unit, for anywhere the kind is not already stated.
    public var formattedValue: String {
        kind == .fan ? "\(figure) \(kind.unit)" : figure + kind.unit
    }

    /// The forms this reading's figure can take, for a menu bar cell that has
    /// to reserve a width rather than resize as the figure moves. The cell
    /// takes the widest of them.
    ///
    /// A cell sized to the current figure moves every time the figure does: a
    /// power rail alternating between "5.0W" and "40W" is three points apart,
    /// and it drags everything to its left along the bar.
    ///
    /// Two digits, not three. Reserving for "100W" costs three points of
    /// permanent width for a reading that is nearly always two digits, and a
    /// three digit figure fits by dropping its unit instead, the way the mini
    /// shape handles 100%. So the reservation is the wider of the two-digit
    /// form (with its decimal point, since "5.0W" is wider than "40W") and the
    /// three-digit figure with the unit dropped. Fans are the exception: their
    /// figure is four digits and has nowhere to shrink to.
    public var menuBarTemplates: [String] {
        switch kind {
        case .fan: return ["0000"]
        case .temperature: return ["00\u{00B0}", "100"]
        default: return ["0.0" + kind.unit, "100"]
        }
    }

    /// The compact form for a menu bar cell: the degree sign but not the scale
    /// letter on temperature, a single decimal below 10 on the electrical
    /// figures. Stats does the same, and without the sign a bare "77" beside a
    /// "21W" says nothing about what it measures.
    public var menuBarValue: String {
        switch kind {
        case .temperature:
            return String(Int(value.rounded())) + "\u{00B0}"
        case .voltage, .power, .energy, .current:
            let text =
                value >= 9.95 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
            return text + kind.unit
        case .fan:
            return String(Int(value))
        }
    }
}

/// Reads the machine's full sensor set: every SMC temperature, voltage,
/// current and power key the catalogue can name, the fans, the IOReport power
/// rails, and the figures derived from them.
///
/// Ported from Stats' `SensorsReader` (github.com/exelban/stats, MIT), keeping
/// its discovery order, its sanity filters and its derived figures, so the
/// list reads the same way. Not thread safe: confine one instance to a single
/// queue. The first `read` pays key discovery (a few hundred milliseconds);
/// repeats re-read only the keys that resolved.
public final class SensorsReader {
    private let smc = SMCReader()
    private let platform = SensorPlatform.current

    /// The keys that resolved on this Mac, in the order the panel lists them.
    /// Built on the first read and then reused.
    private var discovered: [SensorReadingValue]?

    /// Accumulated system energy in watt hours, and the timestamps that turn
    /// the "System Total" wattage into it. Both grow from the first read, so
    /// the average is an average over the app's uptime, as in Stats.
    private var totalWattHours: Double = 0
    private var lastRead: Date?
    private var firstRead: Date?

    public init() {}

    /// Every reading for one sweep. `power` supplies the IOReport rails; pass
    /// an empty value and those rows are simply absent.
    public func read(
        now: Date = Date(), power: EnergyModelPower = EnergyModelPower()
    )
        -> [SensorReadingValue]
    {
        let didDiscover = discovered == nil
        var list = discovered ?? discover(power: power)

        for index in list.indices {
            let sensor = list[index]
            guard !sensor.isComputed else { continue }
            var value = smc.readValue(named: sensor.key) ?? 0
            // Some units report a dead CPU die key as 0 or as a wild figure;
            // Stats holds the previous reading rather than showing it.
            if sensor.kind == .temperature, sensor.domain == .cpu, value < 10 || value > 120 {
                value = sensor.value
            }
            list[index].value = value
            if sensor.kind == .fan, var fan = sensor.fan {
                fan.percentage = Self.fanPercentage(value: value, maxSpeed: fan.maxSpeed)
                list[index].fan = fan
            }
        }

        if !didDiscover { apply(power: power, to: &list) }
        applyDerivedFigures(to: &list, now: now)
        applyCutoffs(to: &list)

        discovered = list
        return list
    }

    // MARK: - Discovery

    /// One pass over the SMC key list, matched against the catalogue: exact
    /// keys first, then the `%` wildcards, then anything left over as an
    /// unknown reading named after its key. This is Stats' order, and it is
    /// what puts "Airport" above "Disk 1 (A)" in the finished list.
    private func discover(power: EnergyModelPower) -> [SensorReadingValue] {
        var list: [SensorReadingValue] = fans()

        var available = Set(
            smc.allKeyNames().filter { key in
                switch key.first {
                case "T", "V", "P", "I": return true
                default: return false
                }
            })
        let catalogue = SensorCatalog.entries(for: platform)

        for entry in catalogue where !entry.key.contains("%") {
            guard available.contains(entry.key) else { continue }
            available.remove(entry.key)
            list.append(reading(entry, key: entry.key, name: entry.name))
        }

        for entry in catalogue where entry.key.contains("%") {
            var ordinal = 1
            for digit in 0..<10 {
                let key = entry.key.replacingOccurrences(of: "%", with: "\(digit)")
                guard available.contains(key) else { continue }
                available.remove(key)
                let name = entry.name.replacingOccurrences(of: "%", with: "\(ordinal)")
                list.append(reading(entry, key: key, name: name))
                ordinal += 1
            }
        }

        // Whatever the catalogue could not name still gets read, filed under
        // its own key. The panel hides these by default: a four-character code
        // with no meaning is noise until someone goes looking for it.
        for key in available.sorted() {
            guard let kind = Self.kind(forUnknownKey: key) else { continue }
            list.append(
                SensorReadingValue(
                    key: key, name: key, kind: kind, domain: .unknown,
                    value: smc.readValue(named: key) ?? 0))
        }

        list = list.filter { sensor in
            switch sensor.kind {
            case .temperature: return sensor.value != 0 && sensor.value <= 110
            case .current: return sensor.value <= 100
            default: return true
            }
        }

        apply(power: power, to: &list)
        list += derivedFigures(for: list)
        return list
    }

    private func reading(
        _ entry: SensorCatalogEntry, key: String, name: String
    )
        -> SensorReadingValue
    {
        SensorReadingValue(
            key: key, name: name, kind: entry.kind, domain: entry.domain,
            value: smc.readValue(named: key) ?? 0, isCore: entry.average)
    }

    private static func kind(forUnknownKey key: String) -> SensorKind? {
        switch key.first {
        case "T": return .temperature
        case "V": return .voltage
        case "P": return .power
        case "I": return .current
        default: return nil
        }
    }

    // MARK: - Fans

    /// The fans, named by their own `F<n>ID` key where the SMC carries one.
    /// A two-fan Mac with unnamed fans gets Stats' left and right labels.
    private func fans() -> [SensorReadingValue] {
        guard let count = smc.readValue(named: "FNum").map({ Int($0) }), count > 0 else {
            return []
        }
        return (0..<count).map { index in
            let speed = smc.readValue(named: "F\(index)Ac") ?? 0
            let minSpeed = smc.readValue(named: "F\(index)Mn") ?? 1
            let maxSpeed = smc.readValue(named: "F\(index)Mx") ?? 1
            var name = smc.readString(named: "F\(index)ID")
            if name == nil, count == 2 {
                name = index == 0 ? t("Left fan") : t("Right fan")
            }
            return SensorReadingValue(
                key: "F\(index)Ac",
                name: name ?? t("Fan #%@", String(index)),
                kind: .fan, domain: .sensor, value: speed,
                fan: SensorFanFacts(
                    index: index, minSpeed: minSpeed, maxSpeed: maxSpeed,
                    percentage: Self.fanPercentage(value: speed, maxSpeed: maxSpeed)))
        }
    }

    /// Zero unless both figures are a real speed: the SMC reports 1 for a fan
    /// whose range it does not know, and 100% of 1 rpm is not a fact.
    static func fanPercentage(value: Double, maxSpeed: Double) -> Int {
        guard value != 0, maxSpeed != 0, value != 1, maxSpeed != 1 else { return 0 }
        return (100 * Int(value)) / Int(maxSpeed)
    }

    // MARK: - IOReport power rails

    /// The rails and the domain each belongs to, in the order Stats lists them.
    private static let powerRailDomains: [(key: String, domain: SensorDomain)] = [
        ("CPU Power", .cpu), ("GPU Power", .gpu), ("ANE Power", .system),
        ("RAM Power", .system), ("PCI Power", .system),
    ]

    private static func watts(_ key: String, in power: EnergyModelPower) -> Double? {
        switch key {
        case "CPU Power": return power.cpuWatts
        case "GPU Power": return power.gpuWatts
        case "ANE Power": return power.aneWatts
        case "RAM Power": return power.ramWatts
        case "PCI Power": return power.pciWatts
        default: return nil
        }
    }

    /// Update the rails, adding any that were not there yet.
    ///
    /// They have to be able to arrive late. Power is an interval figure, so the
    /// very first sweep has no elapsed time to divide by and carries no rails
    /// at all; discovery happens on that same sweep and is then reused for the
    /// life of the reader. Updating in place only would mean a reader that
    /// started before its first power sample never grew the rows.
    ///
    /// Appending at the end is safe for ordering: the panel groups a section by
    /// domain, so a rail lands in its own domain's bucket wherever it sits in
    /// this list.
    private func apply(power: EnergyModelPower, to list: inout [SensorReadingValue]) {
        for (key, domain) in Self.powerRailDomains {
            guard let watts = Self.watts(key, in: power) else { continue }
            if let index = list.firstIndex(where: { $0.key == key }) {
                list[index].value = watts
            } else {
                list.append(
                    SensorReadingValue(
                        key: key, name: key, kind: .power, domain: domain, value: watts,
                        isComputed: true))
            }
        }
    }

    // MARK: - Derived figures

    /// The rows this app computes rather than reads: the CPU and GPU averages
    /// and maxima across the per-core die sensors, the fastest fan on a
    /// multi-fan Mac, and the accumulated system energy.
    ///
    /// Only the sensors the catalogue marks `average` feed the CPU and GPU
    /// figures. Package and proximity sensors measure the same heat from
    /// further away, so folding them in would drag the average toward the case
    /// temperature.
    private func derivedFigures(for list: [SensorReadingValue]) -> [SensorReadingValue] {
        var result: [SensorReadingValue] = []
        let averageKeys = Self.averageKeys(for: platform)

        for (domain, averageName, hottestName) in [
            (SensorDomain.cpu, "Average CPU", "Hottest CPU"),
            (SensorDomain.gpu, "Average GPU", "Hottest GPU"),
        ] {
            let values = list.filter {
                $0.domain == domain && $0.kind == .temperature && averageKeys.contains($0.key)
            }.map(\.value)
            guard !values.isEmpty else { continue }
            result.append(
                SensorReadingValue(
                    key: averageName, name: averageName, kind: .temperature, domain: domain,
                    value: values.reduce(0, +) / Double(values.count), isComputed: true))
            if let hottest = values.max() {
                result.append(
                    SensorReadingValue(
                        key: hottestName, name: hottestName, kind: .temperature,
                        domain: domain, value: hottest, isComputed: true))
            }
        }

        let fanSensors = list.filter { $0.kind == .fan && !$0.isComputed }
        if fanSensors.count > 1, let fastest = fanSensors.max(by: { $0.value < $1.value }) {
            result.append(
                SensorReadingValue(
                    key: "Fastest fan", name: t("Fastest fan"), kind: .fan, domain: .sensor,
                    value: fastest.value, fan: fastest.fan, isComputed: true))
        }

        // Energy only exists where the machine reports its own total draw.
        if list.contains(where: { $0.key == "PSTR" }) {
            result.append(
                SensorReadingValue(
                    key: "Average System Total", name: "Average System Total", kind: .power,
                    domain: .sensor, value: 0, isComputed: true))
            result.append(
                SensorReadingValue(
                    key: "Total System Consumption", name: "Total System Consumption",
                    kind: .energy, domain: .sensor, value: 0, isComputed: true))
        }

        return result
    }

    private func applyDerivedFigures(to list: inout [SensorReadingValue], now: Date) {
        let averageKeys = Self.averageKeys(for: platform)
        for (domain, averageName, hottestName) in [
            (SensorDomain.cpu, "Average CPU", "Hottest CPU"),
            (SensorDomain.gpu, "Average GPU", "Hottest GPU"),
        ] {
            let values = list.filter {
                $0.domain == domain && $0.kind == .temperature && averageKeys.contains($0.key)
            }.map(\.value)
            guard !values.isEmpty else { continue }
            if let index = list.firstIndex(where: { $0.key == averageName }) {
                list[index].value = values.reduce(0, +) / Double(values.count)
            }
            if let hottest = values.max(),
                let index = list.firstIndex(where: { $0.key == hottestName })
            {
                list[index].value = hottest
            }
        }

        let fanSensors = list.filter { $0.kind == .fan && !$0.isComputed }
        if fanSensors.count > 1, let fastest = fanSensors.max(by: { $0.value < $1.value }),
            let index = list.firstIndex(where: { $0.key == "Fastest fan" })
        {
            list[index].value = fastest.value
            list[index].fan = fastest.fan
        }

        // Integrate the system draw into watt hours, and divide it back out
        // over the run to get the average. The first read only starts the
        // clock: there is no interval to integrate over yet.
        if let total = list.first(where: { $0.key == "PSTR" }), total.value > 0 {
            if let lastRead, let firstRead {
                let sinceLast = now.timeIntervalSince(lastRead)
                if sinceLast > 0 {
                    totalWattHours += total.value * sinceLast / 3600
                    if let index = list.firstIndex(where: {
                        $0.key == "Total System Consumption"
                    }) {
                        list[index].value = totalWattHours
                    }
                    let sinceFirst = now.timeIntervalSince(firstRead)
                    if sinceFirst > 0,
                        let index = list.firstIndex(where: { $0.key == "Average System Total" })
                    {
                        list[index].value = totalWattHours * 3600 / sinceFirst
                    }
                }
            } else {
                firstRead = now
            }
            lastRead = now
        }
    }

    /// The catalogue keys that count toward a domain average on this Mac.
    private static func averageKeys(for platform: SensorPlatform?) -> Set<String> {
        var keys: Set<String> = []
        for entry in SensorCatalog.entries(for: platform) where entry.average {
            if entry.key.contains("%") {
                for digit in 0..<10 {
                    keys.insert(entry.key.replacingOccurrences(of: "%", with: "\(digit)"))
                }
            } else {
                keys.insert(entry.key)
            }
        }
        return keys
    }

    /// Stats' floors for the DC-in rails: on battery the SMC leaves noise on
    /// the charger keys rather than reading zero, and a phantom 0.2 V "DC In"
    /// on an unplugged Mac reads as a fault that is not there.
    private func applyCutoffs(to list: inout [SensorReadingValue]) {
        if let index = list.firstIndex(where: { $0.key == "VD0R" }), list[index].value < 0.4 {
            list[index].value = 0
        }
        if let index = list.firstIndex(where: { $0.key == "ID0R" }), list[index].value < 0.05 {
            list[index].value = 0
        }
    }
}

/// How the sensors panel orders one section's rows.
///
/// Stats groups a section's readings by their domain, in the order the domains
/// first appear in the reader's list, and keeps the reader's order inside each
/// domain. That is what lands the derived "Average CPU" and "Hottest CPU"
/// directly under the CPU cores they summarise, and files the IOReport rails
/// after the SMC power keys instead of interleaved with them.
public enum SensorsPanelOrder {
    /// One block per domain, which is also what a reader's eye wants: the CPU
    /// cores are one thing to scan, the GPU clusters another, and the machine's
    /// own sensors a third. A panel can put air between the blocks; a flat list
    /// can just concatenate them.
    public static func grouped(_ readings: [SensorReadingValue]) -> [[SensorReadingValue]] {
        var domains: [SensorDomain] = []
        for reading in readings where !domains.contains(reading.domain) {
            domains.append(reading.domain)
        }
        return domains.map { domain in readings.filter { $0.domain == domain } }
    }

    public static func sorted(_ readings: [SensorReadingValue]) -> [SensorReadingValue] {
        grouped(readings).flatMap { $0 }
    }
}
