import XCTest
import Foundation
import Darwin
@testable import IperfSwift

final class IperfCLIIntegrationTests: XCTestCase {
    func testCLIInteroperabilityRejectsAnUnpinnedIperfVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iperf-swift-version-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("iperf3")
        try "#!/bin/sh\necho 'iperf 3.22 (cJSON 1.7.15)'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(chmod(executable.path, 0o755), 0)

        XCTAssertThrowsError(try TestTools(iperf3Candidates: [executable.path])) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "CLI interoperability requires iperf 3.21, but \(executable.path) reports: iperf 3.22 (cJSON 1.7.15)"
            )
        }
    }

    func testInvalidBindDevicePreservesEngineError() throws {
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.bindDevice = "iperf-invalid-device"
        configuration.port = try TestTools.freePort()

        let failed = expectation(description: "invalid bind device fails")
        let runner = IperfRunner(with: configuration)
        runner.start({ _ in }, { error in
            XCTAssertEqual(error, .IEBINDDEV)
            failed.fulfill()
        }, { _ in })

        wait(for: [failed], timeout: 3)
    }

    func testTimeIntervalErrorsMatchCLIWhereContractsOverlap() throws {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let tools = try TestTools()
        let testCases: [([String], Mutation, IperfError)] = [
            (["--idle-timeout", "0"], { $0.idleTimeout = 0 }, .IEIDLETIMEOUT),
            (["--interval", "-1"], { $0.reporterInterval = -1 }, .IEINTERVAL),
            (["--interval", "0.099"], { $0.reporterInterval = 0.099 }, .IEINTERVAL),
        ]

        for (arguments, mutate, expectedError) in testCases {
            let cliResult = try tools.run(
                tools.iperf3,
                arguments: ["-c", "127.0.0.1"] + arguments
            )
            XCTAssertNotEqual(cliResult.status, 0)
            XCTAssertTrue(cliResult.output.contains("parameter error"), cliResult.output)

            var configuration = IperfConfiguration()
            configuration.address = "invalid.invalid"
            mutate(&configuration)
            let rejected = expectation(description: "Swift rejects \(arguments.joined(separator: " "))")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            runner.start({ _ in }, { error in
                receivedError = error
                rejected.fulfill()
            }, { _ in })

            wait(for: [rejected], timeout: 2)
            XCTAssertEqual(receivedError, expectedError)
        }
    }

    func testClientIntegerErrorsMatchCLI() throws {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let tools = try TestTools()
        let testCases: [(String, String, Mutation, IperfError)] = [
            ("-P", "129", { $0.numStreams = 129 }, .IENUMSTREAMS),
            ("-w", "536870913", { $0.socketBufferSize = 536_870_913 }, .IEBUFSIZE),
            ("-M", "32768", { $0.mss = 32_768 }, .IEMSS),
            ("-S", "-1", { $0.tos = -1 }, .IEBADTOS),
        ]

        for (option, value, mutate, expectedError) in testCases {
            let cliResult = try tools.run(
                tools.iperf3,
                arguments: ["-c", "127.0.0.1", option, value]
            )
            XCTAssertNotEqual(cliResult.status, 0)
            XCTAssertTrue(cliResult.output.contains("parameter error"), cliResult.output)

            var configuration = IperfConfiguration()
            configuration.address = "invalid.invalid"
            mutate(&configuration)
            let rejected = expectation(description: "Swift rejects \(option) \(value)")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            runner.start({ _ in }, { error in
                receivedError = error
                rejected.fulfill()
            }, { _ in })

            wait(for: [rejected], timeout: 2)
            XCTAssertEqual(receivedError, expectedError)
        }
    }

    func testEncryptedServerPrivateKeyIsRejectedWithoutPrompt() throws {
        let tools = try TestTools()
        let privateKey = try tools.makeEncryptedPrivateKeyBase64()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "invalid.invalid"
        configuration.isAuth = true
        configuration.privateKey = privateKey
        configuration.authorizedUsers = "user,hash\n"

        let rejected = expectation(description: "encrypted private key is rejected")
        let runner = IperfRunner(with: configuration)
        var receivedError: IperfError?
        runner.start({ _ in }, { error in
            receivedError = error
            rejected.fulfill()
        }, { _ in })

        wait(for: [rejected], timeout: 2)
        XCTAssertEqual(receivedError, .IESETSERVERAUTH)
    }

    func testEndConditionErrorsMatchCLI() throws {
        let tools = try TestTools()

        for duration in [0, 1] {
            let cliResult = try tools.run(
                tools.iperf3,
                arguments: [
                    "-c", "127.0.0.1",
                    "--time", String(duration),
                    "--bytes", "1",
                ]
            )
            XCTAssertNotEqual(cliResult.status, 0)
            XCTAssertTrue(
                cliResult.output.contains("only one test end condition"),
                cliResult.output
            )

            var configuration = IperfConfiguration()
            configuration.duration = TimeInterval(duration)
            configuration.numberOfBytes = 1
            let failed = expectation(description: "Swift duration \(duration) conflicts with bytes")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            runner.start({ _ in }, { error in
                receivedError = error
                failed.fulfill()
            }, { _ in })

            wait(for: [failed], timeout: 2)
            XCTAssertEqual(receivedError, .IEENDCONDITIONS)
        }
    }

    func testClientPortErrorsMatchCLI() throws {
        let tools = try TestTools()

        for clientPort in [-1, 0, 65_536] {
            let cliResult = try tools.run(
                tools.iperf3,
                arguments: ["-c", "127.0.0.1", "--cport", String(clientPort)]
            )
            XCTAssertNotEqual(cliResult.status, 0)
            XCTAssertTrue(
                cliResult.output.contains("port number must be between 1 and 65535 inclusive"),
                cliResult.output
            )

            var configuration = IperfConfiguration()
            configuration.clientPort = clientPort
            let failed = expectation(description: "Swift client port \(clientPort) fails")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            runner.start({ _ in }, { error in
                receivedError = error
                failed.fulfill()
            }, { _ in })

            wait(for: [failed], timeout: 2)
            XCTAssertEqual(receivedError, .IEBADPORT)
        }
    }

    func testBlockSizeErrorsMatchCLI() throws {
        let tools = try TestTools()
        let testCases: [(String, IperfProtocol, Int, IperfError, String)] = [
            ("TCP generic maximum", .tcp, 1_048_577, .IEBLOCKSIZE, "block size too large"),
            ("UDP minimum", .udp, 15, .IEUDPBLOCKSIZE, "block size invalid"),
            ("UDP maximum", .udp, 65_508, .IEUDPBLOCKSIZE, "block size invalid"),
            ("UDP generic maximum precedence", .udp, 1_048_577, .IEBLOCKSIZE, "block size too large"),
        ]

        for (name, prot, blockSize, expectedError, expectedCLIMessage) in testCases {
            var arguments = ["-c", "127.0.0.1", "--length", String(blockSize)]
            if prot == .udp {
                arguments.append("--udp")
            }
            let cliResult = try tools.run(tools.iperf3, arguments: arguments)
            XCTAssertNotEqual(cliResult.status, 0, name)
            XCTAssertTrue(cliResult.output.contains(expectedCLIMessage), cliResult.output)

            var configuration = IperfConfiguration()
            configuration.prot = prot
            configuration.blockSize = blockSize
            let failed = expectation(description: "Swift \(name) configuration fails")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            runner.start({ _ in }, { error in
                receivedError = error
                failed.fulfill()
            }, { _ in })

            wait(for: [failed], timeout: 2)
            XCTAssertEqual(receivedError, expectedError, name)
        }
    }

    func testSwiftClientNonPositiveBlockSizeMatchesCLIDefaults() throws {
        let tools = try TestTools()

        func resolvedBlockSize(for prot: IperfProtocol) throws -> Int {
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
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.prot = prot
            configuration.mode = .upload
            configuration.numStreams = 1
            configuration.blockSize = -1
            configuration.getServerOutput = true
            configuration.duration = 1
            configuration.reporterInterval = 0.25

            let finished = expectation(description: "\(prot) client with default block size finishes")
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
            let text = try XCTUnwrap(client.serverOutput)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            let start = try XCTUnwrap(json["start"] as? [String: Any])
            let testStart = try XCTUnwrap(start["test_start"] as? [String: Any])
            return try XCTUnwrap(testStart["blksize"] as? Int)
        }

        XCTAssertEqual(try resolvedBlockSize(for: .tcp), 128 * 1_024)
        XCTAssertTrue((16...65_507).contains(try resolvedBlockSize(for: .udp)))
    }

    func testRoleApplicabilityErrorsMatchCLI() throws {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let tools = try TestTools()
        let testCases: [(String, [String], Mutation, IperfError, String)] = [
            (
                "server-only",
                ["-c", "127.0.0.1", "-1"],
                { $0.oneOff = true },
                .IESERVERONLY,
                "some option you are trying to set is server only"
            ),
            (
                "client-only",
                ["-s", "--parallel", "1"],
                { configuration in
                    configuration.role = .server
                    configuration.numStreams = 1
                },
                .IECLIENTONLY,
                "some option you are trying to set is client only"
            ),
            (
                "receive-timeout range",
                ["-c", "127.0.0.1", "--rcv-timeout", "50"],
                { configuration in
                    configuration.mode = .upload
                    configuration.rcvTimeout = 0.05
                },
                .IERCVTIMEOUT,
                "receive timeout value is incorrect or not in range"
            ),
            (
                "receive-timeout mode",
                ["-c", "127.0.0.1", "--rcv-timeout", "1000"],
                { configuration in
                    configuration.mode = .upload
                    configuration.rcvTimeout = 1
                },
                .IERVRSONLYRCVTIMEOUT,
                "client receive timeout is valid only in receiving mode"
            ),
        ]

        for (name, arguments, mutate, expectedError, expectedCLIMessage) in testCases {
            let cliResult = try tools.run(tools.iperf3, arguments: arguments)
            XCTAssertNotEqual(cliResult.status, 0, name)
            XCTAssertTrue(cliResult.output.contains(expectedCLIMessage), cliResult.output)

            var configuration = IperfConfiguration()
            mutate(&configuration)
            let failed = expectation(description: "Swift \(name) configuration fails")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            var states: [IperfRunnerState] = []
            runner.start({ _ in }, { error in
                receivedError = error
                failed.fulfill()
            }, { state in
                states.append(state)
            })

            wait(for: [failed], timeout: 2)
            XCTAssertEqual(receivedError, expectedError, name)
            XCTAssertEqual(states.last, .error, name)
        }
    }

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
            // The single-connection CLI server needs a moment to return to its
            // accept loop after the previous iteration's run and concurrent
            // stop() spam; without this settle the next connect can race the
            // server's reset and fail with IECONNECT under CI load.
            if iteration > 0 {
                Thread.sleep(forTimeInterval: 0.3)
            }

            var configuration = IperfConfiguration()
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.reverse = .upload
            configuration.numberOfBytes = 1_000_000
            configuration.reporterInterval = 0.1
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
    func testByteCountRunOmitsTheShortEmptyIntervalTheCLIOmits() throws {
        // A run that ends on a byte count stops mid-interval, leaving a very
        // short interval that moved nothing. iperf_print_intermediate declines
        // to report it, and the wrapper must not deliver it either.
        let tools = try TestTools()
        let arguments = ["-R", "-P", "5", "-i", "1", "-n", "200M"]

        let cliPort = try TestTools.freePort()
        let cliServer = Process()
        let cliServerOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(cliPort), "-1"]
        cliServer.standardOutput = cliServerOutput
        cliServer.standardError = cliServerOutput
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let cliResult = try tools.run(
            tools.iperf3,
            arguments: ["-c", "127.0.0.1", "-p", String(cliPort), "-J"] + arguments
        )
        let cliJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(cliResult.output.utf8)
            ) as? [String: Any]
        )
        let cliIntervals = try XCTUnwrap(cliJSON["intervals"] as? [[String: Any]])
        let cliShortEmptyIntervals = cliIntervals.filter { interval in
            guard let sum = interval["sum"] as? [String: Any],
                  let seconds = sum["seconds"] as? Double,
                  let bytes = sum["bytes"] as? Int else {
                return false
            }
            return bytes == 0 && seconds < 0.1
        }
        XCTAssertTrue(cliIntervals.count > 0, "the CLI reported no intervals")
        XCTAssertEqual(
            cliShortEmptyIntervals.count, 0,
            "the CLI reported a short empty interval, so the wrapper has nothing to match"
        )

        let port = try TestTools.freePort()
        let wrapperServer = Process()
        let wrapperServerOutput = Pipe()
        wrapperServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        wrapperServer.arguments = ["-s", "-p", String(port), "-1"]
        wrapperServer.standardOutput = wrapperServerOutput
        wrapperServer.standardError = wrapperServerOutput
        try wrapperServer.run()
        addTeardownBlock {
            if wrapperServer.isRunning {
                wrapperServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.prot = .tcp
        configuration.mode = .download
        configuration.numStreams = 5
        configuration.numberOfBytes = 200 * 1_024 * 1_024
        configuration.reporterInterval = 1

        let finished = expectation(description: "byte-count client finished")
        var didFinish = false
        var delivered: [(duration: TimeInterval, bytes: Int)] = []
        let lock = NSLock()
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                lock.lock()
                delivered.append((result.duration, result.totalBytes))
                lock.unlock()
            },
            { error in
                XCTFail("byte-count client failed: \(error.debugDescription)")
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

        wait(for: [finished], timeout: 30)
        lock.lock()
        let results = delivered
        lock.unlock()

        XCTAssertGreaterThan(results.count, 0, "the wrapper delivered no intervals")
        let shortEmpty = results.filter { $0.bytes == 0 && $0.duration < 0.1 }
        XCTAssertEqual(
            shortEmpty.count, 0,
            "delivered a short empty interval the CLI omits: \(shortEmpty)"
        )
    }

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
            configuration.reporterInterval = 0.1
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

    func testProcessGlobalEngineRunsOneRunnerAtATime() throws {
        let tools = try TestTools()
        let embeddedServerPort = try TestTools.freePort()
        var cliServerPort = try TestTools.freePort()
        while cliServerPort == embeddedServerPort {
            cliServerPort = try TestTools.freePort()
        }

        let cliServer = Process()
        let cliServerOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(cliServerPort), "-1"]
        cliServer.standardOutput = cliServerOutput
        cliServer.standardError = cliServerOutput
        try cliServer.run()
        Thread.sleep(forTimeInterval: 0.3)
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }

        var serverConfiguration = IperfConfiguration()
        serverConfiguration.role = .server
        serverConfiguration.address = "127.0.0.1"
        serverConfiguration.port = embeddedServerPort
        let embeddedServer = IperfRunner(with: serverConfiguration)

        var clientConfiguration = IperfConfiguration()
        clientConfiguration.address = "127.0.0.1"
        clientConfiguration.port = cliServerPort
        clientConfiguration.numberOfBytes = 1_000_000
        clientConfiguration.reporterInterval = 0.1
        let queuedClient = IperfRunner(with: clientConfiguration)

        addTeardownBlock {
            embeddedServer.stop()
            queuedClient.stop()
        }

        let serverRunning = expectation(description: "embedded server running")
        let serverFinished = expectation(description: "embedded server finished")
        embeddedServer.start(
            { _ in },
            { error in
                XCTFail("embedded server failed: \(error.debugDescription)")
                serverFinished.fulfill()
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                } else if state == .finished {
                    serverFinished.fulfill()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let clientInitialising = expectation(description: "second runner queued")
        let prematureClientRunning = expectation(description: "second runner ran concurrently")
        prematureClientRunning.isInverted = true
        let clientEventuallyRunning = expectation(description: "second runner eventually ran")
        let clientFinished = expectation(description: "second runner finished")
        let lock = NSLock()
        var engineReleased = false
        queuedClient.start(
            { _ in },
            { error in
                XCTFail("queued client failed: \(error.debugDescription)")
                clientFinished.fulfill()
            },
            { state in
                if state == .initialising {
                    clientInitialising.fulfill()
                } else if state == .running {
                    lock.lock()
                    let released = engineReleased
                    lock.unlock()
                    (released ? clientEventuallyRunning : prematureClientRunning).fulfill()
                } else if state == .finished {
                    clientFinished.fulfill()
                }
            }
        )

        wait(for: [clientInitialising], timeout: 3)
        wait(for: [prematureClientRunning], timeout: 0.3)
        lock.lock()
        engineReleased = true
        lock.unlock()
        embeddedServer.stop()

        wait(for: [serverFinished, clientEventuallyRunning, clientFinished], timeout: 8)
    }

    func testQueuedRunnerCanBeStoppedBeforeItUsesTheEngine() throws {
        var serverConfiguration = IperfConfiguration()
        serverConfiguration.role = .server
        serverConfiguration.address = "127.0.0.1"
        serverConfiguration.port = try TestTools.freePort()
        let activeServer = IperfRunner(with: serverConfiguration)

        var queuedConfiguration = IperfConfiguration()
        queuedConfiguration.address = "127.0.0.1"
        queuedConfiguration.port = try TestTools.freePort()
        let queuedClient = IperfRunner(with: queuedConfiguration)

        addTeardownBlock {
            activeServer.stop()
            queuedClient.stop()
        }

        let serverRunning = expectation(description: "active server running")
        let serverFinished = expectation(description: "active server finished")
        activeServer.start(
            { _ in },
            { error in
                XCTFail("active server failed: \(error.debugDescription)")
                serverFinished.fulfill()
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                } else if state == .finished {
                    serverFinished.fulfill()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let queuedInitialising = expectation(description: "queued runner initialising")
        let queuedStopping = expectation(description: "queued runner stopping")
        let queuedFinished = expectation(description: "queued runner finished")
        let queuedRunning = expectation(description: "queued runner never running")
        queuedRunning.isInverted = true
        let queuedError = expectation(description: "queued runner has no error")
        queuedError.isInverted = true
        queuedClient.start(
            { _ in },
            { _ in queuedError.fulfill() },
            { state in
                switch state {
                case .initialising:
                    queuedInitialising.fulfill()
                case .running:
                    queuedRunning.fulfill()
                case .stopping:
                    queuedStopping.fulfill()
                case .finished:
                    queuedFinished.fulfill()
                default:
                    break
                }
            }
        )

        wait(for: [queuedInitialising], timeout: 3)
        queuedClient.stop()
        wait(for: [queuedStopping, queuedFinished], timeout: 3)
        wait(for: [queuedRunning, queuedError], timeout: 0.2)

        activeServer.stop()
        wait(for: [serverFinished], timeout: 3)
    }

    func testSerializedFailuresKeepTheirOwnTypedErrors() throws {
        let occupied = try TestTools.boundListener()
        defer { close(occupied.descriptor) }
        let occupiedPort = occupied.port
        var unusedPort = try TestTools.freePort()
        while unusedPort == occupiedPort {
            unusedPort = try TestTools.freePort()
        }

        var serverConfiguration = IperfConfiguration()
        serverConfiguration.role = .server
        serverConfiguration.address = "127.0.0.1"
        serverConfiguration.port = occupiedPort
        let failingServer = IperfRunner(with: serverConfiguration)

        var clientConfiguration = IperfConfiguration()
        clientConfiguration.role = .client
        clientConfiguration.address = "127.0.0.1"
        clientConfiguration.port = unusedPort
        let failingClient = IperfRunner(with: clientConfiguration)

        let serverFailed = expectation(description: "server bind fails")
        let clientFailed = expectation(description: "client connect fails")
        let lock = NSLock()
        var serverError: IperfError?
        var clientError: IperfError?

        DispatchQueue.global().async {
            failingServer.start({ _ in }, { error in
                lock.lock()
                serverError = error
                lock.unlock()
                serverFailed.fulfill()
            }, { _ in })
        }
        DispatchQueue.global().async {
            failingClient.start({ _ in }, { error in
                lock.lock()
                clientError = error
                lock.unlock()
                clientFailed.fulfill()
            }, { _ in })
        }

        wait(for: [serverFailed, clientFailed], timeout: 5)
        lock.lock()
        let capturedServerError = serverError
        let capturedClientError = clientError
        lock.unlock()
        XCTAssertEqual(capturedServerError, .IELISTEN)
        XCTAssertEqual(capturedClientError, .IECONNECT)
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

    func testSwiftServerDoesNotOpenAuthorizedUsersPath() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let authorizedUsersURL = tools.directory.appendingPathComponent("authorized-users.csv")
        try credentials.authorizedUsers.write(
            to: authorizedUsersURL,
            atomically: true,
            encoding: .utf8
        )
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.bindDevice = "lo0"
        configuration.port = port
        configuration.isAuth = true
        configuration.privateKey = credentials.privateKeyBase64
        configuration.authorizedUsers = authorizedUsersURL.path

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "Swift server is running")
        let serverFailed = expectation(description: "Swift server rejects an authorized-users path")
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
            environment: ["IPERF3_PASSWORD": credentials.password]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        wait(for: [serverFailed], timeout: 3)
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
                    // Pins the documented reporter-result semantics: a healthy
                    // interval still reports hasError, because the runner leaves
                    // error at .UNKNOWN rather than .IENONE, and it never
                    // populates runnerState. Failures arrive through the error
                    // callback instead. This is current behavior, not a defect
                    // to "fix" here — changing it means updating the warning in
                    // UsingIperfSwift.md.
                    XCTAssertEqual(result.error, .UNKNOWN)
                    XCTAssertTrue(result.hasError)
                    XCTAssertEqual(result.debugDescription, "OK")
                    XCTAssertEqual(result.runnerState, .unknown)
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
                if result.state == .TEST_RUNNING, result.streams.count == 2 {
                    sawTwoStreams = true
                }
                // Every delivery, not only the running ones. Each carries
                // interval deltas, so summing all of them reconstructs the run
                // totals; dropping the closing summary is what made the byte
                // and packet totals disagree (see #137).
                runningBytes += result.totalBytes
                runningPackets += result.totalPackets
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
        // The run sent whole datagrams of blockSize bytes, so once every
        // delivery is counted the two totals agree exactly — no tolerance, and
        // the size of the sender-thread race does not matter. Divisibility
        // alone would not pin the size: 400-byte datagrams also divide 800.
        XCTAssertEqual(runningBytes, Int(runningPackets) * 800,
                       "every UDP datagram should carry exactly blockSize bytes")
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
        var outputWasReadableAtFinish = false
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
            { [weak client] state in
                if state == .finished && !didFinish {
                    // The runner captures the server text before the run's last
                    // reporter callback, so it is already readable here.
                    outputWasReadableAtFinish = client?.serverOutput != nil
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        XCTAssertTrue(
            outputWasReadableAtFinish,
            "server output must be readable by the time the runner reports finished"
        )
        let text = try XCTUnwrap(client.serverOutput, "server output was never delivered")
        XCTAssertTrue(text.contains("receiver"), text)
    }

    func testSwiftClientBindsRequestedClientPort() throws {
        let tools = try TestTools()
        let protocols: [(String, IperfProtocol)] = [("tcp", .tcp), ("udp", .udp)]

        for (name, prot) in protocols {
            let port = try TestTools.freePort()
            let clientPort = try TestTools.freePort()
            let jsonURL = tools.directory.appendingPathComponent("\(name)-server.json")
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
            configuration.prot = prot
            configuration.mode = .upload
            // Streams bind clientPort, clientPort+1, ... — keep a single stream so
            // only the reserved port is used.
            configuration.numStreams = 1
            configuration.clientPort = clientPort
            configuration.duration = 1
            configuration.reporterInterval = 0.25

            let finished = expectation(description: "\(name) client with fixed local port finished")
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
                           "\(name) server should observe the requested client port")
        }
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

    func testPersistentSwiftServerAcceptsClientAfterIdleRestart() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.oneOff = false
        configuration.idleTimeout = 1

        let running = expectation(description: "persistent server started")
        let prematureTerminal = expectation(description: "persistent server ended before stop")
        prematureTerminal.isInverted = true
        let finished = expectation(description: "persistent server stopped")
        let lock = NSLock()
        var isStopping = false
        var terminalError: IperfError?
        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }
        server.start(
            { _ in },
            { error in
                lock.lock()
                terminalError = error
                let stopping = isStopping
                lock.unlock()
                (stopping ? finished : prematureTerminal).fulfill()
            },
            { state in
                if state == .running {
                    running.fulfill()
                } else if state == .finished {
                    lock.lock()
                    let stopping = isStopping
                    lock.unlock()
                    (stopping ? finished : prematureTerminal).fulfill()
                }
            }
        )

        wait(for: [running], timeout: 3)
        wait(for: [prematureTerminal], timeout: 1.5)

        let clientResult = try tools.run(tools.iperf3, arguments: [
            "-c", "127.0.0.1", "-p", String(port), "-n", "1M"
        ])
        XCTAssertEqual(clientResult.status, 0, clientResult.output)

        lock.lock()
        isStopping = true
        lock.unlock()
        server.stop()
        wait(for: [finished], timeout: 5)
        XCTAssertNil(terminalError)
    }

    func testPersistentSwiftServerAcceptsTwoSequentialClients() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.oneOff = false

        let running = expectation(description: "persistent server started")
        let prematureTerminal = expectation(description: "persistent server ended before stop")
        prematureTerminal.isInverted = true
        let finished = expectation(description: "persistent server stopped")
        let lock = NSLock()
        var isStopping = false
        var terminalError: IperfError?
        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }
        server.start(
            { _ in },
            { error in
                lock.lock()
                terminalError = error
                let stopping = isStopping
                lock.unlock()
                (stopping ? finished : prematureTerminal).fulfill()
            },
            { state in
                if state == .running {
                    running.fulfill()
                } else if state == .finished {
                    lock.lock()
                    let stopping = isStopping
                    lock.unlock()
                    (stopping ? finished : prematureTerminal).fulfill()
                }
            }
        )

        wait(for: [running], timeout: 3)
        Thread.sleep(forTimeInterval: 0.3)

        for clientNumber in 1...2 {
            let result = try tools.run(tools.iperf3, arguments: [
                "-c", "127.0.0.1", "-p", String(port), "-n", "1M"
            ])
            XCTAssertEqual(result.status, 0, "client \(clientNumber): \(result.output)")
            Thread.sleep(forTimeInterval: 0.1)
        }
        wait(for: [prematureTerminal], timeout: 0.1)

        lock.lock()
        isStopping = true
        lock.unlock()
        server.stop()
        wait(for: [finished], timeout: 5)
        XCTAssertNil(terminalError)
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

    func testDefaultStreamCountMatchesTheCLI() throws {
        // The wrapper bypasses argument parsing, so every default it does not
        // restore is a silent divergence. This one measured differently for
        // years because nothing compared the two.
        let tools = try TestTools()

        let cliPort = try TestTools.freePort()
        let cliServer = Process()
        let cliServerOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(cliPort), "-1"]
        cliServer.standardOutput = cliServerOutput
        cliServer.standardError = cliServerOutput
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let cliResult = try tools.run(
            tools.iperf3,
            arguments: ["-c", "127.0.0.1", "-p", String(cliPort), "-t", "1", "-J"]
        )
        let cliJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cliResult.output.utf8)) as? [String: Any]
        )
        let start = try XCTUnwrap(cliJSON["start"] as? [String: Any])
        let cliStreamCount = try XCTUnwrap(start["connected"] as? [Any]).count
        XCTAssertGreaterThan(cliStreamCount, 0, cliResult.output)

        let port = try TestTools.freePort()
        let wrapperServer = Process()
        let wrapperServerOutput = Pipe()
        wrapperServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        wrapperServer.arguments = ["-s", "-p", String(port), "-1"]
        wrapperServer.standardOutput = wrapperServerOutput
        wrapperServer.standardError = wrapperServerOutput
        try wrapperServer.run()
        addTeardownBlock {
            if wrapperServer.isRunning {
                wrapperServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Everything the CLI invocation above also states, and nothing more —
        // the stream count has to come from the default.
        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.duration = 1

        let finished = expectation(description: "default-configuration client finished")
        var didFinish = false
        let lock = NSLock()
        var observedStreamCounts: Set<Int> = []
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                // A one-second run at the default reporting interval delivers
                // its only interval as the closing summary, so do not filter on
                // IperfState/TEST_RUNNING here.
                guard !result.streams.isEmpty else {
                    return
                }
                lock.lock()
                observedStreamCounts.insert(result.streams.count)
                lock.unlock()
            },
            { error in
                XCTFail("default-configuration client failed: \(error.debugDescription)")
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

        wait(for: [finished], timeout: 15)
        lock.lock()
        let streamCounts = observedStreamCounts
        lock.unlock()

        XCTAssertEqual(
            streamCounts,
            [cliStreamCount],
            "the wrapper's default stream count diverges from the CLI's"
        )
    }

    func testDefaultDirectionMatchesTheCLI() throws {
        // iperf_defaults() never assigns reverse, so the engine's default
        // client is a sender. The wrapper defaulted to download for years,
        // which silently measured the opposite direction of `iperf3 -c host`.
        let tools = try TestTools()

        let cliPort = try TestTools.freePort()
        let cliServer = Process()
        let cliServerOutput = Pipe()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(cliPort), "-1"]
        cliServer.standardOutput = cliServerOutput
        cliServer.standardError = cliServerOutput
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let cliResult = try tools.run(
            tools.iperf3,
            arguments: ["-c", "127.0.0.1", "-p", String(cliPort), "-t", "1", "-J"]
        )
        let cliJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cliResult.output.utf8)) as? [String: Any]
        )
        let start = try XCTUnwrap(cliJSON["start"] as? [String: Any])
        let testStart = try XCTUnwrap(start["test_start"] as? [String: Any])
        let cliReverse = try XCTUnwrap(testStart["reverse"] as? Int)

        let port = try TestTools.freePort()
        let wrapperServer = Process()
        let wrapperServerOutput = Pipe()
        wrapperServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        wrapperServer.arguments = ["-s", "-p", String(port), "-1"]
        wrapperServer.standardOutput = wrapperServerOutput
        wrapperServer.standardError = wrapperServerOutput
        try wrapperServer.run()
        addTeardownBlock {
            if wrapperServer.isRunning {
                wrapperServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Everything the CLI invocation above also states, and nothing more —
        // the direction has to come from the default.
        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.duration = 1

        let finished = expectation(description: "default-direction client finished")
        var didFinish = false
        let lock = NSLock()
        var observedReverseFlags: Set<Int32> = []
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                guard !result.streams.isEmpty else {
                    return
                }
                lock.lock()
                // Read back from the engine's own field rather than the Swift
                // configuration, so this pins what actually ran.
                observedReverseFlags.insert(result.reverse)
                lock.unlock()
            },
            { error in
                XCTFail("default-direction client failed: \(error.debugDescription)")
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

        wait(for: [finished], timeout: 15)
        lock.lock()
        let reverseFlags = observedReverseFlags
        lock.unlock()

        XCTAssertEqual(cliReverse, 0, "the CLI's own default is no longer upload")
        XCTAssertEqual(
            reverseFlags,
            [Int32(cliReverse)],
            "the wrapper's default direction diverges from the CLI's"
        )
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
        var outputWasReadableAtFinish = false
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
            { [weak client] state in
                if state == .finished && !didFinish {
                    // The JSON variant is captured on the same path as the text
                    // one, before the run's last reporter callback.
                    outputWasReadableAtFinish = client?.serverOutput != nil
                    didFinish = true
                    finished.fulfill()
                }
            }
        )

        wait(for: [finished], timeout: 8)
        XCTAssertTrue(
            outputWasReadableAtFinish,
            "JSON server output must be readable by the time the runner reports finished"
        )
        let text = try XCTUnwrap(client.serverOutput, "JSON server output was never delivered")
        XCTAssertTrue(text.contains("\"start\""), text)
    }

    func testJSONStreamingPreservesEventsAndAppendsFullOutput() throws {
        // Measured CLI baseline for `--json-stream --json-stream-full-output`:
        // one JSON object per line for the start, interval, and end events,
        // then the complete document pretty-printed across the remaining
        // lines. The wrapper delivers the same sequence through its callback,
        // one value per event and the document as the final value.
        let tools = try TestTools()

        let cliPort = try TestTools.freePort()
        let cliServer = Process()
        cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliServer.arguments = ["-s", "-p", String(cliPort), "-1"]
        cliServer.standardOutput = FileHandle.nullDevice
        cliServer.standardError = FileHandle.nullDevice
        try cliServer.run()
        addTeardownBlock {
            if cliServer.isRunning {
                cliServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let cliResult = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1", "-p", String(cliPort),
                "-P", "1", "-t", "1", "-i", "0.25",
                "--json-stream", "--json-stream-full-output",
            ]
        )
        let (cliEventNames, cliSummary) = try Self.splitJSONStream(cliResult.output)
        XCTAssertEqual(cliEventNames.first, "start", cliResult.output)
        XCTAssertEqual(cliEventNames.last, "end", cliResult.output)
        XCTAssertGreaterThan(cliEventNames.filter { $0 == "interval" }.count, 0)
        let cliIntervals = try XCTUnwrap(cliSummary["intervals"] as? [[String: Any]])
        XCTAssertEqual(
            cliIntervals.count,
            cliEventNames.filter { $0 == "interval" }.count,
            "the CLI's summary should retain one entry per streamed interval"
        )

        let port = try TestTools.freePort()
        let wrapperServer = Process()
        wrapperServer.executableURL = URL(fileURLWithPath: tools.iperf3)
        wrapperServer.arguments = ["-s", "-p", String(port), "-1"]
        wrapperServer.standardOutput = FileHandle.nullDevice
        wrapperServer.standardError = FileHandle.nullDevice
        try wrapperServer.run()
        addTeardownBlock {
            if wrapperServer.isRunning {
                wrapperServer.terminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        var configuration = IperfConfiguration()
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.duration = 1
        configuration.reporterInterval = 0.25
        configuration.jsonStream = true
        configuration.jsonStreamFullOutput = true

        let finished = expectation(description: "JSON streaming client finished")
        var outputs: [String] = []
        var outputWasReadableFromFinalCallback = false
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTFail("JSON streaming client failed: \(error.debugDescription)")
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
            },
            onJSONStream: { [weak client] json in
                outputs.append(json)
                let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                if (object as? [String: Any])?["event"] == nil {
                    outputWasReadableFromFinalCallback = client?.jsonOutput == json
                }
            }
        )

        wait(for: [finished], timeout: 8)

        let objects = try outputs.map {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            )
        }
        let eventNames = objects.compactMap { $0["event"] as? String }
        XCTAssertEqual(eventNames.first, "start")
        XCTAssertEqual(eventNames.last, "end")
        XCTAssertGreaterThan(eventNames.filter { $0 == "interval" }.count, 0)

        let summary = try XCTUnwrap(objects.last)
        XCTAssertNil(summary["event"])
        XCTAssertNotNil(summary["start"])
        XCTAssertNotNil(summary["end"])
        let summaryIntervals = try XCTUnwrap(summary["intervals"] as? [[String: Any]])
        XCTAssertEqual(
            summaryIntervals.count,
            eventNames.filter { $0 == "interval" }.count
        )
        XCTAssertEqual(client.jsonOutput, outputs.last)
        XCTAssertTrue(outputWasReadableFromFinalCallback)

        // The wrapper's sequence matches the CLI's for the same run: the same
        // event names in the same order, and a summary carrying the same keys.
        // Interval counts are left out of the comparison because the two runs
        // are independent and either can land on one interval more.
        XCTAssertEqual(
            Array(NSOrderedSet(array: eventNames)) as? [String],
            Array(NSOrderedSet(array: cliEventNames)) as? [String]
        )
        XCTAssertEqual(eventNames.first, cliEventNames.first)
        XCTAssertEqual(eventNames.last, cliEventNames.last)
        XCTAssertEqual(
            Set(summary.keys), Set(cliSummary.keys),
            "the wrapper's final document should carry the same top-level keys as the CLI's"
        )
    }

    /// Splits `--json-stream` output into its per-line event names and the
    /// complete document that `--json-stream-full-output` pretty-prints after
    /// them.
    private static func splitJSONStream(
        _ output: String
    ) throws -> (eventNames: [String], summary: [String: Any]) {
        var eventNames: [String] = []
        var documentLines: [String] = []

        for line in output.components(separatedBy: "\n") {
            if documentLines.isEmpty {
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   let event = (object as? [String: Any])?["event"] as? String {
                    eventNames.append(event)
                    continue
                }
                // The document begins at the first line the engine indents.
                guard line.trimmingCharacters(in: .whitespaces) == "{" else {
                    continue
                }
            }
            documentLines.append(line)
        }

        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(documentLines.joined(separator: "\n").utf8)
            ) as? [String: Any],
            "could not parse the complete document out of:\n\(output)"
        )
        return (eventNames, summary)
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

    func testPersistentServerKeepsListeningAfterARejectedClient() throws {
        // The engine returns -1 from iperf_run_server for a failed client
        // interaction and -2 only when it cannot listen at all. The CLI's loop
        // reports a -1 and goes back to listening, so a rejected password must
        // not end a persistent server here either.
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.oneOff = false
        configuration.isAuth = true
        configuration.privateKey = credentials.privateKeyBase64
        configuration.authorizedUsers = credentials.authorizedUsers

        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }

        let serverRunning = expectation(description: "persistent authenticated server is running")
        let lock = NSLock()
        var serverError: IperfError?
        var reachedFinished = false
        server.start(
            { _ in },
            { error in
                lock.lock()
                serverError = error
                lock.unlock()
            },
            { state in
                if state == .running {
                    serverRunning.fulfill()
                }
                if state == .finished {
                    lock.lock()
                    reachedFinished = true
                    lock.unlock()
                }
            }
        )
        wait(for: [serverRunning], timeout: 3)

        let rejected = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1", "-p", String(port), "-t", "1",
                "--username", credentials.username,
                "--rsa-public-key-path", credentials.publicKeyURL.path,
            ],
            environment: ["IPERF3_PASSWORD": "wrong-\(credentials.password)"]
        )
        XCTAssertNotEqual(rejected.status, 0, "the CLI client was expected to be rejected")

        // The server must still be serving, and must not have reported the
        // rejection as its own failure.
        let accepted = try tools.run(
            tools.iperf3,
            arguments: [
                "-c", "127.0.0.1", "-p", String(port), "-t", "1",
                "--username", credentials.username,
                "--rsa-public-key-path", credentials.publicKeyURL.path,
            ],
            environment: ["IPERF3_PASSWORD": credentials.password]
        )
        XCTAssertEqual(accepted.status, 0, accepted.output)

        lock.lock()
        let observedError = serverError
        let finished = reachedFinished
        lock.unlock()
        // Both halves of what the CLI does: the rejection is reported, and the
        // server is still there afterwards.
        XCTAssertEqual(observedError, .IEAUTHTEST)
        XCTAssertFalse(finished, "server ended instead of continuing to listen")
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
        // iperf3 accepts one end condition, so leave duration unset. The
        // wrapper then clears the engine's default duration the way the CLI
        // does, and the byte count alone ends the run.
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

    func testByteLimitOutlivesTheDefaultDuration() throws {
        // The CLI clears the duration when --bytes is given without -t
        // (iperf_parse_arguments), so a byte-limited run has no time limit.
        // The wrapper bypasses that parser, and while it did not clear the
        // duration itself the engine kept DURATION and cut every byte-limited
        // run off at 10 seconds.
        //
        // Catching that requires a transfer that must take longer than
        // DURATION, so this test paces itself past the threshold rather than
        // racing over loopback. Verified against the CLI first:
        // `iperf3 -c 127.0.0.1 -n 8M -b 4M` runs ~17s and transfers all 8 MB.
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

        // 6 MB at 4 Mbit/s is roughly 12 seconds — past DURATION's 10, and
        // short enough to keep the suite moving.
        let byteCap: UInt64 = 6_000_000
        var configuration = IperfConfiguration()
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.numberOfBytes = byteCap
        configuration.rate = 4_000_000
        configuration.reporterInterval = 1

        let finished = expectation(description: "paced byte-limited client finished")
        var didFinish = false
        var totalBytes = 0
        let started = Date()
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
                XCTFail("paced byte-limited client failed: \(error.debugDescription)")
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

        wait(for: [finished], timeout: 40)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(
            totalBytes, Int(byteCap),
            "the byte target was cut short — the engine's default duration is still ending the run"
        )
        XCTAssertGreaterThan(
            elapsed, 11,
            "the run ended near DURATION, so the byte count was not the only end condition"
        )
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

    func testSwiftClientRunsDownloadMode() throws {
        // Upload and bidirectional modes have interop coverage, but a pure
        // reverse/download client (server sends, client receives) does not.
        // The client is the receiver, so its streams must report the download
        // direction and the download aggregate must accumulate bytes.
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
        configuration.mode = .download
        configuration.numStreams = 1
        configuration.duration = 1
        configuration.reporterInterval = 0.25

        let reportedDownload = expectation(description: "download direction is reported")
        let finished = expectation(description: "download client finished")
        var didReportDownload = false
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if !didReportDownload,
                   result.state == .TEST_RUNNING,
                   result.mode == .download,
                   result.download.totalBytes > 0,
                   !result.streams.isEmpty,
                   result.streams.allSatisfy({ $0.direction == .download }) {
                    didReportDownload = true
                    reportedDownload.fulfill()
                }
            },
            { error in
                XCTFail("download client failed: \(error.debugDescription)")
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

        wait(for: [reportedDownload, finished], timeout: 8)
    }

    func testSwiftClientWritesLogfile() throws {
        // The logfile option redirects the engine's output to a file. libiperf
        // opens it on start and closes it when the test is freed, which the
        // wrapper does before reporting .finished, so the file is complete by
        // the time the run settles.
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

        let logfileURL = tools.directory.appendingPathComponent("client-\(port).log")

        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.duration = 1
        configuration.reporterInterval = 0.25
        configuration.logfile = logfileURL.path

        let finished = expectation(description: "logging client finished")
        var didFinish = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { _ in },
            { error in
                XCTFail("logging client failed: \(error.debugDescription)")
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
        let contents = try XCTUnwrap(
            try? String(contentsOf: logfileURL, encoding: .utf8),
            "logfile was never written"
        )
        XCTAssertFalse(contents.isEmpty, "logfile should capture engine output")
        XCTAssertTrue(contents.contains("127.0.0.1"),
                      "logfile should contain the client's connection output: \(contents)")
    }

    func testStoppingRunningServerReachesFinished() throws {
        // stop() on an active server takes a server-specific path that shuts
        // down and closes the listener socket. Assert it reaches .finished
        // without an error, distinct from the one-off server that ends on its
        // own. No CLI is required — the server is pure Swift.
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port

        let running = expectation(description: "server reaches running state")
        let finished = expectation(description: "server finishes after stop()")
        var didStop = false
        var didFinish = false
        var sawStopping = false
        let server = IperfRunner(with: configuration)
        addTeardownBlock {
            server.stop()
        }
        server.start(
            { _ in },
            { error in
                XCTFail("stopped server must not report an error: \(error.debugDescription)")
            },
            { state in
                if state == .running && !didStop {
                    didStop = true
                    running.fulfill()
                }
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
        // Let the listener socket bind before stop() shuts it down.
        Thread.sleep(forTimeInterval: 0.5)
        server.stop()
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(sawStopping, "a stopped server should pass through the .stopping state")
    }

    func testSwiftClientOmitsInitialIntervals() throws {
        // With --omit set, the engine marks the first seconds' interval results
        // as omitted; the wrapper filters omitted streams, so those intervals
        // arrive with no streams. Assert both an omitted (empty) interval and a
        // later measured interval are observed.
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
        configuration.mode = .upload
        configuration.numStreams = 1
        configuration.duration = 2
        configuration.omit = 1
        configuration.reporterInterval = 0.25

        let finished = expectation(description: "omitting client finished")
        var didFinish = false
        var sawOmittedInterval = false
        var sawMeasuredInterval = false
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                if result.state == .TEST_RUNNING {
                    if result.streams.isEmpty {
                        sawOmittedInterval = true
                    } else if result.totalBytes > 0 {
                        sawMeasuredInterval = true
                    }
                }
            },
            { error in
                XCTFail("omitting client failed: \(error.debugDescription)")
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
        XCTAssertTrue(sawMeasuredInterval, "expected measured intervals after the omit period")
        XCTAssertTrue(sawOmittedInterval, "expected omitted intervals during the first second")
    }

    /// A server's current test only ever ends when its client ends it. In
    /// one-off mode the Runner then finishes; a persistent Server instead resets
    /// and returns to listening. `CLIENT_TERMINATE` returns 0 and leaves
    /// `IECLIENTTERM` behind only as a description of the completed test.
    func testServerTreatsATerminatedClientAsACompletedRun() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()

        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.reporterInterval = 0.25
        configuration.oneOff = true

        let lock = NSLock()
        var receivedErrors = [IperfError]()
        var terminalState: IperfRunnerState?
        var intervalCount = 0

        let finished = expectation(description: "the server reaches a terminal state")
        var didFinish = false

        let server = IperfRunner(with: configuration)
        addTeardownBlock { server.stop() }

        server.start(
            { _ in
                lock.lock()
                intervalCount += 1
                lock.unlock()
            },
            { error in
                lock.lock()
                receivedErrors.append(error)
                lock.unlock()
            },
            { state in
                guard state == .finished || state == .error else { return }
                lock.lock()
                defer { lock.unlock() }
                guard didFinish == false else { return }
                terminalState = state
                didFinish = true
                finished.fulfill()
            }
        )

        Thread.sleep(forTimeInterval: 0.5)

        let cliClient = Process()
        cliClient.executableURL = URL(fileURLWithPath: tools.iperf3)
        cliClient.arguments = [
            "-c", "127.0.0.1", "-p", String(port), "-t", "30", "-i", "0.25",
        ]
        cliClient.standardOutput = FileHandle.nullDevice
        cliClient.standardError = FileHandle.nullDevice
        try cliClient.run()
        addTeardownBlock {
            if cliClient.isRunning {
                cliClient.terminate()
            }
        }

        // Long enough for the transfer to produce intervals, so the assertion
        // below distinguishes a completed run from one that never measured.
        Thread.sleep(forTimeInterval: 1.5)
        cliClient.interrupt()

        wait(for: [finished], timeout: 20)

        lock.lock()
        let errors = receivedErrors
        let state = terminalState
        let intervals = intervalCount
        lock.unlock()

        XCTAssertEqual(state, .finished, "A client going away ends the server's run, it does not fail it")
        XCTAssertEqual(errors, [], "No error describes this outcome; the run produced results")
        XCTAssertGreaterThan(intervals, 0, "The measurements taken before the client left must still reach the consumer")
    }

    /// Every run closes with one delivery carrying `DISPLAY_RESULTS`, holding
    /// the bytes measured since the previous interval. A run reaching its
    /// duration makes it, and so does one that is stopped — the engine gathers
    /// that last measurement either way, so the two differ only in when they
    /// end, not in what the consumer is told.
    func testAStoppedRunDeliversItsClosingIntervalLikeACompletedOne() throws {
        let tools = try TestTools()

        /// The states of the intervals a run delivers, in order.
        func deliveredStates(stoppingAfter stopDelay: TimeInterval?) throws -> [IperfState] {
            let port = try TestTools.freePort()
            let cliServer = Process()
            cliServer.executableURL = URL(fileURLWithPath: tools.iperf3)
            cliServer.arguments = ["-s", "-p", String(port), "-1"]
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
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.numStreams = 1
            configuration.reporterInterval = 0.5
            // Long enough that stopping lands mid-interval, so the closing
            // delivery carries a partial one rather than a whole period.
            configuration.duration = stopDelay == nil ? 2 : 30

            let lock = NSLock()
            var states = [IperfState]()
            let finished = expectation(description: "run reaches a terminal state")
            var didFinish = false

            let client = IperfRunner(with: configuration)
            addTeardownBlock { client.stop() }

            client.start(
                { result in
                    lock.lock()
                    states.append(result.state)
                    lock.unlock()
                },
                { error in
                    XCTFail("Run failed: \(error.debugDescription)")
                },
                { state in
                    guard state == .finished || state == .error else { return }
                    lock.lock()
                    defer { lock.unlock() }
                    guard didFinish == false else { return }
                    didFinish = true
                    finished.fulfill()
                }
            )

            if let stopDelay {
                DispatchQueue.global().asyncAfter(deadline: .now() + stopDelay) {
                    client.stop()
                }
            }

            wait(for: [finished], timeout: 20)
            lock.lock()
            defer { lock.unlock() }
            return states
        }

        let completed = try deliveredStates(stoppingAfter: nil)
        let stopped = try deliveredStates(stoppingAfter: 1.75)

        XCTAssertEqual(
            completed.last, .DISPLAY_RESULTS,
            "A run reaching its duration closes with the engine's final measurement"
        )
        XCTAssertEqual(
            stopped.last, .DISPLAY_RESULTS,
            "A stopped run closes the same way; dropping it loses the bytes measured since the previous interval"
        )
        XCTAssertGreaterThan(
            stopped.count, 1,
            "A stopped run delivers its periodic intervals as well as the closing one"
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

    /// The PEM public key encoded as Base64, the form a Swift client expects in
    /// ``IperfConfiguration/publicKey``.
    func publicKeyBase64() throws -> String {
        try Data(contentsOf: publicKeyURL).base64EncodedString()
    }
}

private final class TestTools {
    let directory: URL
    let iperf3: String
    private let openssl: String?

    init(iperf3Candidates: [String]? = nil) throws {
        self.iperf3 = try IperfCLITestSupport.iperf3(candidates: iperf3Candidates)
        let environment = ProcessInfo.processInfo.environment
        openssl = ([environment["OPENSSL_PATH"]].compactMap { $0 } + [
            "/opt/homebrew/opt/openssl@4/bin/openssl",
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/usr/local/opt/openssl@4/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
        ] + IperfCLITestSupport.executableCandidates(
            named: "openssl",
            overrideVariable: "OPENSSL_PATH"
        )).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iperf-swift-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeCredentials() throws -> Credentials {
        guard let openssl else {
            throw XCTSkip("OpenSSL is not installed")
        }
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

    func makeEncryptedPrivateKeyBase64() throws -> String {
        guard let openssl else {
            throw XCTSkip("OpenSSL is not installed")
        }
        let privateKeyURL = directory.appendingPathComponent("encrypted-private.pem")
        _ = try run(openssl, arguments: [
            "genrsa", "-traditional", "-aes256",
            "-passout", "pass:iperf-test-passphrase",
            "-out", privateKeyURL.path, "2048",
        ])
        return try Data(contentsOf: privateKeyURL).base64EncodedString()
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

    static func boundListener() throws -> (descriptor: Int32, port: Int) {
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
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
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
