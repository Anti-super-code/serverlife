import AppKit
import Darwin
import Foundation
import ServerlifeCore

enum RowFilter: String, CaseIterable { case mine, all, running }

/// Backs the tray panel: owns the live row collection, the filter, the pending drop, and
/// the commands the rows expose. Discovery and the supervisor both push from background
/// contexts, so every mutation here happens back on the main actor.
@MainActor
final class TrayViewModel: ObservableObject {
    private let discovery = Discovery()
    private let supervisor = Supervisor()

    /// Rows for discovered (non-managed) servers, keyed by (port, pid). Rows are kept
    /// and updated in place — rebuilding the list every 2s would reset scroll position
    /// and hover, which on a list meant to sit open all day would read as constant
    /// flicker even though nothing actually changed.
    private var byKey: [PortPidKey: ServerRowItem] = [:]

    /// Rows for managed servers, keyed by object identity — a managed server owns
    /// exactly one row for its whole life, whether or not it is currently listening.
    private var managedRows: [ObjectIdentifier: ServerRowItem] = [:]

    @Published var rows: [ServerRowItem] = []
    // Defaults to .mine rather than .all: an OS or installed-app server shouldn't be
    // sitting in easy reach of Stop by default. All/Running are one click away.
    @Published var filter: RowFilter = .mine
    @Published var summary: String = "Looking for servers…"

    // ---- pending drop ----
    @Published var dropFolder: String?
    @Published var dropCommand: String = ""
    @Published var dropWhy: String = ""

    var hasPendingDrop: Bool { dropFolder != nil }
    var dropFolderName: String { dropFolder.map { ($0 as NSString).lastPathComponent } ?? "" }
    var showDropCommandPlaceholder: Bool { dropCommand.isEmpty }

    var visibleRows: [ServerRowItem] {
        let sorted = rows.sorted { $0.port != $1.port ? $0.port < $1.port : $0.pid < $1.pid }
        switch filter {
        case .mine:
            // Unknown origin (the working-directory read failed, or the row is still
            // non-HTTP) is kept rather than hidden: only a confidently-system row is
            // filtered out here, so a real dev server never disappears just because
            // its folder couldn't be read.
            return sorted.filter { $0.origin != .system }
        case .running:
            return sorted.filter { $0.state == .running }
        case .all:
            return sorted
        }
    }

    init() {
        Task { await discovery.onUpdate { [weak self] servers in
            Task { @MainActor in self?.merge(servers) }
        } }
        supervisor.onChanged = { [weak self] _ in
            Task { @MainActor in self?.refreshManagedState() }
        }
        Task { await discovery.start() }
        supervisor.start()
    }

    // ---- drop to serve --------------------------------------------------------------

