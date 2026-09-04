using System.Windows;
using Serverlife.Core;

namespace Serverlife;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Headless paths finish and exit; they never create a window. ShutdownMode is
        // OnExplicitShutdown throughout because the GUI is a resident tray app whose
        // window closing must not end the process.
        if (e.Args.Length > 0 && e.Args[0] == "--scan")
        {
            _ = RunHeadlessAsync(e.Args);
            return;
        }

        MessageBox.Show(
            "Discovery is wired up; the tray UI is next.\n\n" +
            "Try it now from a terminal:\n    Serverlife.exe --scan",
            "Serverlife",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
        Shutdown(0);
    }

    private async Task RunHeadlessAsync(string[] args)
    {
        var exitCode = await CliRunner.RunAsync(args).ConfigureAwait(true);
        Shutdown(exitCode);
    }
}
