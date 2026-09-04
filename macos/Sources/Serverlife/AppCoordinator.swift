import AppKit
import ServerlifeCore

/// Owns window and status-item lifecycle for the whole app — the Swift counterpart of
/// App.xaml.cs. There is no SingleInstance mutex/pipe to port: `LSMultipleInstancesProhibited`
/// plus `application(_:open:)` gives the same "a second launch hands its folder to the
/// already-running app" guarantee for free, the same way Photokompressor's own
/// AppCoordinator relies on it.
@MainActor
final class AppCoordinator {
    private let viewModel = TrayViewModel()
    private var statusItemController: StatusItemController?
    private var panelWindow: TrayPanelWindow?

    func applicationDidFinishLaunching() {
        let statusItemController = StatusItemController()
        statusItemController.onToggle = { [weak self] in self?.togglePanel() }
        statusItemController.onShow = { [weak self] in self?.showPanel() }
        statusItemController.onQuit = { NSApp.terminate(nil) }
        self.statusItemController = statusItemController

        let settings = SettingsStore.load()
        panelWindow = TrayPanelWindow(viewModel: viewModel, alwaysOnTop: settings.alwaysOnTop) { [weak self] in
            self?.hidePanel()
        }

        // Starts visible on first run so it is obvious the app launched; after that the
        // status item is how it comes back — matching TrayWindow's own ShowFromTray()
        // being called once at the end of OnStartup.
        showPanel()
    }

    /// A folder handed over via the Finder "Start server here" Quick Action, or a
    /// second `open -a` with no folder — the free single-instance handoff described
    /// above; this is application(_:open:)'s payload, forwarded here by AppDelegate.
    func handleOpenFolders(_ paths: [String]) {
        if let folder = paths.first {
            viewModel.prepareDrop(folder)
        }
        showPanel()
    }

    func focusOrShowEmpty() {
        showPanel()
    }

    private func togglePanel() {
        guard let panelWindow else { return }
        if panelWindow.window.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panelWindow, let button = statusItemController?.button else { return }
        panelWindow.reposition(below: button)
        panelWindow.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing hides: this is a resident app, and the status item is the real window
    /// list — the same trade TrayWindow.xaml.cs's OnClosing makes for Alt+F4/taskbar
    /// Close.
    private func hidePanel() {
        panelWindow?.window.orderOut(nil)
    }

    func dispose() {
        viewModel.dispose()
    }
}
