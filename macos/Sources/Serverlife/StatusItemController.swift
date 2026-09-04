import AppKit

/// Owns the menu bar item — the Swift counterpart of App.xaml.cs's NotifyIcon setup.
/// Left-click toggles the panel; right-click opens a small menu with Show/Quit, the
/// same split the Windows tray icon makes between MouseClick and ContextMenuStrip.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    var onToggle: (() -> Void)?
    var onShow: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()

        if let button = statusItem.button {
            // A monochrome template image, not the app's gradient icon: AppKit tints a
            // template image for both light and dark menu bars on its own, where the
            // gradient icon would just read as mud at 18pt.
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Serverlife")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let showItem = NSMenuItem(title: "Show Serverlife", action: #selector(showClicked), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // Attaching the menu only for the moment of a right-click, rather than
            // permanently via `statusItem.menu`, is what keeps a left-click free to
            // toggle the panel instead of always popping the menu.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onToggle?()
        }
    }

    @objc private func showClicked() { onShow?() }
    @objc private func quitClicked() { onQuit?() }

    var button: NSStatusBarButton? { statusItem.button }
}
