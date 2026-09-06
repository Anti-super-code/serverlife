import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by ChromelessWindow when the user starts an edge-drag resize, so
    /// TrayPanelView stops auto-fitting the panel height to the row count.
    static let serverlifePanelManuallyResized = Notification.Name("serverlifePanelManuallyResized")
}

/// Wraps a ChromelessWindow (reused unchanged from Photokompressor) to host the tray
/// panel, adding what that generic constructor doesn't provide: positioning under the
/// status item button rather than near the cursor. Resizing (drag grips, and growing to
/// fit the About/Settings panel) is handled by TrayPanelView itself, the same way
/// WindowDragBackground reaches its own hosting NSWindow directly rather than being
/// handed a reference from outside.
@MainActor
final class TrayPanelWindow {
    static let defaultWidth: CGFloat = 460
    static let minWidth: CGFloat = 340
    static let maxWidth: CGFloat = 760
    static let defaultHeight: CGFloat = 440
    static let minHeight: CGFloat = 220
    /// Height the About/Settings panel opens at: tall enough that the blurb *and* both
    /// toggle rows are on screen without scrolling the inner list. Clamped to the
    /// visible screen height when it's actually applied (see `setInfoShowing`).
    static let infoHeight: CGFloat = 680
    static let shadowMargin: CGFloat = 18
    /// `UserDefaults` keys the resize grips persist the panel size under.
    static let heightDefaultsKey = "panelHeightV1"
    static let widthDefaultsKey = "panelWidthV1"

    /// The panel reopens at whatever height the user last dragged it to (persisted by
    /// ResizeGrip), clamped so a stale value from another display can't open it
    /// off-screen. Falls back to `defaultHeight` on first run.
    private static var startingHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: heightDefaultsKey)
        guard saved >= Double(minHeight) else { return defaultHeight }
        let screenHeight = (NSScreen.main?.visibleFrame.height ?? 2000) - 16
        return min(CGFloat(saved), max(defaultHeight, screenHeight))
    }

    /// Same idea as `startingHeight`: reopen at the user's last dragged width, clamped
    /// so a stale value from a wider display can't open it off-screen. Falls back to
    /// `defaultWidth` on first run.
    private static var startingWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: widthDefaultsKey)
        guard saved >= Double(minWidth) else { return defaultWidth }
        let screenWidth = (NSScreen.main?.visibleFrame.width ?? 3000) - 16
        return min(CGFloat(saved), min(maxWidth, max(defaultWidth, screenWidth)))
    }

    let window: ChromelessWindow

    init(viewModel: TrayViewModel, alwaysOnTop: Bool, onClose: @escaping () -> Void) {
        window = ChromelessWindow(width: Self.startingWidth, height: Self.startingHeight,
                                   shadowMargin: Self.shadowMargin, alwaysOnTop: alwaysOnTop) {
            TrayPanelView(viewModel: viewModel, onClose: onClose)
        }

        // Edge-drag resize, handled in ChromelessWindow.sendEvent. 12pt covers the
        // transparent margin around the card (TrayPanelView's `.padding(12)`); the
        // extra 6pt reaches onto the card's visible border so a click that lands
        // right on the edge — where people actually aim — still starts the drag.
        // Still well clear of the header buttons (10pt in) and the list padding (14pt).
        window.resizeGrabDepth = 18
        window.minResizeSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        window.maxResizeSize = NSSize(width: Self.maxWidth, height: CGFloat.greatestFiniteMagnitude)
        window.onResizeBegin = {
            NotificationCenter.default.post(name: .serverlifePanelManuallyResized, object: nil)
        }
        window.onResizeEnd = { frame in
            UserDefaults.standard.set(Double(frame.width), forKey: Self.widthDefaultsKey)
            UserDefaults.standard.set(Double(frame.height), forKey: Self.heightDefaultsKey)
        }
    }

    func reposition(below button: NSStatusBarButton) {
        let frame = WindowPositioning.frameBelowStatusItem(
            button: button, width: window.frame.width, height: window.frame.height)
        window.setFrame(frame, display: true)
        window.contentView?.setFrameSize(window.frame.size)
    }

    func setAlwaysOnTop(_ alwaysOnTop: Bool) {
        window.setAlwaysOnTop(alwaysOnTop)
    }
}
