import AppKit
import SwiftUI
import ServerlifeCore

/// Grabs the SwiftUI content's own hosting NSWindow, the same way WindowDragBackground
/// reaches `self.window` from inside an NSView rather than being handed a reference —
/// this is what lets the resize grips and the info-panel grow-to-fit adjust the window's
/// frame directly, with no callback plumbing back through TrayPanelWindow.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// A thin, invisible strip along one of the window's edges the user drags to resize the
/// panel — top/bottom for height, left/right for width. The counterpart of
/// TrayWindow.xaml's resize Border elements. `.borderless` drops the OS's own resize edges along with the rest of the
/// chrome; Windows gets them back by handing off to a native resize loop, and this does
/// the macOS equivalent: on mouse-down it pulls drag events straight off the queue with
/// `trackEvents` and moves the window frame itself.
///
/// Why not a SwiftUI `DragGesture`: `WindowDragBackground` already learned that driving
/// a window frame from `DragGesture.onChanged` visibly lags the cursor — every update
/// round-trips through SwiftUI's render cycle first. And why `trackEvents` rather than
/// the earlier version's `mouseDown`/`mouseDragged` pair: the hosting view's own gesture
/// recognisers swallow `mouseDragged` before it reaches a plain child NSView, so that
/// version recorded the press and then never saw the drag. `mouseDown` itself is
/// delivered (the same thing `WindowDragBackground` relies on), and from inside it the
/// tracking loop bypasses SwiftUI entirely.
private struct ResizeGrip: NSViewRepresentable {
    enum Edge { case top, bottom, left, right }
    let edge: Edge
    /// Called the moment the user grabs a grip, so the panel stops auto-fitting itself
    /// to the row count and leaves the height under the user's control from then on.
    /// Only wired up for the vertical grips — a width drag doesn't disturb height auto-fit.
    var onManualResize: () -> Void = {}

    func makeNSView(context: Context) -> GripView {
        let v = GripView()
        v.edge = edge
        v.onManualResize = onManualResize
        return v
    }
    func updateNSView(_ nsView: GripView, context: Context) {
        nsView.edge = edge
        nsView.onManualResize = onManualResize
    }

    final class GripView: NSView {
        var edge: Edge = .bottom
        var onManualResize: () -> Void = {}

        /// Matches TrayWindow.xaml's `MinHeight="220"`.
        private static let minHeight: CGFloat = 220

        private var isHorizontal: Bool { edge == .left || edge == .right }

        // A tracking area rather than `resetCursorRects()` / `addCursorRect`: SwiftUI's
        // hosting view manages its own cursor rects and does not pick up a child
        // representable's, so the resize cursor is set explicitly on enter/exit instead.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            onManualResize()
            let startMouse = NSEvent.mouseLocation
            let startFrame = window.frame
            let visible = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 3000, height: 2000)
            let maxHeight = visible.height - 16
            let maxWidth = min(TrayPanelWindow.maxWidth, visible.width - 16)
            let edge = self.edge

            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                               timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
                guard let ev else { return }
                if ev.type == .leftMouseUp {
                    stop.pointee = true
                    UserDefaults.standard.set(Double(window.frame.height),
                                              forKey: TrayPanelWindow.heightDefaultsKey)
                    UserDefaults.standard.set(Double(window.frame.width),
                                              forKey: TrayPanelWindow.widthDefaultsKey)
                    return
                }
                // AppKit screen coordinates grow upward and rightward: dragging down
                // lowers y, dragging left lowers x.
                let dx = NSEvent.mouseLocation.x - startMouse.x
                let dy = NSEvent.mouseLocation.y - startMouse.y
                var frame = startFrame
                switch edge {
                case .bottom:
                    // The panel hangs off its status item, so the top edge is the anchor:
                    // a bottom-edge drag keeps maxY fixed and grows downward.
                    let h = min(maxHeight, max(Self.minHeight, startFrame.height - dy))
                    frame.origin.y = startFrame.maxY - h
                    frame.size.height = h
                case .top:
                    // A top-edge drag keeps the bottom edge fixed instead.
                    let h = min(maxHeight, max(Self.minHeight, startFrame.height + dy))
                    frame.size.height = h
                case .left:
                    // The panel is right-aligned under its status item, so the right edge
                    // is the anchor: a left-edge drag keeps maxX fixed and grows leftward.
                    let w = min(maxWidth, max(TrayPanelWindow.minWidth, startFrame.width - dx))
                    frame.origin.x = startFrame.maxX - w
                    frame.size.width = w
                case .right:
                    // A right-edge drag keeps the left edge fixed instead.
                    let w = min(maxWidth, max(TrayPanelWindow.minWidth, startFrame.width + dx))
                    frame.size.width = w
                }
                window.setFrame(frame, display: true)
                window.contentView?.setFrameSize(frame.size)
            }
        }
    }
}

