import Foundation

/// The SMC sensor catalogue, ported from Stats (github.com/exelban/stats, MIT).
///
/// The SMC exposes four-character keys with no self-description: `Tp0O` is a
/// number, not a name. Stats carries a hand-maintained table that turns those
/// keys into readable names, and that table is what makes a sensor list worth
/// showing. It is reproduced here key for key, including the per-generation
/// splits: the same key means different silicon on different chips (`Tp01` is
/// a performance core on M2 and M4, and is not in the M5 table at all), so the
/// table is filtered by the running Mac's platform before anything is named.
///
/// Original key list: github.com/acidanthera/VirtualSMC (Docs/SMCSensorKeys.txt).

/// What a sensor measures. Drives the unit, the formatting and the section a
/// reading is filed under.
public enum SensorKind: String, Sendable, Codable, CaseIterable {
    case fan
    case temperature
    case voltage
    case current
    case power
    case energy

    /// The unit written after the figure.
    public var unit: String {
        switch self {
        case .temperature: return "\u{00B0}C"
        case .voltage: return "V"
        case .current: return "A"
        case .power: return "W"
        case .energy: return "Wh"
        case .fan: return "RPM"
        }
    }

    /// The section heading in the sensors panel, in the order Stats lists them.
    public var sectionTitle: String {
        switch self {
        case .fan: return t("Fans")
        case .temperature: return t("Temperature")
        case .voltage: return t("Voltage")
        case .current: return t("Current")
        case .power: return t("Power")
        case .energy: return t("Energy")
        }
    }

    /// Panel order: fans first, then the electrical chain.
    public static let displayOrder: [SensorKind] = [
        .fan, .temperature, .voltage, .current, .power, .energy,
    ]
}

/// Which part of the machine a sensor belongs to. Only used to compute the
/// per-domain averages (average and hottest CPU, average and hottest GPU).
public enum SensorDomain: String, Sendable, Codable {
    case cpu
    case gpu
    case system
    case sensor
    case unknown
}

/// The Apple silicon generation, resolved from the CPU brand string.
///
/// Sensor keys are only stable within a generation, so naming a key correctly
/// means knowing which chip is reading it. Mirrors Stats' `Platform`.
public enum SensorPlatform: String, Sendable, CaseIterable {
    case intel
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    case m4, m4Pro, m4Max, m4Ultra
    case m5, m5Pro, m5Max, m5Ultra

    public static let m1Gen: [SensorPlatform] = [.m1, .m1Pro, .m1Max, .m1Ultra]
    public static let m2Gen: [SensorPlatform] = [.m2, .m2Pro, .m2Max, .m2Ultra]
    public static let m3Gen: [SensorPlatform] = [.m3, .m3Pro, .m3Max, .m3Ultra]
    public static let m4Gen: [SensorPlatform] = [.m4, .m4Pro, .m4Max, .m4Ultra]
    public static let m5Gen: [SensorPlatform] = [.m5, .m5Pro, .m5Max, .m5Ultra]
    public static let apple: [SensorPlatform] = m1Gen + m2Gen + m3Gen + m4Gen + m5Gen
    public static let all: [SensorPlatform] = apple + [.intel]

    /// This Mac, or nil when the brand string names a chip the table has never
    /// seen. Nil means "do not filter": an unknown chip gets the whole table
    /// tried against its actual key set, which is the honest fallback.
    public static let current: SensorPlatform? = resolve(
        Sysctl.string("machdep.cpu.brand_string"))

    static func resolve(_ brand: String?) -> SensorPlatform? {
        guard let name = brand?.lowercased() else { return nil }
        if name.contains("intel") { return .intel }
        // Ordered newest first so "m1" never matches inside a longer name.
        let families: [(String, [SensorPlatform])] = [
            ("m5", m5Gen), ("m4", m4Gen), ("m3", m3Gen), ("m2", m2Gen), ("m1", m1Gen),
        ]
        for (needle, generation) in families where name.contains(needle) {
            if name.contains("ultra") { return generation[3] }
            if name.contains("max") { return generation[2] }
            if name.contains("pro") { return generation[1] }
            return generation[0]
        }
        return nil
    }
}

