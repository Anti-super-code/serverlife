using System.IO;
using System.Text.Json;

namespace Serverlife.Core;

/// <param name="Command">The shell command to run, relative to the folder.</param>
/// <param name="Why">Short human explanation of what was found, shown under the field.</param>
/// <param name="UsesBuiltInServer">True when nothing project-shaped was found and we serve the files ourselves.</param>
public sealed record LaunchSuggestion(string Command, string Why, bool UsesBuiltInServer = false);

/// <summary>
/// Guesses how to start a dropped folder. The guess is never run silently: it is put in
/// an editable field with the reason beside it, because picking the wrong npm script is
/// both easy and annoying — "build" instead of "dev" wastes a minute and serves nothing.
/// </summary>
public static class ProjectDetector
{
    /// <summary>In preference order — the first script present wins.</summary>
    private static readonly string[] ScriptPreference = ["dev", "start", "serve", "preview"];

    public static LaunchSuggestion Suggest(string folder)
    {
        if (TryNode(folder, out var node))
            return node;

        if (File.Exists(Path.Combine(folder, "manage.py")))
            return new LaunchSuggestion("python manage.py runserver", "Django project (manage.py)");

        if (File.Exists(Path.Combine(folder, "Cargo.toml")))
            return new LaunchSuggestion("cargo run", "Rust crate (Cargo.toml)");

        foreach (var compose in new[] { "docker-compose.yml", "docker-compose.yaml", "compose.yml" })
        {
            if (File.Exists(Path.Combine(folder, compose)))
                return new LaunchSuggestion("docker compose up", $"Compose file ({compose})");
        }

        if (File.Exists(Path.Combine(folder, "index.html")))
            return new LaunchSuggestion("", "Static site (index.html) — served by Serverlife", true);

        return new LaunchSuggestion("", "No project files found — served as static files", true);
    }

    private static bool TryNode(string folder, out LaunchSuggestion suggestion)
    {
        suggestion = default!;
        var manifest = Path.Combine(folder, "package.json");
        if (!File.Exists(manifest))
            return false;

        var runner = PackageRunner(folder);
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(manifest));
            if (document.RootElement.TryGetProperty("scripts", out var scripts)
                && scripts.ValueKind == JsonValueKind.Object)
            {
                foreach (var name in ScriptPreference)
                {
                    if (!scripts.TryGetProperty(name, out _))
                        continue;
                    suggestion = new LaunchSuggestion(
                        $"{runner} run {name}",
                        $"package.json script \"{name}\" ({runner})");
                    return true;
                }
            }
        }
        catch (JsonException)
        {
            // A malformed package.json is still a Node project; fall through to the
            // conventional script name rather than refusing to suggest anything.
        }

        suggestion = new LaunchSuggestion($"{runner} run dev", $"package.json found ({runner}), no readable scripts");
        return true;
    }

    /// <summary>
    /// The lockfile decides, not what happens to be installed: running npm in a pnpm
    /// workspace half-installs a second tree and the dev server then fails oddly.
    /// </summary>
    private static string PackageRunner(string folder) =>
        File.Exists(Path.Combine(folder, "pnpm-lock.yaml")) ? "pnpm"
        : File.Exists(Path.Combine(folder, "yarn.lock")) ? "yarn"
        : File.Exists(Path.Combine(folder, "bun.lockb")) ? "bun"
        : "npm";
}
