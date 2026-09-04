import Darwin
import Foundation

public enum ManagedState: Sendable { case stopped, starting, running, restarting, failed }

/// A server Serverlife is responsible for: one we started, or an external one that was
/// adopted. Holds everything needed to bring it back after it dies.
public final class ManagedServer: @unchecked Sendable {
    public var name: String
    public var directory: String
    /// Shell command to run. Empty means serve `directory` with the built-in server.
    public var command: String
    public var autoRestart: Bool = true
    public var state: ManagedState = .stopped
    /// Learned on first successful start, then used as the health check.
    public var port: Int?
    public var restartCount: Int = 0
    public var lastError: String?

    var processGroup: ProcessGroup?
    var builtIn: StaticServer?
    var healthySinceUtc: Date?
    var retryAfterUtc: Date?
    var consecutiveFailures: Int = 0

    /// Last 500 output lines, for the row's log drawer.
    private let logLock = NSLock()
    private var log: [String] = []

    public init(name: String, directory: String, command: String, autoRestart: Bool = true) {
        self.name = name
        self.directory = directory
        self.command = command
        self.autoRestart = autoRestart
    }

    public var usesBuiltInServer: Bool { command.trimmingCharacters(in: .whitespaces).isEmpty }

    public func snapshot() -> [String] {
        logLock.lock(); defer { logLock.unlock() }
        return log
    }

    func append(_ line: String) {
        logLock.lock()
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        logLock.unlock()
    }
}

/// Starts, stops and keeps alive the servers Serverlife manages.
///
/// The watchdog is the reason the app exists: a dev server that dies mid-presentation
/// should be back before anyone notices, without alt-tabbing to a terminal.
public final class Supervisor: @unchecked Sendable {
    private static let watchdogInterval: TimeInterval = 3

    /// Backoff between restart attempts. A server that fails instantly and repeatedly is
    /// usually broken rather than unlucky, and hammering it just burns CPU during a talk.
    private static let backoff: [TimeInterval] = [1, 2, 4, 8, 15]
    private static let maxConsecutiveFailures = 10

    /// How long a server must stay up before its failure streak is forgiven. Without
    /// this, something that dies once an hour would exhaust its ten attempts over a day
    /// and then stay down — the exact opposite of the point.
    private static let healthyResetAfter: TimeInterval = 60

    private let lock = NSLock()
    private var _servers: [ManagedServer] = []
    private var watchdogTask: Task<Void, Never>?

    public init() {}

    public var servers: [ManagedServer] {
        lock.lock(); defer { lock.unlock() }
        return _servers
    }

    /// Raised whenever a managed server changes state, on a background thread.
    public var onChanged: (@Sendable (ManagedServer) -> Void)?