/// One row of the catalogue: an SMC key and what it means.
///
/// A `%` in the key is a placeholder for a digit, expanded 0 through 9 against
/// the keys the SMC actually reports, with the matching `%` in the name
/// replaced by a 1-based counter (so `TA%P` becomes "Ambient 1", "Ambient 2").
struct SensorCatalogEntry: Sendable {
    var key: String
    var name: String
    var domain: SensorDomain
    var kind: SensorKind
    var platforms: [SensorPlatform]
    /// Whether the reading counts toward its domain's average and hottest
    /// figures. Only the per-core die sensors do: package and proximity
    /// sensors would double-count the same heat.
    var average: Bool = false

    init(
        _ key: String, _ name: String, _ domain: SensorDomain, _ kind: SensorKind,
        _ platforms: [SensorPlatform], average: Bool = false
    ) {
        self.key = key
        self.name = name
        self.domain = domain
        self.kind = kind
        self.platforms = platforms
        self.average = average
    }
}

enum SensorCatalog {
    /// The entries that can apply to `platform`, or all of them when the chip
    /// is unrecognised.
    static func entries(for platform: SensorPlatform?) -> [SensorCatalogEntry] {
        guard let platform else { return all }
        return all.filter { $0.platforms.contains(platform) }
    }

    static let all: [SensorCatalogEntry] = temperature + voltage + current + power

