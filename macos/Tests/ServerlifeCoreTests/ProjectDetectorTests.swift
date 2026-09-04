import XCTest
@testable import ServerlifeCore

final class ProjectDetectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ name: String, _ contents: String = "") throws {
        try contents.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testPrefersDevScript() throws {
        try write("package.json", #"{"scripts":{"build":"tsc","dev":"vite"}}"#)
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "npm run dev")
        XCTAssertFalse(s.usesBuiltInServer)
    }

    func testFallsBackThroughScriptPreference() throws {
        try write("package.json", #"{"scripts":{"build":"tsc","start":"node server.js"}}"#)
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "npm run start")
    }

    func testPnpmLockfileChoosesPnpmRunner() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"}}"#)
        try write("pnpm-lock.yaml")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "pnpm run dev")
    }

    func testYarnLockfileChoosesYarnRunner() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"}}"#)
        try write("yarn.lock")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "yarn run dev")
    }

    func testMalformedPackageJsonStillSuggestsConventionalDev() throws {
        try write("package.json", "{not valid json")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "npm run dev")
        XCTAssertTrue(s.why.contains("no readable scripts"))
    }

    func testDjangoManagePy() throws {
        try write("manage.py")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "python manage.py runserver")
    }

    func testRustCargoToml() throws {
        try write("Cargo.toml")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "cargo run")
    }

    func testDockerCompose() throws {
        try write("docker-compose.yml")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertEqual(s.command, "docker compose up")
    }

    func testStaticSiteFallsBackToBuiltInServer() throws {
        try write("index.html", "<html></html>")
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertTrue(s.usesBuiltInServer)
        XCTAssertEqual(s.command, "")
    }

    func testEmptyFolderFallsBackToBuiltInServer() throws {
        let s = ProjectDetector.suggest(folder: tempDir.path)
        XCTAssertTrue(s.usesBuiltInServer)
    }
}
