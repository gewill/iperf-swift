import XCTest
import Foundation
import Darwin
@testable import IperfSwift

final class IperfCLIIntegrationTests: XCTestCase {
    func testSwiftServerAcceptsAuthenticatedCLIClient() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.bindDevice = "lo0"
        configuration.port = port
        configuration.isAuth = true
        configuration.privateKey = credentials.privateKeyBase64
        configuration.authorizedUsers = credentials.authorizedUsers

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "Swift server is running")
        server.start(
            { _ in },
            { error in
                XCTFail("Swift server failed: \(error.debugDescription)")
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let result = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1",
                "-p", String(port),
                "-t", "1",
                "--username", credentials.username,
                "--rsa-public-key-path", credentials.publicKeyURL.path,
                "-J"
            ],
            environment: ["IPERF3_PASSWORD": credentials.password]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testSwiftServerAcceptsUDPCLIClient() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.bindDevice = "lo0"
        configuration.port = port

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "Swift UDP server is running")
        server.start(
            { _ in },
            { error in
                XCTFail("Swift UDP server failed: \(error.debugDescription)")
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let result = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1",
                "-p", String(port),
                "-u",
                "-b", "10M",
                "-t", "1",
                "-J"
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("udp"), result.output)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("lost_packets"), result.output)
    }

    func testSwiftClientAppliesDSCPAndReportsMacOSTCPInfo() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let cliServer = Process()
        let serverOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(port), "-1"]
        cliServer.standardOutput = serverOutput
        cliServer.standardError = serverOutput
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.duration = 1
        configuration.reverse = .upload
        configuration.dscp = 46

        let tcpInfoReported = expectation(description: "macOS TCP info is reported")
        let finished = expectation(description: "Swift client finished")
        var didReportTCPInfo = false
        var didFinish = false
        var states: [IperfRunnerState] = []
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if !didReportTCPInfo,
                   result.streams.contains(where: { $0.sndCwnd > 0 && $0.rtt > 0 }) {
                    didReportTCPInfo = true
                    tcpInfoReported.fulfill()
                }
            },
            { error in
                XCTFail("Swift client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                states.append(state)
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 5)
        wait(for: [tcpInfoReported], timeout: 3)
        XCTAssertTrue(states.contains(.initialising), states.debugDescription)
        XCTAssertTrue(states.contains(.running), states.debugDescription)
        XCTAssertTrue(states.contains(.finished), states.debugDescription)
    }

    func testSwiftServerRejectsWrongAuthenticatedCLIClient() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.isAuth = true
        configuration.privateKey = credentials.privateKeyBase64
        configuration.authorizedUsers = credentials.authorizedUsers

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "Swift server is running")
        let serverFailed = expectation(description: "Swift server rejects the client")
        server.start(
            { _ in },
            { error in
                XCTAssertEqual(error, .IEAUTHTEST)
                serverFailed.fulfill()
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let result = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1",
                "-p", String(port),
                "-t", "1",
                "--username", credentials.username,
                "--rsa-public-key-path", credentials.publicKeyURL.path,
                "-J"
            ],
            environment: ["IPERF3_PASSWORD": "wrong-password"]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        wait(for: [serverFailed], timeout: 3)
    }

    func testSwiftServerAcceptsAuthenticatedUDPCLIClient() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.bindDevice = "lo0"
        configuration.port = port
        configuration.isAuth = true
        configuration.privateKey = credentials.privateKeyBase64
        configuration.authorizedUsers = credentials.authorizedUsers

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "Swift authenticated UDP server is running")
        server.start(
            { _ in },
            { error in
                XCTFail("Swift authenticated UDP server failed: (error.debugDescription)")
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let result = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1",
                "-p", String(port),
                "-u",
                "-b", "10M",
                "-t", "1",
                "--username", credentials.username,
                "--rsa-public-key-path", credentials.publicKeyURL.path,
                "-J"
            ],
            environment: ["IPERF3_PASSWORD": credentials.password]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("lost_packets"), result.output)
    }

    func testCLIClientReportsConnectionFailure() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        let result = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1",
                "-p", String(port),
                "-t", "1"
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.localizedCaseInsensitiveContains("connect") ||
            result.output.localizedCaseInsensitiveContains("refused"),
            result.output
        )
    }
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private struct Credentials {
    let username = "iperf-test-user"
    let password = "iperf-test-password"
    let privateKeyBase64: String
    let publicKeyURL: URL
    let authorizedUsers: String
}

private final class TestTools {
    let directory: URL
    let iperf3: String

    init() throws {
        guard let iperf3 = ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("iperf3 is not installed")
        }
        self.iperf3 = iperf3
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iperf-swift-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeCredentials() throws -> Credentials {
        let privateKeyURL = directory.appendingPathComponent("private.pem")
        let publicKeyURL = directory.appendingPathComponent("public.pem")

        _ = try run("/opt/homebrew/bin/openssl", arguments: [
            "genrsa", "-traditional", "-out", privateKeyURL.path, "2048"
        ])
        _ = try run("/opt/homebrew/bin/openssl", arguments: [
            "rsa", "-in", privateKeyURL.path, "-pubout", "-out", publicKeyURL.path
        ])

        let hash = try run("/usr/bin/shasum", arguments: ["-a", "256"],
                           input: "{iperf-test-user}iperf-test-password")
            .output.split(separator: " ").first.map(String.init) ?? ""
        let privateKeyBase64 = try Data(contentsOf: privateKeyURL).base64EncodedString()
        return Credentials(
            privateKeyBase64: privateKeyBase64,
            publicKeyURL: publicKeyURL,
            authorizedUsers: "iperf-test-user,\(hash)\n"
        )
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        input: String? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()

        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output)
    }

    static func freePort() throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketDescriptor, 0)
        defer { close(socketDescriptor) }

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
}
