using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Serverlife.ViewModels;

namespace Serverlife.UI;

public partial class TrayWindow : Window
{
    private readonly TrayViewModel _model;

    public TrayWindow(TrayViewModel model)
    {
        _model = model;
        InitializeComponent();
        DataContext = model;
    }

    /// <summary>
    /// Bottom-right of the work area, which is where the notification area is and so
    /// where the eye already is after clicking the tray icon. WorkArea rather than screen
    /// bounds, so it clears the taskbar wherever the taskbar happens to live.
    /// </summary>
    public void PositionNearTray()
    {
        var work = SystemParameters.WorkArea;
        Left = work.Right - Width - 8;
        Top = work.Bottom - Height - 8;
    }

    public void ShowFromTray()
    {
        if (!IsVisible)
        {
            PositionNearTray();
            Show();
        }
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
    }

    /// <summary>
    /// The panel is frameless, so the header doubles as the title bar. DragMove throws
    /// if the button is already up by the time it runs, which happens on a fast click.
    /// </summary>
    private void OnChromeDrag(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || e.ButtonState != MouseButtonState.Pressed)
            return;
        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
        }
    }

    /// <summary>Closing hides: this is a resident app, and the tray icon is the real window list.</summary>
    private void OnCloseClicked(object sender, RoutedEventArgs e) => Hide();

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        // Alt+F4 and the taskbar's Close both mean "get out of my way", not "quit".
        // Quitting is deliberate, from the tray menu.
        e.Cancel = true;
        Hide();
    }

    private void OnFilterChecked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string tag } && Enum.TryParse<RowFilter>(tag, out var filter))
            _model.Filter = filter;
    }

    // ---- drop a folder to serve it -------------------------------------------------

    /// <summary>
    /// Folders only. Dropping a file is almost always a mis-drop, and the cursor saying
    /// "no" is a clearer answer than accepting it and serving the parent directory.
    /// </summary>
    private static string? DroppedFolder(DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop))
            return null;
        return e.Data.GetData(DataFormats.FileDrop) is string[] paths
            ? paths.FirstOrDefault(Directory.Exists)
            : null;
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        var folder = DroppedFolder(e);
        e.Effects = folder is null ? DragDropEffects.None : DragDropEffects.Copy;
        e.Handled = true;

        if (folder is null)
            return;
        DropHint.Background = (Brush)FindResource("Accent");
        DropHintText.Text = $"Serve “{Path.GetFileName(folder.TrimEnd('\\'))}”";
        DropHintText.Foreground = Brushes.White;
    }

    private void OnDragLeave(object sender, DragEventArgs e) => ResetDropHint();

    private void OnDrop(object sender, DragEventArgs e)
    {
        ResetDropHint();
        if (DroppedFolder(e) is { } folder)
            _model.PrepareDrop(folder);
        e.Handled = true;
    }

    private void ResetDropHint()
    {
        DropHint.Background = (Brush)FindResource("Sunken");
        DropHintText.Text = "Drop a folder here to serve it";
        DropHintText.Foreground = (Brush)FindResource("TextLo");
    }
}