    public func start() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.watchdogInterval * 1_000_000_000))
                self?.tick()
            }
        }
    }

    @discardableResult
    public func add(_ server: ManagedServer) -> ManagedServer {
        lock.lock(); _servers.append(server); lock.unlock()
        return server
    }

    public func remove(_ server: ManagedServer) {
        stop(server)
        lock.lock(); _servers.removeAll { $0 === server }; lock.unlock()
    }

    /// Takes over an already-running server so the watchdog can bring it back if it
    /// dies. It keeps running as it is — adopting does not restart it.
    @discardableResult
    public func adopt(_ detected: DetectedServer) -> ManagedServer {
        let server = ManagedServer(
            name: detected.displayName, directory: detected.workingDirectory ?? "",
            command: detected.commandLine ?? "")
        server.port = detected.port
        server.state = .running
        server.healthySinceUtc = Date()
        server.append("[serverlife] adopted PID \(detected.pid) on port \(detected.port)")
        return add(server)
    }

    // ---- start / stop --------------------------------------------------------------

    public func startServer(_ server: ManagedServer) {
        stop(server)

        server.lastError = nil
        server.state = .starting
        onChanged?(server)

        do {
            if server.usesBuiltInServer {
                try startBuiltIn(server)
            } else {
                try startProcess(server)
            }
            server.state = .running
            server.healthySinceUtc = Date()
        } catch {
            server.state = .failed
            server.lastError = error.localizedDescription
            server.append("[serverlife] start failed: \(error.localizedDescription)")
        }

        onChanged?(server)
    }

    private func startBuiltIn(_ server: ManagedServer) throws {
        let built = try StaticServer(folder: server.directory)
        built.start()
        server.builtIn = built
        server.port = built.port
        server.append("[serverlife] built-in static server on http://localhost:\(built.port)/")
    }

    private func startProcess(_ server: ManagedServer) throws {
        let group = ProcessGroup()
        try group.spawn(command: server.command, workingDirectory: server.directory) { [weak server] line in
            server?.append(line)
        }
        server.processGroup = group
        server.append("[serverlife] started: \(server.command)")
    }

    public func stop(_ server: ManagedServer) {
        // Killing the process group takes the whole tree: "npm run dev" is
        // sh -> npm -> node, and killing only the process we launched would leave node
        // holding the port.
        server.processGroup?.kill()
        server.processGroup = nil

        server.builtIn?.stop()
        server.builtIn = nil

        server.healthySinceUtc = nil
        if server.state != .failed {
            server.state = .stopped
        }
        onChanged?(server)
    }

    // ---- watchdog --------------------------------------------------------------

    private func tick() {
        let listening = PortScanner.getListeners()

        for server in servers {
            if server.state == .stopped || server.state == .starting { continue }

            if isHealthy(server, listening: listening) {
                onHealthy(server)
                continue
            }

            if !server.autoRestart {
                if server.state != .stopped {
                    server.state = .stopped
                    onChanged?(server)
                }
                continue
            }

            attemptRestart(server)
        }
    }

    /// Healthy means both that the process is alive and that its port is still
    /// accepting. The port matters on its own: a dev server can wedge, keep its process,
    /// and stop listening — from the outside that is indistinguishable from a crash.
    private func isHealthy(_ server: ManagedServer, listening: [Listener]) -> Bool {
        if server.usesBuiltInServer {
            return server.builtIn != nil
        }

        guard let group = server.processGroup, let pid = group.pid else { return false }
        guard kill(pid, 0) == 0 else { return false }

        guard let port = server.port else {
            // Not yet known: still starting. Learn it from whichever process in our
            // group opened a socket — with "npm run dev" that is a grandchild we never
            // held a handle to, so the group is the only reliable way to recognise it.
            if let found = listening.first(where: { group.contains($0.pid) }) {
                server.port = found.port
                server.append("[serverlife] listening on http://localhost:\(found.port)/")
            }
            // An adopted or just-started server without a port yet is given the benefit
            // of the doubt rather than being restarted out from under itself.
            return true
        }

        return listening.contains { $0.port == port }
    }

    private func onHealthy(_ server: ManagedServer) {
        if server.healthySinceUtc == nil { server.healthySinceUtc = Date() }

        if server.consecutiveFailures > 0,
           let since = server.healthySinceUtc, Date().timeIntervalSince(since) >= Self.healthyResetAfter {
            server.consecutiveFailures = 0
            server.retryAfterUtc = nil
        }

        if server.state != .running {
            server.state = .running
            onChanged?(server)
        }
    }

    private func attemptRestart(_ server: ManagedServer) {
        let now = Date()
        if let after = server.retryAfterUtc, now < after { return }

        if server.consecutiveFailures >= Self.maxConsecutiveFailures {
            if server.state != .failed {
                server.state = .failed
                server.lastError = "Gave up after \(Self.maxConsecutiveFailures) restart attempts."
                server.append("[serverlife] \(server.lastError!)")
                onChanged?(server)
            }
            return
        }

        server.state = .restarting
        server.consecutiveFailures += 1
        server.restartCount += 1
        server.healthySinceUtc = nil
        onChanged?(server)

        server.append("[serverlife] died; restart attempt \(server.consecutiveFailures)")
        startServer(server)

        // Schedule the next attempt from the end of this one, so a server that fails
        // instantly still respects the backoff.
        let wait = Self.backoff[min(server.consecutiveFailures - 1, Self.backoff.count - 1)]
        server.retryAfterUtc = Date().addingTimeInterval(wait)
    }

    public func dispose() {
        watchdogTask?.cancel()
        watchdogTask = nil
        for server in servers { stop(server) }
    }
}
