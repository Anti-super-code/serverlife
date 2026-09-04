import Darwin
import Foundation

/// - Parameters:
///   - commandLine: full argv joined into one display string, or nil if it couldn't be read.
///   - workingDirectory: the directory the process was launched from. This is what makes
///     an externally started server restartable, and — unlike the Windows PEB read it
///     replaces — it comes from a documented API, `PROC_PIDVNODEPATHINFO`, so it fails
///     only for a same-uid restriction, not fragile undocumented offsets.
public struct ProcessDetails: Sendable {
    public let pid: Int32
    public let name: String
    public let executablePath: String?
    public let commandLine: String?
    public let workingDirectory: String?
    public let parentPid: Int32
    /// Process group id. The macOS counterpart of "is this pid inside our job object" —
    /// see ProcessGroup.contains(_:).
    public let pgid: Int32
}

/// Describes the processes behind listening ports, via libproc — no batching needed the
/// way Windows batches into one WMI query, since each of these is a cheap syscall rather
/// than a WMI round trip costing tens of milliseconds.
public enum ProcessInspector {
    /// Describes every requested pid. Unknown or exited pids are simply absent from the
    /// result rather than throwing.
    public static func describe(_ pids: some Collection<Int32>) -> [Int32: ProcessDetails] {
        var result: [Int32: ProcessDetails] = [:]
        for pid in Set(pids) {
            guard let details = describe(pid) else { continue }
            result[pid] = details
        }
        return result
    }

    public static func describe(_ pid: Int32) -> ProcessDetails? {
        var bsdInfo = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }

        let name = processName(pid) ?? withUnsafeBytes(of: bsdInfo.pbi_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }

        return ProcessDetails(
            pid: pid,
            name: name,
            executablePath: processPath(pid),
            commandLine: commandLine(pid),
            workingDirectory: workingDirectory(pid),
            parentPid: Int32(bitPattern: bsdInfo.pbi_ppid),
            pgid: Int32(bitPattern: bsdInfo.pbi_pgid))
    }

    private static func processName(_ pid: Int32) -> String? {
        var buf = [Int8](repeating: 0, count: 64)
        let r = proc_name(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        return String(cString: buf)
    }

    /// The macro this mirrors (`PROC_PIDPATHINFO_MAXSIZE`, `4*MAXPATHLEN`) is marked
    /// unavailable to Swift in the SDK header, so its value is inlined instead.
    private static let maxPathInfoSize = 4 * 1024

    private static func processPath(_ pid: Int32) -> String? {
        var buf = [Int8](repeating: 0, count: maxPathInfoSize)
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        return String(cString: buf)
    }

    // ---- working directory, via PROC_PIDVNODEPATHINFO -----------------------------
    //
    // A documented API, unlike the Windows PEB read this replaces: no undocumented
    // offsets, no 64-bit-only restriction. It still fails for a process owned by
    // another uid (EPERM) or one that has already exited; both degrade to nil, and
    // the caller falls back to "unknown folder" exactly as the Windows path does.

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    // ---- command line, via sysctl(KERN_PROCARGS2) ----------------------------------
    //
    // KERN_PROCARGS2 hands back argc, the exec path, then argv, each NUL-separated,
    // padded with extra NULs to a word boundary — not a clean array, so it has to be
    // parsed by hand. Fails (returns nil) for another user's process, same as Windows'
    // WMI CommandLine property does when access is denied.

    private static func commandLine(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 4 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        // Skip argc (4 bytes), then the exec path, then its NUL padding, landing at argv[0].
        var offset = 4
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }

        var args: [String] = []
        var start = offset
        var remaining = Int(argc)
        var cursor = offset
        while cursor < size, remaining > 0 {
            if buffer[cursor] == 0 {
                let slice = buffer[start..<cursor]
                if let s = String(bytes: slice, encoding: .utf8) {
                    args.append(s)
                }
                remaining -= 1
                cursor += 1
                start = cursor
                continue
            }
            cursor += 1
        }
        guard !args.isEmpty else { return nil }
        return args.joined(separator: " ")
    }
}
