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
    // hit-testing, before any gesture recogniser. A left-mouse-down within
    // `resizeGrabDepth` of any window edge starts an edge drag.

    /// How far in from a window edge a left-mouse-down still starts an edge resize,
    /// in points. Set this to the transparent margin around the visible card *plus* a
    /// few points, so a click landing right on the card's visible border still grabs.
    /// 0 disables the behaviour.
    var resizeGrabDepth: CGFloat = 0
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

    /// Which sides a drag is pulling. A single member is an edge drag; a horizontal
    /// plus a vertical member is a corner drag (both dimensions at once).
    private struct ResizeSides: OptionSet {
        let rawValue: Int
        static let top    = ResizeSides(rawValue: 1 << 0)
        static let bottom = ResizeSides(rawValue: 1 << 1)
        static let left   = ResizeSides(rawValue: 1 << 2)
        static let right  = ResizeSides(rawValue: 1 << 3)
    }

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
        if event.type == .leftMouseDown, resizeGrabDepth > 0 {
            let sides = resizeSides(at: event.locationInWindow)
            if !sides.isEmpty {
                performResize(sides)
                return
            }
        }
        super.sendEvent(event)
    }

    /// Which sides a window-space point is close enough to grab. Near one horizontal and
    /// one vertical side at once → a corner (both returned). The top band is kept to
    /// `resizeGrabDepth` so it clears the header buttons; the other three get a little
    /// extra reach.
    private func resizeSides(at p: NSPoint) -> ResizeSides {
        let g = resizeGrabDepth
        let generous = g + 8
        let w = frame.width, h = frame.height
        guard p.x >= 0, p.x <= w, p.y >= 0, p.y <= h else { return [] }

        var s: ResizeSides = []
        if p.y <= generous { s.insert(.bottom) }
        if p.y >= h - g { s.insert(.top) }
        if p.x <= generous { s.insert(.left) }
        if p.x >= w - generous { s.insert(.right) }

        // A tiny window can flag opposite sides at once — nonsensical, so drop both.
        if s.contains([.top, .bottom]) { s.subtract([.top, .bottom]) }
        if s.contains([.left, .right]) { s.subtract([.left, .right]) }
        return s
    }

    private func performResize(_ sides: ResizeSides) {
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        onResizeBegin?()

        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 4000, height: 3000)
        let minW = minResizeSize.width, minH = minResizeSize.height
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
            // Screen coordinates grow up and to the right. Each axis is independent, so
            // a corner just applies both — the two untouched edges stay put as anchors.
            let dx = NSEvent.mouseLocation.x - startMouse.x
            let dy = NSEvent.mouseLocation.y - startMouse.y
            var f = startFrame

            if sides.contains(.top) {
                f.size.height = max(minH, min(maxH, startFrame.height + dy))   // bottom anchored
            } else if sides.contains(.bottom) {
                let nh = max(minH, min(maxH, startFrame.height - dy))          // top anchored
                f.origin.y = startFrame.maxY - nh
                f.size.height = nh
            }
            if sides.contains(.right) {
                f.size.width = max(minW, min(maxW, startFrame.width + dx))     // left anchored
            } else if sides.contains(.left) {
                let nw = max(minW, min(maxW, startFrame.width - dx))           // right anchored
                f.origin.x = startFrame.maxX - nw
                f.size.width = nw
            }

            self.setFrame(f, display: true)
            self.contentView?.setFrameSize(f.size)
        }
    }
}
