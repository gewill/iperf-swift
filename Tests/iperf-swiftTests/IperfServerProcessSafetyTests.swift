#if os(macOS)
import Darwin
import Foundation
import IperfSwift
import XCTest

final class IperfServerProcessSafetyTests: XCTestCase {
    private static let childEnvironmentKey = "IPERF_SWIFT_ONE_OFF_IDLE_TIMEOUT_CHILD"
    private static let completionMarker = "IPERF_SWIFT_ONE_OFF_IDLE_TIMEOUT_COMPLETED"

    func testOneOffIdleTimeoutDoesNotTerminateHostProcess() throws {
        if ProcessInfo.processInfo.environment[Self.childEnvironmentKey] == "1" {
            try runOneOffIdleTimeoutScenario()
            FileHandle.standardOutput.write(Data("\n\(Self.completionMarker)\n".utf8))
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let terminated = expectation(description: "isolated test process terminated")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "iperf_swiftTests.IperfServerProcessSafetyTests/testOneOffIdleTimeoutDoesNotTerminateHostProcess",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            Self.childEnvironmentKey: "1",
        ]) { _, childValue in childValue }
        process.terminationHandler = { _ in
            terminated.fulfill()
        }

        try process.run()
        let waitResult = XCTWaiter.wait(for: [terminated], timeout: 8)
        if waitResult != .completed {
            process.terminate()
            process.waitUntilExit()
            XCTFail("The isolated one-off server did not terminate after its idle timeout")
            return
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(
            output.contains(Self.completionMarker),
            "The embedded server terminated its host process before returning to Swift:\n\(output)"
        )
    }

    private func runOneOffIdleTimeoutScenario() throws {
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = try Self.freePort()
        configuration.oneOff = true
        configuration.idleTimeout = 1

        let terminal = expectation(description: "one-off idle timeout reached a terminal state")
        var terminalError: IperfError?
        var terminalState: IperfRunnerState?
        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }
        server.start(
            { _ in },
            { error in
                terminalError = error
                terminal.fulfill()
            },
            { state in
                if state == .finished {
                    terminalState = state
                    terminal.fulfill()
                }
            }
        )

        wait(for: [terminal], timeout: 5)
        XCTAssertNil(terminalError)
        XCTAssertEqual(terminalState, .finished)
    }

    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
        }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}
#endif
