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
    static let shadowMargin: CGFloat = 18

    let window: ChromelessWindow

    init(viewModel: TrayViewModel, alwaysOnTop: Bool, onClose: @escaping () -> Void) {
        window = ChromelessWindow(width: Self.defaultWidth, height: Self.defaultHeight,
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
