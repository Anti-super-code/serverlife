import Darwin
import XCTest
@testable import ServerlifeCore

final class PortScannerTests: XCTestCase {
    func testFindsOwnListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        let boundPort = Int(UInt16(bigEndian: boundAddr.sin_port))

        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)
        let listeners = PortScanner.getListeners()
        let match = listeners.first { $0.port == boundPort && $0.pid == ownPid }
        XCTAssertNotNil(match, "expected to find our own bound listener among \(listeners.count) listeners")
        XCTAssertTrue(match?.isLocallyReachable ?? false)
    }

    func testAllPidsIncludesOwnProcess() {
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(PortScanner.allPids().contains(ownPid))
    }
}
