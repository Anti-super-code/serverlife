using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using Serverlife.Core;
using Serverlife.UI;
using Serverlife.ViewModels;
using Forms = System.Windows.Forms;

namespace Serverlife;

public partial class App : Application
{
    private Forms.NotifyIcon? _tray;
    private TrayViewModel? _model;
    private TrayWindow? _window;
    private readonly SingleInstance _singleInstance = new();
    private readonly CancellationTokenSource _pipeCts = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // A resident app's whole value is being there when something else falls over -
        // one row's button hitting an edge case (see OnDispatcherUnhandledException)
        // should not take the tray icon down with it, the way it just did.
        DispatcherUnhandledException += OnDispatcherUnhandledException;

        // Headless paths finish and exit without ever creating a window. ShutdownMode is
        // OnExplicitShutdown throughout, because for the GUI a closed window means hidden,
        // not quit - see TrayWindow.OnClosing.
        if (e.Args.FirstOrDefault() is "--scan" or "--run")
        {
            _ = RunHeadlessAsync(e.Args);
            return;
        }

        var folderArg = e.Args.FirstOrDefault(Directory.Exists) is { } f ? Path.GetFullPath(f) : null;

        // Serverlife is resident, but the "Start server here" Explorer verb launches a new
        // process every time it's used. A second copy would mean a second tray icon and a
        // second discovery loop, so a launch that finds one already running just hands its
        // folder over the pipe and quits instead of ever creating a window.
        if (!_singleInstance.TryBecomePrimary())
        {
            SingleInstance.TrySendToPrimary(folderArg);
            Shutdown(0);
            return;
        }

        _model = new TrayViewModel();
        _window = new TrayWindow(_model);
        CreateTrayIcon();

        // A folder on the command line is staged exactly like a drop. This is the entry
        // point the Explorer "Start server here" folder verb uses, since dropping onto
        // a taskbar button is not something the Windows shell delivers to a running app.
        if (folderArg is not null)
            _model.PrepareDrop(folderArg);

        _ = _singleInstance.RunServerAsync(OnFolderFromLaterLaunch, _pipeCts.Token);

        // Starts visible on first run so it is obvious the app launched; after that the
        // tray icon is how it comes back.
        _window.ShowFromTray();
    }

    /// <summary>
    /// Runs on the pipe server's background thread whenever a later launch (typically the
    /// "Start server here" verb) hands off its folder — or, with no folder, just asks to
    /// be brought to the front.
    /// </summary>
    private void OnFolderFromLaterLaunch(string? folder) => Dispatcher.BeginInvoke(() =>
    {
        if (folder is not null && Directory.Exists(folder))
            _model?.PrepareDrop(folder);
        _window?.ShowFromTray();
    });

    private void CreateTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Show Serverlife", null, (_, _) => _window?.ShowFromTray());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Shutdown(0));

        _tray = new Forms.NotifyIcon
        {
            Icon = LoadTrayIcon(),
            Text = "Serverlife",
            Visible = true,
            ContextMenuStrip = menu,
        };
        // Left-click toggles, which is what a tray panel is expected to do; the menu is
        // on right-click, handled by ContextMenuStrip itself.
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button != Forms.MouseButtons.Left)
                return;
            if (_window is { IsVisible: true })
                _window.Hide();
            else
                _window?.ShowFromTray();
        };
    }

    /// <summary>
    /// Reads the multi-size .ico out of our own resources so Windows can pick the size
    /// the notification area actually wants, which varies with DPI. Falls back to the
    /// stock application icon rather than failing to create a tray presence at all.
    /// </summary>
    private static System.Drawing.Icon LoadTrayIcon()
    {
        try
        {
            var uri = new Uri("pack://application:,,,/Assets/serverlife.ico");
            using var stream = GetResourceStream(uri)?.Stream;
            if (stream is not null)
                return new System.Drawing.Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
        }
        catch (Exception)
        {
        }
        return System.Drawing.SystemIcons.Application;
    }

    /// <summary>
    /// Last line of defence: logs and swallows rather than letting one bad click end the
    /// whole resident process - the state a mid-action exception leaves things in is a
    /// smaller problem for a tray app than the tray icon silently vanishing.
    /// </summary>
    private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Debug.WriteLine($"[Serverlife] unhandled UI exception: {e.Exception}");
        e.Handled = true;
    }

    private async Task RunHeadlessAsync(string[] args)
    {
        var exitCode = await CliRunner.RunAsync(args).ConfigureAwait(true);
        Shutdown(exitCode);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        // The tray icon outlives the process unless it is explicitly disposed, leaving a
        // ghost that only vanishes when the user mouses over it.
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        _model?.Dispose();
        _pipeCts.Cancel();
        _singleInstance.Dispose();
        base.OnExit(e);
    }
}

