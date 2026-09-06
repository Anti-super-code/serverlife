using System.IO;
using Microsoft.Win32;

namespace Serverlife.Core;

/// <summary>
/// The PATH a freshly signed-in shell would have.
///
/// A GUI app keeps whatever environment block it was launched with. If Node was
/// installed — or its version manager re-pointed — after this app started, or after the
/// last sign-in, then <c>node</c>/<c>npm</c>/<c>pnpm</c>/<c>bun</c> are not on our PATH:
/// <c>npm run dev</c> spawned by the supervisor dies with "is not recognized", no
/// process comes up, no port opens, and nothing says why. macOS hits the same wall from
/// the other side (a Dock-launched app inherits only the bare system PATH); its
/// <c>LoginShellEnvironment</c> asks the login shell. Windows has no login shell to ask,
/// but the registry holds the authoritative answer.
///
/// This rebuilds PATH from the machine and per-user <c>Environment</c> keys — the same
/// values a new logon reads — unions our own current PATH so nothing already visible is
/// lost, and folds in the usual install locations as a fallback. Resolved once and
/// cached for the process lifetime.
/// </summary>
public static class EnvironmentPath
{
    /// <summary>Resolved once, on first use.</summary>
    public static string Value { get; } = Resolve();

    private static string Resolve()
    {
        var parts = new List<string>();
        parts.AddRange(Split(ReadRegistryPath(RegistryHive.LocalMachine,
            @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")));
        parts.AddRange(Split(ReadRegistryPath(RegistryHive.CurrentUser, "Environment")));
        parts.AddRange(Split(Environment.GetEnvironmentVariable("PATH")));
        parts.AddRange(FallbackDirs());

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var raw in parts)
        {
            var dir = raw.Trim().TrimEnd('\\', '/');
            if (dir.Length > 0 && seen.Add(dir))
                result.Add(dir);
        }
        return string.Join(';', result);
    }

    /// <summary>
    /// A REG_EXPAND_SZ read without auto-expansion, then expanded ourselves — the key
    /// often contains <c>%SystemRoot%</c> and the like. Any failure (key missing, no
    /// permission) is swallowed: this is a best-effort augmentation, not a hard
    /// dependency.
    /// </summary>
    private static string? ReadRegistryPath(RegistryHive hive, string subKey)
    {
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Default);
            using var key = baseKey.OpenSubKey(subKey);
            return key?.GetValue("Path", null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string value
                ? Environment.ExpandEnvironmentVariables(value)
                : null;
        }
        catch
        {
            return null;
        }
    }

    private static IEnumerable<string> Split(string? path) =>
        (path ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    /// <summary>
    /// Where the common Node installs and version managers drop their shims, folded in so
    /// a machine whose PATH has not caught up still resolves them. Only ones that exist
    /// are kept, so this never adds noise on a machine that doesn't use them.
    /// </summary>
    private static IEnumerable<string> FallbackDirs()
    {
        static string? Var(string k) => Environment.GetEnvironmentVariable(k);
        static string? Under(string? root, params string[] rest) =>
            string.IsNullOrEmpty(root) ? null : Path.Combine([root, .. rest]);

        var candidates = new[]
        {
            Var("NVM_SYMLINK"),                       // nvm-windows active version
            Under(Var("ProgramFiles"), "nodejs"),     // official installer, or nvm's default symlink
            Under(Var("APPDATA"), "npm"),             // npm global bin
            Under(Var("LOCALAPPDATA"), "Volta", "bin"),
            Under(Var("USERPROFILE"), "scoop", "shims"),
            Under(Var("LOCALAPPDATA"), "pnpm"),
            Under(Var("APPDATA"), "Yarn", "bin"),
        };
        return candidates.Where(d => !string.IsNullOrEmpty(d) && Directory.Exists(d))!;
    }
}