    /// Stages a dropped folder with its guessed command. Deliberately does not start
    /// it: the guess is shown in an editable field first, because picking "build"
    /// instead of "dev" is both easy and slow to notice.
    func prepareDrop(_ folder: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return }
        let suggestion = ProjectDetector.suggest(folder: folder)
        dropFolder = folder
        dropCommand = suggestion.command
        dropWhy = suggestion.why
    }

    func confirmDrop() {
        guard let folder = dropFolder else { return }
        let server = supervisor.add(ManagedServer(
            name: (folder as NSString).lastPathComponent, directory: folder,
            command: dropCommand.trimmingCharacters(in: .whitespaces)))
        cancelDrop()
        Task.detached { [supervisor] in supervisor.startServer(server) }
    }

    func cancelDrop() {
        dropFolder = nil
        dropCommand = ""
        dropWhy = ""
    }

    // ---- discovery merge --------------------------------------------------------------

    private func merge(_ servers: [DetectedServer]) {
        var managedByPort: [Int: ManagedServer] = [:]
        // Managed servers we haven't tied to a port yet, keyed by their folder — used
        // below to adopt a listener discovered running out of that exact folder.
        var unlinkedManagedByDir: [String: ManagedServer] = [:]
        for s in supervisor.servers {
            if let port = s.port {
                managedByPort[port] = s
            } else {
                let dir = Self.canonicalDir(s.directory)
                if !dir.isEmpty { unlinkedManagedByDir[dir] = s }
            }
        }

        // A managed server owns exactly one row for its whole life, whether or not it
        // is currently listening. Creating it here rather than from discovery is what
        // stops a server appearing twice — once as "the thing we manage" and again as
        // "a port that happens to be open" — the moment it starts and discovery notices
        // its port.
        let live = supervisor.servers
        for managed in live {
            let oid = ObjectIdentifier(managed)
            guard managedRows[oid] == nil else { continue }
            let created = ServerRowItem(managed: managed)
            managedRows[oid] = created
            rows.append(created)
        }

        var seen: Set<PortPidKey> = []
        for server in servers {
            // Discovered a port a managed server owns: fold the detail into that
            // server's existing row instead of making a second one.
            if let owner = managedByPort[server.port], let ownerRow = managedRows[ObjectIdentifier(owner)] {
                ownerRow.apply(server)
                continue
            }

            // A managed server we haven't tied to a port yet, but this listener is
            // running out of its exact folder — almost certainly the same thing. Adopt
            // the port so the row gets its URL and the watchdog can health-check it by
            // port instead of guessing at the process tree. Covers "npm run dev", where
            // the socket is a grandchild the process-group check can miss, and a server
            // started by hand from an editor in that folder.
            if let dir = server.workingDirectory.map(Self.canonicalDir), !dir.isEmpty,
               let owner = unlinkedManagedByDir[dir], let ownerRow = managedRows[ObjectIdentifier(owner)] {
                owner.port = server.port
                managedByPort[server.port] = owner
                unlinkedManagedByDir.removeValue(forKey: dir)
                ownerRow.apply(server)
                continue
            }

            let key = PortPidKey(port: server.port, pid: server.pid)
            seen.insert(key)

            if let row = byKey[key] {
                row.apply(server)
            } else {
                let row = ServerRowItem(detected: server)
                byKey[key] = row
                rows.append(row)
            }
        }

        for (key, row) in byKey where !seen.contains(key) {
            byKey.removeValue(forKey: key)
            rows.removeAll { $0 === row }
        }

        // Rows for servers that are no longer supervised at all.
        let liveSet = Set(live.map(ObjectIdentifier.init))
        for (oid, row) in managedRows where !liveSet.contains(oid) {
            managedRows.removeValue(forKey: oid)
            rows.removeAll { $0 === row }
        }

        refreshManagedState()
        updateSummary()
    }

    private func refreshManagedState() {
        for row in rows where row.managed != nil {
            row.syncFromManaged()
        }
    }

    /// Absolute, symlink-resolved path, for comparing a managed server's folder against
    /// a discovered process's working directory without tripping over `…/tmp` vs
    /// `…/private/tmp` or a trailing slash.
    private static func canonicalDir(_ path: String?) -> String {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func updateSummary() {
        let contested = Set(rows.filter(\.isContested).map(\.port)).count
        let managedCount = rows.filter(\.isManaged).count
        if rows.isEmpty {
            summary = "No local servers running"
        } else {
            var text = "\(rows.count) server\(rows.count == 1 ? "" : "s")"
            if managedCount > 0 { text += "  ·  \(managedCount) managed" }
            if contested > 0 { text += "  ·  \(contested) contested port\(contested == 1 ? "" : "s")" }
            summary = text
        }
    }

    // ---- row commands -----------------------------------------------------------------

    func open(_ row: ServerRowItem?) {
        // url is "" for a managed row that hasn't started listening yet; the button
        // hides itself via hasUrl, and this guards the command too.
        guard let row, row.hasUrl, let url = URL(string: row.url) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyUrl(_ row: ServerRowItem?) {
        guard let row, row.hasUrl else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.url, forType: .string)
    }

    func revealFolder(_ row: ServerRowItem?) {
        guard let dir = row?.workingDirectory, !dir.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    /// Inline rename from the row (double-click the name). Managed rows only — a
    /// discovered row's name is refreshed from discovery on every poll, so a rename
    /// there wouldn't stick. Label only: the folder and command are untouched.
    func rename(_ row: ServerRowItem?, to newName: String) {
        guard let row, row.isManaged else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != row.displayName else { return }
        row.managed?.name = name
        row.displayName = name
    }

    /// Takes over an external server so the watchdog covers it. It is not restarted —
    /// adopting something mid-presentation must not interrupt it.
    func manage(_ row: ServerRowItem?) {
        guard let row, row.managed == nil, let detected = row.detected, row.isAdoptable else { return }
        let managed = supervisor.adopt(detected)
        row.managed = managed
        row.isManaged = true
        row.autoRestart = managed.autoRestart
        managedRows[ObjectIdentifier(managed)] = row
        // Ownership of the row moves to the managed table; leaving it in the discovered
        // one would let the next poll build a second row for the same server.
        byKey.removeValue(forKey: row.key)
        updateSummary()
    }

    func stop(_ row: ServerRowItem?) {
        guard let row else { return }
        if let managed = row.managed {
            // Turn auto-restart off first, or the watchdog treats a deliberate stop as
            // a crash and immediately puts it back.
            managed.autoRestart = false
            row.autoRestart = false
            Task.detached { [supervisor] in supervisor.stop(managed) }
            return
        }
        // Not ours: no process group to fall back on, so this signals the pid directly.
        killExternal(row.pid)
    }

    func restart(_ row: ServerRowItem?) {
        guard let managed = row?.managed else { return }
        Task.detached { [supervisor] in supervisor.startServer(managed) }
    }

    func toggleAutoRestart(_ row: ServerRowItem?) {
        guard let row, let managed = row.managed else { return }
        managed.autoRestart.toggle()
        row.autoRestart = managed.autoRestart
    }

    /// SIGTERM/SIGKILL for a process we did not start — no process group to fall back
    /// on the way a started server has, so this signals the pid directly rather than a
    /// group; whatever it forked on its own may survive, same limitation `taskkill /T`
    /// has on the Windows side for anything the job object didn't cover.
    private func killExternal(_ pid: Int32) {
        guard pid > 0 else { return }
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            if Darwin.kill(pid, 0) == 0 {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    // ---- manual origin pins -----------------------------------------------------------
    //
    // The Mine/System split is a best-effort guess from where a server runs, and it will
    // occasionally get something wrong. These let a right-click correct it, in either
    // direction, and the correction sticks.

    func markNotMine(_ row: ServerRowItem?) {
        guard let row, !row.isManaged, !row.overrideKey.isEmpty else { return }
        OriginOverrideStore.set(row.overrideKey, origin: .system)
        row.origin = .system
    }

    func markMine(_ row: ServerRowItem?) {
        guard let row, !row.isManaged, !row.overrideKey.isEmpty else { return }
        OriginOverrideStore.set(row.overrideKey, origin: .mine)
        row.origin = .mine
    }

    func resetOrigin(_ row: ServerRowItem?) {
        guard let row, !row.isManaged, !row.overrideKey.isEmpty else { return }
        OriginOverrideStore.clear(row.overrideKey)
        // Re-derive from the heuristic immediately rather than waiting for the next poll.
        row.origin = OriginClassifier.classify(workingDirectory: row.workingDirectory,
                                               executablePath: row.executablePath,
                                               processName: row.processName)
    }

    func dispose() {
        Task { await discovery.stop() }
        supervisor.dispose()
    }
}
