using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using Serverlife.Core;

namespace Serverlife.ViewModels;

/// <summary>How a row's status dot reads. Maps onto the theme's semantic colours.</summary>
public enum ServerState
{
    /// <summary>Listening and answering. Theme "Good".</summary>
    Running,

    /// <summary>Died and is being brought back by the watchdog. Theme "Warn".</summary>
    Restarting,

    /// <summary>Gave up restarting, or failed to start at all. Theme "Danger".</summary>
    Failed,

    /// <summary>Known to us but not currently running. Theme "TextLo".</summary>
    Stopped,
}

/// <summary>
/// One line in the list. A row comes from discovery (an external server), from the
/// supervisor (one we manage), or from both once a managed server starts listening and
/// discovery finds it by port.
/// </summary>
public sealed partial class ServerRowItem : ObservableObject
{
    /// <summary>A row for something discovered listening.</summary>
    public ServerRowItem(DetectedServer server) => Apply(server);

    /// <summary>A row for a managed server that is not currently listening, so has no pid.</summary>
    public ServerRowItem(ManagedServer managed)
    {
        Managed = managed;
        IsManaged = true;
        DisplayName = managed.Name;
        WorkingDirectory = managed.Directory;
        CommandLine = managed.Command;
        Port = managed.Port ?? 0;
        // You dropped or adopted this one yourself, so it's yours by definition —
        // regardless of what OriginClassifier would make of its folder.
        Origin = ServerOrigin.Mine;
        SyncFromManaged();
    }

    [ObservableProperty] private int _port;
    [ObservableProperty] private int _pid;
    [ObservableProperty] private string _displayName = "";
    [ObservableProperty] private string _processName = "";
    [ObservableProperty] private string? _workingDirectory;
    [ObservableProperty] private string? _commandLine;
    [ObservableProperty] private string _url = "";
    [ObservableProperty] private ServerState _state = ServerState.Running;
    [ObservableProperty] private bool _isManaged;
    [ObservableProperty] private bool _autoRestart;
    [ObservableProperty] private bool _isAdoptable;
    [ObservableProperty] private int _peersOnPort;
    [ObservableProperty] private int _restartCount;
    [ObservableProperty] private ServerOrigin _origin = ServerOrigin.Unknown;

    /// <summary>The supervisor's record, when this row is managed. Null for external servers.</summary>
    internal ManagedServer? Managed { get; set; }

    /// <summary>The last discovery snapshot, kept so "Manage this" can adopt it.</summary>
    internal DetectedServer? Detected { get; private set; }

    public bool IsContested => PeersOnPort > 0;

    /// <summary>Running out of an OS or installed-application folder — not one of your projects.</summary>
    public bool IsSystem => Origin == ServerOrigin.System;

    /// <summary>Only an external server with a readable command and folder can be adopted.</summary>
    public bool CanManage => Managed is null && IsAdoptable;

    /// <summary>
    /// False for a managed row between "added" and "actually listening" — no port yet,
    /// so Url is still "". Open/Copy hide rather than firing at an empty string.
    /// </summary>
    public bool HasUrl => Url.Length > 0;

    /// <summary>
    /// The full detail, shown on hover. The list itself stays one line per row, so the
    /// folder and command live here rather than taking a second line from every row.
    /// </summary>
    public string Tooltip
    {
        get
        {
            var lines = new List<string> { Port > 0 ? $"{Url}  ·  PID {Pid}" : "not running" };
            if (!string.IsNullOrWhiteSpace(WorkingDirectory))
                lines.Add(WorkingDirectory);
            if (!string.IsNullOrWhiteSpace(CommandLine))
                lines.Add(CommandLine);
            if (RestartCount > 0)
                lines.Add($"Restarted {RestartCount} time{(RestartCount == 1 ? "" : "s")} by Serverlife.");
            if (Managed?.LastError is { Length: > 0 } error)
                lines.Add("⚠ " + error);
            if (IsContested)
                lines.Add($"⚠ {PeersOnPort + 1} unrelated processes are bound to port {Port}. " +
                          "Only the last one to bind is serving.");
            else if (Managed is null && !IsAdoptable)
                lines.Add("Cannot be restarted: no readable command line or working directory.");
            if (IsSystem)
                lines.Add("Looks like it belongs to an installed app or the OS, not one of your projects.");
            return string.Join("\n", lines);
        }
    }

    /// <summary>Refreshes in place from a fresh poll, so the row object survives.</summary>
    public void Apply(DetectedServer server)
    {
        Detected = server;
        Port = server.Port;
        Pid = server.Pid;
        ProcessName = server.ProcessName;
        Url = server.Url;
        IsAdoptable = server.IsAdoptable;
        PeersOnPort = server.PeersOnPort;

        // A managed server's own name and command are authoritative: they are what will
        // be used to restart it, and discovery only ever sees what is running right now.
        if (Managed is null)
        {
            DisplayName = server.DisplayName;
            WorkingDirectory = server.WorkingDirectory;
            CommandLine = server.CommandLine;
            State = ServerState.Running;
            Origin = server.Origin;
        }

        Notify();
    }

    /// <summary>Pulls state across from the supervisor after it reports a change.</summary>
    public void SyncFromManaged()
    {
        if (Managed is not { } managed)
            return;

        State = managed.State switch
        {
            ManagedState.Running => ServerState.Running,
            ManagedState.Restarting or ManagedState.Starting => ServerState.Restarting,
            ManagedState.Failed => ServerState.Failed,
            _ => ServerState.Stopped,
        };
        AutoRestart = managed.AutoRestart;
        RestartCount = managed.RestartCount;
        if (managed.Port is { } port)
        {
            Port = port;
            Url = $"http://localhost:{port}/";
        }
        Notify();
    }

    private void Notify()
    {
        OnPropertyChanged(nameof(IsContested));
        OnPropertyChanged(nameof(IsSystem));
        OnPropertyChanged(nameof(CanManage));
        OnPropertyChanged(nameof(HasUrl));
        OnPropertyChanged(nameof(Tooltip));
    }

    /// <summary>Identity across polls: a port plus the process behind it.</summary>
    public (int Port, int Pid) Key => (Port, Pid);

    /// <summary>Log lines for the row's drawer, newest last.</summary>
    public IReadOnlyList<string> Log => Managed?.Snapshot() ?? [];
}
