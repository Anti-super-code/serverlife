import Darwin
import Foundation

/// The `JobObject` counterpart: kills everything spawned under it when told to.
///
/// This is the whole reason stopping a server actually works. "npm run dev" is
/// sh -> npm -> node; killing only the process we spawned would leave node holding the
/// port. Windows solves this with a kernel job object that is inescapable no matter who
/// exits in between. macOS has no exact equivalent — the nearest primitive is a POSIX
/// process group: the spawned child becomes its own group leader (`pgid == its own pid`),
/// every descendant that doesn't explicitly opt out inherits that pgid, and `kill(-pgid,
/// sig)` signals the whole group in one call.
///
/// The one real gap from a job object: a process group is not inescapable. A child that
/// calls `setsid()` leaves it and becomes unreachable through this mechanism. In practice
/// the Node/Python/Rust dev servers this app targets do not do that.
public final class ProcessGroup {
    public private(set) var pid: pid_t?

    public init() {}

    /// Spawns `command` via `/bin/sh -c`, in its own new process group, with stdout/
    /// stderr piped back through `onOutput`. Throws if `posix_spawn` itself fails;
    /// `onOutput` lines keep arriving asynchronously on a background queue until the
    /// pipes close.
    public func spawn(command: String, workingDirectory: String,
                       onOutput: @escaping (String) -> Void) throws {
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETPGROUP + a target pgid of 0 makes the new process its own
        // group leader — the pgid that every descendant it goes on to fork inherits.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, 2)
        // The non-deprecated `posix_spawn_file_actions_addchdir` only exists from macOS 26
        // on; this app's floor is macOS 13, so the `_np` spelling (available since 10.15)
        // is the only one that actually works on this deployment target.
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

        var childPid: pid_t = 0
        let argv: [String?] = ["/bin/sh", "-c", command, nil]
        let envp: [String?] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + [nil]

        let spawnResult = argv.withCStrings { argvC in
            envp.withCStrings { envpC in
                posix_spawn(&childPid, "/bin/sh", &fileActions, &attr, argvC, envpC)
            }
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        guard spawnResult == 0 else {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw ProcessGroupError.spawnFailed(errno: spawnResult)
        }

        pid = childPid
        pumpLines(from: stdoutPipe.fileHandleForReading, into: onOutput)
        pumpLines(from: stderrPipe.fileHandleForReading, into: onOutput)
    }

    /// Whether a pid belongs to this group. This is how a started server's port is
    /// learned when the listener is a grandchild ("npm run dev" -> sh -> npm -> node):
    /// rather than guessing at the tree, each listening pid is asked whether its pgid
    /// matches ours.
    public func contains(_ candidate: Int32) -> Bool {
        guard let pgid else { return false }
        var info = proc_bsdinfo()
        let r = proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
        return Int32(bitPattern: info.pbi_pgid) == pgid
    }

    private var pgid: pid_t? { pid }

    /// Kills every process in the group. SIGTERM first, a brief grace period, then
    /// SIGKILL for anything still standing — synchronous by the time it returns, same
    /// contract as the Windows `TerminateJobObject` call this replaces.
    public func kill(gracePeriod: TimeInterval = 0.3) {
        guard let pgid else { return }
        Darwin.kill(-pgid, SIGTERM)
        Thread.sleep(forTimeInterval: gracePeriod)
        Darwin.kill(-pgid, SIGKILL)
        self.pid = nil
    }

    private func pumpLines(from handle: FileHandle, into onOutput: @escaping (String) -> Void) {
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onOutput(String(line))
            }
        }
    }
}

public enum ProcessGroupError: Error, LocalizedError {
    case spawnFailed(errno: Int32)
    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let errno):
            return "posix_spawn failed (errno \(errno)): \(String(cString: strerror(errno)))"
        }
    }
}

/// `posix_spawn` wants a `[UnsafeMutablePointer<CChar>?]` argv/envp, nil-terminated.
/// This builds and frees that scratch array around the call.
private extension Array where Element == String? {
    func withCStrings<R>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = self.map { $0.flatMap { strdup($0) } }
        defer { for c in cStrings where c != nil { free(c) } }
        return cStrings.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }
}
