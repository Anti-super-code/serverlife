import AppKit

/// AppKit entry point — the Swift counterpart of App.xaml.cs's OnStartup. A resident
/// app's whole value is being there when something else falls over, so unlike WPF's
/// single global DispatcherUnhandledException catch (which AppKit has no equivalent
/// of), that guarantee is enforced by construction throughout the row commands and Core
/// calls instead: every one of them guards its own preconditions and never force-unwraps.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistration.ensureRegistered()
        NSApp.setActivationPolicy(.regular)
        coordinator.applicationDidFinishLaunching()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        coordinator.handleOpenFolders(urls.map(\.path))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.focusOrShowEmpty()
        return true
    }

    /// This is the macOS expression of TrayWindow.xaml.cs's OnClosing (`e.Cancel =
    /// true`): closing the panel means hide to the status item, not quit. Quitting is
    /// deliberate, from the status item's own menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.dispose()
    }
}
