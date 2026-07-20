import XCTest
import Foundation
import Darwin
@testable import IperfSwift

final class IperfCLIIntegrationTests: XCTestCase {
    func testConcurrentStopDuringFinalNotificationsCompletesSafely() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let cliServer = Process()
        let serverOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(port)]
        cliServer.standardOutput = serverOutput
        cliServer.standardError = serverOutput
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        for iteration in 0..<5 {
            var configuration = IperfConfiguration()
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.reverse = .upload
            configuration.numberOfBytes = 1_000_000
            configuration.reporterInterval = 0.01
            configuration.getServerOutput = true

            let finished = expectation(description: "run \(iteration) reaches final notification")
            finished.assertForOverFulfill = false
            let client = IperfRunner(with: configuration)
            client.start(
                { _ in },
                { error in
                    XCTFail("Swift client failed: \(error.debugDescription)")
                    finished.fulfill()
                },
                { state in
                    if state == .finished {
                        finished.fulfill()
                    }
                }
            )

            wait(for: [finished], timeout: 3)
            DispatchQueue.concurrentPerform(iterations: 20) { _ in
                client.stop()
                _ = client.serverOutput
            }
            XCTAssertNotNil(client.serverOutput)
        }
    }

    // Regression for #16: the reporter callback resolves its owning runner by
    // the test's address, so concurrent independent runners must each receive
    // only their own reporter and server-output callbacks. Each client fixes a
    // distinct source port (`--cport`), which the server names in its output,
    // so a crossed delivery would leave a runner holding another's output —
    // missing its own client port.
    func testIndependentConcurrentRunnersDoNotCrossCallbacks() throws {
        let tools = try TestTools()
        let runnerCount = 3

        var clientPorts: [Int] = []
        var runners: [IperfRunner] = []
        var finishedExpectations: [XCTestExpectation] = []
        let lock = NSLock()
        var reporterCounts = [Int](repeating: 0, count: runnerCount)

        for index in 0..<runnerCount {
            let serverPort = try TestTools.freePort()
            let clientPort = try TestTools.freePort()
            clientPorts.append(clientPort)

            let cliServer = Process()
            let serverPipe = Pipe()
            cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
            cliServer.arguments = ["-s", "-p", String(serverPort), "-1"]
            cliServer.standardOutput = serverPipe
            cliServer.standardError = serverPipe
            try cliServer.run()
            addTeardownBlock {
                if cliServer.isRunning {
                    cliServer.terminate()
                }
            }

            var configuration = IperfConfiguration()
            configuration.address = "127.0.0.1"
            configuration.port = serverPort
            configuration.clientPort = clientPort
            configuration.numStreams = 1
            configuration.numberOfBytes = 2_000_000
            configuration.reporterInterval = 0.05
            configuration.getServerOutput = true

            let finished = expectation(description: "runner \(index) finishes")
            finished.assertForOverFulfill = false
            finishedExpectations.append(finished)

            let runner = IperfRunner(with: configuration)
            runners.append(runner)
            addTeardownBlock {
                runner.stop()
            }
        }

        // Let every one-off server start listening before connecting.
        Thread.sleep(forTimeInterval: 0.3)

        DispatchQueue.concurrentPerform(iterations: runnerCount) { index in
            runners[index].start(
                { _ in
                    lock.lock()
                    reporterCounts[index] += 1
                    lock.unlock()
                },
                { error in
                    XCTFail("runner \(index) failed: \(error.debugDescription)")
                    finishedExpectations[index].fulfill()
                },
                { state in
                    if state == .finished {
                        finishedExpectations[index].fulfill()
                    }
                }
            )
        }

        wait(for: finishedExpectations, timeout: 15)

        for index in 0..<runnerCount {
            let outputDelivered = expectation(
                for: NSPredicate { _, _ in runners[index].serverOutput != nil },
                evaluatedWith: nil
            )
            wait(for: [outputDelivered], timeout: 3)
        }

        var outputs: [String] = []
        for index in 0..<runnerCount {
            let output = try XCTUnwrap(
                runners[index].serverOutput,
                "runner \(index) never received server output"
            )
            outputs.append(output)
            XCTAssertTrue(
                output.contains(String(clientPorts[index])),
                "runner \(index) server output is missing its own client port \(clientPorts[index])"
            )
            XCTAssertGreaterThan(
                reporterCounts[index], 0,
                "runner \(index) received no reporter callbacks"
            )
        }
        XCTAssertEqual(
            Set(outputs).count, runnerCount,
            "concurrent runners received non-distinct server outputs"
        )
    }

    func testConcurrentStartWhileRunningIsIgnored() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let cliServer = Process()
        let serverOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(port)]
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
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.duration = 2
        configuration.reverse = .upload

        let running = expectation(description: "first run reaches running state")
        let finished = expectation(description: "first run finishes")
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }

        var didAttemptSecondStart = false
        client.start(
            { _ in },
            { error in
                XCTFail("first run's client failed: \(error.debugDescription)")
            },
            { state in
                if state == .running && !didAttemptSecondStart {
                    didAttemptSecondStart = true
                    running.fulfill()

                    // A start() issued while a run is active must be a no-op:
                    // none of these callbacks may fire, and the in-flight run
                    // below must be left untouched.
                    client.start(
                        with: configuration,
                        { _ in XCTFail("second start's onReporter must not fire") },
                        { _ in XCTFail("second start's onError must not fire") },
                        { _ in XCTFail("second start's onRunnerState must not fire") }
                    )
                }
                if state == .finished {
                    finished.fulfill()
                }
            }
        )

        wait(for: [running], timeout: 3)
        wait(for: [finished], timeout: 3)
    }

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
        configuration.prot = .udp

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

    func testSwiftServerAcceptsBidirectionalCLIClient() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.reporterInterval = 0.25

        let serverRunning = expectation(description: "Swift server is running")
        let reportedBothDirections = expectation(description: "Swift server reports both directions")
        var didReportBothDirections = false
        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        server.start(
            { result in
                if !didReportBothDirections,
                   result.mode == .bidirectional,
                   result.upload.totalBytes > 0,
                   result.download.totalBytes > 0 {
                    didReportBothDirections = true
                    reportedBothDirections.fulfill()
                }
            },
            { error in
                XCTFail("Swift bidirectional server failed: \(error.debugDescription)")
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
                "--bidir",
                "-P", "1",
                "-t", "1",
                "-i", "0.25",
                "-J"
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        wait(for: [reportedBothDirections], timeout: 3)
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

    func testSwiftClientRunsBidirectionalTCPTest() throws {
        try assertSwiftClientRunsBidirectionalTest(prot: .tcp) { result in
            result.mode == .bidirectional &&
                result.upload.totalBytes > 0 &&
                result.download.totalBytes > 0
        }
    }

    func testSwiftClientRunsBidirectionalUDPTest() throws {
        try assertSwiftClientRunsBidirectionalTest(prot: .udp) { result in
            result.upload.totalBytes > 0 &&
                result.upload.totalPackets > 0 &&
                result.download.totalBytes > 0 &&
                result.download.totalPackets > 0
        }
    }

    private func assertSwiftClientRunsBidirectionalTest(
        prot: IperfProtocol,
        resultMatchesExpectation: @escaping (IperfIntervalResult) -> Bool
    ) throws {
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
        configuration.prot = prot
        configuration.numStreams = 1
        configuration.rate = 2_000_000
        configuration.duration = 1
        configuration.reporterInterval = 0.25
        configuration.mode = .bidirectional

        let reportedBothDirections = expectation(description: "Both \(prot.rawValue) directions are reported")
        let finished = expectation(description: "Swift bidirectional \(prot.rawValue) client finished")
        var didReportBothDirections = false
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }

        client.start(
            { result in
                if !didReportBothDirections,
                   resultMatchesExpectation(result) {
                    didReportBothDirections = true
                    reportedBothDirections.fulfill()
                }
            },
            { error in
                XCTFail("Swift bidirectional \(prot.rawValue) client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [reportedBothDirections, finished], timeout: 5)
    }

    func testSwiftClientAppliesTCPPacingAndSocketOptions() throws {
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
        configuration.prot = .tcp
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.rate = 4_000_000
        configuration.socketBufferSize = 262_144
        configuration.noDelay = true
        configuration.duration = 2
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "Paced Swift TCP client finished")
        var didFinish = false
        var runningBytes = 0
        var runningSeconds: TimeInterval = 0
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    runningBytes += result.totalBytes
                    runningSeconds += result.duration
                }
            },
            { error in
                XCTFail("Paced Swift TCP client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        XCTAssertGreaterThan(runningSeconds, 0)
        let measuredBps = Double(runningBytes) * 8 / runningSeconds
        // An unpaced loopback TCP stream exceeds 1 Gbit/s, so a measurement in
        // the low megabit range proves application pacing is active.
        XCTAssertGreaterThan(measuredBps, 1_000_000, "throughput \(measuredBps) bps")
        XCTAssertLessThan(measuredBps, 16_000_000, "throughput \(measuredBps) bps")
    }

    func testSwiftClientReportsMSSErrorMatchingCLI() throws {
        // macOS rejects TCP_MAXSEG on loopback connections; the official CLI
        // fails with "unable to set TCP/SCTP MSS". The wrapper must surface
        // the same libiperf error, which proves the option reaches the engine.
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
        configuration.prot = .tcp
        configuration.mode = .upload
        configuration.mss = 1_400
        configuration.duration = 1

        let failed = expectation(description: "Swift client reported the MSS error")
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTAssertEqual(error, .IESETMSS)
                failed.fulfill()
            },
            { _ in }
        )

        wait(for: [failed], timeout: 8)
    }

    func testSwiftClientAppliesUDPBlockSizeAndParallelStreams() throws {
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
        configuration.prot = .udp
        configuration.mode = .upload
        configuration.numStreams = 2
        configuration.blockSize = 800
        configuration.rate = 1_000_000
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "Swift UDP multi-stream client finished")
        var didFinish = false
        var sawTwoStreams = false
        var runningBytes = 0
        var runningPackets: Int64 = 0
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    if result.streams.count == 2 {
                        sawTwoStreams = true
                    }
                    runningBytes += result.totalBytes
                    runningPackets += result.totalPackets
                }
            },
            { error in
                XCTFail("Swift UDP multi-stream client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        XCTAssertTrue(sawTwoStreams, "expected an interval reporting two parallel UDP streams")
        XCTAssertGreaterThan(runningPackets, 0)
        // Interval snapshots can race the sender threads by one datagram per
        // stream, so allow that much slack instead of exact byte/packet
        // equality. Divisibility still pins the datagram size to blockSize.
        XCTAssertEqual(runningBytes % 800, 0,
                       "every UDP datagram should carry exactly blockSize bytes")
        XCTAssertLessThanOrEqual(abs(Int(runningPackets) * 800 - runningBytes), 2 * 800,
                                 "bytes \(runningBytes) and packets \(runningPackets) disagree")
    }

    func testSwiftClientRetrievesServerOutput() throws {
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
        configuration.prot = .tcp
        configuration.mode = .upload
        configuration.getServerOutput = true
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "Client requesting server output finished")
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTFail("Swift client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        // The output notification can be queued behind the state change that
        // fulfilled `finished`, so wait on the run loop instead of sleeping.
        let outputDelivered = expectation(
            for: NSPredicate { _, _ in client.serverOutput != nil },
            evaluatedWith: nil
        )
        wait(for: [outputDelivered], timeout: 3)
        let text = try XCTUnwrap(client.serverOutput, "server output was never delivered")
        XCTAssertTrue(text.contains("receiver"), text)
    }

    func testSwiftClientBindsRequestedClientPort() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let clientPort = try TestTools.freePort()
        let jsonURL = tools.directory.appendingPathComponent("server.json")
        FileManager.default.createFile(atPath: jsonURL.path, contents: nil)
        let cliServer = Process()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(port), "-1", "-J"]
        cliServer.standardOutput = try FileHandle(forWritingTo: jsonURL)
        cliServer.standardError = FileHandle.nullDevice
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
        configuration.prot = .tcp
        configuration.mode = .upload
        // Streams bind clientPort, clientPort+1, ... — keep a single stream so
        // only the reserved port is used.
        configuration.numStreams = 1
        configuration.clientPort = clientPort
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "Client with fixed local port finished")
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTFail("Swift client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        cliServer.waitUntilExit()

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: jsonURL)) as? [String: Any]
        let start = json?["start"] as? [String: Any]
        let connected = (start?["connected"] as? [[String: Any]])?.first
        XCTAssertEqual(connected?["remote_port"] as? Int, clientPort,
                       "server should observe the requested client port")
    }

    func testSwiftClientRunsUDPWithCountersRepeatingPayloadAndTOS() throws {
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
        configuration.prot = .udp
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.blockSize = 400
        configuration.udpCounters64Bit = true
        configuration.repeatingPayload = true
        configuration.tos = 32
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "UDP client with extra options finished")
        var didFinish = false
        var runningPackets: Int64 = 0
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    runningPackets += result.totalPackets
                }
            },
            { error in
                XCTFail("UDP client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        XCTAssertGreaterThan(runningPackets, 0,
                             "64-bit counters and repeating payload must interoperate with the CLI")
    }

    func testSwiftServerOneOffFinishesAfterCLIClient() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.oneOff = true
        configuration.idleTimeout = 30
        configuration.rcvTimeout = 10
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "One-off server finished without stop()")
        var didFinish = false
        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }
        server.start(
            { _ in },
            { error in
                XCTFail("One-off server failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )
        Thread.sleep(forTimeInterval: 0.5)

        let clientResult = try tools.run(tools.iperf3, arguments: [
            "-c", "127.0.0.1", "-p", String(port), "-t", "1"
        ])
        XCTAssertEqual(clientResult.status, 0, clientResult.output)

        wait(for: [finished], timeout: 10)
    }

    func testSwiftClientDefaultsUDPToOneMegabitTarget() throws {
        // The CLI applies its 1 Mbit/s UDP default during argument parsing,
        // which the wrapper bypasses, so the wrapper must restore it: an
        // unset rate must not run UDP unlimited.
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
        configuration.prot = .udp
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "Default-rate UDP client finished")
        var didFinish = false
        var runningBytes = 0
        var runningSeconds: TimeInterval = 0
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    runningBytes += result.totalBytes
                    runningSeconds += result.duration
                }
            },
            { error in
                XCTFail("UDP client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        XCTAssertGreaterThan(runningSeconds, 0)
        let measuredBps = Double(runningBytes) * 8 / runningSeconds
        // An unlimited loopback UDP stream reaches gigabits per second; the
        // CLI default paces to about 1 Mbit/s.
        XCTAssertGreaterThan(measuredBps, 250_000, "throughput \(measuredBps) bps")
        XCTAssertLessThan(measuredBps, 4_000_000, "throughput \(measuredBps) bps")
    }

    func testSwiftClientRetrievesServerOutputFromJSONServer() throws {
        // CLI baseline: against `iperf3 -s -J` the server output arrives as
        // JSON (json_server_output), not text, and the CLI prints it as
        // "Server JSON output". The wrapper must capture this variant too.
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let cliServer = Process()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(port), "-1", "-J"]
        cliServer.standardOutput = FileHandle.nullDevice
        cliServer.standardError = FileHandle.nullDevice
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
        configuration.prot = .tcp
        configuration.mode = .upload
        configuration.getServerOutput = true
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "Client against JSON server finished")
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTFail("Swift client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        let outputDelivered = expectation(
            for: NSPredicate { _, _ in client.serverOutput != nil },
            evaluatedWith: nil
        )
        wait(for: [outputDelivered], timeout: 3)
        let text = try XCTUnwrap(client.serverOutput, "JSON server output was never delivered")
        XCTAssertTrue(text.contains("\"start\""), text)
    }

    func testSwiftClientDontFragmentDropsOversizedLoopbackDatagrams() throws {
        // CLI-verified baseline: a 20000-byte UDP payload exceeds the loopback
        // MTU. Without DF it fragments and flows; with DF every send fails and
        // the run completes with zero packets.
        let tools = try TestTools()

        func sentPackets(dontFragment: Bool) throws -> Int64 {
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
            configuration.prot = .udp
            configuration.mode = .upload
            configuration.numStreams = 1
            configuration.blockSize = 20_000
            configuration.dontFragment = dontFragment
            configuration.duration = 1
            configuration.reporterInterval = 0.25

            let finished = expectation(description: "UDP client finished, DF=\(dontFragment)")
            var didFinish = false
            var packets: Int64 = 0
            let client = IperfRunner(with: configuration)
            addTeardownBlock {
                client.stop()
            }
            client.start(
                { result in
                    if result.state == .TEST_RUNNING {
                        packets += result.totalPackets
                    }
                },
                { error in
                    XCTFail("UDP client failed: \(error.debugDescription)")
                    if !didFinish {
                        didFinish = true
                        finished.fulfill()
                    }
                },
                { state in
                    if state == .finished && !didFinish {
                        didFinish = true
                        finished.fulfill()
                    }
                }
            )
            wait(for: [finished], timeout: 8)
            return packets
        }

        XCTAssertGreaterThan(try sentPackets(dontFragment: false), 0,
                             "oversized datagrams should fragment and flow without DF")
        XCTAssertEqual(try sentPackets(dontFragment: true), 0,
                       "oversized datagrams must be dropped when DF is set")
    }

    func testSwiftClientHonorsAddressFamily() throws {
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

        // Forcing IPv4 for an IPv6-only literal must fail to resolve, exactly
        // like `iperf3 -c ::1 -4`.
        var v4Configuration = IperfConfiguration()
        v4Configuration.role = .client
        v4Configuration.address = "::1"
        v4Configuration.port = port
        v4Configuration.prot = .tcp
        v4Configuration.mode = .upload
        v4Configuration.addressFamily = .ipv4
        v4Configuration.duration = 1
        v4Configuration.reporterInterval = 0.25

        let failed = expectation(description: "IPv4-forced client reported a connect error")
        var didFail = false
        let v4Client = IperfRunner(with: v4Configuration)
        addTeardownBlock {
            v4Client.stop()
        }
        v4Client.start(
            { _ in },
            { error in
                if !didFail {
                    didFail = true
                    XCTAssertEqual(error, .IECONNECT)
                    failed.fulfill()
                }
            },
            { _ in }
        )
        wait(for: [failed], timeout: 8)

        // The same endpoint works when IPv6 is requested.
        var v6Configuration = v4Configuration
        v6Configuration.addressFamily = .ipv6

        let finished = expectation(description: "IPv6 client finished")
        var didFinish = false
        var runningBytes = 0
        let v6Client = IperfRunner(with: v6Configuration)
        addTeardownBlock {
            v6Client.stop()
        }
        v6Client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    runningBytes += result.totalBytes
                }
            },
            { error in
                XCTFail("IPv6 client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )
        wait(for: [finished], timeout: 8)
        XCTAssertGreaterThan(runningBytes, 0)
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
        configuration.prot = .udp

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "Swift authenticated UDP server is running")
        server.start(
            { _ in },
            { error in
                XCTFail("Swift authenticated UDP server failed: \(error.debugDescription)")
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

    // MARK: Client-side authentication

    func testSwiftClientAuthenticatesWithCLIServer() throws {
        try assertSwiftClientAuthenticates(usePkcs1Padding: false)
    }

    func testSwiftClientAuthenticatesWithCLIServerUsingPkcs1Padding() throws {
        try assertSwiftClientAuthenticates(usePkcs1Padding: true)
    }

    // Mirror image of testSwiftServerAcceptsAuthenticatedCLIClient: exercise the
    // client-side credential path (iperf_set_test_client_rsa_pubkey / username /
    // password) against the official CLI acting as the authenticating server.
    private func assertSwiftClientAuthenticates(usePkcs1Padding: Bool) throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let port = try TestTools.freePort()
        let server = try tools.startAuthenticatedCLIServer(
            port: port, credentials: credentials, usePkcs1Padding: usePkcs1Padding)
        addTeardownBlock {
            if server.isRunning {
                server.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.duration = 1
        configuration.reporterInterval = 0.25
        configuration.isAuth = true
        configuration.usePkcs1Padding = usePkcs1Padding
        configuration.username = credentials.username
        configuration.password = credentials.password
        configuration.publicKey = try credentials.publicKeyBase64()

        let finished = expectation(description: "authenticated Swift client finished")
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTFail("authenticated Swift client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 10)
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0, "the CLI server should accept the client and exit cleanly")
    }

    func testSwiftClientRejectedByCLIServerWithWrongPassword() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let port = try TestTools.freePort()
        // A long-lived server: it rejects the bad client and keeps listening,
        // so teardown terminates it rather than relying on --one-off exit.
        let server = try tools.startAuthenticatedCLIServer(
            port: port, credentials: credentials, usePkcs1Padding: false, oneOff: false)
        addTeardownBlock {
            if server.isRunning {
                server.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.duration = 1
        configuration.isAuth = true
        configuration.username = credentials.username
        configuration.password = "wrong-password"
        configuration.publicKey = try credentials.publicKeyBase64()

        let failed = expectation(description: "Swift client is rejected")
        var states: [IperfRunnerState] = []
        var receivedError: IperfError?
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                receivedError = error
                failed.fulfill()
            },
            { state in states.append(state) }
        )

        wait(for: [failed], timeout: 10)
        XCTAssertNotEqual(receivedError, .IENONE)
        XCTAssertEqual(states.last, .error)
    }

    // MARK: Lifecycle

    func testStopDuringActiveRunReachesFinishedWithoutError() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let cliServer = Process()
        let serverOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(port)]
        cliServer.standardOutput = serverOutput
        cliServer.standardError = serverOutput
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        // A long run that stop() must cut short well before it would end on
        // its own.
        var configuration = IperfConfiguration()
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.duration = 60
        configuration.reporterInterval = 0.25

        let running = expectation(description: "engine is transferring")
        let finished = expectation(description: "run finishes after stop()")
        var didRequestStop = false
        var didFinish = false
        var sawStopping = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                // Stop only once the engine is genuinely mid-transfer: the
                // .running state fires before iperf_run_client begins, so a
                // stop issued then could be cleared by the engine's own reset.
                if result.state == .TEST_RUNNING && !didRequestStop {
                    didRequestStop = true
                    running.fulfill()
                    client.stop()
                }
            },
            { error in
                XCTFail("stopped run must not report an error: \(error.debugDescription)")
            },
            { state in
                if state == .stopping {
                    sawStopping = true
                }
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [running], timeout: 5)
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(sawStopping, "a stopped run should pass through the .stopping state")
    }

    func testRunnerCanBeReusedAfterFinishing() throws {
        let tools = try TestTools()

        func runOnce(_ client: IperfRunner, label: String) throws {
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
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.mode = .upload
            configuration.duration = 1
            configuration.reporterInterval = 0.25

            let finished = expectation(description: "\(label) finished")
            var didFinish = false
            client.start(
                with: configuration,
                { _ in },
                { error in
                    XCTFail("\(label) failed: \(error.debugDescription)")
                    if !didFinish {
                        didFinish = true
                        finished.fulfill()
                    }
                },
                { state in
                    if state == .finished && !didFinish {
                        didFinish = true
                        finished.fulfill()
                    }
                }
            )
            wait(for: [finished], timeout: 8)
        }

        let client = IperfRunner(with: IperfConfiguration())
        addTeardownBlock {
            client.stop()
        }
        try runOnce(client, label: "first run")
        try runOnce(client, label: "reused run")
    }

    func testRunnerDeallocatesAfterFinishing() throws {
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
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        weak var weakClient: IperfRunner?
        do {
            let client = IperfRunner(with: configuration)
            weakClient = client
            let finished = expectation(description: "run finished before release")
            var didFinish = false
            client.start(
                { _ in },
                { error in
                    XCTFail("run failed: \(error.debugDescription)")
                    if !didFinish {
                        didFinish = true
                        finished.fulfill()
                    }
                },
                { state in
                    if state == .finished && !didFinish {
                        didFinish = true
                        finished.fulfill()
                    }
                }
            )
            wait(for: [finished], timeout: 8)
        }

        // The runner retains itself only for the duration of the async run, so
        // once the run finishes and the last strong reference is dropped it must
        // deallocate — no retain cycle through the callback registry.
        let released = expectation(
            for: NSPredicate { _, _ in weakClient == nil },
            evaluatedWith: nil
        )
        wait(for: [released], timeout: 3)
    }

    // MARK: Additional configuration options

    func testSwiftClientStopsAfterNumberOfBytes() throws {
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

        let byteCap: UInt64 = 5_000_000
        var configuration = IperfConfiguration()
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.numStreams = 1
        // A byte-limited run has no duration; iperf3 accepts only one end
        // condition, so leave duration unset.
        configuration.numberOfBytes = byteCap
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "byte-limited client finished")
        var didFinish = false
        var totalBytes = 0
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    totalBytes += result.totalBytes
                }
            },
            { error in
                XCTFail("byte-limited client failed: \(error.debugDescription)")
                if !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            },
            { state in
                if state == .finished && !didFinish {
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 10)
        // The transfer terminates on the byte count, so it must move at least
        // the requested amount and not run open-endedly toward a time limit.
        XCTAssertGreaterThanOrEqual(totalBytes, Int(byteCap),
                                    "a --bytes run should transmit at least the requested byte count")
    }

    func testSwiftClientWithConnectTimeoutFailsUnreachableHost() throws {
        // Wiring check for --connect-timeout against a documentation-range
        // address (RFC 5737 TEST-NET-1) that does not accept connections. The
        // run must terminate with a terminal error and reach .error instead of
        // hanging. The exact error code depends on how the host's routing
        // rejects the address, so this pins the failure, not a specific code or
        // the precise timeout duration.
        _ = try TestTools()

        var configuration = IperfConfiguration()
        configuration.address = "192.0.2.1"
        configuration.port = 5201
        configuration.mode = .upload
        configuration.duration = 1
        configuration.timeout = 1

        let failed = expectation(description: "unreachable client fails")
        var receivedError: IperfError?
        var states: [IperfRunnerState] = []
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                receivedError = error
                failed.fulfill()
            },
            { state in states.append(state) }
        )

        wait(for: [failed], timeout: 15)
        XCTAssertNotNil(receivedError)
        XCTAssertNotEqual(receivedError, .IENONE)
        XCTAssertEqual(states.last, .error)
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

    /// The PEM public key encoded as Base64, the form a Swift client expects in
    /// ``IperfConfiguration/publicKey``.
    func publicKeyBase64() throws -> String {
        try Data(contentsOf: publicKeyURL).base64EncodedString()
    }
}

