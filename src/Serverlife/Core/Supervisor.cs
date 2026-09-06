using System.Diagnostics;
using System.IO;

namespace Serverlife.Core;

public enum ManagedState { Stopped, Starting, Running, Restarting, Failed }

/// <summary>
/// A server Serverlife is responsible for: one we started, or an external one that was
/// adopted. Holds everything needed to bring it back after it dies.
/// </summary>
public sealed class ManagedServer
{
    public required string Name { get; set; }
    public required string Directory { get; set; }

    /// <summary>Shell command to run. Empty means serve <see cref="Directory"/> with the built-in server.</summary>
    public required string Command { get; set; }

    public bool AutoRestart { get; set; } = true;
    public ManagedState State { get; set; } = ManagedState.Stopped;

    /// <summary>Learned on first successful start, then used as the health check.</summary>
    public int? Port { get; set; }

    public int RestartCount { get; set; }
    public string? LastError { get; set; }

    internal Process? Process { get; set; }
    internal JobObject? Job { get; set; }
    internal StaticServer? BuiltIn { get; set; }
    internal DateTime? HealthySinceUtc { get; set; }
    internal DateTime? RetryAfterUtc { get; set; }
    internal int ConsecutiveFailures { get; set; }

    /// <summary>Last 500 output lines, for the row's log drawer.</summary>
    internal readonly Queue<string> Log = new();

    public bool UsesBuiltInServer => string.IsNullOrWhiteSpace(Command);

    public IReadOnlyList<string> Snapshot()
    {
        lock (Log)
            return Log.ToList();
    }

    internal void Append(string line)
    {
        lock (Log)
        {
            Log.Enqueue(line);
            while (Log.Count > 500)
                Log.Dequeue();
        }
    }
}

/// <summary>
/// Starts, stops and keeps alive the servers Serverlife manages.
///
/// The watchdog is the reason the app exists: a dev server that dies mid-presentation
/// should be back before the audience notices, without anyone alt-tabbing to a terminal.
/// </summary>
public sealed class Supervisor : IDisposable
{
    private static readonly TimeSpan WatchdogInterval = TimeSpan.FromSeconds(3);

