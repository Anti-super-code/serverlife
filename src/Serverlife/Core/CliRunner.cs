using System.IO;
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

        return args.FirstOrDefault() switch
        {
            "--scan" => await ScanAsync(args).ConfigureAwait(false),
            "--run" => await RunSupervisedAsync(args).ConfigureAwait(false),
            _ => Usage(),
        };
    }

    private static int Usage()
    {
        Console.Error.WriteLine("""
            usage:
              Serverlife.exe --scan [--all]
                  List listening ports. --all includes ports that did not answer as HTTP.

              Serverlife.exe --run <folder> [command] [--seconds N] [--no-restart]
                  Start a supervised server and report its state until N seconds elapse.
                  With no command, the folder is served by the built-in static server.
            """);
        return 2;
    }

    /// <summary>
    /// Exercises the supervisor without the UI: start something, watch the watchdog react
    /// when it dies. This is how the kill-tree and restart behaviour get verified.
    /// </summary>
    private static async Task<int> RunSupervisedAsync(string[] args)
    {
        if (args.Length < 2)
            return Usage();

        var folder = Path.GetFullPath(args[1]);
        if (!Directory.Exists(folder))
        {
            Console.Error.WriteLine($"No such folder: {folder}");
            return 2;
        }

        var seconds = 30;
        var index = Array.IndexOf(args, "--seconds");
        if (index >= 0 && index + 1 < args.Length)
            int.TryParse(args[index + 1], out seconds);

        var command = args.Length > 2 && !args[2].StartsWith("--") ? args[2] : "";
        if (command.Length == 0)
        {
            var suggestion = ProjectDetector.Suggest(folder);
            command = suggestion.Command;
            Console.WriteLine($"detected: {suggestion.Why}");
        }

        using var supervisor = new Supervisor();
        supervisor.Changed += s =>
            Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {s.State,-10} port={s.Port?.ToString() ?? "-",-6} " +
                              $"restarts={s.RestartCount} {s.LastError}");

        var server = supervisor.Add(new ManagedServer
        {
            Name = Path.GetFileName(folder),
            Directory = folder,
            Command = command,
            AutoRestart = !args.Contains("--no-restart"),
        });

        supervisor.StartServer(server);
        supervisor.Start();

        Console.WriteLine($"supervising for {seconds}s — kill it externally to watch it come back");
        await Task.Delay(TimeSpan.FromSeconds(seconds)).ConfigureAwait(false);

        Console.WriteLine();
        Console.WriteLine($"final: {server.State}, {server.RestartCount} restart(s), port {server.Port}");
        Console.WriteLine("--- last log lines ---");
        foreach (var line in server.Snapshot().TakeLast(12))
            Console.WriteLine("  " + line);

        supervisor.Stop(server);
        return 0;
    }

    private static async Task<int> ScanAsync(string[] args)
    {
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
