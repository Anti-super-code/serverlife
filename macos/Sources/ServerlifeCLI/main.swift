import Foundation
import ServerlifeCore

/// Headless mode, so discovery and the supervisor can be exercised without the UI:
///
///     serverlife-cli --scan [--all]
///     serverlife-cli --run <folder> [command] [--seconds N] [--no-restart]
///
/// --all keeps ports that did not answer as HTTP (databases, RPC, etc.), which the GUI
/// hides by default.

func usage() -> Int32 {
    FileHandle.standardError.write(Data("""
    usage:
      serverlife-cli --scan [--all]
          List listening ports. --all includes ports that did not answer as HTTP.

      serverlife-cli --run <folder> [command] [--seconds N] [--no-restart]
          Start a supervised server and report its state until N seconds elapse.
          With no command, the folder is served by the built-in static server.

    """.utf8))
    return 2
}

func clip(_ value: String, _ width: Int) -> String {
    value.count <= width ? value : String(value.prefix(width - 1)) + "…"
}

func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}

func runScan(_ args: [String]) async -> Int32 {
    let showAll = args.contains("--all")

    let discovery = Discovery()
    let servers = await discovery.scan()
    let shown = showAll ? servers : servers.filter(\.probe.isHttp)

    if shown.isEmpty {
        print(showAll
            ? "No listening TCP ports found."
            : "No local HTTP servers found. Re-run with --all to include non-HTTP ports.")
        return 0
    }

    print("\(pad("PORT", 6)) \(pad("PID", 7)) \(pad("PROCESS", 18)) \(pad("NAME / TITLE", 34)) FOLDER")
    print(String(repeating: "-", count: 110))
    for s in shown {
        let folder = s.workingDirectory ?? (s.probe.isHttp ? "(unknown)" : "")
        let flag = s.isAdoptable ? " " : "*"
        let port = s.isContested ? "\(s.port)!" : "\(s.port)"
        print("\(pad(port, 6)) \(pad(String(s.pid), 7)) \(pad(clip(s.processName, 18), 18)) "
              + "\(pad(clip(s.displayName, 34), 34)) \(flag)\(folder)")
    }

    print()
    print("\(shown.count) shown, \(servers.count) listening total.")
    print("* = not restartable: no readable command line or working directory.")

    let contestedPorts = Set(shown.filter(\.isContested).map(\.port))
    for port in contestedPorts.sorted() {
        let count = shown.filter { $0.port == port }.count
        print("! = port \(port) has \(count) unrelated processes bound to it; "
              + "only the last one to bind is serving.")
    }
    return 0
}

func runSupervised(_ args: [String]) async -> Int32 {
    guard args.count >= 2 else { return usage() }
    let folder = (args[1] as NSString).standardizingPath
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
        FileHandle.standardError.write(Data("No such folder: \(folder)\n".utf8))
        return 2
    }

    var seconds = 30
    if let idx = args.firstIndex(of: "--seconds"), idx + 1 < args.count, let n = Int(args[idx + 1]) {
        seconds = n
    }

    var command = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : ""
    if command.isEmpty {
        let suggestion = ProjectDetector.suggest(folder: folder)
        command = suggestion.command
        print("detected: \(suggestion.why)")
    }

    let supervisor = Supervisor()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    supervisor.onChanged = { s in
        let state = "\(s.state)"
        print("[\(formatter.string(from: Date()))] \(pad(state, 10)) port=\(pad(s.port.map(String.init) ?? "-", 6)) "
              + "restarts=\(s.restartCount) \(s.lastError ?? "")")
    }

    let server = supervisor.add(ManagedServer(
        name: (folder as NSString).lastPathComponent, directory: folder, command: command,
        autoRestart: !args.contains("--no-restart")))

    supervisor.startServer(server)
    supervisor.start()

    print("supervising for \(seconds)s — kill it externally to watch it come back")
    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)

    print()
    print("final: \(server.state), \(server.restartCount) restart(s), port \(server.port.map(String.init) ?? "-")")
    print("--- last log lines ---")
    for line in server.snapshot().suffix(12) {
        print("  " + line)
    }

    supervisor.stop(server)
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
let exitCode: Int32
switch args.first {
case "--scan": exitCode = await runScan(args)
case "--run": exitCode = await runSupervised(args)
default: exitCode = usage()
}
exit(exitCode)