/// Direct port of TrayWindow.xaml: the resident panel's whole content — header, Mine/
/// All/Running filter, the live server list, the drop-a-folder zone, and (as a full-panel
/// overlay swap, not a separate window) the About & Settings screen.
struct TrayPanelView: View {
    @ObservedObject var viewModel: TrayViewModel
    var onClose: () -> Void

    init(viewModel: TrayViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        // A height the user has dragged to before is theirs to keep — don't auto-fit
        // over it, this launch or any later one.
        _userResized = State(initialValue:
            UserDefaults.standard.object(forKey: TrayPanelWindow.heightDefaultsKey) != nil)
    }

    @State private var hostWindow: NSWindow?
    @State private var infoShowing = false
    @State private var settings = SettingsStore.load()
    @State private var shellRegistered = FinderIntegration.isRegistered()
    @State private var shellError: String?
    /// Set once the user drags a resize grip (or on launch if they have before): from
    /// then on the panel keeps their height instead of sizing itself to the row count.
    @State private var userResized = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.trayBg)
                .shadow(color: Color(hex: 0x243044, opacity: 0.22), radius: 20, x: 0, y: 6)
                .overlay(card)
                .padding(12)
                .background(WindowAccessor { hostWindow = $0; fitToContent() })

            VStack(spacing: 0) {
                ResizeGrip(edge: .top, onManualResize: { userResized = true }).frame(height: 12)
                Spacer(minLength: 0)
                ResizeGrip(edge: .bottom, onManualResize: { userResized = true }).frame(height: 12)
            }

            HStack(spacing: 0) {
                ResizeGrip(edge: .left).frame(width: 12)
                Spacer(minLength: 0)
                ResizeGrip(edge: .right).frame(width: 12)
            }
        }
        .onExitCommand { if infoShowing { setInfoShowing(false) } }
        .onChange(of: viewModel.visibleRows.count) { _ in fitToContent() }
    }

    /// The greatest height the panel sizes itself to, and the height the About/Settings
    /// panel opens at — the screen permitting.
    private func comfortableHeight(_ window: NSWindow) -> CGFloat {
        min(TrayPanelWindow.defaultHeight, (window.screen?.visibleFrame.height ?? 1200) - 16)
    }

    /// Moves the top edge as little as possible: the panel hangs off its status item, so
    /// the top stays put and the bottom edge is what travels.
    private func setPanelHeight(_ height: CGFloat) {
        guard let window = hostWindow else { return }
        var frame = window.frame
        frame.origin.y += (frame.height - height)
        frame.size.height = height
        window.setFrame(frame, display: true)
        window.contentView?.setFrameSize(frame.size)
    }

    /// Sizes the panel to sit snugly around the visible rows — down to `minHeight`, up to
    /// `comfortableHeight`, past which the list scrolls. Does nothing once the user has
    /// resized by hand, or while the About/Settings panel (which scrolls internally) is up.
    private func fitToContent() {
        guard let window = hostWindow, !userResized, !infoShowing else { return }

        // header + filter + drop zone + the card's own 12pt inset, top and bottom.
        let chrome: CGFloat = 160
        let rows = max(viewModel.visibleRows.count, 0)
        let listHeight = rows == 0 ? 24 : CGFloat(rows) * 32
        let ideal = chrome + listHeight

        let target = min(max(TrayPanelWindow.minHeight, ideal), comfortableHeight(window))
        guard abs(target - window.frame.height) > 0.5 else { return }
        setPanelHeight(target)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if infoShowing {
                InfoView(settings: $settings, shellRegistered: $shellRegistered, shellError: $shellError,
                         onDismiss: { setInfoShowing(false) },
                         onAlwaysOnTopChanged: { applyAlwaysOnTop($0) },
                         onShellToggled: { toggleShellRegistration($0) })
            } else {
                filterPicker
                rowList
                dropZone
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("SERVERLIFE").font(Theme.font(size: 11)).foregroundColor(Theme.textLo).tracking(1.1)
                Text(viewModel.summary).font(Theme.font(size: 10.5, .light)).foregroundColor(Theme.textLo)
            }
            .allowsHitTesting(false)
            Spacer()
            if !infoShowing {
                RoundGlyphButton(kind: .options, hoverStyle: .neutral, size: 28) { setInfoShowing(true) }
                    .padding(.trailing, 6)
                RoundGlyphButton(kind: .close, hoverStyle: .neutral, size: 28, action: onClose)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 6, trailing: 14))
        .background(WindowDragBackground())
    }

    private var filterPicker: some View {
        SegmentedPicker(
            options: [("Mine", RowFilter.mine), ("All", RowFilter.all), ("Running", RowFilter.running)],
            selection: $viewModel.filter, height: 34)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(viewModel.visibleRows) { row in
                    ServerRowView(row: row, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var dropZone: some View {
        ZStack {
            if !viewModel.hasPendingDrop {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.sunken)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.insetEdge, lineWidth: 1))
                    .frame(height: 34)
                    .overlay(
                        Text("Drop a folder here to serve it")
                            .font(Theme.font(size: 11)).foregroundColor(Theme.textLo)
                    )
            } else {
                pendingDropPanel
            }
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var pendingDropPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.dropFolderName)
                .font(Theme.font(size: 12.5, .semibold)).foregroundColor(Theme.textHi).lineLimit(1)
            Text(viewModel.dropWhy)
                .font(Theme.font(size: 10.5)).foregroundColor(Theme.textLo).lineLimit(1)
                .padding(.top, 1).padding(.bottom, 6)
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    NeuTextField(text: $viewModel.dropCommand, alignment: .leading, font: Theme.font(size: 11.5))
                    if viewModel.showDropCommandPlaceholder {
                        Text("special commands here")
                            .font(Theme.font(size: 11.5)).foregroundColor(Theme.textLo)
                            .padding(.leading, 10).allowsHitTesting(false)
                    }
                }
                .frame(height: 28)
                Button("Start") { viewModel.confirmDrop() }
                    .buttonStyle(AccentButtonStyle(height: 28)).frame(width: 62)
                Button("Cancel") { viewModel.cancelDrop() }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.insetEdge, lineWidth: 1))
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            Task { @MainActor in viewModel.prepareDrop(url.path) }
        }
        return true
    }

    // ---- about & settings ------------------------------------------------------------

    /// The panel height in effect before the About/Settings panel was opened, restored
    /// when it closes — the same bookkeeping TrayWindow.xaml.cs does with
    /// `_heightBeforeInfo`, minus its measure-driven GrowForInfo (whose SwiftUI
    /// equivalent measured a greedily-filling ScrollView and fed each measurement into
    /// the next, climbing the window to the full height of the screen).
    @State private var heightBeforeInfo: CGFloat?

    private func setInfoShowing(_ show: Bool) {
        withAnimation(.easeOut(duration: 0.16)) { infoShowing = show }
        guard let window = hostWindow else { return }
        if show {
            // Open the About/Settings panel tall enough to show its blurb and both
            // toggles without scrolling — the list is often much shorter than this now
            // that it fits its rows. Never shrink a panel the user dragged taller.
            heightBeforeInfo = window.frame.height
            let screenCap = (window.screen?.visibleFrame.height ?? 1200) - 16
            let target = min(TrayPanelWindow.infoHeight, screenCap)
            if window.frame.height < target { setPanelHeight(target) }
        } else {
            if let restore = heightBeforeInfo { setPanelHeight(restore) }
            heightBeforeInfo = nil
            fitToContent() // the row count may have changed while the panel was up
        }
    }

    private func applyAlwaysOnTop(_ enabled: Bool) {
        settings.alwaysOnTop = enabled
        SettingsStore.save(settings)
        hostWindow.map { win in
            (win as? ChromelessWindow)?.setAlwaysOnTop(enabled)
        }
    }

    private func toggleShellRegistration(_ enabled: Bool) {
        do {
            if enabled {
                try FinderIntegration.register()
            } else {
                try FinderIntegration.unregister()
            }
            shellRegistered = FinderIntegration.isRegistered()
            shellError = nil
        } catch {
            // The filesystem is the source of truth, not the toggle: snap back to
            // what's actually registered rather than trusting the optimistic flip.
            shellRegistered = FinderIntegration.isRegistered()
            shellError = error.localizedDescription
        }
    }
}

