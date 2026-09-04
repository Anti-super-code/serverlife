using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Serverlife.Core;

/// <summary>
/// Adds/removes the "Start server here" verb under HKCU (no admin), on both the folder
/// icon itself and the empty background of a folder you're already inside — right-clicking
/// a folder and right-clicking inside one are two different registry locations in Explorer.
/// </summary>
public static class ShellRegistration
{
    public const string VerbName = "Serverlife";
    public const string MenuText = "Start server here";

    private const string DirectoryKey = @"Software\Classes\Directory\shell";
    private const string BackgroundKey = @"Software\Classes\Directory\Background\shell";

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int wEventId, uint uFlags, nint dwItem1, nint dwItem2);

    private const int SHCNE_ASSOCCHANGED = 0x08000000;
    private const uint SHCNF_IDLIST = 0x0000;

    public static void Register()
    {
        var exePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Cannot determine the application path.");

        foreach (var baseKey in new[] { DirectoryKey, BackgroundKey })
        {
            using var verbKey = Registry.CurrentUser.CreateSubKey($@"{baseKey}\{VerbName}");
            verbKey.SetValue("", MenuText);
            verbKey.SetValue("Icon", $"\"{exePath}\",0");
            using var commandKey = verbKey.CreateSubKey("command");
            // %V is the folder being acted on in both locations — %1 only works on the
            // Directory key, since a background click has nothing selected to pass as %1.
            commandKey.SetValue("", $"\"{exePath}\" \"%V\"");
        }
        NotifyShell();
    }

    public static void Unregister()
    {
        foreach (var baseKey in new[] { DirectoryKey, BackgroundKey })
        {
            try
            {
                Registry.CurrentUser.DeleteSubKeyTree($@"{baseKey}\{VerbName}", throwOnMissingSubKey: false);
            }
            catch { /* key may not exist */ }
        }
        NotifyShell();
    }

    public static bool IsRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey($@"{DirectoryKey}\{VerbName}\command");
        return key?.GetValue("") is string;
    }

    private static void NotifyShell() => SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0);
}
