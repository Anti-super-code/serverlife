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

    /// <summary>Gave up restarting, or the port went away unexpectedly. Theme "Danger".</summary>
    Failed,

    /// <summary>Known to us but not currently running. Theme "TextLo".</summary>
    Stopped,
}

/// <summary>
/// One line in the list. Deliberately flat and cheap: the poll rebuilds the collection
/// every two seconds, so rows are updated in place by port rather than recreated, which
/// is what keeps hover state and selection from flickering.
/// </summary>
public sealed partial class ServerRowItem : ObservableObject
{
    public ServerRowItem(DetectedServer server) => Apply(server);

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

    public bool IsContested => PeersOnPort > 0;

    /// <summary>
    /// The full detail, shown on hover. The list itself stays one line per row, so the
    /// folder and command live here rather than taking a second line from every row.
    /// </summary>
    public string Tooltip
    {
        get
        {
            var lines = new List<string> { $"{Url}  ·  PID {Pid}  ·  {ProcessName}" };
            if (!string.IsNullOrWhiteSpace(WorkingDirectory))
                lines.Add(WorkingDirectory);
            if (!string.IsNullOrWhiteSpace(CommandLine))
                lines.Add(CommandLine);
            if (IsContested)
                lines.Add($"⚠ {PeersOnPort + 1} unrelated processes are bound to port {Port}. " +
                          "Only the last one to bind is serving.");
            else if (!IsAdoptable)
                lines.Add("Cannot be restarted: no readable command line or working directory.");
            return string.Join("\n", lines);
        }
    }

    /// <summary>Refreshes in place from a fresh poll, so the row object survives.</summary>
    public void Apply(DetectedServer server)
    {
        Port = server.Port;
        Pid = server.Pid;
        DisplayName = server.DisplayName;
        ProcessName = server.ProcessName;
        WorkingDirectory = server.WorkingDirectory;
        CommandLine = server.CommandLine;
        Url = server.Url;
        IsAdoptable = server.IsAdoptable;
        PeersOnPort = server.PeersOnPort;
        OnPropertyChanged(nameof(IsContested));
        OnPropertyChanged(nameof(Tooltip));
    }

    /// <summary>Identity across polls: a port plus the process behind it.</summary>
    public (int Port, int Pid) Key => (Port, Pid);
}
