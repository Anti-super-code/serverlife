import XCTest
@testable import ServerlifeCore

final class StaticServerTests: XCTestCase {
    private var tempDir: URL!
    private var server: StaticServer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaticServerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "<html><head><title>hi</title></head><body>hello</body></html>"
            .write(to: tempDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "secret".write(to: tempDir.appendingPathComponent("sub/secret.txt"), atomically: true, encoding: .utf8)

        server = try StaticServer(folder: tempDir.path)
        server.start()
        // The listener's real port is assigned asynchronously; StaticServer.start()
        // already polls briefly for it, so by the time it returns `port` is set.
        XCTAssertGreaterThan(server.port, 0)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func get(_ path: String) throws -> (status: Int, body: String) {
        let url = URL(string: "http://127.0.0.1:\(server.port)\(path)")!
        let expectation = expectation(description: "response")
        var result: (Int, String)?
        let task = URLSession.shared.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            result = (status, body)
            expectation.fulfill()
        }
        task.resume()
        wait(for: [expectation], timeout: 5)
        return result ?? (0, "")
    }

    func testServesIndexHtml() throws {
        let (status, body) = try get("/")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("hello"))
    }

    func testMissingFileReturns404() throws {
        let (status, _) = try get("/does-not-exist.html")
        XCTAssertEqual(status, 404)
    }

    func testPathTraversalIsRefused() throws {
        let (status, _) = try get("/../../etc/passwd")
        XCTAssertNotEqual(status, 200)
    }

    func testEncodedTraversalIsAlsoRefused() throws {
        let (status, _) = try get("/%2e%2e/%2e%2e/etc/passwd")
        XCTAssertNotEqual(status, 200)
    }

    func testServesNestedFile() throws {
        let (status, body) = try get("/sub/secret.txt")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "secret")
    }
}
