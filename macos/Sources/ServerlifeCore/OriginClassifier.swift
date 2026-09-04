import Foundation

/// Whose server this looks like, judged from where it runs — not what it's called.
/// A generic runtime's process name says nothing (`node` backs both your dev server and
/// half of Adobe's UI), but its working directory does: installed software runs out of
/// /Applications, /System, /Library or their per-user equivalents, and your own projects
/// essentially never do.
public enum ServerOrigin: String, Codable, Sendable {
    /// Running from ordinary user territory — almost certainly your own project.
    case mine
    /// Running out of an OS or installed-application directory.
    case system
    /// No working directory could be read, so there is nothing to judge by.
    case unknown
}

public enum OriginClassifier {
    /// Roots that mean "installed software", not "your project". The per-user
    /// `~/Library` and `~/Applications` are in here deliberately: alongside real
    /// per-user tool caches, that's also where an installer without admin rights puts
    /// an app (Electron apps commonly run a bundled Node runtime out of
    /// `~/Library/Application Support/<App>`) — the macOS analogue of what
    /// `LocalApplicationData` catches on Windows for the same reason. `/opt/homebrew`
    /// and `/usr/local` catch Homebrew-installed services (Postgres, Redis) a user did
    /// not write, parallel to what `ProgramData` catches there.
    private static let systemRoots: [String] = buildSystemRoots()

    private static func buildSystemRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/System", "/usr", "/bin", "/sbin",
            "/Applications", "/Library",
            "\(home)/Applications", "\(home)/Library",
            "/private/var/db", "/opt/homebrew", "/usr/local",
        ]
        return Array(Set(candidates)).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    public static func classify(workingDirectory: String?) -> ServerOrigin {
        guard let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unknown
        }
        let path = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
        for root in systemRoots {
            if path.caseInsensitiveCompare(root) == .orderedSame || path.lowercased().hasPrefix(root.lowercased() + "/") {
                return .system
            }
        }
        return .mine
    }
}
