namespace Serverlife.Core;

/// <summary>
/// Whose server this looks like, judged from where it runs — not what it's called.
/// A generic runtime's process name says nothing (node.exe backs both your dev server
/// and half of Adobe's UI), but its working directory does: installed software runs out
/// of Program Files, Windows, ProgramData or the per-user install trees under
/// AppData\Local, and your own projects essentially never do.
/// </summary>
public enum ServerOrigin
{
    /// <summary>Running from ordinary user territory — almost certainly your own project.</summary>
    Mine,

    /// <summary>Running out of an OS or installed-application directory.</summary>
    System,

    /// <summary>No working directory could be read, so there is nothing to judge by.</summary>
    Unknown,
}

public static class OriginClassifier
{
    /// <summary>
    /// Roots that mean "installed software", not "your project". AppData\Local is in
    /// here deliberately: alongside real per-user tool caches it is also where most
    /// installers without admin rights put an app (Adobe's CCLibrary helpers, Spotify,
    /// Discord, game launchers), including ones that embed node.exe or python.exe as
    /// their own UI runtime — exactly the processes GenericRuntimes elsewhere would
    /// otherwise happily label as someone's dev server.
    /// </summary>
    private static readonly string[] SystemRoots = BuildSystemRoots();

    private static string[] BuildSystemRoots()
    {
        string?[] candidates =
        [
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        ];
        return candidates
            .Where(p => !string.IsNullOrEmpty(p))
            .Select(p => p!.TrimEnd('\\'))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static ServerOrigin Classify(string? workingDirectory)
    {
        if (string.IsNullOrWhiteSpace(workingDirectory))
            return ServerOrigin.Unknown;

        var path = workingDirectory.TrimEnd('\\');
        foreach (var root in SystemRoots)
        {
            if (path.Equals(root, StringComparison.OrdinalIgnoreCase)
                || path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
                return ServerOrigin.System;
        }
        return ServerOrigin.Mine;
    }
}
