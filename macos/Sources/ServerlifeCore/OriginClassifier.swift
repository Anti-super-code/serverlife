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
            "/private/var/db", "/opt/homebrew", "/opt/local", "/usr/local", "/nix",
        ]
        return Array(Set(candidates)).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// Interpreters whose own binary path says nothing about whose server this is —
    /// `/opt/homebrew/bin/node` backs a dev server exactly as often as it backs a
    /// menu-bar app. Kept in step with `DetectedServer.genericRuntimes`.
    private static let genericRuntimes: Set<String> = [
        "node", "python", "python3", "ruby", "php", "java", "deno", "bun", "cargo", "go",
    ]

    /// Working-directory-only classification — the original signal, kept for callers
    /// (and tests) that have nothing else to go on.
    public static func classify(workingDirectory: String?) -> ServerOrigin {
        classify(workingDirectory: workingDirectory, executablePath: nil, processName: nil)
    }

    /// Full classification. On macOS the working directory is a weak signal on its own:
    /// launchd daemons and `.app` menu-bar helpers keep theirs at `/`, so a
    /// directory-only check drops every one of them into "mine". The executable path is
    /// the signal that actually holds up — a *named* program (not a bare interpreter)
    /// running out of an install location is installed software, whatever its working
    /// directory says.
    public static func classify(workingDirectory: String?,
                                executablePath: String?,
                                processName: String?) -> ServerOrigin {
        if let executablePath, !executablePath.trimmingCharacters(in: .whitespaces).isEmpty {
            let bare = ((processName?.isEmpty == false ? processName! : executablePath) as NSString)
                .lastPathComponent.lowercased()
            if !genericRuntimes.contains(bare), isUnderSystemRoot(normalise(executablePath)) {
                return .system
            }
        }

        guard let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unknown
        }
        let path = normalise(workingDirectory)
        // A launchd daemon inherits `/` as its working directory; that is not a project
        // folder, so it stays "unknown" rather than being taken for one of yours.
        if path == "/" { return .unknown }
        if isUnderSystemRoot(path) { return .system }
        return .mine
    }

    private static func normalise(_ path: String) -> String {
        path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }

    private static func isUnderSystemRoot(_ path: String) -> Bool {
        for root in systemRoots {
            if path.caseInsensitiveCompare(root) == .orderedSame
                || path.lowercased().hasPrefix(root.lowercased() + "/") {
                return true
            }
        }
        return false
    }
}
