using System.Diagnostics;
using System.IO;
using System.Net;

namespace Serverlife.Core;

/// <summary>One listening port, everything we know about it, ready to put in a row.</summary>
public sealed record DetectedServer(
    int Port,
    int Pid,
    int ParentPid,
    IPAddress Address,
    string ProcessName,
    string? CommandLine,
    string? WorkingDirectory,
    ProbeResult Probe,
    int PeersOnPort = 0)
{
    /// <summary>
    /// True when other, unrelated processes are bound to this same port. Windows permits
    /// that unless a socket asks for SO_EXCLUSIVEADDRUSE, so orphaned dev servers pile up
    /// invisibly and whichever bound last wins the connections. Surfacing it is the point:
    /// it explains "I edited the file and nothing changed".
    /// </summary>
    public bool IsContested => PeersOnPort > 0;

    /// <summary>
    /// Interpreters that tell you nothing about what is being served. For these the
    /// folder name is the far better label — "antidot 2026" beats "python.exe" — but
    /// for a named program like ollama.exe the process name is exactly right, and its
    /// folder (often system32) is actively misleading.
    /// </summary>
    private static readonly HashSet<string> GenericRuntimes = new(StringComparer.OrdinalIgnoreCase)
    {
        "node", "python", "python3", "pythonw", "dotnet", "ruby", "php", "java", "deno", "bun", "cargo", "go",
    };

    public string Url => $"{Probe.Scheme ?? "http"}://localhost:{Port}/";

    private string BareProcessName => Path.GetFileNameWithoutExtension(ProcessName);

    /// <summary>
    /// What the row leads with: the served page's title, else the folder name when the
    /// process is only an interpreter, else the program's own name.
    /// </summary>
    public string DisplayName
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(Probe.Title))
                return Probe.Title;

            if (GenericRuntimes.Contains(BareProcessName)
                && WorkingDirectory is { Length: > 0 } dir
                && Path.GetFileName(dir.TrimEnd('\\')) is { Length: > 0 } folder)
                return folder;

            return BareProcessName;
        }
    }

    /// <summary>
    /// Whether this could be relaunched if it died — the two facts a restart needs.
    /// </summary>
    public bool IsAdoptable => !string.IsNullOrWhiteSpace(CommandLine)
                            && !string.IsNullOrWhiteSpace(WorkingDirectory)
                            && Directory.Exists(WorkingDirectory);
}

