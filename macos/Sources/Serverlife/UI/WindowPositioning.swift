import AppKit

/// Places a window next to the mouse cursor, clamped to the visible area of
/// whichever screen the cursor is on. Direct port of CursorPositioner.cs's
/// logic (offset, flip-to-other-side-if-it-would-spill-off-screen, clamp,
/// shrink-on-short-screens), adapted from Windows' top-left/DPI-scaled screen
/// coordinates to AppKit's bottom-left/point-based ones — AppKit has no DPI
/// dance to do, `NSScreen.visibleFrame` is already in points and already
/// excludes the menu bar and Dock the way Windows' work-area rect excludes
/// the taskbar.
enum WindowPositioning {
    private static let cursorOffset: CGFloat = 12

    /// - Parameters:
    ///   - width: desired window width, in points.
    ///   - height: desired window height, in points.
    ///   - shadowMargin: transparent padding around the visible card, so the
    ///     card itself lands next to the cursor rather than the window's
    ///     (larger, shadow-inclusive) bounds.
    /// - Returns: the frame to apply to the window, with height already
    ///   shrunk to fit short screens if needed.
    static func frameNearCursor(width: CGFloat, height: CGFloat, shadowMargin: CGFloat) -> NSRect {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let work = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }

        var h = height
        if h > work.height {
            h = work.height
        }
        let w = width

        // Work in a local, top-down coordinate frame (origin at the visible
        // area's top-left) to mirror the Windows math exactly, then convert
        // back to AppKit's bottom-left screen coordinates at the end.
        let cursorLocalX = cursor.x - work.minX
        let cursorLocalY = work.maxY - cursor.y
        let workRight = work.width
        let workBottom = work.height

        var x = cursorLocalX + cursorOffset - shadowMargin
        var y = cursorLocalY + cursorOffset - shadowMargin
        // Flip to the other side of the cursor when the visible card would spill off-screen.
        if x + w - shadowMargin > workRight { x = cursorLocalX - w + shadowMargin - cursorOffset }
        if y + h - shadowMargin > workBottom { y = cursorLocalY - h + shadowMargin - cursorOffset }
        x = max(0, min(x, workRight - w))
        y = max(0, min(y, workBottom - h))

        let originX = x + work.minX
        let topAK = work.maxY - y
        let originY = topAK - h
        return NSRect(x: originX, y: originY, width: w, height: h)
    }
}
