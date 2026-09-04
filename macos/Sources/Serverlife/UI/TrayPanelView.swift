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

/// A thin, invisible drag strip along the window's top or bottom edge — the counterpart
/// of TrayWindow.xaml's two new resize Border elements. WindowStyle="None" drops the
/// OS's own resize borders along with the rest of the chrome on both platforms; Windows
/// hands off to a native resize loop via SendMessage(WM_SYSCOMMAND) to get them back,
/// but AppKit needs no such trick — adjusting the already-open window's own frame live
/// during the drag is enough.
private struct ResizeHandle: NSViewRepresentable {
    enum Edge { case top, bottom }
    let edge: Edge

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.edge = edge
        return view
    }
    func updateNSView(_ nsView: DragView, context: Context) { nsView.edge = edge }

    final class DragView: NSView {
        var edge: Edge = .top
        private var lastLocation: NSPoint?
        private static let minHeight: CGFloat = 220

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            lastLocation = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let last = lastLocation else { return }
            let current = NSEvent.mouseLocation
            let deltaY = current.y - last.y
            lastLocation = current

            var frame = window.frame
            switch edge {
            case .bottom:
                // The panel is anchored under its status item, so a bottom-edge drag
                // keeps the top edge fixed and grows/shrinks downward.
                let newHeight = max(Self.minHeight, frame.height - deltaY)
                frame.origin.y -= (newHeight - frame.height)
                frame.size.height = newHeight
            case .top:
                // A top-edge drag keeps the bottom edge fixed instead — the ordinary
                // "extend from whichever edge you grabbed" resize.
                let newHeight = max(Self.minHeight, frame.height + deltaY)
                frame.size.height = newHeight
            }
            window.setFrame(frame, display: true)
            window.contentView?.setFrameSize(frame.size)
        }
    }
}

/// Reports InfoView's real rendered height up so the window can grow to fit it — the
/// same PreferenceKey-summed-from-a-GeometryReader-background pattern
/// GalleryTrayView.swift already uses for Photokompressor's gallery tray.
private struct InfoContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    func measuringHeight(into key: InfoContentHeightKey.Type) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: InfoContentHeightKey.self, value: geo.size.height)
        })
    }
}

/// Direct port of TrayWindow.xaml: the resident panel's whole content — header, Mine/
/// All/Running filter, the live server list, the drop-a-folder zone, and (as a full-panel
/// overlay swap, not a separate window) the About & Settings screen.
struct TrayPanelView: View {
    @ObservedObject var viewModel: TrayViewModel
    var onClose: () -> Void

    @State private var hostWindow: NSWindow?
    @State private var infoShowing = false
    @State private var heightBeforeInfo: CGFloat?
    @State private var settings = SettingsStore.load()
    @State private var shellRegistered = FinderIntegration.isRegistered()
    @State private var shellError: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.trayBg)
                .shadow(color: Color(hex: 0x243044, opacity: 0.22), radius: 20, x: 0, y: 6)
                .overlay(card)
                .padding(12)
                .background(WindowAccessor { hostWindow = $0 })

            VStack {
                ResizeHandle(edge: .top).frame(height: 8)
                Spacer()
                ResizeHandle(edge: .bottom).frame(height: 8)
            }
        }
        .onExitCommand { if infoShowing { setInfoShowing(false) } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if infoShowing {
                InfoView(settings: $settings, shellRegistered: $shellRegistered, shellError: $shellError,
                         onDismiss: { setInfoShowing(false) },
                         onAlwaysOnTopChanged: { applyAlwaysOnTop($0) },
                         onShellToggled: { toggleShellRegistration($0) })
                    .measuringHeight(into: InfoContentHeightKey.self)
                    .onPreferenceChange(InfoContentHeightKey.self) { growForInfo($0) }
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
                RoundGlyphButton(kind: .info, hoverStyle: .neutral, size: 28) { setInfoShowing(true) }
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

    private func setInfoShowing(_ show: Bool) {
        withAnimation(.easeOut(duration: 0.16)) { infoShowing = show }
        if !show { collapseFromInfo() }
    }

    private func growForInfo(_ measured: CGFloat) {
        guard infoShowing, let window = hostWindow, measured > 0 else { return }
        if heightBeforeInfo == nil { heightBeforeInfo = window.frame.height }
        let maxHeight = max(220, (window.screen ?? NSScreen.main)?.visibleFrame.height ?? window.frame.height) - 16
        let headerHeight: CGFloat = 60
        let wanted = min(max(window.frame.height, measured + headerHeight + 24), maxHeight)
        guard abs(wanted - window.frame.height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y -= (wanted - frame.height)
        frame.size.height = wanted
        window.setFrame(frame, display: true)
        window.contentView?.setFrameSize(frame.size)
    }

    private func collapseFromInfo() {
        guard let restored = heightBeforeInfo, let window = hostWindow else { return }
        heightBeforeInfo = nil
        var frame = window.frame
        frame.origin.y += (frame.height - restored)
        frame.size.height = restored
        window.setFrame(frame, display: true)
        window.contentView?.setFrameSize(frame.size)
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
