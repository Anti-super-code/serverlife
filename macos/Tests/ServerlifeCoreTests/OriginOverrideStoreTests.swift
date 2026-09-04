import XCTest
@testable import ServerlifeCore

final class OriginOverrideStoreTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginOverrideStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("origin-overrides.json")
        OriginOverrideStore.storeURLOverride = tempFile
        OriginOverrideStore.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent())
        OriginOverrideStore.storeURLOverride = nil
        OriginOverrideStore.resetCache()
    }

    func testKeyForPrefersWorkingDirectory() {
        let key = OriginOverrideStore.key(workingDirectory: "/Users/chris/dev/site/", processName: "node")
        XCTAssertEqual(key, "dir:/users/chris/dev/site")
    }

    func testKeyForFallsBackToProcessNameWhenNoFolder() {
        XCTAssertEqual(OriginOverrideStore.key(workingDirectory: nil, processName: "GT3Service.exe"), "proc:gt3service")
        XCTAssertEqual(OriginOverrideStore.key(workingDirectory: "", processName: "GT3Service"), "proc:gt3service")
    }

    func testSetGetClearRoundTrip() {
        let key = "dir:/users/chris/dev/site"
        XCTAssertNil(OriginOverrideStore.get(key))

        OriginOverrideStore.set(key, origin: .system)
        XCTAssertEqual(OriginOverrideStore.get(key), .system)

        OriginOverrideStore.clear(key)
        XCTAssertNil(OriginOverrideStore.get(key))
    }

    func testPersistsAcrossCacheReset() {
        let key = "dir:/users/chris/dev/site"
        OriginOverrideStore.set(key, origin: .mine)
        OriginOverrideStore.resetCache()
        XCTAssertEqual(OriginOverrideStore.get(key), .mine)
    }

    func testCorruptFileDegradesToNoOverridesRatherThanThrowing() throws {
        try FileManager.default.createDirectory(at: tempFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not valid json {{{".write(to: tempFile, atomically: true, encoding: .utf8)
        OriginOverrideStore.resetCache()
        XCTAssertNil(OriginOverrideStore.get("dir:/anything"))
    }
}
