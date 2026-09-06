import AppKit
import SwiftUI

/// A borderless, transparent, cursor-positioned window hosting SwiftUI
/// content — the AppKit equivalent of OptionsWindow.xaml/ProgressWindow.xaml's
/// `WindowStyle="None" AllowsTransparency="True" Topmost="True"` plus
/// CursorPositioner. Window-background dragging is handled by
/// `WindowDragBackground` inside the SwiftUI content itself (see its doc
/// comment) rather than `isMovableByWindowBackground`, which drags the
/// whole window even when a SwiftUI control on top — the size slider,
/// notably — is the thing that should be consuming the click instead.
final class ChromelessWindow: NSWindow {
    // ---- manual edge resize -------------------------------------------------------
    //
    // `.borderless` windows get none of the OS's own edge-resize handles, and the
    // earlier approach — a SwiftUI `NSViewRepresentable` strip in each margin that ran
    // the resize from its own `mouseDown` — turned out to be unreliable: when the panel
    // isn't the key window (it floats above other apps, and a click on the menu-bar
    // item or another app quietly drops key), the first click on that strip is spent
    // activating the window and never arrives as `mouseDown`. The cursor still flips to
    // the resize arrow (tracking-area `mouseEntered` doesn't need key), so it looks
    // armed but does nothing.
    //
    // Handling it in `sendEvent(_:)` sidesteps all of that: it runs for every event
    // routed to the window, before the key-window / first-mouse gating, before SwiftUI
    // hit-testing, before any gesture recogniser. A left-mouse-down anywhere in the
    // transparent gutter around the visible card starts an edge drag.

    /// Width of the transparent padding around the visible card (SwiftUI `.padding(...)`).
    /// A left-mouse-down in this outer band starts an edge resize. 0 disables it.
    var resizeGutter: CGFloat = 0
    /// Lower bound applied to the card (window) size during a manual resize.
    var minResizeSize = NSSize(width: 1, height: 1)
    /// Upper bound applied to the card (window) size during a manual resize, before the
    /// on-screen clamp.
    var maxResizeSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
    /// Called once when a manual edge drag begins — the panel uses it to stop
    /// auto-fitting its height to the row count from then on.
    var onResizeBegin: (() -> Void)?
    /// Called with the final frame when the drag ends — the panel persists the size here.
    var onResizeEnd: ((NSRect) -> Void)?

    private enum ResizeEdge { case top, bottom, left, right }

    init<Content: View>(width: CGFloat, height: CGFloat, shadowMargin: CGFloat, alwaysOnTop: Bool = true,
                         @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the card itself draws a drop shadow in SwiftUI
        isMovableByWindowBackground = false
        level = alwaysOnTop ? .floating : .normal
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let hosting = NSHostingView(rootView: content())
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        contentView = hosting

        let frame = WindowPositioning.frameNearCursor(width: width, height: height, shadowMargin: shadowMargin)
        setFrame(frame, display: false)
    }

    /// Applied live when the user flips "Always stay on top" while this
    /// window is still open, not just picked up by newly-created windows.
    func setAlwaysOnTop(_ alwaysOnTop: Bool) {
        level = alwaysOnTop ? .floating : .normal
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, resizeGutter > 0,
           let edge = resizeEdge(at: event.locationInWindow) {
            performEdgeResize(edge)
            return
        }
        super.sendEvent(event)
    }

    /// Which edge (if any) a window-space point falls on, within `resizeGutter` of the
    /// window bounds. Corners resolve to the vertical edge.
    private func resizeEdge(at p: NSPoint) -> ResizeEdge? {
        let g = resizeGutter
        let w = frame.width, h = frame.height
        guard p.x >= 0, p.x <= w, p.y >= 0, p.y <= h else { return nil }
        if p.y >= h - g { return .top }
        if p.y <= g { return .bottom }
        if p.x <= g { return .left }
        if p.x >= w - g { return .right }
        return nil
    }

    private func performEdgeResize(_ edge: ResizeEdge) {
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        onResizeBegin?()

        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 4000, height: 3000)
        let maxH = min(maxResizeSize.height, visible.height - 16)
        let maxW = min(maxResizeSize.width, visible.width - 16)

        trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                    timeout: NSEvent.foreverDuration, mode: .eventTracking) { [weak self] ev, stop in
            guard let self, let ev else { return }
            if ev.type == .leftMouseUp {
                stop.pointee = true
                self.onResizeEnd?(self.frame)
                return
            }
            // Screen coordinates grow up and to the right.
            let dx = NSEvent.mouseLocation.x - startMouse.x
            let dy = NSEvent.mouseLocation.y - startMouse.y
            var f = startFrame
            switch edge {
            case .top:
                // Bottom edge fixed; the top follows the cursor.
                f.size.height = max(self.minResizeSize.height, min(maxH, startFrame.height + dy))
            case .bottom:
                // Top edge fixed (the panel hangs off its status item), bottom follows.
                let nh = max(self.minResizeSize.height, min(maxH, startFrame.height - dy))
                f.origin.y = startFrame.maxY - nh
                f.size.height = nh
            case .left:
                // Right edge fixed (aligned under the status item), left follows.
                let nw = max(self.minResizeSize.width, min(maxW, startFrame.width - dx))
                f.origin.x = startFrame.maxX - nw
                f.size.width = nw
            case .right:
                // Left edge fixed, right follows.
                f.size.width = max(self.minResizeSize.width, min(maxW, startFrame.width + dx))
            }
            self.setFrame(f, display: true)
            self.contentView?.setFrameSize(f.size)
        }
    }
}
