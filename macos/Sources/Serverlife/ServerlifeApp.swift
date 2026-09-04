import SwiftUI

@main
struct ServerlifeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The real window (the tray panel) is a plain NSWindow created and shown
    // imperatively by AppCoordinator, mirroring App.xaml.cs's "one borderless window,
    // positioned programmatically" model — that doesn't map onto SwiftUI's declarative
    // WindowGroup, so this Scene exists only to satisfy App's requirement and stays
    // empty, exactly as Photokompressor's own PhotokompressorApp.swift does.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
