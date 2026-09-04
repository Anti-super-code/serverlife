using System.Windows;
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

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Headless paths finish and exit without ever creating a window. ShutdownMode is
        // OnExplicitShutdown throughout, because for the GUI a closed window means hidden,
        // not quit — see TrayWindow.OnClosing.
        if (e.Args.FirstOrDefault() is "--scan" or "--run")
        {
            _ = RunHeadlessAsync(e.Args);
            return;
        }

        _model = new TrayViewModel();
        _window = new TrayWindow(_model);
        CreateTrayIcon();

        // Starts visible on first run so it is obvious the app launched; after that the
        // tray icon is how it comes back.
        _window.ShowFromTray();
    }

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
        base.OnExit(e);
    }
}
