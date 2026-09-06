import Foundation

/// The `PATH` a fresh login shell would have.
///
/// An app launched from the Dock or Finder inherits a bare `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) — none of the directories a version manager puts
/// `node`/`npm`/`pnpm`/`bun` in (`~/.nvm/...`, `/opt/homebrew/bin`, `/usr/local/bin`,
/// `~/.volta/bin`, `~/.asdf/shims`). So `sh -c "npm run dev"` spawned straight from the
/// app just fails with "command not found" and the server never starts.
///
/// This asks the user's own login shell what its `PATH` is — the same trick VS Code and
/// `shell-path` use — and caches the answer for the process lifetime. Falls back to a
/// sensible union of the usual locations if the shell can't be run or hangs.
public enum LoginShellEnvironment {
    /// Common install locations, always folded in so a spartan `.zshrc` can't drop the
    /// basics. Ordered: Homebrew (Apple silicon, then Intel), then the system set.
    private static let fallbackPath =
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolved once, on first use.
    public static let path: String = resolve()

    /// `ProcessInfo`'s environment with `PATH` replaced by `path` — ready to hand to a
    /// spawned process.
    public static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }

    private static func resolve() -> String {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            return merged(nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // -i -l so both ~/.zprofile (login) and ~/.zshrc (interactive) run — version
        // managers put their PATH setup in one or the other. `command -p` avoids a
        // shell alias for printf.
        process.arguments = ["-ilc", "command -p printf '%s' \"$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return merged(nil)
        }

        // A noisy or blocking shell rc file must not wedge startup.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return merged(nil)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let reported = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reported, reported.contains("/") else { return merged(nil) }
        return merged(reported)
    }

    /// `reported` (if any) first, then the fallback locations, de-duplicated, order kept.
    private static func merged(_ reported: String?) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for segment in [(reported ?? ""), fallbackPath].joined(separator: ":").split(separator: ":") {
            let dir = String(segment)
            guard !dir.isEmpty, seen.insert(dir).inserted else { continue }
            result.append(dir)
        }
        return result.joined(separator: ":")
    }
}