private final class TestTools {
    let directory: URL
    let iperf3: String
    let openssl: String

    init() throws {
        guard let iperf3 = ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("iperf3 is not installed")
        }
        self.iperf3 = iperf3
        guard let openssl = [
            "/opt/homebrew/bin/openssl",
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
            "/usr/local/bin/openssl",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("OpenSSL is not installed")
        }
        self.openssl = openssl
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

        _ = try run(openssl, arguments: [
            "genrsa", "-traditional", "-out", privateKeyURL.path, "2048"
        ])
        _ = try run(openssl, arguments: [
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

    /// Starts an official iperf3 server configured to authenticate clients,
    /// writing the private key and authorized-users list into the test's
    /// temporary directory. The returned process is running.
    func startAuthenticatedCLIServer(
        port: Int,
        credentials: Credentials,
        usePkcs1Padding: Bool,
        oneOff: Bool = true
    ) throws -> Process {
        let privateKeyURL = directory.appendingPathComponent("cli-server-\(port).pem")
        guard let privateKeyData = Data(base64Encoded: credentials.privateKeyBase64) else {
            throw XCTSkip("could not decode the generated private key")
        }
        try privateKeyData.write(to: privateKeyURL)
        let authorizedUsersURL = directory.appendingPathComponent("cli-server-\(port)-users.csv")
        try credentials.authorizedUsers.write(to: authorizedUsersURL, atomically: true, encoding: .utf8)

        var arguments = [
            "-s", "-p", String(port),
            "--rsa-private-key-path", privateKeyURL.path,
            "--authorized-users-path", authorizedUsersURL.path,
        ]
        if oneOff {
            arguments.append("-1")
        }
        if usePkcs1Padding {
            arguments.append("--use-pkcs1-padding")
        }

        let server = Process()
        let serverOutput = Pipe()
        server.executableURL = URL(fileURLWithPath: iperf3)
        server.arguments = arguments
        server.standardOutput = serverOutput
        server.standardError = serverOutput
        try server.run()
        return server
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
