import Foundation

/// Direct port of SettingsStore.cs — same JSON-file-of-settings approach, relocated to
/// macOS's equivalent of %APPDATA%.
public enum SettingsStore {
    public static var settingsURLOverride: URL?

    private static var settingsURL: URL {
        if let settingsURLOverride { return settingsURLOverride }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Serverlife", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            // Corrupt or unreadable settings fall back to defaults.
            return AppSettings()
        }
        return settings
    }

    public static func save(_ settings: AppSettings) {
        do {
            let dir = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            // Best-effort; never block the app on this.
        }
    }
}
