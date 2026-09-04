import Darwin
import Foundation

/// A socket in the LISTEN state, with the process that owns it.
public struct Listener: Hashable, Sendable {
    public let port: Int
    public let pid: Int32
    /// The local bind address, as text — "0.0.0.0", "::", "127.0.0.1", etc.
    public let address: String

    public init(port: Int, pid: Int32, address: String) {
        self.port = port
        self.pid = pid
        self.address = address
    }

    /// True when the socket is reachable from this machine's browser: either bound to
    /// a loopback address or to the wildcard (0.0.0.0 / ::), which includes loopback.
    /// Servers bound only to a LAN address are still listed, just not assumed local.
    public var isLocallyReachable: Bool {
        address == "127.0.0.1" || address == "0.0.0.0" || address == "::" || address == "::1"
    }
}

/// Enumerates listening TCP sockets and their owning PIDs via libproc — the same
/// per-process fd walk `lsof` itself uses. Unlike the Windows counterpart
/// (`GetExtendedTcpTable`, a single system-wide call), macOS has no system-wide
/// "all listening sockets" table exposed to an unprivileged process, so this walks
/// every process's own fd list instead: `proc_listpids` for the pid set, then
/// `proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` per pid.
public enum PortScanner {
    /// All listening sockets, IPv4 and IPv6. Never throws: a pid that exits mid-walk,
    /// or one we don't have permission to inspect (EPERM for another user's process —
    /// this incidentally does the job the Windows SystemPid==4 filter does, since a
    /// root-owned listener is simply invisible rather than needing to be excluded),
    /// is skipped rather than aborting the whole scan.
    public static func getListeners() -> [Listener] {
        var results: [Listener] = []
        for pid in allPids() {
            results.append(contentsOf: listeners(for: pid))
        }
        return results
    }

    /// Every pid currently running, via `proc_listpids(PROC_ALL_PIDS)`.
    public static func allPids() -> [Int32] {
        let bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let count = Int(bufSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actual = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufSize)
        guard actual > 0 else { return [] }
        let actualCount = Int(actual) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(actualCount)).filter { $0 > 0 }
    }

    private static func listeners(for pid: Int32) -> [Listener] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
        guard count > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard actual > 0 else { return [] }
        let actualCount = Int(actual) / MemoryLayout<proc_fdinfo>.size

        var found: [Listener] = []
        for entry in fds.prefix(actualCount) {
            guard entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var info = socket_fdinfo()
            let r = proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                    Int32(MemoryLayout<socket_fdinfo>.size))
            guard r == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }

            // The port is a network-order u16 living in a wider `int` field; the
            // remaining bytes are padding and must be ignored, not folded in.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            let address = addressString(tcp.tcpsi_ini)
            found.append(Listener(port: port, pid: pid, address: address))
        }
        return found
    }

    private static func addressString(_ ini: in_sockinfo) -> String {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            var buf = [Int8](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        } else {
            var addr = ini.insi_laddr.ina_6
            var buf = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buf)
        }
    }
}
