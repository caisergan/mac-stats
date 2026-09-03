import Foundation
import MacPerfMonitorCore

/// `macperfmonitor-cli sensors`: print the machine's full sensor inventory the
/// way the app's sensors panel groups it. Two sweeps a second apart, so the
/// IOReport power rails have an interval to average over.
func runSensors(arguments: [String]) {
    let showUnknown = arguments.contains("--unknown")
    let reader = SensorsReader()
    let power = EnergyModelPowerReader()

    _ = power.read()
    _ = reader.read()
    Thread.sleep(forTimeInterval: 1)
    let readings = reader.read(power: power.read() ?? EnergyModelPower())

    let shown = showUnknown ? readings : readings.filter { $0.domain != .unknown }
    guard !shown.isEmpty else {
        print("No readable sensors (no AppleSMC access on this machine).")
        return
    }

    print("Platform: \(SensorPlatform.current?.rawValue ?? "unrecognised")")
    print("Sensors: \(shown.count) shown, \(readings.count) read")
    for kind in SensorKind.displayOrder {
        let group = shown.filter { $0.kind == kind }
        guard !group.isEmpty else { continue }
        print("\n\(kind.sectionTitle.uppercased())")
        for sensor in SensorsPanelOrder.sorted(group) {
            let name = sensor.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            var line = "  \(name) \(sensor.formattedValue)"
            if let fan = sensor.fan, fan.percentage > 0 { line += "  (\(fan.percentage)%)" }
            print(line)
        }
    }
}
