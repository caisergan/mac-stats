import AppKit
import SwiftUI

/// Zoom/pan gestures reported by `PerformanceChart` in data space. The chart
/// converts cursor positions and gesture deltas into dates/seconds; the parent
/// owns the visible-domain math (clamping to the loaded window, minimum span,
/// snapping back to the full view).
struct ChartZoomActions {
    /// Zoom about `anchor`, keeping it fixed on screen. `factor` > 1 zooms in.
    var zoom: (_ anchor: Date, _ factor: Double) -> Void
    /// Shift the visible window. Positive moves it later in time.
    var pan: (_ deltaSeconds: TimeInterval) -> Void
    /// Rubber-band selection: zoom to exactly this range.
    var selectRange: (_ range: ClosedRange<Date>) -> Void
}

/// Invisible view that captures scroll-wheel events over its bounds via a
/// local event monitor — SwiftUI exposes no scroll-wheel modifier on macOS —
/// and reports the cursor position (local coordinates) plus the scroll deltas.
/// `hitTest` returns nil so clicks, drags, and hover pass straight through to
/// the SwiftUI overlay above; matching events over the view are consumed so
/// they don't also scroll an enclosing container.
struct ScrollWheelCatcher: NSViewRepresentable {
    /// (local cursor position, deltaX, deltaY) — deltas normalised so wheel
    /// notches and precise trackpad deltas land in the same ballpark.
    var onScroll: (CGPoint, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGPoint, CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                    [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    let local = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(local) else { return event }
                    // Line-based wheels report whole notches; precise trackpads
                    // report points. Scale notches up so both feel similar.
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    self.onScroll?(
                        local, event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
                    return nil
                }
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}

/// The floating read-out a scrubbed chart pins beside its marker: the sample's
/// wall-clock time above one row per value. Shared so every hoverable chart
/// (Swift Charts or `TrendChart`) tells the reading the same way.
struct ChartScrubCard<Content: View>: View {
    let date: Date
    @ViewBuilder var content: () -> Content

    init(date: Date, @ViewBuilder content: @escaping () -> Content) {
        self.date = date
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// One labelled reading inside a `ChartScrubCard`: a dot in the series' colour,
/// the series name, then the formatted value.
struct ChartScrubRow: View {
    let color: Color
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.caption2)
            Spacer(minLength: 10)
            Text(value)
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
    }
}
