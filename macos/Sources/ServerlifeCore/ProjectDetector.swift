import Foundation

/// - Parameters:
///   - command: the shell command to run, relative to the folder.
///   - why: short human explanation of what was found, shown under the field.
///   - usesBuiltInServer: true when nothing project-shaped was found and we serve the
///     files ourselves.
public struct LaunchSuggestion: Sendable {
    public let command: String
    public let why: String
    public let usesBuiltInServer: Bool

    public init(command: String, why: String, usesBuiltInServer: Bool = false) {
        self.command = command
        self.why = why
        self.usesBuiltInServer = usesBuiltInServer
    }
}

/// Guesses how to start a dropped folder. The guess is never run silently: it is put in
/// an editable field with the reason beside it, because picking the wrong npm script is
/// both easy and annoying — "build" instead of "dev" wastes a minute and serves nothing.
public enum ProjectDetector {
    /// In preference order — the first script present wins.
    private static let scriptPreference = ["dev", "start", "serve", "preview"]

    public static func suggest(folder: String) -> LaunchSuggestion {
        if let node = tryNode(folder: folder) { return node }

        let fm = FileManager.default
        if fm.fileExists(atPath: (folder as NSString).appendingPathComponent("manage.py")) {
            return LaunchSuggestion(command: "python manage.py runserver", why: "Django project (manage.py)")
        }
        if fm.fileExists(atPath: (folder as NSString).appendingPathComponent("Cargo.toml")) {
            return LaunchSuggestion(command: "cargo run", why: "Rust crate (Cargo.toml)")
        }
        for compose in ["docker-compose.yml", "docker-compose.yaml", "compose.yml"] {
            if fm.fileExists(atPath: (folder as NSString).appendingPathComponent(compose)) {
                return LaunchSuggestion(command: "docker compose up", why: "Compose file (\(compose))")
            }
        }
        if fm.fileExists(atPath: (folder as NSString).appendingPathComponent("index.html")) {
            return LaunchSuggestion(command: "", why: "Static site (index.html) — served by Serverlife",
                                     usesBuiltInServer: true)
        }
        return LaunchSuggestion(command: "", why: "No project files found — served as static files",
                                 usesBuiltInServer: true)
    }

    private static func tryNode(folder: String) -> LaunchSuggestion? {
        let manifest = (folder as NSString).appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: manifest) else { return nil }

        let runner = packageRunner(folder: folder)
        if let data = FileManager.default.contents(atPath: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            for name in scriptPreference {
                guard scripts[name] != nil else { continue }
                return LaunchSuggestion(command: "\(runner) run \(name)",
                                         why: "package.json script \"\(name)\" (\(runner))")
            }
        }
        // A malformed or scriptless package.json is still a Node project; fall through
        // to the conventional script name rather than refusing to suggest anything.
        return LaunchSuggestion(command: "\(runner) run dev",
                                 why: "package.json found (\(runner)), no readable scripts")
    }

    /// The lockfile decides, not what happens to be installed: running npm in a pnpm
    /// workspace half-installs a second tree and the dev server then fails oddly.
    private static func packageRunner(folder: String) -> String {
        let fm = FileManager.default
        let path = { (name: String) in (folder as NSString).appendingPathComponent(name) }
        if fm.fileExists(atPath: path("pnpm-lock.yaml")) { return "pnpm" }
        if fm.fileExists(atPath: path("yarn.lock")) { return "yarn" }
        if fm.fileExists(atPath: path("bun.lockb")) { return "bun" }
        return "npm"
    }
}
