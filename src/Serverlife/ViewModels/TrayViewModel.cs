using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Serverlife.Core;

namespace Serverlife.ViewModels;

public enum RowFilter { All, Mine, Running }

/// <summary>
/// Backs the tray window: owns the live row collection, the filter, the pending drop, and
/// the commands the rows expose. Discovery and the supervisor both push from background
/// threads, so every mutation here is marshalled onto the dispatcher first.
/// </summary>
public sealed partial class TrayViewModel : ObservableObject, IDisposable
{
    private readonly Discovery _discovery = new();
    private readonly Supervisor _supervisor = new();

    /// <summary>
    /// Rows are kept and updated in place, keyed by (port, pid). Rebuilding the
    /// collection every 2s would reset hover, scroll position and selection - on a list
    /// meant to sit open all day, that reads as the UI flickering at you.
    /// </summary>
    private readonly Dictionary<(int Port, int Pid), ServerRowItem> _byKey = new();

    /// <summary>Rows for managed servers that are not currently listening, so have no pid.</summary>
    private readonly Dictionary<ManagedServer, ServerRowItem> _managedRows = new();

    public ObservableCollection<ServerRowItem> Rows { get; } = new();

    private readonly ICollectionView _rowsView;

    // Defaults to "Mine" rather than "All": the whole point of the origin split is that
    // an OS or installed-app server shouldn't be sitting in easy reach of Stop by default.
    // "All" is one click away when you actually want to see everything.
    [ObservableProperty] private RowFilter _filter = RowFilter.Mine;
    [ObservableProperty] private bool _showNonHttp;
    [ObservableProperty] private string _summary = "Looking for servers…";

    // ---- pending drop ----
    [ObservableProperty] private string? _dropFolder;
    [ObservableProperty] private string _dropCommand = "";
    [ObservableProperty] private string _dropWhy = "";

    public bool HasPendingDrop => DropFolder is not null;
    public string DropFolderName => DropFolder is null ? "" : Path.GetFileName(DropFolder.TrimEnd('\\'));
    public bool ShowDropCommandPlaceholder => DropCommand.Length == 0;

    public TrayViewModel()
    {
        _rowsView = CollectionViewSource.GetDefaultView(Rows);
        EnableLiveFiltering();
        ApplyFilter();

        _discovery.Updated += OnDiscovered;
        _supervisor.Changed += _ => Application.Current?.Dispatcher.BeginInvoke(RefreshManagedState);
        _discovery.Start();
        _supervisor.Start();
    }

    /// <summary>
    /// Without this, every 2s poll's ApplyFilter() -> Refresh() reset the whole
    /// CollectionView, which WPF answers by tearing down and rebuilding every row's
    /// container - visible as the list flashing even when nothing about it actually
    /// changed. Live filtering re-evaluates only the row whose filter-relevant property
    /// just changed, so membership updates land without touching the rest.
    /// </summary>
    private void EnableLiveFiltering()
    {
        if (_rowsView is not ICollectionViewLiveShaping liveShaping || !liveShaping.CanChangeLiveFiltering)
            return;
        liveShaping.LiveFilteringProperties.Add(nameof(ServerRowItem.Origin));
        liveShaping.LiveFilteringProperties.Add(nameof(ServerRowItem.State));
        liveShaping.IsLiveFiltering = true;
    }

    partial void OnFilterChanged(RowFilter value) => ApplyFilter();
    partial void OnShowNonHttpChanged(bool value) => ApplyFilter();

    partial void OnDropFolderChanged(string? value)
    {
        OnPropertyChanged(nameof(HasPendingDrop));
        OnPropertyChanged(nameof(DropFolderName));
    }

    partial void OnDropCommandChanged(string value) => OnPropertyChanged(nameof(ShowDropCommandPlaceholder));

    // ---- drop to serve ------------------------------------------------------------

    /// <summary>
    /// Stages a dropped folder with its guessed command. Deliberately does not start it:
    /// the guess is shown in an editable field first, because picking "build" instead of
    /// "dev" is both easy and slow to notice.
    /// </summary>
    public void PrepareDrop(string folder)
    {
        if (!Directory.Exists(folder))
            return;
        var suggestion = ProjectDetector.Suggest(folder);
        DropFolder = folder;
        DropCommand = suggestion.Command;
        DropWhy = suggestion.Why;
    }

