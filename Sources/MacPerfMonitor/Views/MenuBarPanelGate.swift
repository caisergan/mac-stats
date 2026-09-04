import SwiftUI

/// Whether a status-item popover's SwiftUI content is on screen, plus the size
/// it last occupied.
///
/// The popover object and its hosting controller are kept alive across closes
/// (rebuilding them costs a full from-scratch SwiftUI layout of the whole
/// panel, which is the bulk of the open latency), so something else has to stop
/// a hidden panel doing work. This flag is it: `MenuBarPanelGate` drops the
/// entire content subtree out of the view graph while the popover is closed, so
/// the panel's `@EnvironmentObject` subscriptions to the sampler and the menu
/// lists are torn down with it and a closed panel re-renders exactly never.
@MainActor
final class MenuBarPanelVisibility: ObservableObject {
    @Published var isOpen = false
    /// The content size the panel last reported, used to hold the popover
    /// window at that size while closed so reopening does not resize it.
    var lastSize = CGSize(width: 404, height: 420)
}

/// Shows `content` only while the popover is open, and a same-sized blank
/// stand-in while it is closed.
///
/// The stand-in matters as much as the gate: NSPopover sizes its window from
/// the hosting controller's preferred content size, so a zero-sized placeholder
/// would make every open a grow-from-nothing resize, which costs a second full
/// layout pass. Holding the last size means the reopened panel usually lands in
/// a window that is already the right shape.
struct MenuBarPanelGate<Content: View>: View {
    @ObservedObject var visibility: MenuBarPanelVisibility
    @ViewBuilder var content: () -> Content

    var body: some View {
        if visibility.isOpen {
            content()
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { size in
                    if size.width > 0, size.height > 0 { visibility.lastSize = size }
                }
        } else {
            Color.clear
                .frame(width: visibility.lastSize.width, height: visibility.lastSize.height)
        }
    }
}
