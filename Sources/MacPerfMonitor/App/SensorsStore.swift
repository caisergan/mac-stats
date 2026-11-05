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
@MainActor
final class SensorsStore: ObservableObject {
    static let shared = SensorsStore()

    static let menuBarKeysDefaultsKey = "sensorsMenuBarKeys"

    /// Every reading of the latest sweep, in panel order.
    @Published private(set) var readings: [SensorReadingValue] = []

    /// The keys the user put in the menu bar, in the order they picked them.
    /// Order is the user's: it is the order the cells are drawn in.
    @Published private(set) var menuBarKeys: [String]

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
