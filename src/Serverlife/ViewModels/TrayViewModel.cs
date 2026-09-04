using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Serverlife.Core;

namespace Serverlife.ViewModels;

public enum RowFilter { All, Running, Managed }

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

    [ObservableProperty] private RowFilter _filter = RowFilter.All;
    [ObservableProperty] private bool _showNonHttp;
    [ObservableProperty] private string _summary = "Looking for servers…";

    // ---- pending drop ----
    [ObservableProperty] private string? _dropFolder;
    [ObservableProperty] private string _dropCommand = "";
    [ObservableProperty] private string _dropWhy = "";

    public bool HasPendingDrop => DropFolder is not null;
    public string DropFolderName => DropFolder is null ? "" : Path.GetFileName(DropFolder.TrimEnd('\\'));

    public TrayViewModel()
    {
        _discovery.Updated += OnDiscovered;
        _supervisor.Changed += _ => Application.Current?.Dispatcher.BeginInvoke(RefreshManagedState);
        _discovery.Start();
        _supervisor.Start();
    }

    partial void OnFilterChanged(RowFilter value) => ApplyFilter();
    partial void OnShowNonHttpChanged(bool value) => ApplyFilter();

    partial void OnDropFolderChanged(string? value)
    {
        OnPropertyChanged(nameof(HasPendingDrop));
        OnPropertyChanged(nameof(DropFolderName));
    }

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
        ApplyFilter();
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
        var view = System.Windows.Data.CollectionViewSource.GetDefaultView(Rows);
        view.Filter = Filter switch
        {
            RowFilter.Running => o => o is ServerRowItem { State: ServerState.Running },
            RowFilter.Managed => o => o is ServerRowItem { IsManaged: true },
            _ => null,
        };
        view.Refresh();
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
        if (row is null)
            return;
        // UseShellExecute sends it to the default browser rather than trying to exec a URL.
        Process.Start(new ProcessStartInfo(row.Url) { UseShellExecute = true });
    }

    [RelayCommand]
    private static void CopyUrl(ServerRowItem? row)
    {
        if (row is not null)
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
