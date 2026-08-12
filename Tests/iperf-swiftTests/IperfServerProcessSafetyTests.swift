#if os(macOS)
import Darwin
import Foundation
import IperfSwift
import XCTest

private func recordSIGPIPE(_: Int32) {}

final class IperfServerProcessSafetyTests: XCTestCase {
    private static let childEnvironmentKey = "IPERF_SWIFT_ONE_OFF_IDLE_TIMEOUT_CHILD"
    private static let completionMarker = "IPERF_SWIFT_ONE_OFF_IDLE_TIMEOUT_COMPLETED"
    private static let listenerReuseChildEnvironmentKey = "IPERF_SWIFT_LISTENER_REUSE_CHILD"
    private static let listenerReuseCompletionMarker = "IPERF_SWIFT_LISTENER_REUSE_COMPLETED"
    private static let sigpipeHandlerChildEnvironmentKey = "IPERF_SWIFT_SIGPIPE_HANDLER_CHILD"
    private static let sigpipeHandlerCompletionMarker = "IPERF_SWIFT_SIGPIPE_HANDLER_COMPLETED"
    private static let abruptDisconnectChildEnvironmentKey = "IPERF_SWIFT_ABRUPT_DISCONNECT_CHILD"
    private static let abruptDisconnectCompletionMarker = "IPERF_SWIFT_ABRUPT_DISCONNECT_COMPLETED"
    private static let abruptClientDisconnectChildEnvironmentKey = "IPERF_SWIFT_ABRUPT_CLIENT_DISCONNECT_CHILD"
    private static let abruptClientDisconnectCompletionMarker = "IPERF_SWIFT_ABRUPT_CLIENT_DISCONNECT_COMPLETED"

    func testRunnerDoesNotReplaceHostSIGPIPEHandler() throws {
        if ProcessInfo.processInfo.environment[Self.sigpipeHandlerChildEnvironmentKey] == "1" {
            try runSIGPIPEHandlerScenario()
            FileHandle.standardOutput.write(Data("\n\(Self.sigpipeHandlerCompletionMarker)\n".utf8))
            return
        }

        try runIsolatedTest(
            named: "testRunnerDoesNotReplaceHostSIGPIPEHandler",
            environmentKey: Self.sigpipeHandlerChildEnvironmentKey,
            completionMarker: Self.sigpipeHandlerCompletionMarker,
            timeout: 5
        )
    }

    func testAbruptServerDisconnectUsesSocketLocalSIGPIPESuppression() throws {
        guard Self.iperf3Path != nil else {
            throw XCTSkip("iperf3 is not installed")
        }
        if ProcessInfo.processInfo.environment[Self.abruptDisconnectChildEnvironmentKey] == "1" {
            try runAbruptServerDisconnectScenario()
            FileHandle.standardOutput.write(Data("\n\(Self.abruptDisconnectCompletionMarker)\n".utf8))
            return
        }

        try runIsolatedTest(
            named: "testAbruptServerDisconnectUsesSocketLocalSIGPIPESuppression",
            environmentKey: Self.abruptDisconnectChildEnvironmentKey,
            completionMarker: Self.abruptDisconnectCompletionMarker,
            timeout: 10
        )
    }

    func testAbruptClientDisconnectUsesSocketLocalSIGPIPESuppression() throws {
        guard Self.iperf3Path != nil else {
            throw XCTSkip("iperf3 is not installed")
        }
        if ProcessInfo.processInfo.environment[Self.abruptClientDisconnectChildEnvironmentKey] == "1" {
            try runAbruptClientDisconnectScenario()
            FileHandle.standardOutput.write(Data("\n\(Self.abruptClientDisconnectCompletionMarker)\n".utf8))
            return
        }

        try runIsolatedTest(
            named: "testAbruptClientDisconnectUsesSocketLocalSIGPIPESuppression",
            environmentKey: Self.abruptClientDisconnectChildEnvironmentKey,
            completionMarker: Self.abruptClientDisconnectCompletionMarker,
            timeout: 10
        )
    }

    func testOneOffIdleTimeoutDoesNotTerminateHostProcess() throws {
        if ProcessInfo.processInfo.environment[Self.childEnvironmentKey] == "1" {
            try runOneOffIdleTimeoutScenario()
            FileHandle.standardOutput.write(Data("\n\(Self.completionMarker)\n".utf8))
            return
        }

        try runIsolatedTest(
            named: "testOneOffIdleTimeoutDoesNotTerminateHostProcess",
            environmentKey: Self.childEnvironmentKey,
            completionMarker: Self.completionMarker,
            timeout: 8
        )
    }

