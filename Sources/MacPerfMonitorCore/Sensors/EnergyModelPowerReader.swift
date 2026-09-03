import Foundation

/// The IOReport "Energy Model" rails as the sensors panel wants them.
///
/// A thin public face on the same reader the GPU sampling path uses. The
/// sensors surface subscribes for itself rather than riding the sampler's
/// cadence, so its rows keep updating whether or not a GPU surface happens to
/// be open, and the subscription goes away with the surface.
///
/// Power is an interval figure: the counters are monotonic energy, so the
/// first read has nothing to difference against and returns nil.
public final class EnergyModelPowerReader {
    private let reader = PowerReader()

    public init() {}

    public func read(now: Date = Date()) -> EnergyModelPower? {
        guard let sample = reader.read(now: now) else { return nil }
        return EnergyModelPower(
            cpuWatts: sample.cpuWatts, gpuWatts: sample.gpuWatts, aneWatts: sample.aneWatts,
            ramWatts: sample.ramWatts, pciWatts: sample.pciWatts)
    }
}
