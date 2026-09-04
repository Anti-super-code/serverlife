import Foundation

/// One listening port, everything we know about it, ready to put in a row.
public struct DetectedServer: Sendable {
    public let port: Int
    public let pid: Int32
    public let parentPid: Int32
    public let address: String
    public let processName: String
    public let commandLine: String?
    public let workingDirectory: String?
    public let probe: ProbeResult
    public let peersOnPort: Int

    public init(port: Int, pid: Int32, parentPid: Int32, address: String, processName: String,
                commandLine: String?, workingDirectory: String?, probe: ProbeResult, peersOnPort: Int = 0) {
        self.port = port
        self.pid = pid
        self.parentPid = parentPid
        self.address = address
        self.processName = processName
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.probe = probe
        self.peersOnPort = peersOnPort
    }

    /// True when other, unrelated processes are bound to this same port. Rare on macOS —
    /// BSD refuses a second bind without SO_REUSEPORT — but a SO_REUSEPORT server can
    /// still trigger it, so the detection stays even though the pathology it exists to
    /// surface (Windows lets several processes bind unless SO_EXCLUSIVEADDRUSE is set)
    /// mostly cannot happen here.
    public var isContested: Bool { peersOnPort > 0 }

    /// Interpreters that tell you nothing about what is being served. For these the
    /// folder name is the far better label — "antidot 2026" beats "node" — but for a
    /// named program the process name is exactly right, and its folder is often
    /// actively misleading.
    private static let genericRuntimes: Set<String> = [
        "node", "python", "python3", "ruby", "php", "java", "deno", "bun", "cargo", "go",
    ]

    public var url: String { "\(probe.scheme ?? "http")://localhost:\(port)/" }

    private var bareProcessName: String { (processName as NSString).lastPathComponent }

    /// Whose server this looks like. A user pin wins outright; otherwise falls back to
    /// OriginClassifier's guess.
    public var origin: ServerOrigin {
        let key = OriginOverrideStore.key(workingDirectory: workingDirectory, processName: processName)
        return OriginOverrideStore.get(key) ?? OriginClassifier.classify(workingDirectory: workingDirectory)
    }

    /// What the row leads with: the served page's title, else the folder name when the
    /// process is only an interpreter, else the program's own name.
    public var displayName: String {
        if let title = probe.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if Self.genericRuntimes.contains(bareProcessName),
           let dir = workingDirectory, !dir.isEmpty {
            let folder = (dir as NSString).lastPathComponent
            if !folder.isEmpty { return folder }
        }
        return bareProcessName
    }

