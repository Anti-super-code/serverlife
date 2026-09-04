import Foundation
import Network

/// A minimal static file server, so dropping a plain folder of HTML works with no
/// tooling installed at all.
///
/// Built on `NWListener`/raw TCP rather than anything higher-level: the subset of HTTP a
/// browser needs to render a local folder is small, and this way there is no dependency
/// on a full HTTP server stack for what is, at bottom, "read a file, write a header".
public final class StaticServer {
    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8", "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "wasm": "application/wasm",
        "txt": "text/plain; charset=utf-8", "map": "application/json; charset=utf-8",
        "pdf": "application/pdf",
    ]

    private let root: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "gr.antidot.serverlife.staticserver")

    public private(set) var port: Int = 0

    /// Loopback only. This serves whatever folder was dropped on it, with no
    /// authentication of any kind; binding the wildcard would publish it to the
    /// network, which is never what dropping a folder on a menu bar app asks for.
    public init(folder: String, port requestedPort: UInt16 = 0) throws {
        self.root = (folder as NSString).resolvingSymlinksInPath
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        self.listener = try NWListener(using: params)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: queue)
        // NWListener assigns its actual port asynchronously once .ready fires; poll
        // briefly for the common synchronous-enough case rather than forcing every
        // caller onto a callback for what is, in practice, an instant assignment.
        for _ in 0..<200 {
            if let assigned = listener.port?.rawValue, assigned != 0 {
                port = Int(assigned)
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestLine(connection, buffer: Data())
    }

    private func receiveRequestLine(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.handleRequest(head, on: connection)
                return
            }
            if isComplete || error != nil || buffer.count > 16 * 1024 {
                connection.cancel()
                return
            }
            self.receiveRequestLine(connection, buffer: buffer)
        }
    }

    private func handleRequest(_ head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            writeStatus(405, "Method Not Allowed", on: connection)
            return
        }

        guard let file = resolve(target) else {
            writeStatus(404, "Not Found", on: connection)
            return
        }

        sendFile(file, headOnly: method == "HEAD", on: connection)
    }

    /// Maps a request target onto a real file, refusing anything that escapes the root.
    /// The containment check runs on the resolved absolute path, so "..", encoded
    /// separators and symlinked parents are all covered by the same test.
    private func resolve(_ target: String) -> String? {
        var path = String(target.split(separator: "?", maxSplits: 1)[0].split(separator: "#", maxSplits: 1)[0])
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { path.removeFirst() }

        let candidate = ((root as NSString).appendingPathComponent(path) as NSString)
            .resolvingSymlinksInPath

        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard candidate.caseInsensitiveCompare(root) == .orderedSame
            || candidate.lowercased().hasPrefix(rootWithSlash.lowercased()) else { return nil }

        var final = candidate
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: final, isDirectory: &isDir), isDir.boolValue {
            final = (final as NSString).appendingPathComponent("index.html")
        }
        guard FileManager.default.fileExists(atPath: final, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return final
    }

    private func sendFile(_ file: String, headOnly: Bool, on connection: NWConnection) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let size = attrs[.size] as? Int else {
            writeStatus(404, "Not Found", on: connection)
            return
        }
        let ext = (file as NSString).pathExtension.lowercased()
        let type = Self.mimeTypes[ext] ?? "application/octet-stream"

        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(type)\r\n" +
            "Content-Length: \(size)\r\n" +
            // A dev server that caches is a dev server you have to hard-refresh.
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        if !headOnly, let contents = FileManager.default.contents(atPath: file) {
            payload.append(contents)
        }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func writeStatus(_ code: Int, _ reason: String, on connection: NWConnection) {
        let body = "<!doctype html><title>\(code) \(reason)</title><h1>\(code) \(reason)</h1>"
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(code) \(reason)\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