    private static let temperature: [SensorCatalogEntry] = [
        SensorCatalogEntry("TA%P", "Ambient %", .sensor, .temperature, SensorPlatform.all),
        SensorCatalogEntry("Th%H", "Heatpipe %", .sensor, .temperature, [.intel]),
        SensorCatalogEntry("TZ%C", "Thermal zone %", .sensor, .temperature, SensorPlatform.all),

        // DEVIATION from Stats: the Intel-era CPU and GPU keys are marked
        // Intel only here, where Stats offers them on every platform. Apple
        // silicon has no CPU diode and no discrete GPU, and on an M5 `TG0H`
        // ("GPU heatsink") is a live SMC key holding a frozen 34.0: it does
        // not move while the GPU dies climb 15 degrees under load. Stats never
        // shows it because its SMC decoder has no `ioft` case and the read
        // fails; this app's decoder does read `ioft`, so the placeholder has to
        // be excluded on purpose rather than by accident.
        SensorCatalogEntry("TC0D", "CPU diode", .cpu, .temperature, [.intel]),
        SensorCatalogEntry("TC0E", "CPU diode virtual", .cpu, .temperature, [.intel]),
        SensorCatalogEntry("TC0F", "CPU diode filtered", .cpu, .temperature, [.intel]),
        SensorCatalogEntry("TC0H", "CPU heatsink", .cpu, .temperature, [.intel]),
        SensorCatalogEntry("TC0P", "CPU proximity", .cpu, .temperature, [.intel]),
        SensorCatalogEntry("TCAD", "CPU package", .cpu, .temperature, [.intel]),

        SensorCatalogEntry("TC%c", "CPU core %", .cpu, .temperature, [.intel], average: true),
        SensorCatalogEntry("TC%C", "CPU Core %", .cpu, .temperature, [.intel], average: true),

        SensorCatalogEntry("TCGC", "GPU Intel Graphics", .gpu, .temperature, [.intel]),
        SensorCatalogEntry("TG0D", "GPU diode", .gpu, .temperature, [.intel]),
        SensorCatalogEntry("TGDD", "GPU AMD Radeon", .gpu, .temperature, [.intel]),
        SensorCatalogEntry("TG0H", "GPU heatsink", .gpu, .temperature, [.intel]),
        SensorCatalogEntry("TG0P", "GPU proximity", .gpu, .temperature, [.intel]),

        SensorCatalogEntry("Tm0P", "Mainboard", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("Tp0P", "Powerboard", .system, .temperature, [.intel]),
        SensorCatalogEntry("TB1T", "Battery", .system, .temperature, [.intel]),
        SensorCatalogEntry("TW0P", "Airport", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("TL0P", "Display", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("TI%P", "Thunderbolt %", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("TH%A", "Disk % (A)", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("TH%B", "Disk % (B)", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("TH%C", "Disk % (C)", .system, .temperature, SensorPlatform.all),

        SensorCatalogEntry("TTLD", "Thunderbolt left", .system, .temperature, SensorPlatform.all),
        SensorCatalogEntry("TTRD", "Thunderbolt right", .system, .temperature, SensorPlatform.all),

        // Also Intel only: Apple silicon has no northbridge.
        SensorCatalogEntry("TN0D", "Northbridge diode", .system, .temperature, [.intel]),
        SensorCatalogEntry("TN0H", "Northbridge heatsink", .system, .temperature, [.intel]),
        SensorCatalogEntry("TN0P", "Northbridge proximity", .system, .temperature, [.intel]),

        // M1
        SensorCatalogEntry(
            "Tp09", "CPU efficiency core 1", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0T", "CPU efficiency core 2", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp01", "CPU performance core 1", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp05", "CPU performance core 2", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0D", "CPU performance core 3", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0H", "CPU performance core 4", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0L", "CPU performance core 5", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0P", "CPU performance core 6", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0X", "CPU performance core 7", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0b", "CPU performance core 8", .cpu, .temperature, SensorPlatform.m1Gen,
            average: true),

        SensorCatalogEntry(
            "Tg05", "GPU 1", .gpu, .temperature, SensorPlatform.m1Gen, average: true),
        SensorCatalogEntry(
            "Tg0D", "GPU 2", .gpu, .temperature, SensorPlatform.m1Gen, average: true),
        SensorCatalogEntry(
            "Tg0L", "GPU 3", .gpu, .temperature, SensorPlatform.m1Gen, average: true),
        SensorCatalogEntry(
            "Tg0T", "GPU 4", .gpu, .temperature, SensorPlatform.m1Gen, average: true),

        SensorCatalogEntry("Tm02", "Memory 1", .sensor, .temperature, SensorPlatform.m1Gen),
        SensorCatalogEntry("Tm06", "Memory 2", .sensor, .temperature, SensorPlatform.m1Gen),
        SensorCatalogEntry("Tm08", "Memory 3", .sensor, .temperature, SensorPlatform.m1Gen),
        SensorCatalogEntry("Tm09", "Memory 4", .sensor, .temperature, SensorPlatform.m1Gen),

        // M2
        SensorCatalogEntry(
            "Tp1h", "CPU efficiency core 1", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp1t", "CPU efficiency core 2", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp1p", "CPU efficiency core 3", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp1l", "CPU efficiency core 4", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),

        SensorCatalogEntry(
            "Tp01", "CPU performance core 1", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp05", "CPU performance core 2", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp09", "CPU performance core 3", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0D", "CPU performance core 4", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0X", "CPU performance core 5", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0b", "CPU performance core 6", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0f", "CPU performance core 7", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0j", "CPU performance core 8", .cpu, .temperature, SensorPlatform.m2Gen,
            average: true),

        SensorCatalogEntry(
            "Tg0f", "GPU 1", .gpu, .temperature, SensorPlatform.m2Gen, average: true),
        SensorCatalogEntry(
            "Tg0j", "GPU 2", .gpu, .temperature, SensorPlatform.m2Gen, average: true),

        // M3
        SensorCatalogEntry(
            "Te05", "CPU efficiency core 1", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Te0L", "CPU efficiency core 2", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Te0P", "CPU efficiency core 3", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Te0S", "CPU efficiency core 4", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),

        SensorCatalogEntry(
            "Tf04", "CPU performance core 1", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf09", "CPU performance core 2", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf0A", "CPU performance core 3", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf0B", "CPU performance core 4", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf0D", "CPU performance core 5", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf0E", "CPU performance core 6", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf44", "CPU performance core 7", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf49", "CPU performance core 8", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf4A", "CPU performance core 9", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf4B", "CPU performance core 10", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf4D", "CPU performance core 11", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),
        SensorCatalogEntry(
            "Tf4E", "CPU performance core 12", .cpu, .temperature, SensorPlatform.m3Gen,
            average: true),

        SensorCatalogEntry(
            "Tf14", "GPU 1", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf18", "GPU 2", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf19", "GPU 3", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf1A", "GPU 4", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf24", "GPU 5", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf28", "GPU 6", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf29", "GPU 7", .gpu, .temperature, SensorPlatform.m3Gen, average: true),
        SensorCatalogEntry(
            "Tf2A", "GPU 8", .gpu, .temperature, SensorPlatform.m3Gen, average: true),

        // M4
        SensorCatalogEntry(
            "Te05", "CPU efficiency core 1", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Te0S", "CPU efficiency core 2", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Te09", "CPU efficiency core 3", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Te0H", "CPU efficiency core 4", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),

        SensorCatalogEntry(
            "Tp01", "CPU performance core 1", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp05", "CPU performance core 2", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp09", "CPU performance core 3", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0D", "CPU performance core 4", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0V", "CPU performance core 5", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0Y", "CPU performance core 6", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0b", "CPU performance core 7", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0e", "CPU performance core 8", .cpu, .temperature, SensorPlatform.m4Gen,
            average: true),

        SensorCatalogEntry("Tg0G", "GPU 1", .gpu, .temperature, [.m4], average: true),
        SensorCatalogEntry("Tg0H", "GPU 2", .gpu, .temperature, [.m4], average: true),
        SensorCatalogEntry(
            "Tg1U", "GPU 1", .gpu, .temperature, [.m4Pro, .m4Max, .m4Ultra], average: true),
        SensorCatalogEntry(
            "Tg1k", "GPU 2", .gpu, .temperature, [.m4Pro, .m4Max, .m4Ultra], average: true),

        SensorCatalogEntry(
            "Tg0K", "GPU 3", .gpu, .temperature, SensorPlatform.m4Gen, average: true),
        SensorCatalogEntry(
            "Tg0L", "GPU 4", .gpu, .temperature, SensorPlatform.m4Gen, average: true),
        SensorCatalogEntry(
            "Tg0d", "GPU 5", .gpu, .temperature, SensorPlatform.m4Gen, average: true),
        SensorCatalogEntry(
            "Tg0e", "GPU 6", .gpu, .temperature, SensorPlatform.m4Gen, average: true),
        SensorCatalogEntry(
            "Tg0j", "GPU 7", .gpu, .temperature, SensorPlatform.m4Gen, average: true),
        SensorCatalogEntry(
            "Tg0k", "GPU 8", .gpu, .temperature, SensorPlatform.m4Gen, average: true),

        SensorCatalogEntry(
            "Tm0p", "Memory Proximity 1", .sensor, .temperature, SensorPlatform.m4Gen),
        SensorCatalogEntry(
            "Tm1p", "Memory Proximity 2", .sensor, .temperature, SensorPlatform.m4Gen),
        SensorCatalogEntry(
            "Tm2p", "Memory Proximity 3", .sensor, .temperature, SensorPlatform.m4Gen),

        // M5
        SensorCatalogEntry(
            "Tp00", "CPU super core 1", .cpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tp04", "CPU super core 2", .cpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tp08", "CPU super core 3", .cpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tp0C", "CPU super core 4", .cpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tp0G", "CPU super core 5", .cpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tp0K", "CPU super core 6", .cpu, .temperature, SensorPlatform.m5Gen, average: true),

        SensorCatalogEntry(
            "Tp0O", "CPU performance core 1", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0R", "CPU performance core 2", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0U", "CPU performance core 3", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0X", "CPU performance core 4", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0a", "CPU performance core 5", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0d", "CPU performance core 6", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0g", "CPU performance core 7", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0j", "CPU performance core 8", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0m", "CPU performance core 9", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0p", "CPU performance core 10", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0u", "CPU performance core 11", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),
        SensorCatalogEntry(
            "Tp0y", "CPU performance core 12", .cpu, .temperature, SensorPlatform.m5Gen,
            average: true),

        SensorCatalogEntry(
            "Tg0U", "GPU 1", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg0X", "GPU 2", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg0d", "GPU 3", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg0g", "GPU 4", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg0j", "GPU 5", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg1Y", "GPU 6", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg1c", "GPU 7", .gpu, .temperature, SensorPlatform.m5Gen, average: true),
        SensorCatalogEntry(
            "Tg1g", "GPU 8", .gpu, .temperature, SensorPlatform.m5Gen, average: true),

        // Apple silicon, all generations
        SensorCatalogEntry(
            "TaLP", "Airflow left", .sensor, .temperature, SensorPlatform.apple),
        SensorCatalogEntry(
            "TaRF", "Airflow right", .sensor, .temperature, SensorPlatform.apple),

        SensorCatalogEntry("TH0x", "NAND", .system, .temperature, SensorPlatform.apple),
        SensorCatalogEntry("TB1T", "Battery 1", .system, .temperature, SensorPlatform.apple),
        SensorCatalogEntry("TB2T", "Battery 2", .system, .temperature, SensorPlatform.apple),
        SensorCatalogEntry("TW0P", "Airport", .system, .temperature, SensorPlatform.apple),
    ]

    private static let voltage: [SensorCatalogEntry] = [
        SensorCatalogEntry("VCAC", "CPU IA", .cpu, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VCSC", "CPU System Agent", .cpu, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VC%C", "CPU Core %", .cpu, .voltage, SensorPlatform.all),

        SensorCatalogEntry("VCTC", "GPU Intel Graphics", .gpu, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VG0C", "GPU", .gpu, .voltage, SensorPlatform.all),

        SensorCatalogEntry("VM0R", "Memory", .system, .voltage, SensorPlatform.all),
        SensorCatalogEntry("Vb0R", "CMOS", .system, .voltage, SensorPlatform.all),

        SensorCatalogEntry("VD0R", "DC In", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VP0R", "12V rail", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("Vp0C", "12V vcc", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VV2S", "3V", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VR3R", "3.3V", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VV1S", "5V", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VV9S", "12V", .sensor, .voltage, SensorPlatform.all),
        SensorCatalogEntry("VeES", "PCI 12V", .sensor, .voltage, SensorPlatform.all),
    ]

    private static let current: [SensorCatalogEntry] = [
        SensorCatalogEntry("IC0R", "CPU High side", .sensor, .current, SensorPlatform.all),
        SensorCatalogEntry("IG0R", "GPU High side", .sensor, .current, SensorPlatform.all),
        SensorCatalogEntry("ID0R", "DC In", .sensor, .current, SensorPlatform.all),
        SensorCatalogEntry("IBAC", "Battery", .sensor, .current, SensorPlatform.all),
        SensorCatalogEntry("IDBR", "Brightness", .sensor, .current, SensorPlatform.all),
        SensorCatalogEntry("IU1R", "Thunderbolt Left", .sensor, .current, SensorPlatform.all),
        SensorCatalogEntry("IU2R", "Thunderbolt Right", .sensor, .current, SensorPlatform.all),
    ]

    private static let power: [SensorCatalogEntry] = [
        SensorCatalogEntry("PC0C", "CPU Core", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCAM", "CPU Core (IMON)", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCPC", "CPU Package", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCTR", "CPU Total", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCPT", "CPU Package total", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCPR", "CPU Package total (SMC)", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry(
            "PC0R", "CPU Computing high side", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PC0G", "CPU GFX", .cpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCEC", "CPU VccEDRAM", .cpu, .power, SensorPlatform.all),

        SensorCatalogEntry("PCPG", "GPU Intel Graphics", .gpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PG0C", "GPU", .gpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PG0R", "GPU 1", .gpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PG1R", "GPU 2", .gpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCGC", "Intel GPU", .gpu, .power, SensorPlatform.all),
        SensorCatalogEntry("PCGM", "Intel GPU (IMON)", .gpu, .power, SensorPlatform.all),

        SensorCatalogEntry("PC3C", "RAM", .sensor, .power, SensorPlatform.all),
        SensorCatalogEntry("PPBR", "Battery", .sensor, .power, SensorPlatform.all),
        SensorCatalogEntry("PDTR", "DC In", .sensor, .power, SensorPlatform.all),
        SensorCatalogEntry("PMTR", "Memory Total", .sensor, .power, SensorPlatform.all),
        SensorCatalogEntry("PSTR", "System Total", .sensor, .power, SensorPlatform.all),

        SensorCatalogEntry("PU1R", "Thunderbolt Left", .sensor, .power, SensorPlatform.all),
        SensorCatalogEntry("PU2R", "Thunderbolt Right", .sensor, .power, SensorPlatform.all),

        SensorCatalogEntry(
            "PDBR", "Power Delivery Brightness", .sensor, .power,
            [.m1, .m1Pro, .m1Max, .m1Ultra, .m4, .m4Pro, .m4Max, .m4Ultra]),
    ]
}
