import MacPerfMonitorCore
import SwiftUI

/// The menu bar panel's chart range control. One setting for every tab, kept
/// in UserDefaults so the panel reopens on the range it was left on; Settings
/// edits the same value.
struct MenuChartRangePicker: View {
    @AppStorage(MenuChartRange.defaultsKey) private var range = MenuChartRange.default

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MenuChartRange.allCases) { option in
                Button {
                    range = option
                } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: option == range ? .semibold : .regular))
                        .foregroundStyle(option == range ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(
                            option == range ? MenuPanelStyle.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == range ? .isSelected : [])
            }
        }
        .padding(1)
        .background(MenuPanelStyle.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        .help(
            "How much history the charts show. One minute plots every sample; the longer ranges plot averages with a band out to the lowest and highest readings."
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chart range")
    }
}
