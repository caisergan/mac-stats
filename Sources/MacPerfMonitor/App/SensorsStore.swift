import Foundation
import MacPerfMonitorCore

/// The machine's live sensor list, shared by the sensors panel, the menu bar
/// read-out and Settings.
///
/// One queue-confined `SensorsReader` behind an observable snapshot, in the
/// shape of `SensorLiveStore` on the Hardware tab. A single store rather than
/// one per surface: the first sweep pays SMC key discovery, and the derived
/// energy total is an integral over the run, so it has to be the same reader
/// every time or the figure resets whenever a panel closes.
///
/// Sweeps only happen when something is watching: a surface asks with
/// `refreshIfDue`, and the interval it passes is how fresh that surface needs
/// the numbers to be.
/// One block of the sensors panel: a heading, the rows under it, and the unit
/// the heading states on their behalf.
struct SensorSection: Identifiable {
    var title: String
    /// The unit every row in this section shares, stated once in the heading so
    /// no row repeats it. Nil when the section mixes units, and then the rows
    /// carry their own.
    var unit: String?
    /// Per-domain blocks, so the panel can put air between them.
    var blocks: [[SensorReadingValue]]
    /// Whether this section offers the switch between core averages and every
    /// core.
    var showsCoreSwitch: Bool

    var id: String { title }
}

@MainActor
final class SensorsStore: ObservableObject {
    static let shared = SensorsStore()

    static let menuBarKeysDefaultsKey = "sensorsMenuBarKeys"
    static let showsAllCoresDefaultsKey = "sensorsShowsAllCores"

    /// Every reading of the latest sweep, in panel order.
    @Published private(set) var readings: [SensorReadingValue] = []

    /// The keys the user put in the menu bar, in the order they picked them.
    /// Order is the user's: it is the order the cells are drawn in.
    @Published private(set) var menuBarKeys: [String]

    /// Whether the panel lists every per-core die sensor, or just the averages
    /// that summarise them. Off by default: a modern chip reports twenty-odd
    /// cores that track each other within a degree or two, so listing them all
    /// buries the sensors that say something distinct.
    @Published var showsAllCores: Bool {
        didSet { defaults.set(showsAllCores, forKey: Self.showsAllCoresDefaultsKey) }
    }

    private let defaults: UserDefaults
    private let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.sensors", qos: .utility)
    /// Both are touched only inside `queue.async`, never on the main actor, so
    /// the isolation is the queue's rather than the actor's.
    private nonisolated(unsafe) let reader = SensorsReader()
    private nonisolated(unsafe) let powerReader = EnergyModelPowerReader()

    private var lastSweep: Date?
    private var inFlight = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.menuBarKeys = defaults.stringArray(forKey: Self.menuBarKeysDefaultsKey) ?? []
        self.showsAllCores = defaults.bool(forKey: Self.showsAllCoresDefaultsKey)
    }

    /// The readings the user chose for the menu bar, in their chosen order,
    /// skipping any whose key has gone (a fan that stopped being reported, a
    /// key that only exists while plugged in).
    var menuBarReadings: [SensorReadingValue] {
        menuBarKeys.compactMap { key in readings.first { $0.key == key } }
    }

    var hasMenuBarSelection: Bool { !menuBarKeys.isEmpty }

    func isInMenuBar(_ key: String) -> Bool { menuBarKeys.contains(key) }

    func setInMenuBar(_ key: String, _ included: Bool) {
        if included {
            guard !menuBarKeys.contains(key) else { return }
            menuBarKeys.append(key)
        } else {
            menuBarKeys.removeAll { $0 == key }
        }
        defaults.set(menuBarKeys, forKey: Self.menuBarKeysDefaultsKey)
    }

    /// Whether this Mac reports per-core sensors at all, so the panel only
    /// offers to expand them where there is something to expand.
    var hasCoreReadings: Bool { readings.contains(where: \.isCore) }

    /// The panel's sections, each split into its per-domain blocks so the panel
    /// can put air between the CPU cores, the GPU clusters and the machine's
    /// own sensors.
    ///
    /// Volts and amps join the watts rather than standing as sections of their
    /// own. They are the two halves of the power beside them, and a Mac reports
    /// so few of them (two rails and one current, here) that three separate
    /// headings cost more room than the rows they introduce. They sit below the
    /// watts, which are the figures a reader came for.
    ///
    /// Two things are left out. The keys the catalogue could not name are never
    /// listed: a four-character code with no meaning is noise in a panel, and
    /// `macperfmonitor-cli sensors --unknown` is where to go looking for them.
    /// The per-core sensors are folded into their averages unless the user
    /// asked for them.
    func sections() -> [SensorSection] {
        let visible = readings.filter {
            $0.domain != .unknown && (showsAllCores || !$0.isCore)
        }
        func blocks(_ kinds: [SensorKind]) -> [[SensorReadingValue]] {
            kinds.flatMap { kind in
                SensorsPanelOrder.grouped(visible.filter { $0.kind == kind })
            }
        }

        var sections: [SensorSection] = []
        func add(
            _ title: String, _ unit: String?, _ blocks: [[SensorReadingValue]],
            showsCoreSwitch: Bool = false
        ) {
            guard !blocks.isEmpty else { return }
            sections.append(
                SensorSection(
                    title: title, unit: unit, blocks: blocks, showsCoreSwitch: showsCoreSwitch))
        }

        add(SensorKind.fan.sectionTitle, SensorKind.fan.unit, blocks([.fan]))
        add(
            SensorKind.temperature.sectionTitle, SensorKind.temperature.unit,
            blocks([.temperature]), showsCoreSwitch: hasCoreReadings)

        let electrical = blocks([.power, .voltage, .current])
        // The heading keeps its unit on a Mac that reports watts alone, and
        // gives it up as soon as the section mixes them.
        let kinds = Set(electrical.flatMap { $0 }.map(\.kind))
        add(
            SensorKind.power.sectionTitle,
            kinds.count > 1 ? nil : kinds.first?.unit, electrical)

        add(SensorKind.energy.sectionTitle, SensorKind.energy.unit, blocks([.energy]))
        return sections
    }

    /// Sweep the SMC if `minInterval` has passed. The panel asks for a tight
    /// interval while it is open; the menu bar asks on its own refresh cycle.
    func refreshIfDue(now: Date = Date(), floor minInterval: TimeInterval = 2) {
        if let lastSweep, now.timeIntervalSince(lastSweep) < minInterval { return }
        guard !inFlight else { return }
        inFlight = true
        lastSweep = now
        queue.async { [weak self] in
            guard let self else { return }
            let power = self.powerReader.read(now: now) ?? EnergyModelPower()
            let readings = self.reader.read(now: now, power: power)
            DispatchQueue.main.async {
                self.inFlight = false
                self.readings = readings
            }
        }
    }
}
