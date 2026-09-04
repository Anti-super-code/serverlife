using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Serverlife.UI;

/// <summary>
/// Places a window next to the mouse cursor, clamped to the work area of
/// whichever monitor the cursor is on, DPI-correct. Works in physical pixels
/// via SetWindowPos to avoid WPF's first-show DPI ambiguity — call from
/// Window.SourceInitialized (handle exists, window not yet shown).
/// </summary>
public static class CursorPositioner
{
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
    }

    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(POINT pt, uint dwFlags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(nint hMonitor, ref MONITORINFO lpmi);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint hmonitor, int dpiType, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const int CursorOffsetPx = 12;

    /// <param name="shadowMargin">
    /// Transparent padding around the visible card, in DIPs, so the card itself
    /// lands next to the cursor rather than the window's invisible bounds.
    /// </param>
    public static void PlaceAtCursor(Window window, double shadowMargin = 0)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == 0)
            return;

        GetCursorPos(out var pt);
        var hMonitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(hMonitor, ref mi);

        uint dpiX = 96, dpiY = 96;
        try { GetDpiForMonitor(hMonitor, 0 /* MDT_EFFECTIVE_DPI */, out dpiX, out dpiY); }
        catch { /* pre-8.1 fallback: assume 96 */ }

        var w = (int)Math.Ceiling(window.Width * dpiX / 96.0);
        var h = (int)Math.Ceiling((double.IsNaN(window.Height) ? 460 : window.Height) * dpiY / 96.0);
        var padX = (int)Math.Round(shadowMargin * dpiX / 96.0);
        var padY = (int)Math.Round(shadowMargin * dpiY / 96.0);

        // On short screens, shrink the window so the footer stays reachable —
        // the dialog body scrolls instead of hanging off the bottom.
        var workHeight = mi.rcWork.Bottom - mi.rcWork.Top;
        if (h > workHeight)
        {
            h = workHeight;
            window.Height = h * 96.0 / dpiY;
        }

        var x = pt.X + CursorOffsetPx - padX;
        var y = pt.Y + CursorOffsetPx - padY;
        // Flip to the other side of the cursor when the visible card would spill off-screen.
        if (x + w - padX > mi.rcWork.Right) x = pt.X - w + padX - CursorOffsetPx;
        if (y + h - padY > mi.rcWork.Bottom) y = pt.Y - h + padY - CursorOffsetPx;
        x = Math.Max(mi.rcWork.Left, Math.Min(x, mi.rcWork.Right - w));
        y = Math.Max(mi.rcWork.Top, Math.Min(y, mi.rcWork.Bottom - h));

        SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}
