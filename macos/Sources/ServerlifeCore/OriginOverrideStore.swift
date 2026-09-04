import Foundation

/// User corrections to OriginClassifier's folder-based guess, persisted so a pin survives
/// a restart. Keyed by working directory when one is known — the same signal the
/// classifier itself uses — and by process name when it isn't, since that's all there is
/// to go on for something whose folder can't be read (a service running under another
/// uid, say).
public enum OriginOverrideStore {
    public static var storeURLOverride: URL?

    private static var storeURL: URL {
        if let storeURLOverride { return storeURLOverride }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Serverlife", isDirectory: true)
            .appendingPathComponent("origin-overrides.json")
    }

    private static var cache: [String: ServerOrigin]?

    public static func key(workingDirectory: String?, processName: String) -> String {
        if let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
            return "dir:" + trimmed.lowercased()
        }
        let bare = (processName as NSString).deletingPathExtension
        return "proc:" + bare.lowercased()
    }

    public static func get(_ key: String) -> ServerOrigin? {
        loaded()[key]
    }

    public static func set(_ key: String, origin: ServerOrigin) {
        var overrides = loaded()
        overrides[key] = origin
        cache = overrides
        save(overrides)
    }

    public static func clear(_ key: String) {
        var overrides = loaded()
        guard overrides.removeValue(forKey: key) != nil else { return }
        cache = overrides
        save(overrides)
    }

    /// Re-reads from disk on first use; a test can reset `storeURLOverride` and then
    /// this without restarting the process.
    public static func resetCache() { cache = nil }

    private static func loaded() -> [String: ServerOrigin] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    private static func load() -> [String: ServerOrigin] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: ServerOrigin].self, from: data) else {
            // Corrupt or unreadable overrides fall back to none rather than blocking startup.
            return [:]
        }
        return decoded
    }

    private static func save(_ overrides: [String: ServerOrigin]) {
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(overrides)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Best-effort; never block the app on this.
        }
    }
}
