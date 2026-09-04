import SwiftUI
import AppKit

/// Place behind header content via `.background(WindowDragBackground())`
/// (never as a `ZStack` sibling — as a plain `NSView` with no intrinsic
/// size, it expands to swallow whatever space it's given rather than
/// matching its host's size, which once blew up an entire header's layout).
///
/// Uses `NSWindow.performDrag(with:)` — native, synchronous, exactly as
/// smooth as dragging a real title bar — rather than manually repositioning
/// the window frame from a SwiftUI `DragGesture.onChanged`, which was tried
/// and visibly lagged behind the cursor: every update round-trips through
/// SwiftUI's state-diff-render cycle before AppKit ever moves the window.
///
/// Reachability (not smoothness) is the real challenge here: SwiftUI `Text`
/// views block hit-testing to whatever's behind them by default, so plain
/// z-order alone only exposes this view through genuinely empty gaps
/// between elements. The header applies `.allowsHitTesting(false)` to its
/// title/subtitle Text views specifically (but not to its buttons) so
/// clicks pass through the text down to this view too, not just the gaps
/// around it.
struct WindowDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