    func testRepeatedStopDoesNotCloseAReusedListenerDescriptor() throws {
        if ProcessInfo.processInfo.environment[Self.listenerReuseChildEnvironmentKey] == "1" {
            try runListenerReuseScenario()
            FileHandle.standardOutput.write(Data("\n\(Self.listenerReuseCompletionMarker)\n".utf8))
            return
        }

        try runIsolatedTest(
            named: "testRepeatedStopDoesNotCloseAReusedListenerDescriptor",
            environmentKey: Self.listenerReuseChildEnvironmentKey,
            completionMarker: Self.listenerReuseCompletionMarker,
            timeout: 8
        )
    }

    func testServerListenFailureLeavesTheOccupiedDescriptorOpen() throws {
        let occupied = try Self.boundListener()
        defer { close(occupied.descriptor) }

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = occupied.port

        let failed = expectation(description: "server listen failed")
        var terminalError: IperfError?
        let server = IperfRunner(with: configuration)
        server.start(
            { _ in },
            { error in
                terminalError = error
                failed.fulfill()
            },
            { _ in }
        )

        wait(for: [failed], timeout: 3)
        XCTAssertEqual(terminalError, .IELISTEN)
        XCTAssertNotEqual(fcntl(occupied.descriptor, F_GETFD), -1)
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

    private func runSIGPIPEHandlerScenario() throws {
        let previousHandler = signal(SIGPIPE, recordSIGPIPE)
        defer { signal(SIGPIPE, previousHandler) }

        var configuration = IperfConfiguration()
        configuration.clientPort = 0

        let failed = expectation(description: "invalid configuration rejected")
        let runner = IperfRunner(with: configuration)
        runner.start({ _ in }, { error in
            XCTAssertEqual(error, .IEBADPORT)
            failed.fulfill()
        }, { _ in })

        wait(for: [failed], timeout: 2)
        let currentHandler = signal(SIGPIPE, recordSIGPIPE)
        XCTAssertEqual(
            unsafeBitCast(currentHandler, to: UInt.self),
            unsafeBitCast(recordSIGPIPE as sig_t, to: UInt.self),
            "IperfRunner replaced the host SIGPIPE handler"
        )
    }

    private func runAbruptServerDisconnectScenario() throws {
        signal(SIGPIPE, SIG_DFL)

        let port = try Self.freePort()
        let server = Process()
        let serverOutput = Pipe()
        server.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.iperf3Path))
        server.arguments = ["-s", "-p", String(port)]
        server.standardOutput = serverOutput
        server.standardError = serverOutput
        try server.run()
        addTeardownBlock {
            if server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
        }
        try Self.waitForListener(boundTo: port, process: server)

        var configuration = IperfConfiguration()
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.duration = 30
        configuration.numStreams = 4
        configuration.reporterInterval = 0.1