    [RelayCommand]
    private void ConfirmDrop()
    {
        if (DropFolder is not { } folder)
            return;

        var server = _supervisor.Add(new ManagedServer
        {
            Name = Path.GetFileName(folder.TrimEnd('\\')),
            Directory = folder,
            Command = DropCommand.Trim(),
            AutoRestart = true,
        });

        CancelDrop();
        Task.Run(() => _supervisor.StartServer(server));
    }

    [RelayCommand]
    private void CancelDrop()
    {
        DropFolder = null;
        DropCommand = "";
        DropWhy = "";
    }

    // ---- discovery merge ----------------------------------------------------------

    private void OnDiscovered(IReadOnlyList<DetectedServer> servers) =>
        Application.Current?.Dispatcher.BeginInvoke(() => Merge(servers));

    private void Merge(IReadOnlyList<DetectedServer> servers)
    {
        var visible = servers.Where(s => ShowNonHttp || s.Probe.IsHttp).ToList();
        var managedByPort = _supervisor.Servers
            .Where(s => s.Port is not null)
            .GroupBy(s => s.Port!.Value)
            .ToDictionary(g => g.Key, g => g.First());

        // Managed servers not yet tied to a port, keyed by their (canonicalised) folder —
        // used below to adopt a listener discovered running out of that exact folder.
        var unlinkedManagedByDir = new Dictionary<string, ManagedServer>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in _supervisor.Servers)
            if (s.Port is null && CanonicalDir(s.Directory) is { Length: > 0 } dir)
                unlinkedManagedByDir[dir] = s;

        // A managed server owns exactly one row for its whole life, whether or not it is
        // currently listening. Creating it here rather than from discovery is what stops
        // a server appearing twice — once as "the thing we manage" and again as "a port
        // that happens to be open" — the moment it starts and discovery notices its port.
        var live = _supervisor.Servers;
        foreach (var managed in live)
        {
            if (_managedRows.ContainsKey(managed))
                continue;
            var created = new ServerRowItem(managed);
            _managedRows[managed] = created;
            Rows.Add(created);
        }

        var seen = new HashSet<(int, int)>();
        foreach (var server in visible)
        {
            // Discovered a port a managed server owns: fold the detail into that server's
            // existing row instead of making a second one.
            if (managedByPort.TryGetValue(server.Port, out var owner)
                && _managedRows.TryGetValue(owner, out var ownerRow))
            {
                ownerRow.Apply(server);
                continue;
            }

            // A managed server we haven't tied to a port yet, with a listener running out
            // of its exact folder: almost certainly the same server. Adopt the port so the
            // row gets its URL and the watchdog can health-check by port instead of walking
            // the process tree — "npm run dev" puts the socket on a grandchild the job
            // check can miss, and this also covers a dev server started by hand from an
            // editor in that folder. Only fires while the managed entry has no port, so it
            // won't hijack an unrelated server.
            if (CanonicalDir(server.WorkingDirectory) is { Length: > 0 } wd
                && unlinkedManagedByDir.TryGetValue(wd, out var dirOwner)
                && _managedRows.TryGetValue(dirOwner, out var dirOwnerRow))
            {
                dirOwner.Port = server.Port;
                managedByPort[server.Port] = dirOwner;
                unlinkedManagedByDir.Remove(wd);
                dirOwnerRow.Apply(server);
                continue;
            }

            var key = (server.Port, server.Pid);
            seen.Add(key);

            if (_byKey.TryGetValue(key, out var row))
                row.Apply(server);
            else
            {
                row = new ServerRowItem(server);
                _byKey[key] = row;
                Rows.Add(row);
            }
        }

        foreach (var (key, row) in _byKey.Where(kv => !seen.Contains(kv.Key)).ToList())
        {
            _byKey.Remove(key);
            Rows.Remove(row);
        }

        // Rows for servers that are no longer supervised at all.
        foreach (var (managed, row) in _managedRows.Where(kv => !live.Contains(kv.Key)).ToList())
        {
            _managedRows.Remove(managed);
            Rows.Remove(row);
        }

