using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Serverlife.Core;
using Serverlife.ViewModels;

namespace Serverlife.UI;

public partial class TrayWindow : Window
{
    private readonly TrayViewModel _model;

    /// <summary>Suppresses the toggle handlers while they're only being set from settings.</summary>
    private bool _sync;

    private const string SourceUrl = "https://github.com/Anti-super-code/serverlife";
    private const string HomepageUrl = "https://antidot.gr";

    private static string AppVersion
    {
        get
        {
            var v = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
            return v == null ? "0.1" : $"{v.Major}.{v.Minor}";
        }
    }

    public TrayWindow(TrayViewModel model)
    {
        _model = model;
        InitializeComponent();
        DataContext = model;

        _sync = true;
        var settings = SettingsStore.Load();
        AlwaysOnTopCheck.IsChecked = settings.AlwaysOnTop;
        Topmost = settings.AlwaysOnTop;
        ShellCheck.IsChecked = ShellRegistration.IsRegistered();
        UpdateShellHint();
        _sync = false;

        VersionText.Text = $"V.{AppVersion}";
        PreviewKeyDown += OnPreviewKeyDown;
    }

    /// <summary>
    /// Toward the bottom-right of the work area, near the notification area where the eye
    /// already is after clicking the tray icon — but held off the corner by GrowGap so
    /// there's room to drag the right and bottom edges outward (the only two that resize;
    /// see WndProc). WorkArea rather than screen bounds, so it clears the taskbar.
    /// </summary>
    private const double GrowGap = 150;

    public void PositionNearTray()
    {
        var work = SystemParameters.WorkArea;
        Left = Math.Max(work.Left + 8, work.Right - Width - GrowGap);
        Top = Math.Max(work.Top + 8, work.Bottom - Height - GrowGap);
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

    // ---- resize from the right / bottom edge and the bottom-right corner ----------

    private const int WM_NCHITTEST = 0x0084;
    private const int HTRIGHT = 11, HTBOTTOM = 15, HTBOTTOMRIGHT = 17;

    /// <summary>Grab band, in DIPs, in from the window's edge.</summary>
    private const double ResizeBand = 34;

    /// <summary>
    /// WindowStyle="None" + AllowsTransparency drops the OS resize borders, so WM_NCHITTEST
    /// puts them back: the outer band of the right and bottom edges (and the corner where
    /// they meet) reports as a resize edge, and Windows runs its own resize loop from there.
    ///
    /// Only those two edges. This is a layered window, and the moment a resize moves the
    /// window's top-left corner Windows aborts the drag after a pixel or two — so the left
    /// and top edges can't be made to work here. The panel opens with room to grow down and
    /// right (see PositionNearTray) so these two are enough. The band sits in the shadow
    /// margin, which the root Grid's 1/255 wash keeps hit-testable.
    /// </summary>
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ((HwndSource)PresentationSource.FromVisual(this)!).AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_NCHITTEST || WindowState != WindowState.Normal)
            return IntPtr.Zero;

        int lp = lParam.ToInt32();
        var dpi = VisualTreeHelper.GetDpi(this);
        double x = (short)(lp & 0xFFFF) / dpi.DpiScaleX;   // screen point, DIPs
        double y = (short)(lp >> 16) / dpi.DpiScaleY;

        bool right = x > Left + ActualWidth - ResizeBand && x < Left + ActualWidth;
        bool bottom = y > Top + ActualHeight - ResizeBand && y < Top + ActualHeight;

        int hit = right && bottom ? HTBOTTOMRIGHT : right ? HTRIGHT : bottom ? HTBOTTOM : 0;
        if (hit == 0)
            return IntPtr.Zero;