        let terminal = expectation(description: "client handled abrupt server disconnect")
        var serverWasKilled = false
        var socketsSuppressSIGPIPE = false
        var reachedTerminalState = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in
                guard !serverWasKilled else {
                    return
                }
                let sockets = Self.connectedTCPSockets(port: port, endpoint: .peer)
                socketsSuppressSIGPIPE = !sockets.isEmpty && sockets.allSatisfy {
                    Self.suppressesSIGPIPE($0)
                }
                serverWasKilled = true
                kill(server.processIdentifier, SIGKILL)
            },
            { _ in
                guard !reachedTerminalState else {
                    return
                }
                reachedTerminalState = true
                terminal.fulfill()
            },
            { state in
                if state == .finished && !reachedTerminalState {
                    reachedTerminalState = true
                    terminal.fulfill()
                }
            }
        )

        wait(for: [terminal], timeout: 6)
        XCTAssertTrue(serverWasKilled, "the client never started transferring data")
        XCTAssertTrue(socketsSuppressSIGPIPE, "a Runner TCP socket did not enable SO_NOSIGPIPE")
        XCTAssertTrue(reachedTerminalState)
    }

    private func runAbruptClientDisconnectScenario() throws {
        signal(SIGPIPE, SIG_DFL)

        let port = try Self.freePort()
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.reporterInterval = 0.1

        let running = expectation(description: "server started")
        let active = expectation(description: "server received client traffic")
        let terminal = expectation(description: "server handled abrupt client disconnect")
        var inspectedSockets = false
        var socketsSuppressSIGPIPE = false
        var reachedTerminalState = false
        let server = IperfRunner(with: configuration)
        let client = Process()
        let clientOutput = Pipe()
        addTeardownBlock {
            server.stop()
            if client.isRunning {
                client.terminate()
                client.waitUntilExit()
            }
        }
        server.start(
            { _ in
                guard !inspectedSockets else {
                    return
                }
                inspectedSockets = true
                let sockets = Self.connectedTCPSockets(port: port, endpoint: .local)
                socketsSuppressSIGPIPE = !sockets.isEmpty && sockets.allSatisfy {
                    Self.suppressesSIGPIPE($0)
                }
                active.fulfill()
            },
            { _ in
                guard !reachedTerminalState else {
                    return
                }
                reachedTerminalState = true
                terminal.fulfill()
            },
            { state in
                switch state {
                case .running:
                    running.fulfill()
                case .finished where !reachedTerminalState:
                    reachedTerminalState = true
                    terminal.fulfill()
                default:
                    break
                }
            }
        )

        wait(for: [running], timeout: 3)
        client.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.iperf3Path))
        client.arguments = ["-c", "127.0.0.1", "-p", String(port), "-t", "30", "-P", "4"]
        client.standardOutput = clientOutput
        client.standardError = clientOutput
        try client.run()

        wait(for: [active], timeout: 5)
        kill(client.processIdentifier, SIGKILL)
        client.waitUntilExit()
        server.stop()
        wait(for: [terminal], timeout: 6)
        XCTAssertTrue(socketsSuppressSIGPIPE, "an accepted Runner TCP socket did not enable SO_NOSIGPIPE")
        XCTAssertTrue(reachedTerminalState)
    }

    private func runListenerReuseScenario() throws {
        var sentinelPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&sentinelPipe) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF)
        }
        let sentinelSource = sentinelPipe[0]
        defer {
            close(sentinelPipe[0])
            close(sentinelPipe[1])
        }

        let port = try Self.freePort()
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.reporterInterval = 0.1

        let running = expectation(description: "server started")
        let active = expectation(description: "server received traffic")
        let sentinelInstalled = expectation(description: "listener descriptor reused")
        let finished = expectation(description: "server stopped")
        var listenerDescriptor: Int32 = -1
        var sawActiveInterval = false
        var stoppingCount = 0
        var terminalError: IperfError?
        let server = IperfRunner(with: configuration)
        let client = Process()
        let clientOutput = Pipe()
        addTeardownBlock {
            server.stop()
            if client.isRunning {
                client.terminate()
                client.waitUntilExit()
            }
            if listenerDescriptor >= 0 {
                close(listenerDescriptor)
            }
        }
        server.start(
            { _ in
                if !sawActiveInterval {
                    sawActiveInterval = true
                    active.fulfill()
                }
            },
            { error in
                terminalError = error
                finished.fulfill()
            },
            { state in
                switch state {
                case .running:
                    running.fulfill()
                case .stopping:
                    stoppingCount += 1
                    guard stoppingCount == 2 else {
                        return
                    }
                    XCTAssertEqual(dup2(sentinelSource, listenerDescriptor), listenerDescriptor)
                    sentinelInstalled.fulfill()
                case .finished:
                    finished.fulfill()
                default:
                    break
                }
            }
        )

        wait(for: [running], timeout: 3)
        listenerDescriptor = try Self.waitForListenerDescriptor(boundTo: port)
        client.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        client.arguments = [
            "iperf3", "-c", "127.0.0.1", "-p", String(port),
            "-t", "30", "-P", "8",
        ]
        client.standardOutput = clientOutput
        client.standardError = clientOutput
        try client.run()
        wait(for: [active], timeout: 5)

        server.stop()
        server.stop()
        wait(for: [sentinelInstalled, finished], timeout: 5)
        if client.isRunning {
            client.terminate()
            client.waitUntilExit()
        }

        XCTAssertNil(terminalError)
        var sourceStatus = stat()
        var reusedStatus = stat()
        XCTAssertEqual(fstat(sentinelSource, &sourceStatus), 0)
        XCTAssertEqual(
            fstat(listenerDescriptor, &reusedStatus),
            0,
            "A later stop or C cleanup closed a descriptor that had reused the listener number"
        )
        XCTAssertEqual(reusedStatus.st_dev, sourceStatus.st_dev)
        XCTAssertEqual(reusedStatus.st_ino, sourceStatus.st_ino)
    }

    private func runIsolatedTest(
        named testName: String,
        environmentKey: String,
        completionMarker: String,
        timeout: TimeInterval
    ) throws {
        let process = Process()
        let outputPipe = Pipe()
        let terminated = expectation(description: "isolated test process terminated")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "iperf_swiftTests.IperfServerProcessSafetyTests/\(testName)",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            environmentKey: "1",
        ]) { _, childValue in childValue }
        process.terminationHandler = { _ in
            terminated.fulfill()
        }

        try process.run()
        let waitResult = XCTWaiter.wait(for: [terminated], timeout: timeout)
        if waitResult != .completed {
            process.terminate()
            process.waitUntilExit()
            XCTFail("The isolated server safety test timed out")
            return
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains(completionMarker), output)
    }

    private static func waitForListenerDescriptor(boundTo port: Int) throws -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let descriptor = listenerDescriptor(boundTo: port) {
                return descriptor
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw POSIXError(.ENOENT)
    }

    private static func waitForListener(boundTo port: Int, process: Process) throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            guard probe >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let bindError = errno
            close(probe)
            if result < 0 && bindError == EADDRINUSE {
                return
            }
            guard process.isRunning else {
                throw POSIXError(.ECONNREFUSED)
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw POSIXError(.ETIMEDOUT)
    }

    private static func listenerDescriptor(boundTo port: Int) -> Int32? {
        let upperBound = min(getdtablesize(), 1_024)
        for descriptor in 0..<upperBound {
            var address = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &addressLength)
                }
            }
            guard result == 0, address.ss_family == sa_family_t(AF_INET) else {
                continue
            }
            let boundPort = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    Int(UInt16(bigEndian: $0.pointee.sin_port))
                }
            }
            if boundPort == port {
                return descriptor
            }
        }
        return nil
    }

    private static func freePort() throws -> Int {
        let listener = try boundListener()
        close(listener.descriptor)
        return listener.port
    }

    private static var iperf3Path: String? {
        ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private enum SocketEndpoint {
        case local
        case peer
    }

    private static func connectedTCPSockets(port: Int, endpoint: SocketEndpoint) -> [Int32] {
        let upperBound = min(getdtablesize(), 1_024)
        return (0..<upperBound).filter { descriptor in
            var socketType: Int32 = 0
            var socketTypeLength = socklen_t(MemoryLayout.size(ofValue: socketType))
            guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &socketType, &socketTypeLength) == 0,
                  socketType == SOCK_STREAM else {
                return false
            }

            guard socketPort(descriptor, endpoint: endpoint) == port else {
                return false
            }
            let oppositeEndpoint: SocketEndpoint
            switch endpoint {
            case .local:
                oppositeEndpoint = .peer
            case .peer:
                oppositeEndpoint = .local
            }
            return socketPort(descriptor, endpoint: oppositeEndpoint) != nil
        }
    }

    private static func socketPort(_ descriptor: Int32, endpoint: SocketEndpoint) -> Int? {
        var address = sockaddr_storage()
        var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                switch endpoint {
                case .local:
                    return getsockname(descriptor, $0, &addressLength)
                case .peer:
                    return getpeername(descriptor, $0, &addressLength)
                }
            }
        }
        return result == 0 ? port(of: address) : nil
    }

    private static func port(of address: sockaddr_storage) -> Int? {
        var address = address
        switch Int32(address.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    Int(UInt16(bigEndian: $0.pointee.sin_port))
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Int(UInt16(bigEndian: $0.pointee.sin6_port))
                }
            }
        default:
            return nil
        }
    }

    private static func suppressesSIGPIPE(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 0
        var enabledLength = socklen_t(MemoryLayout.size(ofValue: enabled))
        return getsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &enabledLength) == 0
            && enabled == 1
    }

    private static func boundListener() throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }

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
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
        }
        guard listen(descriptor, 1) == 0 else {
            close(descriptor)
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
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
        }
        return (descriptor, Int(UInt16(bigEndian: boundAddress.sin_port)))
    }
}
#endif
