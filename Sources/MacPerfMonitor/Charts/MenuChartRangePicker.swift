import MacPerfMonitorCore
import SwiftUI

/// The menu bar panel's chart range control. One setting for every tab, kept
/// in UserDefaults so the panel reopens on the range it was left on; Settings
/// edits the same value.
struct MenuChartRangePicker: View {
    @AppStorage(MenuChartRange.defaultsKey) private var range = MenuChartRange.default

    var body: some View {
        Picker("Chart range", selection: $range) {
            ForEach(MenuChartRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .help(
            "How much history the charts show. One minute plots every sample; the longer ranges plot averages with a band out to the lowest and highest readings."
        )
    }
}
