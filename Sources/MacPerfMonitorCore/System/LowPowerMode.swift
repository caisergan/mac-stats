import Foundation

/// Whether Low Power Mode is on, read from the active power-management
/// preferences: the same source `pmset -g` reads.
///
/// Deliberately not `ProcessInfo.processInfo.isLowPowerModeEnabled`. That
/// property is a cached value, refreshed only when the process observes
/// `NSProcessInfoPowerStateDidChange`; a long-running app that does not
/// observe keeps reporting whatever was true when it first asked. This app
/// sampled it every tick and still tinted the battery orange hours after Low
/// Power Mode had been switched off, because every one of those reads returned
/// the same stale answer.
///
/// The setting is per power source (macOS offers "Only on Battery", "Only on
/// Power Adapter" and "Always"), so the answer is the entry for whichever
/// source is currently providing power.
enum LowPowerMode {
    /// The current state, cached briefly: this is read once per sample and the
    /// preferences copy is a round trip into powerd, which is not worth
    /// repeating every second for a setting that changes by hand. The caller
    /// passes the power source it has already determined, so this does not
    /// query it a second time.
    static func isEnabled(onBattery: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let cached, cached.onBattery == onBattery,
            now.timeIntervalSince(cached.read) < cacheInterval
        {
            return cached.value
        }
        let value = readNow(onBattery: onBattery)
        cached = (value: value, onBattery: onBattery, read: now)
        return value
    }

    /// The preferences pick, split out from the reading so it can be tested
    /// without a machine in a particular power state.
    static func enabled(in preferences: [String: Any], source: String) -> Bool? {
        guard let domain = preferences[source] as? [String: Any] else { return nil }
        guard let raw = domain["LowPowerMode"] as? NSNumber else { return nil }
        return raw.boolValue
    }

    /// The domain name the preferences use for the source currently supplying
    /// power. These are `pmset`'s own names.
    static let batteryDomain = "Battery Power"
    static let acDomain = "AC Power"

    private static let cacheInterval: TimeInterval = 2
    private static let lock = NSLock()
    private static var cached: (value: Bool, onBattery: Bool, read: Date)?

    /// `IOPMCopyActivePMPreferences` is declared in IOKit's headers but is not
    /// in the Swift module map, so it is resolved at runtime the way this
    /// project resolves the IOReport calls. If it cannot be resolved the stale
    /// property is still better than nothing.
    private typealias CopyPreferencesFn = @convention(c) () -> Unmanaged<CFMutableDictionary>?
    private static let copyPreferences: CopyPreferencesFn? = {
        guard
            let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2), "IOPMCopyActivePMPreferences")
        else { return nil }
        return unsafeBitCast(symbol, to: CopyPreferencesFn.self)
    }()

    private static func readNow(onBattery: Bool) -> Bool {
        guard let copyPreferences,
            let preferences = copyPreferences()?.takeRetainedValue() as? [String: Any]
        else {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        let source = onBattery ? batteryDomain : acDomain
        // Fall back to the other domain rather than to false: a Mac set to
        // "Always" has the flag in both, and a missing entry means the machine
        // does not report that domain, not that the mode is off.
        return enabled(in: preferences, source: source)
            ?? enabled(in: preferences, source: source == batteryDomain ? acDomain : batteryDomain)
            ?? ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
