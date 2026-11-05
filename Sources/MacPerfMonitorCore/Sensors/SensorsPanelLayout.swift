import Foundation

/// The machine's sensors sorted into the sensors panel's places, so the readings
/// that answer the first questions lead and the rest are a glance away:
/// how much power, how hot at the hottest, how fast the fans. Pure, so the
/// sorting can be checked against any Mac's sensor set, not only the one running
/// the tests.
///
/// Every shown reading lands in exactly one place. The keys the catalogue could
/// not name are left out: a four-character code with no meaning is noise in a
/// panel, and `macperfmonitor-cli sensors --unknown` is where to go looking.
public struct SensorsPanelLayout: Sendable, Equatable {
    /// The whole machine's draw, the panel's headline.
    public var systemTotal: SensorReadingValue?
    /// Hottest CPU and hottest GPU.
    public var hottest: [SensorReadingValue] = []
    public var fans: [SensorReadingValue] = []
    public var cpuAverage: SensorReadingValue?
    public var gpuAverage: SensorReadingValue?
    /// The per-core die sensors, which track each other closely enough that the
    /// panel keeps them folded behind their average until asked.
    public var cpuCores: [SensorReadingValue] = []
    public var gpuCores: [SensorReadingValue] = []
    /// Every other temperature, hottest first, so a hot spot leads.
    public var otherTemperatures: [SensorReadingValue] = []
    /// What feeds the machine: charger and battery power, then the rails.
    public var supply: [SensorReadingValue] = []
    /// What consumes it: the CPU, GPU and other rails, highest first.
    public var components: [SensorReadingValue] = []
    /// The running totals: the average draw and the accumulated energy.
    public var totals: [SensorReadingValue] = []

    public init(readings: [SensorReadingValue]) {
        for reading in readings where reading.domain != .unknown {
            switch reading.kind {
            case .fan:
                fans.append(reading)
            case .temperature:
                place(temperature: reading)
            case .power:
                place(power: reading)
            case .voltage, .current:
                supply.append(reading)
            case .energy:
                totals.append(reading)
            }
        }
        otherTemperatures.sort { $0.value > $1.value }
        components.sort { $0.value > $1.value }
        // Watts lead the supply column, biggest first, ahead of the rails that
        // explain them.
        let watts = supply.filter { $0.kind == .power }.sorted { $0.value > $1.value }
        supply = watts + supply.filter { $0.kind != .power }
    }

    private mutating func place(temperature reading: SensorReadingValue) {
        // By name, not key: only the derived readings have a key that says what
        // they are, and an SMC reading's key is its four-character code.
        switch reading.name {
        case "Hottest CPU", "Hottest GPU": hottest.append(reading)
        case "Average CPU": cpuAverage = reading
        case "Average GPU": gpuAverage = reading
        default:
            if reading.isCore, reading.domain == .cpu {
                cpuCores.append(reading)
            } else if reading.isCore, reading.domain == .gpu {
                gpuCores.append(reading)
            } else {
                otherTemperatures.append(reading)
            }
        }
    }

    private mutating func place(power reading: SensorReadingValue) {
        if reading.name == "System Total" {
            systemTotal = reading
        } else if reading.name == "Average System Total" {
            totals.insert(reading, at: 0)
        } else if reading.isComputed, reading.name.hasSuffix(" Power") {
            components.append(reading)
        } else {
            supply.append(reading)
        }
    }

    /// A component's name without the unit word its column already states:
    /// "CPU Power" reads as "CPU" under a Components heading.
    public static func componentLabel(_ name: String) -> String {
        name.hasSuffix(" Power") ? String(name.dropLast(" Power".count)) : name
    }

    /// A supply reading's label. A Mac reports "DC In" as power, voltage and
    /// current under one name, so the rails say which they are; `kindName` is the
    /// kind's localised name, since this layer has no strings of its own.
    public func supplyLabel(_ reading: SensorReadingValue, kindName: String) -> String {
        let shared = supply.contains { $0.name == reading.name && $0.kind != reading.kind }
        guard shared, reading.kind != .power else { return reading.name }
        return "\(reading.name) \(kindName.lowercased())"
    }

    /// A core's short label for its tile: "CPU super core 4" is S4, "CPU
    /// performance core 10" is P10, "CPU efficiency core 2" is E2. A name with
    /// no cluster keeps just its number ("GPU 5" is 5), and one with no number
    /// keeps its leading characters, so an unexpected name still labels a tile.
    public static func coreLabel(_ name: String) -> String {
        let words = name.split(separator: " ").map(String.init)
        let number = words.last { Int($0) != nil }
        let cluster: String
        if words.contains("super") {
            cluster = "S"
        } else if words.contains("performance") {
            cluster = "P"
        } else if words.contains("efficiency") {
            cluster = "E"
        } else {
            cluster = ""
        }
        if let number { return cluster + number }
        return String(name.prefix(3))
    }
}