        handled = true;
        return new IntPtr(hit);
    }

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

    // ---- about & settings -----------------------------------------------------------

    private bool InfoShowing => InfoPanel.Visibility == Visibility.Visible;

    private double _heightBeforeInfo;
    private double _topBeforeInfo;

    private void OnInfoClicked(object sender, RoutedEventArgs e) => ShowInfo(true);

    private void OnServerPamperClicked(object sender, RoutedEventArgs e) => ShowInfo(false);

    private void ShowInfo(bool show)
    {
        InfoPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        // The cog and hide-to-tray step aside while this is up — "Server pamper" (or Esc)
        // is the only way back, the same trade Photokompressor makes with "Let's kompress".
        HeaderButtons.Visibility = show ? Visibility.Collapsed : Visibility.Visible;

        if (show)
        {
            _heightBeforeInfo = Height;
            _topBeforeInfo = Top;
            GrowForInfo();
        }
        else
        {
            Height = _heightBeforeInfo;
            Top = _topBeforeInfo;
        }

        var heartbeat = (Storyboard)FindResource("HeartbeatStoryboard");
        if (show)
            heartbeat.Begin(this, isControllable: true);
        else
            heartbeat.Stop(this);
    }

    /// <summary>The card Border's Margin="28" in TrayWindow.xaml — same inset on all four sides.</summary>
    private const double ChromeMargin = 28;

    /// <summary>
    /// Grows (never shrinks) the window so the info panel's footer — the CTA and version
    /// line — lands inside the frame instead of needing a scroll to reach it. Grows
    /// upward, keeping the bottom edge (and the tray it's anchored near) fixed, rather
    /// than pushing the window further down the screen.
    ///
    /// Two passes: Measure() gives an instant, mostly-right size with no visible jump for
    /// the common case, but it's a prediction, not the truth WPF's real layout will land
    /// on. Once that real layout has actually run (DispatcherPriority.Loaded), a second
    /// pass checks the ScrollViewer's own ScrollableHeight and closes whatever gap is
    /// left — that's what actually guarantees no scrollbar, rather than trusting the
    /// prediction to be exact.
    /// </summary>
    private void GrowForInfo()
    {
        var maxHeight = SystemParameters.WorkArea.Height - 16;

        InfoPanel.Measure(new Size(ActualWidth - 2 * ChromeMargin, double.PositiveInfinity));
        var wanted = HeaderRow.ActualHeight + InfoPanel.DesiredSize.Height + 2 * ChromeMargin + 8;
        GrowTo(Math.Clamp(Math.Max(Height, wanted), MinHeight, maxHeight));

        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!InfoShowing || InfoScroll.ScrollableHeight <= 0)
                return;
            GrowTo(Math.Min(Height + InfoScroll.ScrollableHeight + 4, maxHeight));
        }), DispatcherPriority.Loaded);
    }

    private void GrowTo(double newHeight)
    {
        Top -= newHeight - Height;
        Height = newHeight;
    }

    /// <summary>Esc backs out of the info screen; the window itself is left alone.</summary>
    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && InfoShowing)
        {
            ShowInfo(false);
            e.Handled = true;
        }
    }

    private void OnSourceClicked(object sender, RoutedEventArgs e) => OpenExternal(SourceUrl);

    private void OnMadeByClicked(object sender, RoutedEventArgs e) => OpenExternal(HomepageUrl);

    private static void OpenExternal(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // No browser, or the user cancelled the "open with" prompt — not worth
            // interrupting them over.
        }
    }

    private void OnAlwaysOnTopToggled(object sender, RoutedEventArgs e)
    {
        if (_sync) return;
        var enabled = AlwaysOnTopCheck.IsChecked == true;
        Topmost = enabled;
        var settings = SettingsStore.Load();
        settings.AlwaysOnTop = enabled;
        SettingsStore.Save(settings);
    }

    private void OnShellToggled(object sender, RoutedEventArgs e)
    {
        if (_sync) return;
        try
        {
            if (ShellCheck.IsChecked == true)
                ShellRegistration.Register();
            else
                ShellRegistration.Unregister();
        }
        catch (Exception ex)
        {
            // Snap the switch back to what the registry actually says — the registry,
            // not the checkbox, is the source of truth here.
            _sync = true;
            ShellCheck.IsChecked = ShellRegistration.IsRegistered();
            _sync = false;
            UpdateShellHint();
            ShellHint.Text = $"Couldn't update it — {ex.Message}";
            ShellHint.Foreground = (Brush)FindResource("Danger");
            return;
        }
        UpdateShellHint();
    }

    private void UpdateShellHint()
    {
        ShellHint.Foreground = (Brush)FindResource("TextLo");
        ShellHint.Text = ShellCheck.IsChecked == true
            ? "“Start server here” on any folder in Explorer, on its icon or in its empty space"
            : "Drop a folder onto Serverlife instead, or pass it on the command line";
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