        RefreshManagedState();
        Reorder();
        // No ApplyFilter()/Refresh() here: live filtering (set up once in the constructor)
        // already re-evaluates membership as row properties change, and Rows.Add/Remove
        // above already carries new/gone rows through the existing filter on its own.
        UpdateSummary();
    }

    private void Attach(ServerRowItem row, ManagedServer managed)
    {
        row.Managed = managed;
        row.IsManaged = true;
        row.AutoRestart = managed.AutoRestart;
        _managedRows[managed] = row;
    }

    private void RefreshManagedState()
    {
        foreach (var row in Rows.Where(r => r.Managed is not null))
            row.SyncFromManaged();
    }

    private void Reorder()
    {
        var ordered = Rows.OrderBy(r => r.Port).ThenBy(r => r.Pid).ToList();
        for (var target = 0; target < ordered.Count; target++)
        {
            var current = Rows.IndexOf(ordered[target]);
            if (current != target)
                Rows.Move(current, target);
        }
    }

    private void ApplyFilter()
    {
        // Assigning Filter already re-evaluates every row on its own; called only when
        // the filter itself changes (a deliberate click), never from the discovery poll.
        _rowsView.Filter = Filter switch
        {
            // Unknown origin (the PEB read failed, or the row is still non-HTTP) is kept
            // rather than hidden: only a confidently-System row is filtered out here, so
            // a real dev server never disappears just because its folder couldn't be read.
            RowFilter.Mine => o => o is ServerRowItem { Origin: not ServerOrigin.System },
            RowFilter.Running => o => o is ServerRowItem { State: ServerState.Running },
            _ => null,
        };
    }

    private void UpdateSummary()
    {
        var contested = Rows.Where(r => r.IsContested).Select(r => r.Port).Distinct().Count();
        var managed = Rows.Count(r => r.IsManaged);
        Summary = Rows.Count == 0
            ? "No local servers running"
            : $"{Rows.Count} server{(Rows.Count == 1 ? "" : "s")}"
              + (managed > 0 ? $"  ·  {managed} managed" : "")
              + (contested > 0 ? $"  ·  {contested} contested port{(contested == 1 ? "" : "s")}" : "");
    }

    // ---- row commands -------------------------------------------------------------

    [RelayCommand]
    private static void Open(ServerRowItem? row)
    {
        // Url is "" for a managed row that hasn't started listening yet - passing that as
        // a FileName throws and previously took the whole app down (no ProcessStartInfo,
        // no process). The button hides itself via HasUrl; this guards the command too.
        if (row is not { HasUrl: true })
            return;
        // UseShellExecute sends it to the default browser rather than trying to exec a URL.
        Process.Start(new ProcessStartInfo(row.Url) { UseShellExecute = true });
    }

    [RelayCommand]
    private static void CopyUrl(ServerRowItem? row)
    {
        if (row is { HasUrl: true })
            Clipboard.SetText(row.Url);
    }

    [RelayCommand]
    private static void RevealFolder(ServerRowItem? row)
    {
        if (row?.WorkingDirectory is not { Length: > 0 } dir || !Directory.Exists(dir))
            return;
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dir}\"") { UseShellExecute = true });
    }

    /// <summary>
    /// Inline rename from the row (double-click the name). Managed rows only — a discovered
    /// row's name is refreshed from discovery on every poll, so a rename there wouldn't
    /// stick. Label only: the folder and command are left untouched.
    /// </summary>
    public void Rename(ServerRowItem? row, string? newName)
    {
        if (row is not { IsManaged: true, Managed: { } managed })
            return;
        var name = (newName ?? "").Trim();
        if (name.Length == 0 || name == row.DisplayName)
            return;
        managed.Name = name;
        row.DisplayName = name;
    }

    /// <summary>
    /// Absolute, link-resolved, trailing-slash-trimmed path, so a managed server's folder
    /// can be matched against a discovered process's working directory without tripping
    /// over a trailing slash or a symlinked project dir. "" when the path is unusable.
    /// </summary>
    private static string CanonicalDir(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return "";
        try
        {
            var full = Path.GetFullPath(path);
            if (Directory.Exists(full)
                && new DirectoryInfo(full).ResolveLinkTarget(returnFinalTarget: true) is { FullName: var target })
                full = target;
            return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch
        {
            return "";
        }
    }

    /// <summary>
    /// Takes over an external server so the watchdog covers it. It is not restarted —
    /// adopting something mid-presentation must not interrupt it.
    /// </summary>
    [RelayCommand]
    private void Manage(ServerRowItem? row)
    {
        if (row?.Managed is not null || row?.Detected is not { } detected || !row.IsAdoptable)
            return;
        var managed = _supervisor.Adopt(detected);
        Attach(row, managed);
        // Ownership of the row moves to the managed table; leaving it in the discovered
        // one would let the next poll build a second row for the same server.
        _byKey.Remove(row.Key);
        UpdateSummary();

        // The Manage button's own Visibility is bound to CanManage, which just went false -
        // so the element under the cursor vanished mid-click. WPF doesn't re-check hover
        // state on its own until the next real mouse move, leaving the row's action panel
        // stuck showing. Forcing a re-sync now is what that next mouse move would have done.
        Mouse.Synchronize();
    }

    // ---- manual origin pins ---------------------------------------------------------
    //
    // The Mine/System split is a best-effort guess from where a server runs, and it will
    // occasionally get something wrong - a folder that happens to sit under AppData\Local,
    // or a service like the GT3 one a user hit whose folder can't be read at all. These
    // let a right-click correct it, in either direction, and the correction sticks.

    [RelayCommand]
    private static void MarkNotMine(ServerRowItem? row)
    {
        if (row is not { IsManaged: false, OverrideKey.Length: > 0 })
            return;
        OriginOverrideStore.Set(row.OverrideKey, ServerOrigin.System);
        row.Origin = ServerOrigin.System;
        row.Notify();
    }

    [RelayCommand]
    private static void MarkMine(ServerRowItem? row)
    {
        if (row is not { IsManaged: false, OverrideKey.Length: > 0 })
            return;
        OriginOverrideStore.Set(row.OverrideKey, ServerOrigin.Mine);
        row.Origin = ServerOrigin.Mine;
        row.Notify();
    }

    [RelayCommand]
    private static void ResetOrigin(ServerRowItem? row)
    {
        if (row is not { IsManaged: false, OverrideKey.Length: > 0 })
            return;
        OriginOverrideStore.Clear(row.OverrideKey);
        // Re-derive from the heuristic immediately rather than waiting for the next poll.
        row.Origin = OriginClassifier.Classify(row.WorkingDirectory);
        row.Notify();
    }

    [RelayCommand]
    private void Stop(ServerRowItem? row)
    {
        if (row is null)
            return;

        if (row.Managed is { } managed)
        {
            // Turn auto-restart off first, or the watchdog treats a deliberate stop as a
            // crash and immediately puts it back.
            managed.AutoRestart = false;
            row.AutoRestart = false;
            Task.Run(() => _supervisor.Stop(managed));
            return;
        }

        // Not ours: no job object to fall back on, so the tree is walked by pid.
        KillExternal(row.Pid);
    }

    [RelayCommand]
    private void Restart(ServerRowItem? row)
    {
        if (row?.Managed is not { } managed)
            return;
        Task.Run(() => _supervisor.StartServer(managed));
    }

    [RelayCommand]
    private void ToggleAutoRestart(ServerRowItem? row)
    {
        if (row?.Managed is not { } managed)
            return;
        managed.AutoRestart = !managed.AutoRestart;
        row.AutoRestart = managed.AutoRestart;
    }

    /// <summary>
    /// taskkill /T /F for processes we did not start. It walks the tree by parent id,
    /// which misses children already orphaned by an exited intermediate — the reason
    /// servers we start get a job object instead.
    /// </summary>
    private static void KillExternal(int pid)
    {
        try
        {
            using var kill = Process.Start(new ProcessStartInfo("taskkill.exe", $"/PID {pid} /T /F")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            kill?.WaitForExit(5000);
        }
        catch (Exception e)
        {
            Debug.WriteLine($"[Serverlife] taskkill for {pid} failed: {e.Message}");
        }
    }

    public void Dispose()
    {
        _discovery.Dispose();
        _supervisor.Dispose();
    }
}
