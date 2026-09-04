import XCTest
@testable import ServerlifeCore

final class HttpProbeTests: XCTestCase {
    func testExtractsSimpleTitle() {
        let html = "<html><head><title>Astarte 3D — workbench</title></head><body></body></html>"
        XCTAssertEqual(HttpProbe.extractTitle(html), "Astarte 3D — workbench")
    }

    func testTitleWithAttributesAndWhitespace() {
        let html = "<title lang=\"en\">\n   Vite\n   +   React \n</title>"
        XCTAssertEqual(HttpProbe.extractTitle(html), "Vite + React")
    }

    func testNoTitleReturnsNil() {
        XCTAssertNil(HttpProbe.extractTitle("<html><body>no title here</body></html>"))
    }

    func testEmptyTitleReturnsNil() {
        XCTAssertNil(HttpProbe.extractTitle("<title></title>"))
    }

    func testDecodesNamedEntities() {
        XCTAssertEqual(HttpProbe.decodeEntities("Fish &amp; Chips"), "Fish & Chips")
        XCTAssertEqual(HttpProbe.decodeEntities("&lt;script&gt;"), "<script>")
        XCTAssertEqual(HttpProbe.decodeEntities("&quot;quoted&quot;"), "\"quoted\"")
        XCTAssertEqual(HttpProbe.decodeEntities("it&apos;s"), "it's")
    }

    func testDecodesNumericEntities() {
        XCTAssertEqual(HttpProbe.decodeEntities("&#169; 2026"), "\u{00A9} 2026")
        XCTAssertEqual(HttpProbe.decodeEntities("&#x2014;"), "\u{2014}")
    }

    func testUnknownEntityPassesThroughUnchanged() {
        XCTAssertEqual(HttpProbe.decodeEntities("A&nbsp;B &notarealentity; C"), "A&nbsp;B &notarealentity; C")
    }

    func testShouldProbeExcludesKnownDatabasePorts() {
        XCTAssertFalse(HttpProbe.shouldProbe(5432))
        XCTAssertFalse(HttpProbe.shouldProbe(3306))
        XCTAssertFalse(HttpProbe.shouldProbe(6379))
        XCTAssertTrue(HttpProbe.shouldProbe(3000))
        XCTAssertTrue(HttpProbe.shouldProbe(8080))
    }

    func testProbeAgainstRealStaticServer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HttpProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try "<title>Test Page</title>".write(
            to: tempDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let server = try StaticServer(folder: tempDir.path)
        server.start()
        defer { server.stop() }

        let result = await HttpProbe.probe(port: server.port)
        XCTAssertTrue(result.isHttp)
        XCTAssertEqual(result.title, "Test Page")
        XCTAssertEqual(result.scheme, "http")
    }

    func testProbeAgainstClosedPortIsNotHttp() async {
        // Port 1 is a reserved low port that's virtually never bound and refuses
        // connections outright, standing in for "nothing is listening here".
        let result = await HttpProbe.probe(port: 1)
        XCTAssertFalse(result.isHttp)
    }
}
