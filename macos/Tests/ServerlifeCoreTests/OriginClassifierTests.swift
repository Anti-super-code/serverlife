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
}
