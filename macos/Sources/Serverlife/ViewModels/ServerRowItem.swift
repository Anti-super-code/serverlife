import Foundation
import ServerlifeCore

/// How a row's status dot reads. Maps onto the theme's semantic colours.
enum RowState {
    /// Listening and answering. Theme "good".
    case running
    /// Died and is being brought back by the watchdog. Theme "warn".
    case restarting
    /// Gave up restarting, or failed to start at all. Theme "danger".
    case failed
    /// Known to us but not currently running. Theme "textLo".
    case stopped
}

/// One line in the list. A row comes from discovery (an external server), from the
/// supervisor (one we manage), or from both once a managed server starts listening and
/// discovery finds it by port.
@MainActor
final class ServerRowItem: ObservableObject, Identifiable {
    let id = UUID()

    @Published var port: Int = 0
    @Published var pid: Int32 = 0
    @Published var displayName: String = ""
    @Published var processName: String = ""
    @Published var executablePath: String?
    @Published var workingDirectory: String?
    @Published var commandLine: String?
    @Published var url: String = ""
    @Published var state: RowState = .running
    @Published var isManaged: Bool = false
    @Published var autoRestart: Bool = false
    @Published var isAdoptable: Bool = false
    @Published var peersOnPort: Int = 0
    @Published var restartCount: Int = 0
    @Published var origin: ServerOrigin = .unknown

    /// The supervisor's record, when this row is managed. nil for external servers.
    var managed: ManagedServer?

    /// The last discovery snapshot, kept so "Manage this" can adopt it.
    private(set) var detected: DetectedServer?

    /// The key a manual pin is stored under — workingDirectory when known, else
    /// processName. Set from apply(); "" for a managed row, which is never overridable
    /// since it was dropped or adopted directly and is already unconditionally .mine.
    private(set) var overrideKey: String = ""

    var isContested: Bool { peersOnPort > 0 }

    /// Running out of an OS or installed-application folder — not one of your projects.
    var isSystem: Bool { origin == .system }

    /// Right-click "Not mine" — offered for a discovered row not already tagged system.
    var showNotMine: Bool { !isManaged && origin != .system }

    /// Right-click "Mark as mine" — offered for a discovered row currently tagged system.
    var showMarkMine: Bool { !isManaged && origin == .system }

    /// Whether a pin exists for this row's key, so "Reset to automatic" has something to undo.
    var hasOriginOverride: Bool { !isManaged && !overrideKey.isEmpty && OriginOverrideStore.get(overrideKey) != nil }

    /// Only an external server with a readable command and folder can be adopted.
    var canManage: Bool { managed == nil && isAdoptable }

    /// False for a managed row between "added" and "actually listening" — no port yet,
    /// so url is still "". Open/Copy hide rather than firing at an empty string.
    var hasUrl: Bool { !url.isEmpty }

    /// A row for something discovered listening.
    init(detected: DetectedServer) {
        apply(detected)
    }

    /// A row for a managed server that is not currently listening, so has no pid.
    init(managed: ManagedServer) {
        self.managed = managed
        isManaged = true
        displayName = managed.name
        workingDirectory = managed.directory
        commandLine = managed.command
        port = managed.port ?? 0
        // You dropped or adopted this one yourself, so it's yours by definition —
        // regardless of what OriginClassifier would make of its folder.
        origin = .mine
        syncFromManaged()
    }

    /// The full detail, shown as a tooltip. The list itself stays one line per row, so
    /// the folder and command live here rather than taking a second line from every row.
    var tooltip: String {
        var lines: [String] = [port > 0 ? "\(url)  ·  PID \(pid)" : "not running"]
        if let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(workingDirectory)
        }
        if let commandLine, !commandLine.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(commandLine)
        }
        if restartCount > 0 {
            lines.append("Restarted \(restartCount) time\(restartCount == 1 ? "" : "s") by Serverlife.")
        }
        if let error = managed?.lastError, !error.isEmpty {
            lines.append("⚠ " + error)
        }
        if isContested {
            lines.append("⚠ \(peersOnPort + 1) unrelated processes are bound to port \(port). "
                          + "Only the last one to bind is serving.")
        } else if managed == nil && !isAdoptable {
            lines.append("Cannot be restarted: no readable command line or working directory.")
        }
        if isSystem {
            lines.append("Looks like it belongs to an installed app or the OS, not one of your projects.")
        }
        return lines.joined(separator: "\n")
    }

    /// Refreshes in place from a fresh poll, so the row object survives.
    func apply(_ server: DetectedServer) {
        detected = server
        port = server.port
        pid = server.pid
        processName = server.processName
        url = server.url
        isAdoptable = server.isAdoptable
        peersOnPort = server.peersOnPort

        // A managed server's own name and command are authoritative: they are what will
        // be used to restart it, and discovery only ever sees what is running right now.
        if managed == nil {
            displayName = server.displayName
            executablePath = server.executablePath
            workingDirectory = server.workingDirectory
            commandLine = server.commandLine
            state = .running
            origin = server.origin
            overrideKey = OriginOverrideStore.key(workingDirectory: server.workingDirectory, processName: server.processName)
        }
    }

    /// Pulls state across from the supervisor after it reports a change.
    func syncFromManaged() {
        guard let managed else { return }
        switch managed.state {
        case .running: state = .running
        case .restarting, .starting: state = .restarting
        case .failed: state = .failed
        case .stopped: state = .stopped
        }
        autoRestart = managed.autoRestart
        restartCount = managed.restartCount
        if let port = managed.port {
            self.port = port
            url = "http://localhost:\(port)/"
        }
    }

    /// Identity across polls: a port plus the process behind it.
    var key: PortPidKey { PortPidKey(port: port, pid: pid) }

    /// Log lines for the row's drawer, newest last.
    var log: [String] { managed?.snapshot() ?? [] }
}

/// Identity across polls: a port plus the process behind it — the Swift counterpart of
/// the C# `(int Port, int Pid)` tuple key used throughout TrayViewModel.
struct PortPidKey: Hashable {
    let port: Int
    let pid: Int32
}