    /// Whether this could be relaunched if it died — the two facts a restart needs.
    public var isAdoptable: Bool {
        guard let commandLine, !commandLine.trimmingCharacters(in: .whitespaces).isEmpty,
              let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Polls for listening ports and describes what is behind them. Owns no UI and no
/// process lifetime: it only ever observes. Starting and stopping lives in Supervisor.
public actor Discovery {
    private static let pollInterval: TimeInterval = 2
    private static let probeConcurrency = 16

    private let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)

    /// Probe results keyed by port AND pid, so a port reused by a different process is
    /// re-probed rather than inheriting the old title. Without the pid in the key,
    /// restarting a server on the same port would keep showing its previous page.
    private var probeCache: [PortPidKey: ProbeResult] = [:]

    private struct PortPidKey: Hashable { let port: Int; let pid: Int32 }

    private var loopTask: Task<Void, Never>?
    private var updateHandler: (@Sendable ([DetectedServer]) -> Void)?

    public init() {}

    public func onUpdate(_ handler: @escaping @Sendable ([DetectedServer]) -> Void) {
        updateHandler = handler
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let servers = await self.scan()
                await self.publish(servers)
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func publish(_ servers: [DetectedServer]) {
        updateHandler?(servers)
    }

    /// One full pass: ports, then owning processes, then titles for anything new.
    public func scan() async -> [DetectedServer] {
        let listeners = PortScanner.getListeners()
            .filter { $0.isLocallyReachable && $0.pid != ownPid }

        // The same server usually holds both an IPv4 and an IPv6 socket on one port.
        // Collapse to one entry per (port, pid) before doing any real work.
        var uniqueByKey: [PortPidKey: Listener] = [:]
        for l in listeners { uniqueByKey[PortPidKey(port: l.port, pid: l.pid)] = l }
        let unique = Array(uniqueByKey.values)

        var details = ProcessInspector.describe(unique.map(\.pid))
        describeSharedParents(unique, details: &details)

        // Resolve every port's owners first, so the probes can then all be issued at
        // once rather than one port at a time.
        var byPort: [Int: [Listener]] = [:]
        for l in unique { byPort[l.port, default: []].append(l) }

        var ports: [(port: Int, address: String, owners: [Int32])] = []
        for (port, holders) in byPort {
            let owners = resolveOwners(holders, details: details)
            ports.append((port, holders.first?.address ?? "", owners))
        }

        await probeAll(ports)

        var servers: [DetectedServer] = []
        for (port, address, owners) in ports {
            let probe = probeCache[PortPidKey(port: port, pid: owners.first ?? 0)] ?? .notHttp
            for pid in owners {
                let info = details[pid]
                servers.append(DetectedServer(
                    port: port, pid: pid, parentPid: info?.parentPid ?? 0, address: address,
                    processName: info?.name ?? "unknown", commandLine: info?.commandLine,
                    workingDirectory: info?.workingDirectory, probe: probe, peersOnPort: owners.count - 1))
            }
        }

        pruneCache(live: Set(ports.map { PortPidKey(port: $0.port, pid: $0.owners.first ?? 0) }))
        return servers.sorted { $0.port < $1.port }
    }

    /// When a port's holders are all siblings forked by one supervisor, that supervisor
    /// is the process worth acting on even though it holds no socket itself — so it has
    /// to be described too.
    private func describeSharedParents(_ listeners: [Listener], details: inout [Int32: ProcessDetails]) {
        var byPort: [Int: [Listener]] = [:]
        for l in listeners { byPort[l.port, default: []].append(l) }

        var extra: Set<Int32> = []
        for (_, holders) in byPort where holders.count > 1 {
            if let parent = findSharedParent(holders.map(\.pid), details: details), details[parent] == nil {
                extra.insert(parent)
            }
        }
        for (pid, info) in ProcessInspector.describe(extra) {
            details[pid] = info
        }
    }

    /// The one parent common to every holder, when it exists and is not itself a holder.
    private func findSharedParent(_ holders: [Int32], details: [Int32: ProcessDetails]) -> Int32? {
        let holderSet = Set(holders)
        let parents = Set(holders.map { details[$0]?.parentPid ?? 0 })
        guard parents.count == 1, let parent = parents.first else { return nil }
        if parent == 0 || holderSet.contains(parent) { return nil }
        return parent
    }

    /// Resolves a port's holders to the processes actually worth showing and acting on.
    ///
    /// Several pids on one port means one of two very different things:
    ///
    ///   - ONE server whose workers inherited the listening handle. Collapses to the
    ///     ancestor or the supervisor that forked them.
    ///   - SEVERAL independent servers that each bound the same port (SO_REUSEPORT).
    ///     These stay as separate rows, flagged, because hiding them hides the problem.
    private func resolveOwners(_ holders: [Listener], details: [Int32: ProcessDetails]) -> [Int32] {
        let pids = Array(Set(holders.map(\.pid)))
        guard pids.count > 1 else { return pids }
        let pidSet = Set(pids)

        let roots = pids.filter { pid in
            guard let info = details[pid] else { return false }
            return !pidSet.contains(info.parentPid)
        }
        if roots.count == 1 { return roots }

        if let shared = findSharedParent(pids, details: details), details[shared] != nil {
            return [shared]
        }
        return pids.sorted()
    }

    private func probeAll(_ ports: [(port: Int, address: String, owners: [Int32])]) async {
        await withTaskGroup(of: Void.self) { group in
            for lane in partition(ports, lanes: Self.probeConcurrency) {
                group.addTask { [self] in
                    for (port, _, owners) in lane {
                        let key = PortPidKey(port: port, pid: owners.first ?? 0)
                        if await self.hasCached(key) { continue }
                        let result = await HttpProbe.probe(port: port)
                        await self.cache(result, for: key)
                    }
                }
            }
        }
    }

    private func hasCached(_ key: PortPidKey) -> Bool { probeCache[key] != nil }
    private func cache(_ result: ProbeResult, for key: PortPidKey) { probeCache[key] = result }

    /// Splits into `lanes` round-robin slices, each walked serially, so one slow stretch
    /// of adjacent ports cannot land entirely in a single lane.
    private func partition<T>(_ items: [T], lanes: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let laneCount = min(lanes, items.count)
        var buckets = Array(repeating: [T](), count: laneCount)
        for (i, item) in items.enumerated() { buckets[i % laneCount].append(item) }
        return buckets
    }

    /// Drops cache entries for sockets that have gone, so it cannot grow without bound.
    private func pruneCache(live: Set<PortPidKey>) {
        guard probeCache.count > live.count else { return }
        for key in probeCache.keys where !live.contains(key) {
            probeCache.removeValue(forKey: key)
        }
    }
}
