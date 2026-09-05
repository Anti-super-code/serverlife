import XCTest
@testable import ServerlifeCore

final class OriginClassifierTests: XCTestCase {
    func testSystemRootsClassifyAsSystem() {
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/Applications/Xcode.app/Contents"), .system)
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/System/Library/Frameworks"), .system)
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/usr/local/bin"), .system)
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/opt/homebrew/var/postgres"), .system)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "\(home)/Library/Application Support/SomeApp"), .system)
    }

    func testExactRootMatchIsSystem() {
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/Applications"), .system)
    }

    func testOrdinaryProjectFolderIsMine() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "\(home)/dev/my-project"), .mine)
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/Users/someone/Documents/site"), .mine)
    }

    func testNilOrEmptyIsUnknown() {
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: nil), .unknown)
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: ""), .unknown)
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "   "), .unknown)
    }

    func testSimilarButUnrelatedPrefixIsNotCaught() {
        // "/Applications-backup" must not be treated as under "/Applications".
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/Applications-backup/my-project"), .mine)
    }

    // ---- executable-path signal ---------------------------------------------------------

    func testNamedProgramInInstallLocationIsSystemEvenAtRootWorkingDir() {
        // A launchd daemon / .app helper keeps its working directory at "/", which a
        // directory-only check would read as "mine". The executable path is what
        // actually places it.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: "/",
            executablePath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            processName: "ControlCenter"), .system)
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: "/",
            executablePath: "/usr/libexec/rapportd", processName: "rapportd"), .system)
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: nil,
            executablePath: "/Applications/Android Studio.app/Contents/MacOS/studio", processName: "studio"), .system)
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: "/",
            executablePath: "\(home)/Library/Android/sdk/platform-tools/adb", processName: "adb"), .system)
    }

    func testGenericRuntimeIsJudgedByWorkingDirectoryNotItsInterpreterPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // node lives in /opt/homebrew, but that says nothing about the dev server it runs.
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: "\(home)/dev/my-site",
            executablePath: "/opt/homebrew/bin/node", processName: "node"), .mine)
        // ...and the working directory still condemns it when it is itself system.
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: "\(home)/Library/Application Support/Slack",
            executablePath: "/opt/homebrew/bin/node", processName: "node"), .system)
    }

    func testCompiledProjectBinaryIsMine() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(OriginClassifier.classify(
            workingDirectory: "\(home)/code/api",
            executablePath: "\(home)/code/api/target/debug/api", processName: "api"), .mine)
    }

    func testRootWorkingDirectoryWithNoOtherSignalIsUnknown() {
        XCTAssertEqual(OriginClassifier.classify(workingDirectory: "/",
                                                 executablePath: nil, processName: nil), .unknown)
    }
}
