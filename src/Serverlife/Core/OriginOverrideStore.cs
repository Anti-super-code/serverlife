using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Serverlife.Core;

/// <summary>
/// User corrections to OriginClassifier's folder-based guess, persisted so a pin survives
/// a restart. Keyed by working directory when one is known — the same signal the
/// classifier itself uses — and by process name when it isn't, since that's all there is
/// to go on for something like a service whose folder can't be read (see the GT3 case:
/// WorkingDirectory unreadable, so it fell back to showing under Mine as Unknown).
/// </summary>
public static class OriginOverrideStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static string StorePath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Serverlife", "origin-overrides.json");

    private static readonly Dictionary<string, ServerOrigin> Overrides = Load();

    public static string KeyFor(string? workingDirectory, string processName) =>
        !string.IsNullOrWhiteSpace(workingDirectory)
            ? "dir:" + workingDirectory.TrimEnd('\\').ToLowerInvariant()
            : "proc:" + Path.GetFileNameWithoutExtension(processName).ToLowerInvariant();

    public static ServerOrigin? Get(string key) =>
        Overrides.TryGetValue(key, out var origin) ? origin : null;

    public static void Set(string key, ServerOrigin origin)
    {
        Overrides[key] = origin;
        Save();
    }

    public static void Clear(string key)
    {
        if (Overrides.Remove(key))
            Save();
    }

    private static Dictionary<string, ServerOrigin> Load()
    {
        try
        {
            if (File.Exists(StorePath))
            {
                var json = File.ReadAllText(StorePath);
                if (JsonSerializer.Deserialize<Dictionary<string, ServerOrigin>>(json, JsonOptions) is { } loaded)
                    return loaded;
            }
        }
        catch
        {
            // Corrupt or unreadable overrides fall back to none rather than blocking startup.
        }
        return new Dictionary<string, ServerOrigin>();
    }

    private static void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(StorePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(StorePath, JsonSerializer.Serialize(Overrides, JsonOptions));
        }
        catch
        {
            // Best-effort; never block the app on this.
        }
    }
}
