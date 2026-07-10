import XCTest
import Darwin
@testable import IperfSwift

final class iperf_swiftTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
//        XCTAssertEqual(iperf_swift().text, "Hello, World!")
    }

    func testServerRejectsUnauthenticatedClientWhenAuthConfigurationIsInvalid() throws {
        let port = try Self.freePort()
        let authorizedUsersURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iperf-authorized-users-\(UUID().uuidString)")
        try "user,passwordHash\n".write(to: authorizedUsersURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: authorizedUsersURL)
        }

        var serverConfiguration = IperfConfiguration()
        serverConfiguration.role = .server
        serverConfiguration.address = "127.0.0.1"
        serverConfiguration.port = port
        serverConfiguration.isAuth = true
        serverConfiguration.privateKey = "invalid-private-key"
        serverConfiguration.authorizedUsers = authorizedUsersURL.path

        let server = IperfRunner(with: serverConfiguration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "server is running")
        let serverRejectedClient = expectation(description: "server rejects unauthenticated client")

        server.start(
            { _ in },
            { _ in
                serverRejectedClient.fulfill()
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                }
            }
        )

        wait(for: [serverRunning], timeout: 2.0)

        var clientConfiguration = IperfConfiguration()
        clientConfiguration.role = .client
        clientConfiguration.address = "127.0.0.1"
        clientConfiguration.port = port
        clientConfiguration.duration = 1
        clientConfiguration.timeout = 1

        let client = IperfRunner(with: clientConfiguration)
        addTeardownBlock {
            client.stop()
        }

        client.start({ _ in }, { _ in }, { _ in })

        wait(for: [serverRejectedClient], timeout: 3.0)
    }

    private static func freePort() throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketDescriptor, 0)
        defer {
            close(socketDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &boundAddressLength)
            }
        }
        XCTAssertEqual(nameResult, 0)

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

//    static var allTests = [
//        ("testExample", testExample),
//    ]
}
