import XCTest
@testable import ServerlifeCore

final class FinderIntegrationTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        // Point registration at a scratch directory instead of the real
        // ~/Library/Services — otherwise a test run could read and (via
        // unregister() in tearDown) delete whatever real Quick Action
        // registration is actually live on the machine.
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerlifeTests-\(UUID().uuidString)", isDirectory: true)
        FinderIntegration.servicesDirOverride = scratchDir
    }

    override func tearDown() {
        try? FinderIntegration.unregister()
        try? FileManager.default.removeItem(at: scratchDir)
        FinderIntegration.servicesDirOverride = nil
        super.tearDown()
    }

    /// Adapted from Photokompressor's own test for the same guard: registering while
    /// running from the mounted install .dmg bakes in a /Volumes/... path that stops
    /// existing the moment the disk image is ejected.
    func testRefusesToRegisterFromRemovableVolume() {
        XCTAssertThrowsError(
            try FinderIntegration.register(appPathOverride: "/Volumes/Serverlife 0.1.0/Serverlife.app")
        ) { error in
            guard let finderError = error as? FinderIntegration.FinderIntegrationError else {
                return XCTFail("wrong error type: \(error)")
            }
            XCTAssertEqual(finderError, .runningFromRemovableVolume)
        }
        XCTAssertFalse(FinderIntegration.isRegistered())
    }

    func testRegistersFromANormalPath() throws {
        try FinderIntegration.register(appPathOverride: "/Applications/Serverlife.app")
        XCTAssertTrue(FinderIntegration.isRegistered())
    }

    func testUnregisterRemovesTheWorkflow() throws {
        try FinderIntegration.register(appPathOverride: "/Applications/Serverlife.app")
        XCTAssertTrue(FinderIntegration.isRegistered())
        try FinderIntegration.unregister()
        XCTAssertFalse(FinderIntegration.isRegistered())
    }

    func testWorkflowAcceptsFoldersNotFiles() throws {
        try FinderIntegration.register(appPathOverride: "/Applications/Serverlife.app")
        let infoPlist = scratchDir
            .appendingPathComponent("Start server here.workflow")
            .appendingPathComponent("Contents/Info.plist")
        let contents = try String(contentsOf: infoPlist, encoding: .utf8)
        XCTAssertTrue(contents.contains("public.folder"))
    }
}