    /// <summary>
    /// Backoff between restart attempts. A server that fails instantly and repeatedly is
    /// usually broken rather than unlucky, and hammering it just burns CPU during a talk.
    /// </summary>
    private static readonly TimeSpan[] Backoff =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
        TimeSpan.FromSeconds(15),
    ];

    private const int MaxConsecutiveFailures = 10;

    /// <summary>
    /// How long a server must stay up before its failure streak is forgiven. Without
    /// this, something that dies once an hour would exhaust its ten attempts over a day
    /// and then stay down — the exact opposite of the point.
    /// </summary>
    private static readonly TimeSpan HealthyResetAfter = TimeSpan.FromSeconds(60);

    private readonly List<ManagedServer> _servers = new();
    private readonly CancellationTokenSource _cts = new();

    public IReadOnlyList<ManagedServer> Servers
    {
        get { lock (_servers) return _servers.ToList(); }
    }

    /// <summary>Raised whenever a managed server changes state, on a background thread.</summary>
    public event Action<ManagedServer>? Changed;

    public void Start() => _ = WatchdogLoopAsync(_cts.Token);

    public ManagedServer Add(ManagedServer server)
    {
        lock (_servers)
            _servers.Add(server);
        return server;
    }

    public void Remove(ManagedServer server)
    {
        Stop(server);
        lock (_servers)
            _servers.Remove(server);
    }

    /// <summary>
    /// Takes over an already-running server so the watchdog can bring it back if it dies.
    /// It keeps running as it is — adopting does not restart it.
    /// </summary>
    public ManagedServer Adopt(DetectedServer detected)
    {
        var server = new ManagedServer
        {
            Name = detected.DisplayName,
            Directory = detected.WorkingDirectory ?? "",
            Command = detected.CommandLine ?? "",
            Port = detected.Port,
            State = ManagedState.Running,
            HealthySinceUtc = DateTime.UtcNow,
        };
        server.Append($"[serverlife] adopted PID {detected.Pid} on port {detected.Port}");
        return Add(server);
    }

    // ---- start / stop ------------------------------------------------------------

    public void StartServer(ManagedServer server)
    {
        Stop(server);

        server.LastError = null;
        server.State = ManagedState.Starting;
        Changed?.Invoke(server);

        try
        {
            if (server.UsesBuiltInServer)
                StartBuiltIn(server);
            else
                StartProcess(server);

            server.State = ManagedState.Running;
            server.HealthySinceUtc = DateTime.UtcNow;
        }
        catch (Exception e)
        {
            server.State = ManagedState.Failed;
            server.LastError = e.Message;
            server.Append($"[serverlife] start failed: {e.Message}");
        }

        Changed?.Invoke(server);
    }

    private static void StartBuiltIn(ManagedServer server)
    {
        var built = new StaticServer(server.Directory);
        built.Start();
        server.BuiltIn = built;
        server.Port = built.Port;
        server.Append($"[serverlife] built-in static server on http://localhost:{built.Port}/");
    }

    private void StartProcess(ManagedServer server)
    {
        var job = new JobObject();

        var info = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            // /C so cmd exits once the command does. The command is passed as one quoted
            // unit so its own quotes survive cmd's parsing.
            Arguments = $"/C \"{server.Command}\"",
            WorkingDirectory = server.Directory,
            UseShellExecute = false,
            // Without this every start flashes a console window on screen, which during a
            // presentation is exactly the thing this app is meant to prevent.
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        // A GUI app keeps the PATH it was launched with, so a Node that was installed (or
        // a version manager that re-pointed) since the last sign-in isn't on it and
        // "npm run dev" dies with "is not recognized". Hand the child the PATH a fresh
        // logon would have instead. info.Environment is pre-seeded with our own block, so
        // this replaces just the one entry.
        info.Environment["Path"] = EnvironmentPath.Value;

        var process = Process.Start(info)
            ?? throw new InvalidOperationException("Process.Start returned no process.");

        // Assign before the child has a chance to spawn anything, so descendants are
        // covered by the job from the outset.
        job.Assign(process);

        process.OutputDataReceived += (_, e) => { if (e.Data is not null) server.Append(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) server.Append(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        server.Process = process;
        server.Job = job;
        server.Append($"[serverlife] started: {server.Command}");
    }

    public void Stop(ManagedServer server)
    {
        // Killing the job takes the whole tree: "npm run dev" is cmd -> npm -> node, and
        // killing only the process we launched would leave node holding the port.
        server.Job?.Kill();
        server.Job?.Dispose();
        server.Job = null;

        try
        {
            server.Process?.Dispose();
        }
        catch (InvalidOperationException)
        {
        }
        server.Process = null;

        server.BuiltIn?.Dispose();
        server.BuiltIn = null;

        server.HealthySinceUtc = null;
        if (server.State is not ManagedState.Failed)
            server.State = ManagedState.Stopped;
        Changed?.Invoke(server);
    }

    // ---- watchdog ----------------------------------------------------------------

    private async Task WatchdogLoopAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(WatchdogInterval);
        while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false))
        {
            try
            {
                Tick();
            }
            catch (Exception e)
            {
                Debug.WriteLine($"[Serverlife] watchdog tick failed: {e}");
            }
        }
    }

    private void Tick()
    {
        var listening = PortScanner.GetListeners();

        foreach (var server in Servers)
        {
            if (server.State is ManagedState.Stopped or ManagedState.Starting)
                continue;

            if (IsHealthy(server, listening))
            {
                OnHealthy(server);
                continue;
            }

            if (!server.AutoRestart)
            {
                if (server.State is not ManagedState.Stopped)
                {
                    server.State = ManagedState.Stopped;
                    Changed?.Invoke(server);
                }
                continue;
            }

            AttemptRestart(server);
        }
    }

    /// <summary>
    /// Healthy means both that the process is alive and that its port is still accepting.
    /// The port matters on its own: a dev server can wedge, keep its process, and stop
    /// listening — from the audience's side that is indistinguishable from a crash.
    /// </summary>
    private static bool IsHealthy(ManagedServer server, List<Listener> listening)
    {
        if (server.UsesBuiltInServer)
            return server.BuiltIn is not null;

        if (server.Process is { HasExited: true })
            return false;

        if (server.Port is not { } port)
        {
            // Not yet known: still starting. Learn it from whichever process in our job
            // opened a socket - with "npm run dev" that is a grandchild we never held a
            // handle to, so the job is the only reliable way to recognise it as ours.
            if (server.Job is { } job)
            {
                var found = listening.FirstOrDefault(l => job.Contains(l.Pid));
                if (found.Port != 0)
                {
                    server.Port = found.Port;
                    server.Append($"[serverlife] listening on http://localhost:{found.Port}/");
                }
            }
            // An adopted or just-started server without a port yet is given the benefit
            // of the doubt rather than being restarted out from under itself.
            return true;
        }

        return listening.Any(l => l.Port == port);
    }

    private void OnHealthy(ManagedServer server)
    {
        server.HealthySinceUtc ??= DateTime.UtcNow;

        if (server.ConsecutiveFailures > 0
            && DateTime.UtcNow - server.HealthySinceUtc >= HealthyResetAfter)
        {
            server.ConsecutiveFailures = 0;
            server.RetryAfterUtc = null;
        }

        if (server.State is not ManagedState.Running)
        {
            server.State = ManagedState.Running;
            Changed?.Invoke(server);
        }
    }

    private void AttemptRestart(ManagedServer server)
    {
        var now = DateTime.UtcNow;
        if (server.RetryAfterUtc is { } after && now < after)
            return;

        if (server.ConsecutiveFailures >= MaxConsecutiveFailures)
        {
            if (server.State is not ManagedState.Failed)
            {
                server.State = ManagedState.Failed;
                server.LastError = $"Gave up after {MaxConsecutiveFailures} restart attempts.";
                server.Append($"[serverlife] {server.LastError}");
                Changed?.Invoke(server);
            }
            return;
        }

        server.State = ManagedState.Restarting;
        server.ConsecutiveFailures++;
        server.RestartCount++;
        server.HealthySinceUtc = null;
        Changed?.Invoke(server);

        server.Append($"[serverlife] died; restart attempt {server.ConsecutiveFailures}");
        StartServer(server);

        // Schedule the next attempt from the end of this one, so a server that fails
        // instantly still respects the backoff.
        var wait = Backoff[Math.Min(server.ConsecutiveFailures - 1, Backoff.Length - 1)];
        server.RetryAfterUtc = DateTime.UtcNow + wait;
    }

    public void Dispose()
    {
        _cts.Cancel();
        foreach (var server in Servers)
            Stop(server);
        _cts.Dispose();
    }
}
