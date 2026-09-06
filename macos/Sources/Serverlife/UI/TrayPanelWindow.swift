import AppKit
import SwiftUI

/// Wraps a ChromelessWindow (reused unchanged from Photokompressor) to host the tray
/// panel, adding what that generic constructor doesn't provide: positioning under the
/// status item button rather than near the cursor. Resizing (drag grips, and growing to
/// fit the About/Settings panel) is handled by TrayPanelView itself, the same way
/// WindowDragBackground reaches its own hosting NSWindow directly rather than being
/// handed a reference from outside.
@MainActor
final class TrayPanelWindow {
    static let defaultWidth: CGFloat = 380
    static let defaultHeight: CGFloat = 440
    static let minHeight: CGFloat = 220
    /// Height the About/Settings panel opens at: tall enough that the blurb *and* both
    /// toggle rows are on screen without scrolling the inner list. Clamped to the
    /// visible screen height when it's actually applied (see `setInfoShowing`).
    static let infoHeight: CGFloat = 680
    static let shadowMargin: CGFloat = 18
    /// `UserDefaults` key the resize grips persist the panel height under.
    static let heightDefaultsKey = "panelHeightV1"

    /// The panel reopens at whatever height the user last dragged it to (persisted by
    /// ResizeGrip), clamped so a stale value from another display can't open it
    /// off-screen. Falls back to `defaultHeight` on first run.
    private static var startingHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: heightDefaultsKey)
        guard saved >= Double(minHeight) else { return defaultHeight }
        let screenHeight = (NSScreen.main?.visibleFrame.height ?? 2000) - 16
        return min(CGFloat(saved), max(defaultHeight, screenHeight))
    }

    let window: ChromelessWindow

    init(viewModel: TrayViewModel, alwaysOnTop: Bool, onClose: @escaping () -> Void) {
        window = ChromelessWindow(width: Self.defaultWidth, height: Self.startingHeight,
                                   shadowMargin: Self.shadowMargin, alwaysOnTop: alwaysOnTop) {
            TrayPanelView(viewModel: viewModel, onClose: onClose)
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