/// <summary>
/// Polls for listening ports and describes what is behind them. Owns no UI and no
/// process lifetime: it only ever observes. Starting and stopping lives in Supervisor.
/// </summary>
public sealed class Discovery : IDisposable
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    private const int IdlePid = 0;

    /// <summary>
    /// The System process owns http.sys's reserved URL prefixes, which answer a probe
    /// with a real HTTP error page. That is never a dev server and can never be
    /// started or stopped, so it is dropped rather than shown as a row.
    /// </summary>
    private const int SystemPid = 4;

    /// <summary>
    /// Probe results keyed by port AND pid, so a port reused by a different process is
    /// re-probed rather than inheriting the old title. Without the pid in the key,
    /// restarting a server on the same port would keep showing its previous page.
    /// </summary>
    private readonly Dictionary<(int Port, int Pid), ProbeResult> _probeCache = new();

    private readonly CancellationTokenSource _cts = new();
    private readonly int _ownPid = Environment.ProcessId;
    private Task? _loop;

    /// <summary>Raised on a background thread after every poll; marshal to the UI yourself.</summary>
    public event Action<IReadOnlyList<DetectedServer>>? Updated;

    public void Start() => _loop ??= Task.Run(() => LoopAsync(_cts.Token));

    private async Task LoopAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(PollInterval);
        do
        {
            try
            {
                Updated?.Invoke(await ScanAsync(token).ConfigureAwait(false));
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception e)
            {
                // A single bad poll must not end the loop — the app's whole value is
                // being there when something else falls over.
                Debug.WriteLine($"[Serverlife] discovery poll failed: {e}");
            }
        }
        while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false));
    }

    /// <summary>One full pass: ports, then owning processes, then titles for anything new.</summary>
    public async Task<IReadOnlyList<DetectedServer>> ScanAsync(CancellationToken token = default)
    {
        var listeners = PortScanner.GetListeners()
            .Where(l => l.IsLocallyReachable)
            .Where(l => l.Pid != _ownPid && l.Pid != IdlePid && l.Pid != SystemPid)
            .ToList();

        // The same server usually holds both an IPv4 and an IPv6 socket on one port.
        // Collapse to one entry per (port, pid) before doing any real work.
        var unique = listeners
            .GroupBy(l => (l.Port, l.Pid))
            .Select(g => g.First())
            .ToList();

        var details = ProcessInspector.Describe(unique.Select(l => l.Pid).Distinct().ToList());
        DescribeSharedParents(unique, details);

        var servers = new List<DetectedServer>();
        foreach (var samePort in unique.GroupBy(l => l.Port))
        {
            token.ThrowIfCancellationRequested();

            var group = samePort.ToList();
            var owners = ResolveOwners(group, details);

            // One probe for the port, shared by every row on it: the processes are
            // fighting over one socket, so they necessarily serve the same response.
            var probe = await ProbeCachedAsync(samePort.Key, owners[0], token).ConfigureAwait(false);

            foreach (var pid in owners)
            {
                details.TryGetValue(pid, out var info);
                servers.Add(new DetectedServer(
                    Port: samePort.Key,
                    Pid: pid,
                    ParentPid: info?.ParentPid ?? 0,
                    Address: group[0].Address,
                    ProcessName: info?.Name ?? "unknown",
                    CommandLine: info?.CommandLine,
                    WorkingDirectory: info?.WorkingDirectory,
                    Probe: probe,
                    PeersOnPort: owners.Count - 1));
            }
        }

        PruneCache(unique);
        return servers.OrderBy(s => s.Port).ToList();
    }

    /// <summary>
    /// When a port's holders are all siblings forked by one supervisor, that supervisor
    /// is the process worth acting on even though it holds no socket itself — so it has
    /// to be described too. One extra WMI query, and only for ports that have more than
    /// one holder, which is uncommon.
    /// </summary>
    private static void DescribeSharedParents(List<Listener> listeners, Dictionary<int, ProcessDetails> details)
    {
        var extra = new HashSet<int>();
        foreach (var samePort in listeners.GroupBy(l => l.Port).Where(g => g.Count() > 1))
        {
            if (FindSharedParent(samePort.Select(l => l.Pid).ToList(), details) is { } parent
                && !details.ContainsKey(parent))
                extra.Add(parent);
        }

        foreach (var (pid, info) in ProcessInspector.Describe(extra))
            details[pid] = info;
    }

    /// <summary>The one parent common to every holder, when it exists and is not itself a holder.</summary>
    private static int? FindSharedParent(List<int> holders, Dictionary<int, ProcessDetails> details)
    {
        var holderSet = holders.ToHashSet();
        var parents = holders
            .Select(p => details.TryGetValue(p, out var info) ? info.ParentPid : 0)
            .Distinct()
            .ToList();

        if (parents.Count != 1)
            return null;
        var parent = parents[0];
        return parent is IdlePid or SystemPid || holderSet.Contains(parent) ? null : parent;
    }

    /// <summary>
    /// Resolves a port's holders to the processes actually worth showing and acting on.
    ///
    /// Several pids on one port means one of two very different things, and conflating
    /// them is a real bug either way:
    ///
    ///   * ONE server whose workers inherited the listening handle. Windows reports the
    ///     socket once per holder, but there is a single server; stopping a worker would
    ///     leave it running. Collapses to the ancestor or the supervisor that forked them.
    ///
    ///   * SEVERAL independent servers that each bound the same port, which Windows
    ///     permits unless a socket sets SO_EXCLUSIVEADDRUSE. Orphaned dev servers
    ///     accumulate exactly like this, and only the last binder gets the connections.
    ///     These stay as separate rows, flagged, because hiding them hides the problem.
    /// </summary>
    private static List<int> ResolveOwners(List<Listener> holders, Dictionary<int, ProcessDetails> details)
    {
        var pids = holders.Select(h => h.Pid).Distinct().ToList();
        if (pids.Count == 1)
            return pids;

        var pidSet = pids.ToHashSet();

        // A holder that is an ancestor of the others: one server, one row.
        var roots = pids
            .Where(p => details.TryGetValue(p, out var info) && !pidSet.Contains(info.ParentPid))
            .ToList();
        if (roots.Count == 1)
            return roots;

        // A live supervisor common to all of them: also one server, one row — and the
        // parent is the process to stop, even though it holds no socket itself.
        if (FindSharedParent(pids, details) is { } shared && details.ContainsKey(shared))
            return [shared];

        // Otherwise they are unrelated. Show every one, oldest first.
        return pids.OrderBy(p => p).ToList();
    }

    private async Task<ProbeResult> ProbeCachedAsync(int port, int pid, CancellationToken token)
    {
        if (_probeCache.TryGetValue((port, pid), out var cached))
            return cached;

        var result = await HttpProbe.ProbeAsync(port, token).ConfigureAwait(false);
        _probeCache[(port, pid)] = result;
        return result;
    }

    /// <summary>Drops cache entries for sockets that have gone, so it cannot grow without bound.</summary>
    private void PruneCache(List<Listener> live)
    {
        if (_probeCache.Count <= live.Count)
            return;
        var alive = live.Select(l => (l.Port, l.Pid)).ToHashSet();
        foreach (var key in _probeCache.Keys.Where(k => !alive.Contains(k)).ToList())
            _probeCache.Remove(key);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}
