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
}
