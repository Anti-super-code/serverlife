using System.Runtime.InteropServices;

namespace Serverlife.Core;

/// <summary>
/// Hidden headless mode, so discovery can be exercised without the tray UI:
///
///     Serverlife.exe --scan [--all]
///
/// --all keeps ports that did not answer as HTTP (SMB, RPC, databases), which the
/// GUI hides by default.
/// </summary>
public static class CliRunner
{
    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int dwProcessId);

    private const int AttachParentProcess = -1;

    public static async Task<int> RunAsync(string[] args)
    {
        AttachConsole(AttachParentProcess);

        if (args.Length == 0 || args[0] != "--scan")
        {
            Console.Error.WriteLine("usage: Serverlife.exe --scan [--all]");
            return 2;
        }

        var showAll = args.Contains("--all");

        using var discovery = new Discovery();
        var servers = await discovery.ScanAsync().ConfigureAwait(false);
        var shown = showAll ? servers : servers.Where(s => s.Probe.IsHttp).ToList();

        if (shown.Count == 0)
        {
            Console.WriteLine(showAll
                ? "No listening TCP ports found."
                : "No local HTTP servers found. Re-run with --all to include non-HTTP ports.");
            return 0;
        }

        Console.WriteLine($"{"PORT",-6} {"PID",-7} {"PROCESS",-18} {"NAME / TITLE",-34} FOLDER");
        Console.WriteLine(new string('-', 110));
        foreach (var s in shown)
        {
            var folder = s.WorkingDirectory ?? (s.Probe.IsHttp ? "(unknown)" : "");
            var flag = s.IsAdoptable ? " " : "*";
            var port = s.IsContested ? $"{s.Port}!" : s.Port.ToString();
            Console.WriteLine($"{port,-6} {s.Pid,-7} {Clip(s.ProcessName, 18),-18} {Clip(s.DisplayName, 34),-34} {flag}{folder}");
        }

        Console.WriteLine();
        Console.WriteLine($"{shown.Count} shown, {servers.Count} listening total.");
        Console.WriteLine("* = not restartable: no readable command line or working directory.");

        var contested = shown.Where(s => s.IsContested).GroupBy(s => s.Port).ToList();
        foreach (var port in contested)
        {
            Console.WriteLine($"! = port {port.Key} has {port.Count()} unrelated processes bound to it; " +
                              "only the last one to bind is serving.");
        }
        return 0;
    }

    private static string Clip(string value, int width) =>
        value.Length <= width ? value : value[..(width - 1)] + "…";
}
