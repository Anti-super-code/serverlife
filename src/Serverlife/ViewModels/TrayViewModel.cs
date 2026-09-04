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
/// Backs the tray window: owns the live row collection, the filter, and the commands the
/// rows expose. Discovery pushes from a background thread, so every mutation here is
/// marshalled onto the dispatcher first.
/// </summary>
public sealed partial class TrayViewModel : ObservableObject, IDisposable
{
    private readonly Discovery _discovery = new();

    /// <summary>
    /// Rows are kept and updated in place, keyed by (port, pid). Rebuilding the
    /// collection every 2s would reset hover, scroll position and selection - on a list
    /// that is meant to sit open all day, that reads as the UI flickering at you.
    /// </summary>
    private readonly Dictionary<(int Port, int Pid), ServerRowItem> _byKey = new();

    public ObservableCollection<ServerRowItem> Rows { get; } = new();

    [ObservableProperty] private RowFilter _filter = RowFilter.All;
    [ObservableProperty] private bool _showNonHttp;
    [ObservableProperty] private string _summary = "Looking for servers…";

    public TrayViewModel()
    {
        _discovery.Updated += OnDiscovered;
        _discovery.Start();
    }

    partial void OnFilterChanged(RowFilter value) => ApplyFilter();
    partial void OnShowNonHttpChanged(bool value) => ApplyFilter();

    private void OnDiscovered(IReadOnlyList<DetectedServer> servers)
    {
        // Discovery runs off the UI thread; the collection is bound, so it must not be
        // touched from there.
        Application.Current?.Dispatcher.BeginInvoke(() => Merge(servers));
    }

    private void Merge(IReadOnlyList<DetectedServer> servers)
    {
        var visible = servers.Where(s => ShowNonHttp || s.Probe.IsHttp).ToList();
        var seen = new HashSet<(int, int)>();

        foreach (var server in visible)
        {
            var key = (server.Port, server.Pid);
            seen.Add(key);

            if (_byKey.TryGetValue(key, out var existing))
            {
                existing.Apply(server);
                continue;
            }

            var row = new ServerRowItem(server);
            _byKey[key] = row;
            Rows.Add(row);
        }

        foreach (var (key, row) in _byKey.Where(kv => !seen.Contains(kv.Key)).ToList())
        {
            // A managed server that vanished is not gone from the list - it is stopped,
            // and the watchdog may be about to bring it back. Only unmanaged rows are
            // actually removed.
            if (row.IsManaged)
            {
                row.State = row.AutoRestart ? ServerState.Restarting : ServerState.Stopped;
                continue;
            }
            _byKey.Remove(key);
            Rows.Remove(row);
        }

        Reorder();
        ApplyFilter();
        UpdateSummary(servers.Count);
    }

    /// <summary>Ports ascending, which is the order people remember them in.</summary>
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

    private void UpdateSummary(int totalListening)
    {
        var contested = Rows.Where(r => r.IsContested).Select(r => r.Port).Distinct().Count();
        Summary = Rows.Count == 0
            ? "No local servers running"
            : $"{Rows.Count} server{(Rows.Count == 1 ? "" : "s")}" +
              (contested > 0 ? $"  ·  {contested} contested port{(contested == 1 ? "" : "s")}" : "");
    }

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

    public void Dispose() => _discovery.Dispose();
}
