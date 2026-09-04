import Foundation

/// - Parameters:
///   - isHttp: false when the port answered but not as HTTP (a database, say).
///   - title: the page's <title>, trimmed, or nil if it had none.
///   - scheme: "http" or "https" — whichever actually answered.
public struct ProbeResult: Sendable {
    public let isHttp: Bool
    public let title: String?
    public let scheme: String?
    public let status: Int?

    public static let notHttp = ProbeResult(isHttp: false, title: nil, scheme: nil, status: nil)
}

/// Asks a local port what it is serving, so a row can read "Vite + React" instead of
/// "node". One GET per port, cached by the caller — see Discovery.
public enum HttpProbe {
    private static let timeout: TimeInterval = 0.8

    /// Ports that are never worth a probe. Sending even a well-formed GET to a database
    /// makes it log a protocol error, so they are skipped outright rather than tried
    /// and discarded.
    private static let neverProbe: Set<Int> = [
        135, 139, 445, 1433, 3306, 5432, 6379, 11211, 27017,
    ]

    /// A delegate that accepts loopback's self-signed certs (we are only reading a
    /// title, not verifying identity) and disables redirects, so the title read
    /// belongs to the port asked about, not wherever it forwards.
    private final class LoopbackSession: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let delegate = LoopbackSession()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    public static func shouldProbe(_ port: Int) -> Bool { !neverProbe.contains(port) }

    /// Probes http first, then https. Never throws: an unreachable or non-HTTP port
    /// comes back as `.notHttp`.
    public static func probe(port: Int) async -> ProbeResult {
        guard shouldProbe(port) else { return .notHttp }

        let viaHttp = await tryOne(scheme: "http", port: port)
        if viaHttp.isHttp { return viaHttp }
        return await tryOne(scheme: "https", port: port)
    }

    private static func tryOne(scheme: String, port: Int) async -> ProbeResult {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/") else { return .notHttp }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .notHttp }

            guard isHtml(http) else {
                return ProbeResult(isHttp: true, title: nil, scheme: scheme, status: http.statusCode)
            }

            let html = try await readCapped(bytes)
            return ProbeResult(isHttp: true, title: extractTitle(html), scheme: scheme, status: http.statusCode)
        } catch {
            // Connection refused, TLS mismatch, timeout, or a service that answered with
            // something that is not HTTP at all. All mean the same thing to us.
            return .notHttp
        }
    }

    private static func isHtml(_ response: HTTPURLResponse) -> Bool {
        // A dev server that omits Content-Type is still worth parsing; a JSON API is not.
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else { return true }
        return contentType.range(of: "html", options: .caseInsensitive) != nil
    }

    /// Reads only the head of the document. The title lives in <head>, and some dev
    /// servers stream responses that never end — reading to completion would hang until
    /// the timeout on every single poll.
    private static func readCapped(_ bytes: URLSession.AsyncBytes) async throws -> String {
        let cap = 64 * 1024
        var data = Data()
        data.reserveCapacity(cap)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= cap { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static let titlePattern = try? NSRegularExpression(
        pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    static let whitespaceRun = try? NSRegularExpression(pattern: "\\s+")

    static func extractTitle(_ html: String) -> String? {
        guard let titlePattern else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = titlePattern.firstMatch(in: html, range: range),
              let group = Range(match.range(at: 1), in: html) else { return nil }

        let raw = decodeEntities(String(html[group]))
        let collapsed: String
        if let whitespaceRun {
            let fullRange = NSRange(raw.startIndex..., in: raw)
            collapsed = whitespaceRun.stringByReplacingMatches(in: raw, range: fullRange, withTemplate: " ")
        } else {
            collapsed = raw
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Foundation has no HttpUtility.HtmlDecode equivalent that's safe to call off the
    /// main thread on a poll loop (NSAttributedString(html:) is main-thread-only and far
    /// too slow here), so the handful of entities that actually show up in page titles
    /// are decoded by hand: the five named XML entities, plus numeric refs.
    static func decodeEntities(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var chars = Substring(text)
        while let ampIndex = chars.firstIndex(of: "&") {
            result += chars[chars.startIndex..<ampIndex]
            let rest = chars[ampIndex...]
            guard let semiIndex = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semiIndex) <= 10 else {
                result.append("&")
                chars = chars[chars.index(after: ampIndex)...]
                continue
            }
            let entity = rest[rest.index(after: rest.startIndex)..<semiIndex]
            if let scalar = decodeOneEntity(String(entity)) {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[rest.startIndex...semiIndex]
            }
            chars = chars[rest.index(after: semiIndex)...]
        }
        result += chars
        return result
    }

    static func decodeOneEntity(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X"),
               let code = UInt32(name.dropFirst(2), radix: 16) {
                return Unicode.Scalar(code)
            }
            if name.hasPrefix("#"), let code = UInt32(name.dropFirst()) {
                return Unicode.Scalar(code)
            }
            return nil
        }
    }
}
