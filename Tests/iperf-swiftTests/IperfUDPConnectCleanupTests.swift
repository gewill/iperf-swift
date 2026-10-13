import Darwin
import Foundation
import IperfCLib
import XCTest

final class IperfUDPConnectCleanupTests: XCTestCase {
    func testInvalidReplyReleasesClientPortBeforeSuccessfulRetry() throws {
        let peer = try boundSocket()
        defer { close(peer.descriptor) }
        let reservation = try boundSocket()
        let clientPort = reservation.port
        close(reservation.descriptor)

        let test = try makeClient(clientPort: clientPort, serverPort: peer.port)
        defer { iperf_free_test(test) }

        for _ in 0..<3 {
            let rejected = replyOnce(on: peer.descriptor, with: 0)
            XCTAssertEqual(iperf_udp_connect(test), -1)
            XCTAssertEqual(iperf_get_error(), Int32(IESTREAMREAD))
            wait(for: [rejected], timeout: 5)
            guard assertPortIsReusable(clientPort) else { return }

            // Success transfers ownership to the caller instead of running cleanup.
            let accepted = replyOnce(on: peer.descriptor, with: UInt32(UDP_CONNECT_REPLY))
            iperf_set_error(Int32(IENONE))
            let connected = iperf_udp_connect(test)
            wait(for: [accepted], timeout: 5)
            XCTAssertGreaterThanOrEqual(connected, 0)
            guard connected >= 0 else { return }
            do {
                defer { close(connected) }
                XCTAssertNotEqual(fcntl(connected, F_GETFD), -1)
                XCTAssertEqual(try localPort(of: connected), clientPort)
            }
            XCTAssertTrue(assertPortIsReusable(clientPort))
        }
    }

    func testReadFailureReleasesClientPortAndPreservesErrors() throws {
        // A closed loopback peer normally causes ECONNREFUSED. The OS may
        // suppress ICMP replies, in which case the unchanged 30-second receive
        // timeout produces EAGAIN/EWOULDBLOCK. Both exercise recv's error path.
        let (serverPort, clientPort) = try unusedPortPair()

        let test = try makeClient(clientPort: clientPort, serverPort: serverPort)
        defer { iperf_free_test(test) }

        iperf_set_error(Int32(IENONE))
        errno = 0
        let result = iperf_udp_connect(test)
        let socketError = errno
        let iperfError = iperf_get_error()
        XCTAssertEqual(result, -1)
        XCTAssertTrue([ECONNREFUSED, EAGAIN, EWOULDBLOCK].contains(socketError),
                      "Unexpected recv errno: \(socketError)")
        XCTAssertEqual(iperfError, Int32(IESTREAMREAD))
        XCTAssertTrue(assertPortIsReusable(clientPort))
    }

    private func makeClient(clientPort: Int32, serverPort: Int32) throws -> UnsafeMutablePointer<iperf_test> {
        let test = try XCTUnwrap(iperf_new_test())
        guard iperf_defaults(test) == 0 else {
            iperf_free_test(test)
            throw NSError(domain: "IperfUDPConnectCleanupTests", code: 1)
        }
        iperf_set_test_role(test, Int8(UInt8(ascii: "c")))
        test.pointee.settings.pointee.domain = AF_INET
        iperf_set_test_server_hostname(test, "127.0.0.1")
        iperf_set_test_bind_address(test, "127.0.0.1")
        iperf_set_test_bind_port(test, clientPort)
        iperf_set_test_server_port(test, serverPort)
        iperf_set_test_blksize(test, 1_400)
        return test
    }

    private func replyOnce(on descriptor: Int32, with reply: UInt32) -> XCTestExpectation {
        let replied = expectation(description: "UDP peer received connect and replied")
        // The socket is already bound. poll bounds a broken fixture without
        // sleeping or probing the one handshake the client expects to consume.
        DispatchQueue.global().async {
            defer { replied.fulfill() }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 3_000) == 1 else {
                XCTFail("UDP peer did not receive a connect datagram")
                return
            }
            var client = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var request: UInt32 = 0
            let received = withUnsafeMutablePointer(to: &client) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &request, MemoryLayout<UInt32>.size, 0, $0, &length)
                }
            }
            XCTAssertEqual(received, MemoryLayout<UInt32>.size)
            XCTAssertEqual(request, UInt32(UDP_CONNECT_MSG))
            guard received == MemoryLayout<UInt32>.size else { return }
            var response = reply
            let sent = withUnsafePointer(to: &client) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, &response, MemoryLayout<UInt32>.size, 0, $0, length)
                }
            }
            XCTAssertEqual(sent, MemoryLayout<UInt32>.size)
        }
        return replied
    }

    @discardableResult
    private func assertPortIsReusable(_ port: Int32, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        do {
            let rebound = try boundSocket(port: port)
            close(rebound.descriptor)
            return true
        } catch {
            XCTFail("failed UDP connect still holds client port \(port): \(error)", file: file, line: line)
            return false
        }
    }

    private func unusedPortPair() throws -> (Int32, Int32) {
        // Hold both reservations until their distinct ephemeral ports are known.
        let server = try boundSocket()
        defer { close(server.descriptor) }
        let client = try boundSocket()
        defer { close(client.descriptor) }
        return (server.port, client.port)
    }

    private func boundSocket(port: Int32 = 0) throws -> (descriptor: Int32, port: Int32) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw posixError() }
            return (descriptor, try localPort(of: descriptor))
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func localPort(of descriptor: Int32) throws -> Int32 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { throw posixError() }
        return Int32(UInt16(bigEndian: address.sin_port))
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