/// One line in the list: a 30pt row with the port, dot, title, and system/contested
/// badges visible at rest; the action buttons live in a hover-revealed overlay layer
/// (not a sibling column) so they reserve no width and cannot truncate the title.
private struct ServerRowView: View {
    @ObservedObject var row: ServerRowItem
    let viewModel: TrayViewModel

    @State private var hovering = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(verbatim: "\(row.port)")
                    .font(Theme.font(size: 11.5)).foregroundColor(Theme.textMid)
                    .frame(minWidth: 38, alignment: .leading).padding(.leading, 8).padding(.trailing, 8)
                Text(row.displayName)
                    .font(Theme.font(size: 12.5)).foregroundColor(Theme.textHi)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if row.isSystem {
                    Text("system").font(Theme.font(size: 9.5)).foregroundColor(Theme.textLo).padding(.trailing, 6)
                }
                if row.isContested {
                    Text(verbatim: "+\(row.peersOnPort)")
                        .font(Theme.font(size: 9.5, .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 6).frame(height: 15)
                        .background(Capsule().fill(Theme.warn))
                }
            }
            .padding(.horizontal, 6)

            HStack {
                Spacer()
                actions
            }
            .padding(.horizontal, 12)
            .background(hovering ? Color.white.opacity(0.4) : Color.clear)
            .opacity(hovering ? 1 : 0)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.white.opacity(0.4) : Color.clear))
        .onHover { hovering = $0 }
        .help(row.tooltip)
        .contextMenu {
            if row.showNotMine {
                Button("Not mine — move to general pool") { viewModel.markNotMine(row) }
            }
            if row.showMarkMine {
                Button("Mark as mine") { viewModel.markMine(row) }
            }
            if row.hasOriginOverride {
                Button("Reset to automatic") { viewModel.resetOrigin(row) }
            }
        }
    }

    private var dotColor: Color {
        switch row.state {
        case .running: return Theme.good
        case .restarting: return Theme.warn
        case .failed: return Theme.danger
        case .stopped: return Theme.textLo
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if row.isManaged {
                NeuToggle(isOn: Binding(
                    get: { row.autoRestart },
                    set: { _ in viewModel.toggleAutoRestart(row) }))
                    .scaleEffect(0.55)
                    .frame(width: 30, height: 17)
                    .help("Restart automatically if it dies")
            }
            if row.canManage {
                Button("Manage") { viewModel.manage(row) }
                    .buttonStyle(LinkButtonStyle())
                    .help("Watch this server and restart it if it dies")
            }
            if row.isManaged {
                Button("Restart") { viewModel.restart(row) }
                    .buttonStyle(LinkButtonStyle())
                    .help("Restart now")
            }
            if row.hasUrl {
                Button("Open") { viewModel.open(row) }
                    .buttonStyle(LinkButtonStyle())
                    .help("Open in browser")
                Button("Copy") { viewModel.copyUrl(row) }
                    .buttonStyle(LinkButtonStyle())
                    .help("Copy URL")
            }
            Button("Stop") { viewModel.stop(row) }
                .buttonStyle(LinkButtonStyle(tint: Theme.danger))
                .help("Stop this server and everything it started")
        }
        .font(Theme.font(size: 11))
    }
}
