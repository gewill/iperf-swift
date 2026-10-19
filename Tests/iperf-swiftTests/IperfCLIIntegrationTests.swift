import XCTest
import Foundation
import Darwin
import IperfCLib
@testable import IperfSwift

final class IperfCLIIntegrationTests: XCTestCase {
    func testPersistentServerReportsTheNegotiatedProtocolForEachClient() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.reporterInterval = 0.25

        let lock = NSLock()
        var intervals: [IperfIntervalResult] = []
        let finished = expectation(description: "persistent server stopped")
        let server = IperfRunner(with: configuration)
        addTeardownBlock { server.stop() }
        server.start(
            { interval in
                lock.lock()
                intervals.append(interval)
                lock.unlock()
            },
            { error in XCTFail("server failed: \(error)") },
            { state in
                if state == .finished { finished.fulfill() }
            }
        )

        for prot in [IperfProtocol.udp, .tcp] {
            try waitUntilSwiftServerListens(on: port)
            lock.lock()
            intervals.removeAll()
            lock.unlock()

            var arguments = [
                "-c", "127.0.0.1", "-p", String(port),
                "-t", "1", "-i", "0.25", "-b", "2M", "-J"
            ]
            if prot == .udp { arguments += ["-u", "-l", "1200"] }
            let cli = try tools.run(tools.iperf3, arguments: arguments)
            XCTAssertEqual(cli.status, 0, cli.output)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(cli.output.utf8)) as? [String: Any]
            )

            // The server gathers and reports its closing interval before
            // exchanging results, so the completed CLI has received all of it.
            lock.lock()
            let delivered = intervals.filter { !$0.streams.isEmpty }
            lock.unlock()
            XCTAssertFalse(delivered.isEmpty)
            XCTAssertTrue(delivered.allSatisfy { $0.prot == prot })
            XCTAssertGreaterThan(delivered.reduce(0) { $0 + $1.totalBytes }, 0)
            if prot == .udp {
                let end = try XCTUnwrap(json["end"] as? [String: Any])
                let sum = try XCTUnwrap(end["sum"] as? [String: Any])
                let cliPackets = try XCTUnwrap(sum["packets"] as? Int64)
                let wrapperPackets = delivered.reduce(Int64(0)) { $0 + $1.totalPackets }
                XCTAssertGreaterThan(cliPackets, 0)
                XCTAssertEqual(wrapperPackets, cliPackets)
                for interval in delivered {
                    XCTAssertEqual(interval.upload.totalPackets, interval.totalPackets)
                    XCTAssertEqual(
                        interval.averageJitter,
                        interval.streams.reduce(0) { $0 + $1.jitter } / Double(interval.streams.count)
                    )
                }
            } else {
                XCTAssertTrue(delivered.allSatisfy { $0.totalPackets == 0 && $0.averageJitter == 0 })
            }
        }

        server.stop()
        wait(for: [finished], timeout: 5)
    }

    func testCLIInteroperabilityRejectsAnUnpinnedIperfVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iperf-swift-version-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("iperf3")
        try "#!/bin/sh\necho 'iperf 3.21 (cJSON 1.7.15)'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(chmod(executable.path, 0o755), 0)

        XCTAssertThrowsError(try TestTools(iperf3Candidates: [executable.path])) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "CLI interoperability requires iperf 3.22, but \(executable.path) reports: iperf 3.21 (cJSON 1.7.15)"
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
            cliResult.assertParameterError(expectedError)

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
            ("-P", "0", { $0.numStreams = 0 }, .IENUMSTREAMS),
            ("-w", "-1", { $0.socketBufferSize = -1 }, .IEBUFSIZE),
            ("-M", "-1", { $0.mss = -1 }, .IEMSS),
            ("--dscp", "64", { $0.dscp = 64 }, .IEBADDSCP),
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
            cliResult.assertParameterError(expectedError)

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
            let cliServer = try startCLIServer(tools, ["-1", "-J"])
            let port = cliServer.port

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
        let cliServer = try startCLIServer(tools)
        let port = cliServer.port

        for iteration in 0..<5 {
            // The persistent CLI server closes its listener once the previous
            // iteration's client is gone, then listens again; a connect before
            // that races the server's reset and fails with IECONNECT.
            if iteration > 0 {
                try cliServer.waitUntilListening()
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

        let cliServer = try startCLIServer(tools, ["-1"])
        let cliPort = cliServer.port

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

        let wrapperServer = try startCLIServer(tools, ["-1"])
        let port = wrapperServer.port

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
            let cliServer = try startCLIServer(tools, ["-1"])
            let clientPort = try TestTools.freePort()
            clientPorts.append(clientPort)

            var configuration = IperfConfiguration()
            configuration.address = "127.0.0.1"
            configuration.port = cliServer.port
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
        let cliServer = try startCLIServer(tools, ["-1"])
        let cliServerPort = cliServer.port
        // The CLI server already holds its port, so freePort() cannot return it.
        let embeddedServerPort = try TestTools.freePort()

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
        let cliServer = try startCLIServer(tools)
        let port = cliServer.port

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
        // Only the CLI needs a key file. The Swift server receives PEM text
        // encoded as Base64 and must work after its source file is deleted.
        try FileManager.default.removeItem(at: credentials.privateKeyURL)
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
        try waitUntilSwiftServerListens(on: port)

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
        try waitUntilSwiftServerListens(on: port)

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
        try waitUntilSwiftServerListens(on: port)

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
        try waitUntilSwiftServerListens(on: port)

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        // The run sent whole datagrams of blockSize bytes. Counting every
        // delivery reconstructs the totals for every interval but the last:
        // the sender-thread race attributes a datagram to the packet count
        // before its bytes, and the compensating bytes arrive in the next
        // delivery, which the final interval does not have (see #145).
        //
        // So bound the residue rather than forbidding it. Divisibility alone
        // would not pin the size — 400-byte datagrams also divide 800 — but
        // the pair does: with 400-byte datagrams the shortfall would be
        // packets × 400, orders of magnitude outside this bound.
        XCTAssertEqual(runningBytes % 800, 0,
                       "byte total is not a whole number of blockSize datagrams")
        let shortfall = Int(runningPackets) * 800 - runningBytes
        XCTAssertTrue((0...800).contains(shortfall),
                      "byte and packet totals disagree by more than one datagram: \(shortfall)")
    }

    func testSwiftClientRetrievesServerOutput() throws {
        let tools = try TestTools()
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
            let cliServer = try startCLIServer(tools, ["-1", "-J"])
            let port = cliServer.port
            let clientPort = try TestTools.freePort()

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
            cliServer.process.waitUntilExit()

            let json = try JSONSerialization.jsonObject(
                with: Data(cliServer.standardOutput.utf8)) as? [String: Any]
            let start = json?["start"] as? [String: Any]
            let connected = (start?["connected"] as? [[String: Any]])?.first
            XCTAssertEqual(connected?["remote_port"] as? Int, clientPort,
                           "\(name) server should observe the requested client port")
        }
    }

    func testSwiftClientRunsUDPWithCountersRepeatingPayloadAndTOS() throws {
        let tools = try TestTools()
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        // An idle restart replaces the listener, as the end of a run does.
        try waitUntilSwiftServerListens(on: port)

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

        for clientNumber in 1...2 {
            // The server replaces its listener after each client.
            try waitUntilSwiftServerListens(on: port)
            let result = try tools.run(tools.iperf3, arguments: [
                "-c", "127.0.0.1", "-p", String(port), "-n", "1M"
            ])
            XCTAssertEqual(result.status, 0, "client \(clientNumber): \(result.output)")
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
        try waitUntilSwiftServerListens(on: port)

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

        let cliServer = try startCLIServer(tools, ["-1"])
        let cliPort = cliServer.port

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

        let wrapperServer = try startCLIServer(tools, ["-1"])
        let port = wrapperServer.port

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

    func testStartCLIServerMovesAServerThatLostItsPortToAnother() throws {
        // The tests startCLIServer guards would otherwise go on without a peer
        // and fail later as something else, so its handling needs tests too.
        // The collision reproduced here is server against server: an iperf3
        // server binds the wildcard address, and a second one on the same port
        // exits with "Address already in use".
        let tools = try TestTools()
        let holder = try startCLIServer(tools)
        let fresh = try TestTools.freePort()
        var offered = [holder.port, fresh]

        let server = try startCLIServer(tools, ["-1"], ports: { offered.removeFirst() })

        XCTAssertEqual(server.port, fresh)
        XCTAssertEqual(offered, [], "the held port was never offered")
    }

    func testStartCLIServerReportsAnyOtherFailureAtOnce() throws {
        // Only a lost port is worth another port; any other failure to start
        // is reported with what the server printed.
        let tools = try TestTools()
        var offered = 0
        XCTAssertThrowsError(
            try startCLIServer(tools, ["--no-such-option"], ports: {
                offered += 1
                return try TestTools.freePort()
            })
        ) { error in
            XCTAssertTrue("\(error)".contains("unrecognized option"), "\(error)")
        }
        XCTAssertEqual(offered, 1)
    }

    func testStartCLIServerStopsWaitingForAServerThatNeverListens() throws {
        // The wait is bounded, and its failure carries what the server printed.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iperf-swift-silent-server-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("iperf3")
        try """
            #!/bin/sh
            [ "$1" = --version ] && echo 'iperf 3.22 (cJSON 1.7.15)' && exit 0
            echo 'started, never listening'
            exec sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        let tools = try TestTools(iperf3Candidates: [executable.path])

        let started = Date()
        XCTAssertThrowsError(try startCLIServer(tools, timeout: 0.5)) { error in
            XCTAssertTrue("\(error)".contains("started, never listening"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testFreePortRefusesAPortHeldOnAnotherAddress() throws {
        // A bind to 127.0.0.1 is refused only by sockets on 127.0.0.1 and the
        // wildcard, so each of these holders passes it, and each defeats a
        // test given its port. Measured: an iperf3 server on such a port still
        // starts, but a UDP run against it hangs while a UDP socket holds the
        // port, and so does a client connecting to ::1 while a TCP socket
        // holds it there.
        func bindsLoopbackTCP(_ port: Int) -> Bool {
            guard let descriptor = TestTools.boundSocket(SOCK_STREAM, AF_INET, port: port, loopback: true) else {
                return false
            }
            close(descriptor)
            return true
        }

        let holders: [(name: String, type: Int32, family: Int32)] = [
            ("TCP on ::1", SOCK_STREAM, AF_INET6),
            ("UDP on 127.0.0.1", SOCK_DGRAM, AF_INET),
            ("UDP on ::1", SOCK_DGRAM, AF_INET6),
        ]
        for holder in holders {
            let descriptor = try XCTUnwrap(
                TestTools.boundSocket(holder.type, holder.family, port: 0, loopback: true),
                holder.name
            )
            defer { close(descriptor) }
            let port = try XCTUnwrap(TestTools.boundPort(descriptor), holder.name)
            XCTAssertTrue(bindsLoopbackTCP(port), "\(holder.name) should pass a 127.0.0.1 probe")
            XCTAssertFalse(TestTools.isFree(port: port), "\(holder.name) holds the port")
        }
        XCTAssertTrue(TestTools.isFree(port: try TestTools.freePort()))
    }

    func testDefaultDirectionMatchesTheCLI() throws {
        // iperf_defaults() never assigns reverse, so the engine's default
        // client is a sender. The wrapper defaulted to download for years,
        // which silently measured the opposite direction of `iperf3 -c host`.
        let tools = try TestTools()

        let cliServer = try startCLIServer(tools, ["-1"])
        let cliPort = cliServer.port

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

        let wrapperServer = try startCLIServer(tools, ["-1"])
        let port = wrapperServer.port

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
        var observedModes: Set<IperfTestMode> = []
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
                // `mode` is assigned straight from the engine's own reverse and
                // bidirectional flags, so this pins what actually ran rather
                // than what the Swift configuration asked for. Reading
                // `result.reverse` would go one derivation further out, since
                // it is computed from `mode`.
                observedModes.insert(result.mode)
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
        let modes = observedModes
        lock.unlock()

        XCTAssertEqual(cliReverse, 0, "the CLI's own default is no longer upload")
        XCTAssertEqual(
            modes,
            [.upload],
            "the wrapper's default direction diverges from the CLI's"
        )
    }

    func testStreamRunTotalsReportAbsenceWhereTheCLIReportsZeros() throws {
        // The engine accumulates per-stream run totals in one pass guarded by
        // TCP, platform TCP info, and this endpoint being the sender. The CLI
        // prints zeros when that pass never ran — a `-R` client reports
        // mean_rtt 0 — which reads as a measurement. The wrapper reports the
        // absence instead, and this pins both halves against the CLI.
        let tools = try TestTools()

        func cliSenderMeanRTT(flags: [String]) throws -> Int {
            let server = try startCLIServer(tools, ["-1"])
            let port = server.port

            let result = try tools.run(
                tools.iperf3,
                arguments: ["-c", "127.0.0.1", "-p", String(port), "-t", "1", "-J"] + flags
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
                result.output
            )
            let end = try XCTUnwrap(json["end"] as? [String: Any])
            let streams = try XCTUnwrap(end["streams"] as? [[String: Any]])
            let sender = try XCTUnwrap(streams.first?["sender"] as? [String: Any])
            return try XCTUnwrap(sender["mean_rtt"] as? Int)
        }

        // The CLI's own behaviour, which is the reason the wrapper distinguishes
        // these two cases at all.
        XCTAssertGreaterThan(
            try cliSenderMeanRTT(flags: []),
            0,
            "the CLI no longer reports a sender RTT for an upload run"
        )
        XCTAssertEqual(
            try cliSenderMeanRTT(flags: ["-R"]),
            0,
            "the CLI no longer reports zero for a receiving client"
        )

        func wrapperTotals(
            _ mutate: (inout IperfConfiguration) -> Void
        ) throws -> [IperfStreamRunResult] {
            let server = try startCLIServer(tools, ["-1"])
            let port = server.port

            var configuration = IperfConfiguration()
            configuration.role = .client
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.duration = 1
            mutate(&configuration)

            let finished = expectation(description: "run finished")
            var didFinish = false
            let client = IperfRunner(with: configuration)
            addTeardownBlock {
                client.stop()
            }
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
            wait(for: [finished], timeout: 15)
            return client.streamTotals ?? []
        }

        let uploadTotals = try wrapperTotals { $0.mode = .upload }
        let sending = try XCTUnwrap(uploadTotals.first)
        XCTAssertEqual(sending.direction, .upload)
        let totals = try XCTUnwrap(
            sending.tcpSenderTotals,
            "a sending TCP stream should carry run totals"
        )
        XCTAssertGreaterThan(totals.rttSampleCount, 0)
        XCTAssertLessThanOrEqual(totals.minRtt, totals.meanRtt)
        XCTAssertLessThanOrEqual(totals.meanRtt, totals.maxRtt)
        XCTAssertGreaterThan(totals.maxSendCongestionWindow, 0)

        // Where the CLI prints zeros, the wrapper reports nothing at all.
        let downloadTotals = try wrapperTotals { $0.mode = .download }
        let receiving = try XCTUnwrap(downloadTotals.first)
        XCTAssertEqual(receiving.direction, .download)
        XCTAssertNil(
            receiving.tcpSenderTotals,
            "a receiving stream has no sender totals — the CLI's zeros are not measurements"
        )

        let udpTotals = try wrapperTotals {
            $0.mode = .upload
            $0.prot = .udp
            $0.rate = 1_000_000
        }
        XCTAssertNil(
            try XCTUnwrap(udpTotals.first).tcpSenderTotals,
            "UDP carries no TCP sender totals"
        )
    }

    func testEveryDirectionReportsTheCLIsFlagPair() throws {
        // libiperf tracks direction as two flags and refuses the fourth
        // combination — `-R` with `--bidir` fails as IEREVERSEBIDIR — so its
        // reachable states are exactly IperfTestMode's three cases. This pins
        // the whole mapping against the CLI, including that the derived
        // `reverse` flag reproduces the engine's own value. Bidirectional is
        // the case worth having: the engine reports reverse 0 there, the same
        // as an upload, and only `bidir` tells them apart.
        let tools = try TestTools()

        let directions: [(
            name: String,
            flags: [String],
            mode: IperfTestMode,
            reverse: Int,
            bidir: Int
        )] = [
            ("upload", [], .upload, 0, 0),
            ("download", ["-R"], .download, 1, 0),
            ("bidirectional", ["--bidir"], .bidirectional, 0, 1),
        ]

        for direction in directions {
            let cliServer = try startCLIServer(tools, ["-1"])
            let cliPort = cliServer.port

            let cliResult = try tools.run(
                tools.iperf3,
                arguments: ["-c", "127.0.0.1", "-p", String(cliPort), "-t", "1", "-J"]
                    + direction.flags
            )
            let cliJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(cliResult.output.utf8)) as? [String: Any],
                "\(direction.name): \(cliResult.output)"
            )
            let start = try XCTUnwrap(cliJSON["start"] as? [String: Any], direction.name)
            let testStart = try XCTUnwrap(start["test_start"] as? [String: Any], direction.name)
            let cliReverse = try XCTUnwrap(testStart["reverse"] as? Int, direction.name)
            let cliBidir = try XCTUnwrap(testStart["bidir"] as? Int, direction.name)

            // Fail loudly if a future engine changes the pair this mapping
            // rests on, rather than silently comparing against the new one.
            XCTAssertEqual(
                [cliReverse, cliBidir],
                [direction.reverse, direction.bidir],
                "the CLI's flag pair for \(direction.name) is not what this mapping assumes"
            )

            let wrapperServer = try startCLIServer(tools, ["-1"])
            let port = wrapperServer.port

            var configuration = IperfConfiguration()
            configuration.role = .client
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.duration = 1
            configuration.mode = direction.mode

            let finished = expectation(description: "\(direction.name) client finished")
            var didFinish = false
            let lock = NSLock()
            var observedModes: Set<IperfTestMode> = []
            var observedFlags: Set<Int32> = []
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
                    observedModes.insert(result.mode)
                    observedFlags.insert(result.reverse)
                    lock.unlock()
                },
                { error in
                    XCTFail("\(direction.name) client failed: \(error.debugDescription)")
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
            let modes = observedModes
            let flags = observedFlags
            lock.unlock()

            XCTAssertEqual(
                modes,
                [direction.mode],
                "the engine ran a different direction than \(direction.name) configured"
            )
            XCTAssertEqual(
                flags,
                [Int32(cliReverse)],
                "the derived reverse flag does not reproduce the CLI's for \(direction.name)"
            )
        }
    }

    func testSwiftClientDefaultsUDPToOneMegabitTarget() throws {
        // The CLI applies its 1 Mbit/s UDP default during argument parsing,
        // which the wrapper bypasses, so the wrapper must restore it: an
        // unset rate must not run UDP unlimited.
        let tools = try TestTools()
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1", "-J"])
        let port = cliServer.port

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

        let cliServer = try startCLIServer(tools, ["-1"])
        let cliPort = cliServer.port

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

        let wrapperServer = try startCLIServer(tools, ["-1"])
        let port = wrapperServer.port

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
            let cliServer = try startCLIServer(tools, ["-1"])
            let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        try waitUntilSwiftServerListens(on: port)

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
        try waitUntilSwiftServerListens(on: port)

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
        // rejection as its own failure. It replaces its listener after a
        // rejected client as after any other.
        try waitUntilSwiftServerListens(on: port)
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
        try waitUntilSwiftServerListens(on: port)

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

    func testRSAKeyConfigurationRejectsExistingFilePaths() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        let publicKeyBase64 = try credentials.publicKeyBase64()

        for role in [IperfRole.client, .server] {
            let keyURL = role == .client ? credentials.publicKeyURL : credentials.privateKeyURL
            let keyText = role == .client ? publicKeyBase64 : credentials.privateKeyBase64
            XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
            XCTAssertEqual(try Data(contentsOf: keyURL).base64EncodedString(), keyText)

            var configuration = IperfConfiguration()
            configuration.role = role
            configuration.isAuth = true
            if role == .client {
                configuration.username = credentials.username
                configuration.password = credentials.password
                configuration.publicKey = keyText
            } else {
                configuration.privateKey = keyText
                configuration.authorizedUsers = credentials.authorizedUsers
            }
            // Prove these are valid keys before checking that neither a path
            // nor Base64(path) can substitute for Base64(PEM content).
            XCTAssertNil(IperfRunner.authenticationError(for: configuration))
            for path in [keyURL.path, Data(keyURL.path.utf8).base64EncodedString()] {
                let test = try XCTUnwrap(iperf_new_test())
                defer { iperf_free_test(test) }
                XCTAssertEqual(iperf_defaults(test), 0)
                if role == .client {
                    configuration.publicKey = path
                    XCTAssertEqual(IperfRunner.authenticationError(for: configuration), .IESETCLIENTAUTH)
                    iperf_set_test_client_rsa_pubkey(test, path)
                    XCTAssertNil(test.pointee.settings.pointee.client_rsa_pubkey)
                } else {
                    configuration.privateKey = path
                    XCTAssertEqual(IperfRunner.authenticationError(for: configuration), .IESETSERVERAUTH)
                    iperf_set_test_server_rsa_privkey(test, path)
                    XCTAssertNil(test.pointee.server_rsa_private_key)
                }
            }
        }
    }

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
        let publicKeyBase64 = try credentials.publicKeyBase64()
        // The CLI server reads its private-key file; the Swift client must
        // authenticate using only the public-key text, in both padding modes.
        try FileManager.default.removeItem(at: credentials.publicKeyURL)
        let server = try startCLIServer(
            tools,
            tools.authenticatedServerArguments(credentials: credentials, usePkcs1Padding: usePkcs1Padding)
        )
        let port = server.port

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
        configuration.publicKey = publicKeyBase64

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
        server.process.waitUntilExit()
        XCTAssertEqual(
            server.process.terminationStatus, 0,
            "the CLI server should accept the client and exit cleanly"
        )
    }

    func testSwiftClientRejectedByCLIServerWithWrongPassword() throws {
        let tools = try TestTools()
        let credentials = try tools.makeCredentials()
        // A long-lived server: it rejects the bad client and keeps listening,
        // so teardown terminates it rather than relying on --one-off exit.
        let server = try startCLIServer(
            tools,
            tools.authenticatedServerArguments(credentials: credentials, usePkcs1Padding: false, oneOff: false)
        )
        let port = server.port

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
        let cliServer = try startCLIServer(tools)
        let port = cliServer.port

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
            let cliServer = try startCLIServer(tools, ["-1"])
            let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let lock = NSLock()
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                guard result.state == .TEST_RUNNING else {
                    return
                }
                lock.lock()
                totalBytes += result.totalBytes
                lock.unlock()
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
        lock.lock()
        let transferred = totalBytes
        lock.unlock()
        // The transfer terminates on the byte count, so it must move at least
        // the requested amount and not run open-endedly toward a time limit.
        XCTAssertGreaterThanOrEqual(transferred, Int(byteCap),
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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let lock = NSLock()
        let started = Date()
        let client = IperfRunner(with: configuration)
        addTeardownBlock {
            client.stop()
        }
        client.start(
            { result in
                guard result.state == .TEST_RUNNING else {
                    return
                }
                lock.lock()
                totalBytes += result.totalBytes
                lock.unlock()
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
        lock.lock()
        let transferred = totalBytes
        lock.unlock()

        // The wall clock is the signal: a run ended by DURATION stops at ten
        // seconds, and reverting the fix produced exactly that (10.006s).
        XCTAssertGreaterThan(
            elapsed, 11,
            "the run ended near DURATION, so the byte count was not the only end condition"
        )
        // Corroboration, deliberately not an exact match against byteCap.
        // Summing reporter deltas is the only way to obtain a run total today
        // (see #149) and the reconstruction depends on how the engine slices
        // the final intervals, so pin it to the failure mode instead: at this
        // test's 4 Mbit/s pacing a DURATION-capped run moves about 5,000,000
        // bytes in its ten seconds. The pre-fix run reported 4,587,520.
        XCTAssertGreaterThan(
            transferred, 5_000_000,
            "transferred no more than a DURATION-capped run would have"
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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

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
        // Wait for the listener, so that stop() has one to shut down.
        try waitUntilSwiftServerListens(on: port)
        server.stop()
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(sawStopping, "a stopped server should pass through the .stopping state")
    }

    func testSwiftClientOmitsInitialIntervals() throws {
        try assertOmittedIntervals(udpBidirectional: false)
    }

    func testSwiftClientOmitsBidirectionalUDPIntervals() throws {
        try assertOmittedIntervals(udpBidirectional: true)
    }

    private func assertOmittedIntervals(udpBidirectional: Bool) throws {
        // With --omit set, the engine marks the first seconds' interval results
        // as omitted; the wrapper filters omitted streams, so those intervals
        // arrive with no streams. Assert both an omitted (empty) interval and a
        // later measured interval are observed.
        let tools = try TestTools()
        let cliServer = try startCLIServer(tools, ["-1"])
        let port = cliServer.port

        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.prot = udpBidirectional ? .udp : .tcp
        configuration.mode = udpBidirectional ? .bidirectional : .upload
        configuration.numStreams = udpBidirectional ? 2 : 1
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
                        sawMeasuredInterval = sawMeasuredInterval || !udpBidirectional ||
                            (result.upload.totalBytes > 0 && result.download.totalBytes > 0 &&
                             result.upload.totalPackets > 0 && result.download.totalPackets > 0)
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

        try waitUntilSwiftServerListens(on: port)

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
            let cliServer = try startCLIServer(tools, ["-1"])
            let port = cliServer.port

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

private extension XCTestCase {
    /// Starts `iperf3 -s -p <port>` followed by `arguments`, and returns it
    /// once it is listening; teardown terminates it.
    ///
    /// Waiting a fixed interval instead lets a test go on without a peer: the
    /// server may not be listening yet, or may have lost its port, and the run
    /// then fails later as whatever the client makes of an absent server.
    /// ``TestTools/freePort()`` releases its port before the server binds it,
    /// so a server that reports it could not listen is started again on
    /// another port, up to five times. Any other exit, or a server still not
    /// listening after `timeout`, fails with what the server printed.
    func startCLIServer(
        _ tools: TestTools,
        _ arguments: [String] = [],
        timeout: TimeInterval = 10,
        ports: () throws -> Int = TestTools.freePort
    ) throws -> CLIServer {
        var attempt = 1
        while true {
            let server = try CLIServer(tools: tools, port: ports(), arguments: arguments)
            addTeardownBlock { server.terminate() }
            do {
                try server.waitUntilListening(timeout: timeout)
                return server
            } catch let failure as CLIServer.StartupFailure where failure.lostPort && attempt < 5 {
                attempt += 1
            }
        }
    }

    struct SwiftServerNotListening: LocalizedError, CustomStringConvertible {
        let description: String

        var errorDescription: String? { description }
    }

    /// Returns once the Swift server this process runs on `port` holds no TCP
    /// socket there but its listener, the condition
    /// ``CLIServer/waitUntilListening(timeout:)`` waits for in an `iperf3`
    /// server.
    ///
    /// ``IperfRunnerState/running`` is no such signal: the runner reports it
    /// before the engine opens its listener, so a client started then can find
    /// nothing listening. Nor, between a persistent server's runs, is a
    /// listener alone. The engine closes the previous client's control
    /// connection, then that listener, and only then opens a new one; a client
    /// that connects in between is refused, or reset when the old listener
    /// closes.
    func waitUntilSwiftServerListens(on port: Int, timeout: TimeInterval = 10) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            let states = try TestTools.tcpSocketStates(pid: getpid(), port: port)
            if states == ["LISTEN"] {
                return
            }
            guard Date() < deadline else {
                let held = states.isEmpty ? "no TCP socket" : states.joined(separator: ", ")
                throw SwiftServerNotListening(
                    description: "the Swift server on port \(port) was not listening alone after "
                        + "\(timeout)s; this process held \(held) on that port"
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private struct ProcessResult {
    let status: Int32
    let output: String

    /// The CLI prints `parameter error - <iperf_strerror(i_errno)>`, so the
    /// engine's own message identifies which error the argument was rejected
    /// with; matching only the prefix would accept any parameter error.
    func assertParameterError(
        _ error: IperfError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(status, 0, file: file, line: line)
        let message = String(cString: iperf_strerror(error.rawValue))
        XCTAssertTrue(output.contains("parameter error - \(message)"), output, file: file, line: line)
    }
}

private struct Credentials {
    let username = "iperf-test-user"
    let password = "iperf-test-password"
    let privateKeyBase64: String
    let privateKeyURL: URL
    let publicKeyURL: URL
    let authorizedUsers: String

    /// The PEM public key encoded as Base64, the form a Swift client expects in
    /// ``IperfConfiguration/publicKey``.
    func publicKeyBase64() throws -> String {
        try Data(contentsOf: publicKeyURL).base64EncodedString()
    }
}

final class IperfLogLifecycleTests: XCTestCase {
    func testOneOffServerReuseSeparatesCompletionsAndPreservesExistingLog() throws {
        let tools = try TestTools()
        let url = tools.directory.appendingPathComponent("one-off.log")
        let runner = IperfRunner(with: IperfConfiguration())
        addTeardownBlock { runner.stop() }
        var generations: Set<UUID> = []
        var original: Data?
        for prot in [IperfProtocol.tcp, .udp, .tcp] {
            let port = try TestTools.freePort()
            var configuration = IperfConfiguration()
            configuration.role = .server
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.oneOff = true
            configuration.reporterInterval = 0.1
            configuration.logfile = url.path
            configuration.logfileByteLimit = 128
            let released = expectation(description: "one-off resources released")
            var bytes = 0
            var result: IperfRunCompletion?
            runner.start(with: configuration, { bytes += $0.totalBytes },
                         { XCTFail("one-off failed: \($0)") }, { _ in },
                         onResourcesReleased: { completion in
                self.assertClosed(url)
                XCTAssertEqual(try? TestTools.tcpSocketStates(pid: getpid(), port: port), [])
                result = completion
                released.fulfill()
            })
            try waitUntilSwiftServerListens(on: port)
            var arguments = ["-c", "127.0.0.1", "-p", String(port), "-t", "1", "-b", "1M", "-J"]
            if prot == .udp { arguments += ["-u", "-l", "1200"] }
            let cli = try tools.run(tools.iperf3, arguments: arguments)
            XCTAssertEqual(cli.status, 0, cli.output)
            wait(for: [released], timeout: 5)
            XCTAssertGreaterThan(bytes, 0)
            let completion = try XCTUnwrap(result)
            XCTAssertTrue(generations.insert(completion.runID).inserted)
            XCTAssertEqual(completion.logfile?.isTruncated, true)
            let content = try Data(contentsOf: url)
            if let original {
                XCTAssertEqual(content, original)
                XCTAssertEqual(completion.logfile?.bytesWritten, 0)
            } else { original = content }
            XCTAssertLessThanOrEqual(content.count, 128)
        }
    }

    func testQueuedRestartBeforeOldCompletionCannotReplaceGenerationPayload() throws {
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        let port = try TestTools.freePort()
        configuration.port = port
        let blocker = IperfRunner(with: configuration)
        let stopped = expectation(description: "blocking server stopped")
        addTeardownBlock { blocker.stop() }
        blocker.start({ _ in }, { XCTFail("blocker failed: \($0)") }, { _ in },
                      onResourcesReleased: { _ in stopped.fulfill() })
        try waitUntilSwiftServerListens(on: port)
        let runner = IperfRunner(with: IperfConfiguration())
        let queued = expectation(description: "first generation queued")
        let released = expectation(description: "both generations released")
        released.expectedFulfillmentCount = 2
        let lock = NSLock()
        var results: [IperfRunCompletion] = []
        runner.start({ _ in XCTFail("queued run measured") }, { _ in XCTFail("queued run failed") }, { [weak runner] state in
            if state == .initialising { queued.fulfill() }
            if state == .finished {
                var invalid = IperfConfiguration()
                invalid.port = 0
                // Enqueued before the old release notification is delivered.
                runner?.start(with: invalid, { _ in XCTFail("invalid run measured") },
                              { XCTAssertEqual($0, .IEBADPORT) }, { _ in },
                              onResourcesReleased: { result in
                    lock.lock(); results.append(result); lock.unlock()
                    released.fulfill()
                })
            }
        }, onResourcesReleased: { result in
            lock.lock(); results.append(result); lock.unlock()
            released.fulfill()
        })
        wait(for: [queued], timeout: 3)
        runner.stop()
        wait(for: [released], timeout: 3)
        lock.lock(); let captured = results; lock.unlock()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(Set(captured.map(\.runID)).count, 2)
        XCTAssertEqual(runner.completion, captured.last)
        blocker.stop()
        wait(for: [stopped], timeout: 5)
    }

    private func assertClosed(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        // Inspect this process's actual descriptors, including those above 1024.
        // Unlink succeeding alone would not prove the native FILE was closed.
        let required = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        XCTAssertGreaterThan(required, 0, file: file, line: line)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(),
                                        count: Int(required) / MemoryLayout<proc_fdinfo>.stride + 32)
        let size = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
        let used = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, size)
        }
        XCTAssertGreaterThan(used, 0, file: file, line: line)
        XCTAssertLessThan(used, size, "descriptor inventory was truncated", file: file, line: line)
        for descriptor in descriptors.prefix(Int(max(used, 0)) / MemoryLayout<proc_fdinfo>.stride) {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor.proc_fd, F_GETPATH, &path) == 0 {
                XCTAssertNotEqual(String(cString: path), url.resolvingSymlinksInPath().path,
                                  "native logfile descriptor remains open", file: file, line: line)
            }
        }
    }

    func testClientTextAndJSONBudgetsPreserveTCPAndUDPMeasurements() throws {
        let tools = try TestTools()
        for prot in [IperfProtocol.tcp, .udp] {
            for json in [false, true] {
                for limit: UInt64? in [nil, 128] {
                    let port = try startCLIServer(tools, ["-1"]).port
                    let url = tools.directory.appendingPathComponent(UUID().uuidString)
                    var configuration = IperfConfiguration()
                    configuration.address = "127.0.0.1"
                    configuration.port = port
                    configuration.prot = prot
                    configuration.rate = 1_000_000
                    configuration.blockSize = prot == .tcp ? 16_384 : 1_200
                    configuration.duration = 1
                    configuration.reporterInterval = 0.1
                    configuration.logfile = url.path
                    configuration.logfileByteLimit = limit
                    configuration.jsonStream = json
                    configuration.jsonStreamFullOutput = json
                    let runner = IperfRunner(with: configuration)
                    addTeardownBlock { runner.stop() }
                    let released = expectation(description: "client resources released")
                    var samplesAfterTruncation = 0
                    var measured = 0
                    var jsonEvents = 0
                    runner.start({ interval in
                        measured += interval.totalBytes
                        if limit != nil, interval.totalBytes > 0,
                           let text = try? String(contentsOf: url, encoding: .utf8),
                           text.contains("[iperf log truncated]") {
                            samplesAfterTruncation += 1
                        }
                    }, { error in XCTFail("bounded logging broke measurement: \(error)") }, { _ in },
                    onJSONStream: { text in
                        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                        jsonEvents += 1
                    }, onResourcesReleased: { completion in
                        self.assertClosed(url)
                        XCTAssertEqual(runner.completion, completion)
                        if let limit {
                            XCTAssertEqual(completion.logfile?.byteLimit, limit)
                            XCTAssertEqual(completion.logfile?.isTruncated, !json)
                            XCTAssertNil(completion.logfile?.writeError)
                            XCTAssertNil(completion.logfile?.closeError)
                            XCTAssertEqual(completion.logfile?.fileBytes, UInt64((try? Data(contentsOf: url).count) ?? 0))
                        } else {
                            XCTAssertNil(completion.logfile)
                        }
                        released.fulfill()
                    })
                    wait(for: [released], timeout: 8)
                    XCTAssertGreaterThan(measured, 0)
                    XCTAssertEqual(jsonEvents > 0, json)
                    let output = try Data(contentsOf: url)
                    if json {
                        // The existing json_callback route bypasses outfile.
                        // Budgeting the file must not truncate structured callbacks.
                        XCTAssertTrue(output.isEmpty)
                    } else if let limit {
                        XCTAssertLessThanOrEqual(output.count, Int(limit))
                        XCTAssertGreaterThan(samplesAfterTruncation, 1)
                        XCTAssertEqual(String(decoding: output, as: UTF8.self).components(separatedBy: "[iperf log truncated]").count, 2)
                    } else {
                        XCTAssertGreaterThan(output.count, 128)
                    }
                }
            }
        }
    }

    func testOpenFailureDoesNotFailMeasurementAndReportsUnknownFileSize() throws {
        let tools = try TestTools()
        let port = try startCLIServer(tools, ["-1"]).port
        var configuration = IperfConfiguration()
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.duration = 1
        configuration.rate = 1_000_000
        configuration.logfile = tools.directory.appendingPathComponent("missing/log").path
        configuration.logfileByteLimit = 128
        let runner = IperfRunner(with: configuration)
        addTeardownBlock { runner.stop() }
        let released = expectation(description: "measurement survives unavailable logfile")
        var bytes = 0
        runner.start({ bytes += $0.totalBytes }, { XCTFail("measurement failed: \($0)") }, { _ in },
                     onResourcesReleased: { completion in
            XCTAssertEqual(completion.logfile?.openError, ENOENT)
            XCTAssertNil(completion.logfile?.fileBytes)
            XCTAssertEqual(completion.logfile?.bytesWritten, 0)
            released.fulfill()
        })
        wait(for: [released], timeout: 8)
        XCTAssertGreaterThan(bytes, 0)
    }

    func testPersistentServerRetainsOneBudgetAcrossTCPAndUDPClientsThenStops() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        let url = tools.directory.appendingPathComponent("persistent.log")
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        configuration.reporterInterval = 0.1
        configuration.logfile = url.path
        configuration.logfileByteLimit = 128
        let runner = IperfRunner(with: configuration)
        addTeardownBlock { runner.stop() }
        let released = expectation(description: "persistent server releases after stop")
        let lock = NSLock()
        var protocols: Set<IperfProtocol> = []
        runner.start({ interval in
            if interval.totalBytes > 0 {
                lock.lock(); protocols.insert(interval.prot); lock.unlock()
            }
        }, { XCTFail("server failed: \($0)") }, { _ in }, onResourcesReleased: { completion in
            self.assertClosed(url)
            XCTAssertEqual(try? TestTools.tcpSocketStates(pid: getpid(), port: port), [])
            XCTAssertEqual(completion.logfile?.isTruncated, true)
            XCTAssertNil(completion.logfile?.openError)
            released.fulfill()
        })
        for prot in [IperfProtocol.tcp, .udp] {
            // The server replaces its listener after every client.
            try waitUntilSwiftServerListens(on: port)
            var arguments = ["-c", "127.0.0.1", "-p", String(port), "-t", "1", "-b", "1M", "-J"]
            if prot == .udp { arguments += ["-u", "-l", "1200"] }
            let cli = try tools.run(tools.iperf3, arguments: arguments)
            XCTAssertEqual(cli.status, 0, cli.output)
            XCTAssertNil(runner.completion)
        }
        runner.stop(); runner.stop()
        wait(for: [released], timeout: 5)
        lock.lock(); let observed = protocols; lock.unlock()
        XCTAssertEqual(observed, [.tcp, .udp])
        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(output.utf8.count, 128)
        XCTAssertEqual(output.components(separatedBy: "[iperf log truncated]").count, 2)
    }

    func testStoppedClientsAndNativeErrorReleaseLogfile() throws {
        let tools = try TestTools()
        for prot in [IperfProtocol.tcp, .udp] {
            let port = try startCLIServer(tools, ["-1"]).port
            let url = tools.directory.appendingPathComponent(UUID().uuidString)
            var configuration = IperfConfiguration()
            configuration.address = "127.0.0.1"
            configuration.port = port
            configuration.prot = prot
            configuration.duration = 60
            configuration.rate = 1_000_000
            configuration.reporterInterval = 0.1
            configuration.logfile = url.path
            configuration.logfileByteLimit = 128
            let runner = IperfRunner(with: configuration)
            addTeardownBlock { runner.stop() }
            let released = expectation(description: "stopped client releases logfile")
            var samples = 0
            runner.start({ interval in
                if interval.totalBytes > 0 { samples += 1 }
                if samples == 3 { runner.stop(); runner.stop() }
            }, { XCTFail("stopped client failed: \($0)") }, { _ in }, onResourcesReleased: { completion in
                self.assertClosed(url)
                XCTAssertEqual(completion.logfile?.isTruncated, true)
                released.fulfill()
            })
            wait(for: [released], timeout: 8)
            XCTAssertGreaterThanOrEqual(samples, 3)
        }
        var bad = IperfConfiguration()
        bad.role = .server
        bad.bindDevice = "iperf-invalid-device"
        bad.port = try TestTools.freePort()
        let url = tools.directory.appendingPathComponent("error.log")
        bad.logfile = url.path
        bad.logfileByteLimit = 128
        let runner = IperfRunner(with: bad)
        let failed = expectation(description: "native error delivered")
        let released = expectation(description: "native failure released")
        runner.start({ _ in XCTFail("unexpected measurement") }, { error in
            XCTAssertEqual(error, .IEBINDDEV)
            failed.fulfill()
        }, { _ in }, onResourcesReleased: { _ in
            self.assertClosed(url)
            released.fulfill()
        })
        wait(for: [failed, released], timeout: 5, enforceOrder: true)
    }

    func testQueuedCancelIgnoredStartAndQueuedDeallocationCompleteOnce() throws {
        let tools = try TestTools()
        let port = try TestTools.freePort()
        var configuration = IperfConfiguration()
        configuration.role = .server
        configuration.address = "127.0.0.1"
        configuration.port = port
        let blocker = IperfRunner(with: configuration)
        addTeardownBlock { blocker.stop() }
        let blockerReleased = expectation(description: "blocking native server released")
        blocker.start({ _ in }, { XCTFail("blocker failed: \($0)") }, { _ in },
                      onResourcesReleased: { _ in blockerReleased.fulfill() })
        try waitUntilSwiftServerListens(on: port)

        for deallocate in [false, true] {
            let url = tools.directory.appendingPathComponent(UUID().uuidString)
            var next = IperfConfiguration()
            next.logfile = url.path
            next.logfileByteLimit = 128
            var queued: IperfRunner? = IperfRunner(with: next)
            weak var weakQueued = queued
            let initialising = expectation(description: "run is queued")
            let released = expectation(description: "queued run released")
            queued?.start({ _ in XCTFail("queued run measured") }, { XCTFail("queued run failed: \($0)") }, { state in
                if state == .initialising { initialising.fulfill() }
                XCTAssertNotEqual(state, .running)
            }, onResourcesReleased: { completion in
                XCTAssertNil(completion.logfile)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                released.fulfill()
            })
            wait(for: [initialising], timeout: 3)
            queued?.start(with: next, { _ in XCTFail("ignored start measured") }, { _ in XCTFail("ignored start failed") },
                          { _ in XCTFail("ignored start changed state") }, onResourcesReleased: { _ in XCTFail("ignored start completed") })
            if deallocate {
                queued = nil
            } else {
                queued?.stop(); queued?.stop()
            }
            wait(for: [released], timeout: 3)
            if deallocate { XCTAssertNil(weakQueued) }
            else { XCTAssertNotNil(queued?.completion) }
        }
        blocker.stop()
        wait(for: [blockerReleased], timeout: 5)
    }
}

/// An `iperf3 -s` process, keeping what it writes for failure messages.
///
/// ``XCTestCase/startCLIServer(_:_:timeout:ports:)`` starts one
/// and returns it once it is listening.
private final class CLIServer {
    struct StartupFailure: LocalizedError, CustomStringConvertible {
        let description: String
        /// The server could not listen on its port, which another port can fix.
        let lostPort: Bool

        var errorDescription: String? { description }
    }

    /// The CLI's IELISTEN message, on stderr or in the `-J` document's error.
    private static let listenFailure = "unable to start listener for connections"

    let process = Process()
    let port: Int
    // Keeps the temporary directory, which holds the output and any files the
    // arguments name, for as long as the server may read or write it.
    private let tools: TestTools
    private let standardOutputURL: URL
    private let standardErrorURL: URL

    init(tools: TestTools, port: Int, arguments: [String]) throws {
        self.tools = tools
        self.port = port
        standardOutputURL = tools.directory.appendingPathComponent("iperf3-server-\(port).out")
        standardErrorURL = tools.directory.appendingPathComponent("iperf3-server-\(port).err")
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: tools.iperf3)
        process.arguments = ["-s", "-p", String(port)] + arguments
        process.standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        process.standardError = try FileHandle(forWritingTo: standardErrorURL)
        try process.run()
    }

    /// What the server has written to standard output. iperf3 buffers it when
    /// it is not a terminal, so it is complete once the server has exited.
    var standardOutput: String {
        (try? String(contentsOf: standardOutputURL, encoding: .utf8)) ?? ""
    }

    private var output: String {
        standardOutput + ((try? String(contentsOf: standardErrorURL, encoding: .utf8)) ?? "")
    }

    /// Returns once the server's only TCP socket on its port is its listener.
    ///
    /// The socket is read with lsof rather than probed. Connecting would
    /// consume the one client a `-1` server serves, and a bind cannot tell:
    /// the server binds the wildcard address, so a bind on a specific address
    /// succeeds whether it is listening or not. Requiring the listener to be
    /// the only socket makes this the wait between a persistent server's runs
    /// too: the server keeps its old listener until it has closed the previous
    /// client's connection, and only then replaces it.
    func waitUntilListening(timeout: TimeInterval = 10) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning {
            if try TestTools.tcpSocketStates(pid: process.processIdentifier, port: port) == ["LISTEN"] {
                return
            }
            guard Date() < deadline else {
                // Let it exit first, so that what it buffered is written.
                terminate()
                let exitDeadline = Date(timeIntervalSinceNow: 2)
                while process.isRunning && Date() < exitDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw StartupFailure(
                    description: "the iperf3 server on port \(port) was not listening after \(timeout)s:\n\(output)",
                    lostPort: false
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let printed = output
        throw StartupFailure(
            description: "the iperf3 server on port \(port) exited with status "
                + "\(process.terminationStatus) before listening:\n\(printed)",
            lostPort: printed.contains(Self.listenFailure)
        )
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
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
            privateKeyURL: privateKeyURL,
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

    /// Server arguments for an official iperf3 server that authenticates
    /// clients, after writing its private key and authorized-users list into
    /// the test's temporary directory.
    func authenticatedServerArguments(
        credentials: Credentials,
        usePkcs1Padding: Bool,
        oneOff: Bool = true
    ) throws -> [String] {
        let name = "cli-server-\(UUID().uuidString)"
        let privateKeyURL = directory.appendingPathComponent("\(name).pem")
        guard let privateKeyData = Data(base64Encoded: credentials.privateKeyBase64) else {
            throw XCTSkip("could not decode the generated private key")
        }
        try privateKeyData.write(to: privateKeyURL)
        let authorizedUsersURL = directory.appendingPathComponent("\(name)-users.csv")
        try credentials.authorizedUsers.write(to: authorizedUsersURL, atomically: true, encoding: .utf8)

        var arguments = [
            "--rsa-private-key-path", privateKeyURL.path,
            "--authorized-users-path", authorizedUsersURL.path,
        ]
        if oneOff {
            arguments.append("-1")
        }
        if usePkcs1Padding {
            arguments.append("--use-pkcs1-padding")
        }
        return arguments
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

    /// The states of the TCP sockets process `pid` holds on `port`, read with
    /// lsof from outside the process, as `Scripts/verify_engine_regressions.sh`
    /// waits for a server.
    static func tcpSocketStates(pid: pid_t, port: Int) throws -> [String] {
        let lsof = Process()
        let output = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-Ts", "-FT"]
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsof.waitUntilExit()
        return report.split(separator: "\n").compactMap { field in
            field.hasPrefix("TST=") ? String(field.dropFirst(4)) : nil
        }
    }

    /// A port that no TCP or UDP socket on this host holds, on any address.
    ///
    /// The kernel's choice for `127.0.0.1:0` only avoids sockets on 127.0.0.1
    /// and the wildcard, and a port held on another address defeats the binds
    /// tests make. An `iperf3` server binds the dual-stack wildcard, which
    /// another user's socket on any address refuses: ports that root's
    /// `remoted` held on IPv6 addresses passed that probe, and `iperf3 -s`
    /// then exited with "Address already in use". A `clientPort` stream binds
    /// the IPv4 wildcard without `SO_REUSEADDR`, which any socket on the port
    /// refuses, and a UDP socket on the port takes a UDP run's datagrams. So a
    /// candidate is handed out only if ``isFree(port:)`` as well.
    ///
    /// The port is released before it is returned, so a server can still lose
    /// it; ``XCTestCase/startCLIServer(_:_:timeout:ports:)``
    /// starts such a server again on another port.
    static func freePort() throws -> Int {
        for _ in 0..<64 {
            guard let descriptor = boundSocket(SOCK_STREAM, AF_INET, port: 0, loopback: true) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
            }
            let candidate = boundPort(descriptor)
            close(descriptor)
            if let candidate, isFree(port: candidate) {
                return candidate
            }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// Whether `port` binds on the wildcard address of both families, for TCP
    /// and UDP, without `SO_REUSEADDR` — which any socket holding it refuses.
    /// Neither family stands in for the other: a dual-stack bind succeeds over
    /// a socket on the IPv4 wildcard.
    static func isFree(port: Int) -> Bool {
        [SOCK_STREAM, SOCK_DGRAM].allSatisfy { type in
            [AF_INET, AF_INET6].allSatisfy { family in
                guard let descriptor = boundSocket(type, family, port: port) else {
                    return false
                }
                close(descriptor)
                return true
            }
        }
    }

    /// A socket of `type` bound to `port` on the wildcard address of `family`,
    /// or on its loopback address; nil if the bind is refused. An IPv6 socket
    /// is dual-stack, the default.
    static func boundSocket(_ type: Int32, _ family: Int32, port: Int, loopback: Bool = false) -> Int32? {
        let descriptor = socket(family, type, 0)
        guard descriptor >= 0 else {
            return nil
        }
        let result: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: loopback ? in_addr_t(INADDR_LOOPBACK).bigEndian : 0)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0 else {
            let bindError = errno
            close(descriptor)
            errno = bindError
            return nil
        }
        return descriptor
    }

    static func boundPort(_ descriptor: Int32) -> Int? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else {
            return nil
        }
        let family = Int32(address.ss_family)
        return withUnsafePointer(to: &address) {
            if family == AF_INET6 {
                return $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Int(UInt16(bigEndian: $0.pointee.sin6_port))
                }
            }
            return $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                Int(UInt16(bigEndian: $0.pointee.sin_port))
            }
        }
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
