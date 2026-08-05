import XCTest
@testable import IperfSwift

final class IperfSwiftUnitTests: XCTestCase {
    func testConcurrentStartsDeliverEachCallersErrorCallback() {
        let invocationCount = 200
        let callbacks = expectation(description: "all concurrent starts complete")
        callbacks.expectedFulfillmentCount = invocationCount
        let lock = NSLock()
        var callbackIDs = Set<Int>()
        var configuration = IperfConfiguration()
        configuration.port = 0
        let runner = IperfRunner(with: configuration)

        DispatchQueue.concurrentPerform(iterations: invocationCount) { index in
            runner.start(with: configuration, { _ in }, { error in
                XCTAssertEqual(error, .IEBADPORT)
                lock.lock()
                callbackIDs.insert(index)
                lock.unlock()
                callbacks.fulfill()
            }, { _ in })
        }

        wait(for: [callbacks], timeout: 5)
        lock.lock()
        let receivedCallbackIDs = callbackIDs
        lock.unlock()
        XCTAssertEqual(receivedCallbackIDs, Set(0..<invocationCount))
    }

    func testOutOfRangeConfigurationReturnsCLIParameterErrors() {
        var testCases: [(configuration: IperfConfiguration, error: IperfError)] = []

        var portConfiguration = IperfConfiguration()
        portConfiguration.port = .max
        testCases.append((portConfiguration, .IEBADPORT))

        var negativePortConfiguration = IperfConfiguration()
        negativePortConfiguration.port = .min
        testCases.append((negativePortConfiguration, .IEBADPORT))

        var omitConfiguration = IperfConfiguration()
        omitConfiguration.omit = .max
        testCases.append((omitConfiguration, .IEOMIT))

        var negativeOmitConfiguration = IperfConfiguration()
        negativeOmitConfiguration.omit = .min
        testCases.append((negativeOmitConfiguration, .IEOMIT))

        var oversizedDurationConfiguration = IperfConfiguration()
        oversizedDurationConfiguration.duration = .greatestFiniteMagnitude
        testCases.append((oversizedDurationConfiguration, .IEDURATION))

        var negativeDurationConfiguration = IperfConfiguration()
        negativeDurationConfiguration.duration = -1
        testCases.append((negativeDurationConfiguration, .IEDURATION))

        var negativeDscpConfiguration = IperfConfiguration()
        negativeDscpConfiguration.dscp = .min
        testCases.append((negativeDscpConfiguration, .IEBADTOS))

        var dscpConfiguration = IperfConfiguration()
        dscpConfiguration.dscp = .max
        testCases.append((dscpConfiguration, .IEBADTOS))

        var shortReceivingTimeoutConfiguration = IperfConfiguration()
        shortReceivingTimeoutConfiguration.rcvTimeout = 0.05
        testCases.append((shortReceivingTimeoutConfiguration, .IERCVTIMEOUT))

        var shortSendingTimeoutConfiguration = IperfConfiguration()
        shortSendingTimeoutConfiguration.mode = .upload
        shortSendingTimeoutConfiguration.rcvTimeout = 0.05
        testCases.append((shortSendingTimeoutConfiguration, .IERCVTIMEOUT))

        var shortServerTimeoutConfiguration = IperfConfiguration()
        shortServerTimeoutConfiguration.role = .server
        shortServerTimeoutConfiguration.rcvTimeout = 0.05
        testCases.append((shortServerTimeoutConfiguration, .IERCVTIMEOUT))

        var oversizedReceiveTimeoutConfiguration = IperfConfiguration()
        oversizedReceiveTimeoutConfiguration.rcvTimeout = 86_400.001
        testCases.append((oversizedReceiveTimeoutConfiguration, .IERCVTIMEOUT))

        var infiniteReceiveTimeoutConfiguration = IperfConfiguration()
        infiniteReceiveTimeoutConfiguration.rcvTimeout = .infinity
        testCases.append((infiniteReceiveTimeoutConfiguration, .IERCVTIMEOUT))

        var nanReceiveTimeoutConfiguration = IperfConfiguration()
        nanReceiveTimeoutConfiguration.rcvTimeout = .nan
        testCases.append((nanReceiveTimeoutConfiguration, .IERCVTIMEOUT))

        for (index, testCase) in testCases.enumerated() {
            let failed = expectation(description: "invalid configuration \(index) fails normally")
            let runner = IperfRunner(with: testCase.configuration)
            var receivedError: IperfError?
            var states: [IperfRunnerState] = []

            runner.start({ _ in }, { error in
                receivedError = error
                failed.fulfill()
            }, { state in
                states.append(state)
            })

            wait(for: [failed], timeout: 2)
            XCTAssertEqual(receivedError, testCase.error)
            XCTAssertEqual(states.last, .error)
        }
    }

    func testBlockSizeBoundaryValidation() {
        let testCases: [(IperfProtocol, Int?, IperfError?)] = [
            (.tcp, nil, nil),
            (.tcp, -1, nil),
            (.tcp, 0, nil),
            (.tcp, 1, nil),
            (.tcp, 1_048_576, nil),
            (.tcp, 1_048_577, .IEBLOCKSIZE),
            (.udp, nil, nil),
            (.udp, -1, nil),
            (.udp, 0, nil),
            (.udp, 1, .IEUDPBLOCKSIZE),
            (.udp, 15, .IEUDPBLOCKSIZE),
            (.udp, 16, nil),
            (.udp, 65_507, nil),
            (.udp, 65_508, .IEUDPBLOCKSIZE),
            (.udp, 1_048_576, .IEUDPBLOCKSIZE),
            (.udp, 1_048_577, .IEBLOCKSIZE),
        ]

        for (prot, blockSize, expectedError) in testCases {
            XCTAssertEqual(
                IperfRunner.blockSizeError(blockSize, for: prot),
                expectedError,
                "\(prot) blockSize=\(String(describing: blockSize))"
            )
        }

        XCTAssertEqual(IperfRunner.resolvedBlockSize(nil, for: .tcp), 128 * 1_024)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(-1, for: .tcp), 128 * 1_024)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(0, for: .tcp), 128 * 1_024)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(nil, for: .udp), 0)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(-1, for: .udp), 0)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(0, for: .udp), 0)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(1_200, for: .tcp), 1_200)
        XCTAssertEqual(IperfRunner.resolvedBlockSize(1_200, for: .udp), 1_200)
    }

    func testInvalidBlockSizeFailsBeforeApplicabilityAndNetworking() {
        var oversizedTCP = IperfConfiguration()
        oversizedTCP.address = "invalid.invalid"
        oversizedTCP.blockSize = 1_048_577

        var undersizedUDP = IperfConfiguration()
        undersizedUDP.address = "invalid.invalid"
        undersizedUDP.prot = .udp
        undersizedUDP.blockSize = 15

        var oversizedUDP = IperfConfiguration()
        oversizedUDP.address = "invalid.invalid"
        oversizedUDP.prot = .udp
        oversizedUDP.blockSize = 1_048_577

        var wrongRole = IperfConfiguration()
        wrongRole.role = .server
        wrongRole.blockSize = 1_048_577

        let testCases: [(String, IperfConfiguration, IperfError)] = [
            ("TCP generic maximum", oversizedTCP, .IEBLOCKSIZE),
            ("UDP protocol minimum", undersizedUDP, .IEUDPBLOCKSIZE),
            ("UDP generic maximum precedence", oversizedUDP, .IEBLOCKSIZE),
            ("intrinsic before role", wrongRole, .IEBLOCKSIZE),
        ]

        for (name, configuration, expectedError) in testCases {
            assertRunnerFails(configuration, with: expectedError, description: name)
        }
    }

    func testClientPortBoundaryValidation() {
        let testCases: [(Int?, Int, IperfTestMode, IperfError?)] = [
            (nil, 2, .upload, nil),
            (0, 2, .upload, .IEBADPORT),
            (-1, 2, .upload, .IEBADPORT),
            (65_536, 2, .upload, .IEBADPORT),
            (65_535, 1, .upload, nil),
            (65_534, 2, .upload, nil),
            (65_535, 2, .upload, .IEBADPORT),
            (65_534, 1, .bidirectional, nil),
            (65_535, 1, .bidirectional, .IEBADPORT),
            (65_532, 2, .bidirectional, nil),
            (65_533, 2, .bidirectional, .IEBADPORT),
            (1, .max, .bidirectional, .IEBADPORT),
            (65_535, 0, .upload, nil),
        ]

        for (clientPort, numStreams, mode, expectedError) in testCases {
            XCTAssertEqual(
                IperfRunner.clientPortError(clientPort, numStreams: numStreams, mode: mode),
                expectedError,
                "port=\(String(describing: clientPort)) streams=\(numStreams) mode=\(mode)"
            )
        }
    }

    func testInvalidClientPortFailsBeforeRoleAndNetworking() {
        var invalidBase = IperfConfiguration()
        invalidBase.address = "invalid.invalid"
        invalidBase.clientPort = 0

        var invalidRange = IperfConfiguration()
        invalidRange.address = "invalid.invalid"
        invalidRange.clientPort = 65_535
        invalidRange.numStreams = 2

        var invalidServerBase = IperfConfiguration()
        invalidServerBase.role = .server
        invalidServerBase.clientPort = 0

        var validServerBase = IperfConfiguration()
        validServerBase.role = .server
        validServerBase.clientPort = 5_203

        let testCases: [(String, IperfConfiguration, IperfError)] = [
            ("base range", invalidBase, .IEBADPORT),
            ("stream range", invalidRange, .IEBADPORT),
            ("value before role", invalidServerBase, .IEBADPORT),
            ("client-only role", validServerBase, .IECLIENTONLY),
        ]

        for (name, configuration, expectedError) in testCases {
            assertRunnerFails(configuration, with: expectedError, description: name)
        }
    }

    func testEndConditionValidationMatchesCLI() {
        let testCases: [(TimeInterval?, UInt64?, IperfError?)] = [
            (nil, nil, nil),
            (1, nil, nil),
            (nil, 1, nil),
            (1, 1, .IEENDCONDITIONS),
            (0, 1, .IEENDCONDITIONS),
            (1, 0, nil),
            (0, 0, nil),
            (-1, 1, .IEDURATION),
            (.infinity, 1, .IEENDCONDITIONS),
            (.nan, 1, .IEENDCONDITIONS),
        ]

        for (duration, numberOfBytes, expectedError) in testCases {
            XCTAssertEqual(
                IperfRunner.endConditionError(duration: duration, numberOfBytes: numberOfBytes),
                expectedError,
                "duration=\(String(describing: duration)) bytes=\(String(describing: numberOfBytes))"
            )
        }
    }

    func testConflictingEndConditionsFailBeforeApplicabilityAndNetworking() {
        for prot in [IperfProtocol.tcp, .udp] {
            for mode in [IperfTestMode.upload, .download, .bidirectional] {
                var configuration = IperfConfiguration()
                configuration.address = "invalid.invalid"
                configuration.prot = prot
                configuration.mode = mode
                configuration.duration = 1
                configuration.numberOfBytes = 1

                assertRunnerFails(
                    configuration,
                    with: .IEENDCONDITIONS,
                    description: "\(prot) \(mode) end condition conflict"
                )
            }
        }

        var wrongRole = IperfConfiguration()
        wrongRole.role = .server
        wrongRole.duration = 1
        wrongRole.numberOfBytes = 1
        assertRunnerFails(
            wrongRole,
            with: .IEENDCONDITIONS,
            description: "end condition conflict precedes role"
        )
    }

    func testAuthenticationValidationFailsBeforeNetworking() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let testCases: [(String, IperfRole, Mutation, IperfError)] = [
            ("disabled client credential", .client, { $0.username = "user" }, .IESETCLIENTAUTH),
            ("disabled client padding", .client, { $0.usePkcs1Padding = true }, .IESETCLIENTAUTH),
            ("incomplete client credentials", .client, {
                $0.isAuth = true
                $0.username = "user"
            }, .IESETCLIENTAUTH),
            ("invalid client public key", .client, {
                $0.isAuth = true
                $0.username = "user"
                $0.password = "password"
                $0.publicKey = "not-base64-pem"
            }, .IESETCLIENTAUTH),
            ("disabled server credential", .server, { $0.authorizedUsers = "user,hash" }, .IESETSERVERAUTH),
            ("disabled server padding", .server, { $0.usePkcs1Padding = true }, .IESETSERVERAUTH),
            ("disabled explicit server skew", .server, { $0.timeSkewThreshold = 10 }, .IESETSERVERAUTH),
            ("incomplete server credentials", .server, {
                $0.isAuth = true
                $0.authorizedUsers = "user,hash"
            }, .IESETSERVERAUTH),
            ("nonpositive server skew", .server, {
                $0.isAuth = true
                $0.privateKey = "not-base64-pem"
                $0.authorizedUsers = "user,hash"
                $0.timeSkewThreshold = 0
            }, .IESETSERVERAUTH),
            ("invalid server private key", .server, {
                $0.isAuth = true
                $0.privateKey = "not-base64-pem"
                $0.authorizedUsers = "user,hash"
            }, .IESETSERVERAUTH),
        ]

        for (name, role, mutate, expectedError) in testCases {
            var configuration = IperfConfiguration()
            configuration.role = role
            configuration.address = "invalid.invalid"
            mutate(&configuration)

            assertRunnerFails(configuration, with: expectedError, description: name)
        }
    }

    func testWrongRoleAuthenticationErrorsPrecedeCompletenessErrors() {
        var client = IperfConfiguration()
        client.isAuth = true
        client.privateKey = "not-base64-pem"
        assertRunnerFails(client, with: .IESERVERONLY, description: "server key on client")

        var server = IperfConfiguration()
        server.role = .server
        server.isAuth = true
        server.username = "user"
        assertRunnerFails(server, with: .IECLIENTONLY, description: "client username on server")
    }

    func testClientIntegerOptionBoundaries() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let testCases: [(String, Mutation, IperfError?)] = [
            ("streams minimum", { $0.numStreams = 1 }, nil),
            ("streams maximum", { $0.numStreams = 128 }, nil),
            ("streams zero", { $0.numStreams = 0 }, .IENUMSTREAMS),
            ("streams negative", { $0.numStreams = -1 }, .IENUMSTREAMS),
            ("streams above maximum", { $0.numStreams = 129 }, .IENUMSTREAMS),
            ("streams narrowing overflow", { $0.numStreams = .max }, .IENUMSTREAMS),
            ("buffer default", { $0.socketBufferSize = 0 }, nil),
            ("buffer maximum", { $0.socketBufferSize = 512 * 1_024 * 1_024 }, nil),
            ("buffer negative", { $0.socketBufferSize = -1 }, .IEBUFSIZE),
            ("buffer above maximum", { $0.socketBufferSize = 512 * 1_024 * 1_024 + 1 }, .IEBUFSIZE),
            ("buffer narrowing overflow", { $0.socketBufferSize = .max }, .IEBUFSIZE),
            ("mss default", { $0.mss = 0 }, nil),
            ("mss maximum", { $0.mss = 32_767 }, nil),
            ("mss negative", { $0.mss = -1 }, .IEMSS),
            ("mss above maximum", { $0.mss = 32_768 }, .IEMSS),
            ("mss narrowing overflow", { $0.mss = .max }, .IEMSS),
            ("tos minimum", { $0.tos = 0 }, nil),
            ("tos maximum", { $0.tos = 255 }, nil),
            ("tos negative", { $0.tos = -1 }, .IEBADTOS),
            ("tos above maximum", { $0.tos = 256 }, .IEBADTOS),
            ("tos narrowing overflow", { $0.tos = .max }, .IEBADTOS),
        ]

        for (name, mutate, expectedError) in testCases {
            var configuration = IperfConfiguration()
            mutate(&configuration)
            XCTAssertEqual(
                IperfRunner.clientIntegerError(for: configuration),
                expectedError,
                name
            )
        }
    }

    func testInvalidClientIntegersPrecedeApplicabilityAndNetworking() {
        var invalidMSS = IperfConfiguration()
        invalidMSS.address = "invalid.invalid"
        invalidMSS.prot = .udp
        invalidMSS.mss = -1
        assertRunnerFails(invalidMSS, with: .IEMSS, description: "invalid MSS before TCP-only")

        var invalidServerStreams = IperfConfiguration()
        invalidServerStreams.role = .server
        invalidServerStreams.numStreams = 0
        assertRunnerFails(
            invalidServerStreams,
            with: .IENUMSTREAMS,
            description: "invalid stream count before client-only"
        )

        var invalidTOS = IperfConfiguration()
        invalidTOS.address = "invalid.invalid"
        invalidTOS.prot = .udp
        invalidTOS.addressFamily = .ipv6
        invalidTOS.dontFragment = true
        invalidTOS.tos = 256
        assertRunnerFails(invalidTOS, with: .IEBADTOS, description: "invalid TOS before IPv4-only")
    }

    func testTimeIntervalOptionBoundaries() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let maximumConnectTimeout = Double(Int32.max) / 1_000
        let testCases: [(String, Mutation, IperfError?)] = [
            ("defaults", { _ in }, nil),
            ("idle fractional minimum", { $0.idleTimeout = 0.000_001 }, nil),
            ("idle maximum", { $0.idleTimeout = 86_400 }, nil),
            ("idle zero", { $0.idleTimeout = 0 }, .IEIDLETIMEOUT),
            ("idle negative", { $0.idleTimeout = -1 }, .IEIDLETIMEOUT),
            ("idle above maximum after rounding", { $0.idleTimeout = 86_400.000_001 }, .IEIDLETIMEOUT),
            ("idle NaN", { $0.idleTimeout = .nan }, .IEIDLETIMEOUT),
            ("idle infinity", { $0.idleTimeout = .infinity }, .IEIDLETIMEOUT),
            ("reporter disabled", { $0.reporterInterval = 0 }, nil),
            ("reporter CLI minimum", { $0.reporterInterval = 0.1 }, nil),
            ("reporter maximum", { $0.reporterInterval = 60 }, nil),
            ("reporter just below CLI minimum", { $0.reporterInterval = 0.099 }, .IEINTERVAL),
            ("reporter sub-CLI minimum", { $0.reporterInterval = 0.01 }, .IEINTERVAL),
            ("reporter microsecond minimum", { $0.reporterInterval = 0.000_001 }, .IEINTERVAL),
            ("reporter negative", { $0.reporterInterval = -1 }, .IEINTERVAL),
            ("reporter above maximum", { $0.reporterInterval = 60.000_001 }, .IEINTERVAL),
            ("reporter NaN", { $0.reporterInterval = .nan }, .IEINTERVAL),
            ("reporter infinity", { $0.reporterInterval = .infinity }, .IEINTERVAL),
            ("connect default", { $0.timeout = 0 }, nil),
            ("connect millisecond minimum", { $0.timeout = 0.001 }, nil),
            ("connect maximum", { $0.timeout = maximumConnectTimeout }, nil),
            ("connect below millisecond precision", { $0.timeout = 0.000_999 }, .IECONNECTTIMEOUT),
            ("connect negative", { $0.timeout = -1 }, .IECONNECTTIMEOUT),
            ("connect above maximum", { $0.timeout = maximumConnectTimeout + 0.000_001 }, .IECONNECTTIMEOUT),
            ("connect NaN", { $0.timeout = .nan }, .IECONNECTTIMEOUT),
            ("connect infinity", { $0.timeout = .infinity }, .IECONNECTTIMEOUT),
            ("connect multiplication overflow", { $0.timeout = .greatestFiniteMagnitude }, .IECONNECTTIMEOUT),
        ]

        for (name, mutate, expectedError) in testCases {
            var configuration = IperfConfiguration()
            mutate(&configuration)
            XCTAssertEqual(IperfRunner.timeIntervalError(for: configuration), expectedError, name)
        }
    }

    func testTimeIntervalConversionsPreserveDocumentedRounding() {
        XCTAssertEqual(IperfRunner.idleTimeoutSeconds(0.000_001), 1)
        XCTAssertEqual(IperfRunner.idleTimeoutSeconds(1), 1)
        XCTAssertEqual(IperfRunner.idleTimeoutSeconds(1.000_001), 2)
        XCTAssertEqual(IperfRunner.idleTimeoutSeconds(86_399.1), 86_400)

        XCTAssertEqual(IperfRunner.connectTimeoutMilliseconds(0.001), 1)
        XCTAssertEqual(IperfRunner.connectTimeoutMilliseconds(0.001_9), 1)
        XCTAssertEqual(IperfRunner.connectTimeoutMilliseconds(1.999_9), 1_999)
        XCTAssertEqual(
            IperfRunner.connectTimeoutMilliseconds(Double(Int32.max) / 1_000),
            Int32.max
        )
    }

    func testInvalidTimeIntervalsPrecedeApplicabilityAndNetworking() {
        var invalidIdle = IperfConfiguration()
        invalidIdle.idleTimeout = 0
        assertRunnerFails(invalidIdle, with: .IEIDLETIMEOUT, description: "idle range before server-only")

        var validIdleWrongRole = IperfConfiguration()
        validIdleWrongRole.idleTimeout = 0.1
        assertRunnerFails(validIdleWrongRole, with: .IESERVERONLY, description: "valid idle reaches role check")

        var invalidConnect = IperfConfiguration()
        invalidConnect.role = .server
        invalidConnect.timeout = -1
        assertRunnerFails(
            invalidConnect,
            with: .IECONNECTTIMEOUT,
            description: "connect range before client-only"
        )

        var validConnectWrongRole = IperfConfiguration()
        validConnectWrongRole.role = .server
        validConnectWrongRole.timeout = 0.001
        assertRunnerFails(
            validConnectWrongRole,
            with: .IECLIENTONLY,
            description: "valid connect reaches role check"
        )

        var invalidReporter = IperfConfiguration()
        invalidReporter.address = "invalid.invalid"
        invalidReporter.reporterInterval = .nan
        assertRunnerFails(invalidReporter, with: .IEINTERVAL, description: "reporter before networking")
    }

    func testNonFiniteDurationDoesNotTrap() {
        var configurations: [IperfConfiguration] = []

        var infiniteDurationConfiguration = unreachableClientConfiguration()
        infiniteDurationConfiguration.duration = .infinity
        configurations.append(infiniteDurationConfiguration)

        var nanDurationConfiguration = unreachableClientConfiguration()
        nanDurationConfiguration.duration = .nan
        configurations.append(nanDurationConfiguration)

        for (index, configuration) in configurations.enumerated() {
            let failed = expectation(description: "non-finite duration \(index) fails normally")
            let runner = IperfRunner(with: configuration)

            runner.start({ _ in }, { _ in failed.fulfill() }, { _ in })

            wait(for: [failed], timeout: 2)
        }
    }

    func testDurationConversionMatchesCLIIntegerSemantics() {
        XCTAssertEqual(IperfRunner.durationSeconds(0), 0)
        XCTAssertEqual(IperfRunner.durationSeconds(-0.5), 0)
        XCTAssertEqual(IperfRunner.durationSeconds(86_400.9), 86_400)
        XCTAssertNil(IperfRunner.durationSeconds(-1))
        XCTAssertNil(IperfRunner.durationSeconds(86_401))
        XCTAssertEqual(IperfRunner.durationSeconds(.nan), 0)
        XCTAssertEqual(IperfRunner.durationSeconds(.infinity), 0)
    }

    func testConfigurationDefaultsAndCustomNetworkSettings() {
        var configuration = IperfConfiguration()

        XCTAssertEqual(configuration.role, .client)
        XCTAssertEqual(configuration.mode, .download)
        XCTAssertEqual(configuration.reverse, .download)
        XCTAssertEqual(configuration.prot, .tcp)
        XCTAssertFalse(configuration.isAuth)
        XCTAssertNil(configuration.bindDevice)
        XCTAssertNil(configuration.dscp)

        configuration.bindDevice = "lo0"
        configuration.dscp = 46
        configuration.reverse = .upload

        XCTAssertEqual(configuration.bindDevice, "lo0")
        XCTAssertEqual(configuration.dscp, 46)
        XCTAssertEqual(configuration.mode, .upload)

        configuration.mode = .bidirectional

        XCTAssertEqual(configuration.reverse, .upload)
    }

    func testConfigurationPerformanceOptionDefaults() {
        var configuration = IperfConfiguration()

        XCTAssertNil(configuration.rate)
        XCTAssertNil(configuration.blockSize)
        XCTAssertNil(configuration.socketBufferSize)
        XCTAssertNil(configuration.mss)
        XCTAssertFalse(configuration.noDelay)
        XCTAssertNil(configuration.statsInterval)

        configuration.rate = 5_000_000
        configuration.blockSize = 1_200
        configuration.socketBufferSize = 262_144
        configuration.mss = 1_400
        configuration.noDelay = true

        XCTAssertEqual(configuration.rate, 5_000_000)
        XCTAssertEqual(configuration.blockSize, 1_200)
        XCTAssertEqual(configuration.socketBufferSize, 262_144)
        XCTAssertEqual(configuration.mss, 1_400)
        XCTAssertTrue(configuration.noDelay)
    }

    func testConfigurationMidPriorityOptionDefaults() {
        var configuration = IperfConfiguration()

        XCTAssertNil(configuration.clientPort)
        XCTAssertNil(configuration.tos)
        XCTAssertFalse(configuration.udpCounters64Bit)
        XCTAssertFalse(configuration.repeatingPayload)
        XCTAssertFalse(configuration.getServerOutput)
        XCTAssertFalse(configuration.oneOff)
        XCTAssertNil(configuration.idleTimeout)
        XCTAssertNil(configuration.rcvTimeout)

        configuration.clientPort = 24_001
        configuration.tos = 32
        configuration.udpCounters64Bit = true
        configuration.repeatingPayload = true
        configuration.getServerOutput = true
        configuration.oneOff = true
        configuration.idleTimeout = 30
        configuration.rcvTimeout = 10

        XCTAssertEqual(configuration.clientPort, 24_001)
        XCTAssertEqual(configuration.tos, 32)
        XCTAssertTrue(configuration.udpCounters64Bit)
        XCTAssertTrue(configuration.repeatingPayload)
        XCTAssertTrue(configuration.getServerOutput)
        XCTAssertTrue(configuration.oneOff)
        XCTAssertEqual(configuration.idleTimeout, 30)
        XCTAssertEqual(configuration.rcvTimeout, 10)
    }

    func testConfigurationAddressFamilyAndDontFragmentDefaults() {
        var configuration = IperfConfiguration()

        XCTAssertEqual(configuration.addressFamily, .any)
        XCTAssertFalse(configuration.dontFragment)

        configuration.addressFamily = .ipv6
        configuration.dontFragment = true

        XCTAssertEqual(configuration.addressFamily, .ipv6)
        XCTAssertTrue(configuration.dontFragment)
    }

    func testReverseRoundTripKeepsBidirectionalMode() {
        var configuration = IperfConfiguration()
        configuration.mode = .bidirectional

        configuration.reverse = configuration.reverse

        XCTAssertEqual(configuration.mode, .bidirectional)

        configuration.reverse = .download

        XCTAssertEqual(configuration.mode, .download)
    }

    func testRoleApplicabilityRejectsWrongRoleOptions() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let testCases: [(String, IperfRole, Mutation, IperfError)] = [
            ("oneOff", .client, { $0.oneOff = true }, .IESERVERONLY),
            ("idleTimeout", .client, { $0.idleTimeout = 1 }, .IESERVERONLY),
            ("privateKey", .client, { $0.privateKey = "key" }, .IESERVERONLY),
            ("authorizedUsers", .client, { $0.authorizedUsers = "user,hash" }, .IESERVERONLY),
            ("timeSkewThreshold", .client, { $0.timeSkewThreshold = 10 }, .IESERVERONLY),
            ("numStreams", .server, { $0.numStreams = 1 }, .IECLIENTONLY),
            ("mode", .server, { $0.mode = .upload }, .IECLIENTONLY),
            ("reverse", .server, { $0.reverse = .download }, .IECLIENTONLY),
            ("prot", .server, { $0.prot = .udp }, .IECLIENTONLY),
            ("rate", .server, { $0.rate = 1 }, .IECLIENTONLY),
            ("duration", .server, { $0.duration = 1 }, .IECLIENTONLY),
            ("numberOfBytes", .server, { $0.numberOfBytes = 1 }, .IECLIENTONLY),
            ("blockSize", .server, { $0.blockSize = 1 }, .IECLIENTONLY),
            ("socketBufferSize", .server, { $0.socketBufferSize = 1 }, .IECLIENTONLY),
            ("mss", .server, { $0.mss = 1 }, .IECLIENTONLY),
            ("tos", .server, { $0.tos = 1 }, .IECLIENTONLY),
            ("dscp", .server, { $0.dscp = 1 }, .IECLIENTONLY),
            ("timeout", .server, { $0.timeout = 1 }, .IECLIENTONLY),
            ("clientPort", .server, { $0.clientPort = 5_203 }, .IECLIENTONLY),
            ("noDelay", .server, { $0.noDelay = true }, .IECLIENTONLY),
            ("repeatingPayload", .server, { $0.repeatingPayload = true }, .IECLIENTONLY),
            ("getServerOutput", .server, { $0.getServerOutput = true }, .IECLIENTONLY),
            ("udpCounters64Bit", .server, { $0.udpCounters64Bit = true }, .IECLIENTONLY),
            ("dontFragment", .server, { $0.dontFragment = true }, .IECLIENTONLY),
            ("omit", .server, { $0.omit = 1 }, .IECLIENTONLY),
            ("username", .server, { $0.username = "user" }, .IECLIENTONLY),
            ("publicKey", .server, { $0.publicKey = "key" }, .IECLIENTONLY),
            ("password", .server, { $0.password = "password" }, .IECLIENTONLY),
        ]

        for (name, role, mutate, expectedError) in testCases {
            var configuration = IperfConfiguration()
            configuration.role = role
            mutate(&configuration)

            XCTAssertEqual(configuration.roleApplicabilityError(), expectedError, name)
        }
    }

    func testRoleApplicabilityTracksSameDefaultAssignmentsAndCopies() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let serverMutations: [(String, Mutation)] = [
            ("numStreams", { $0.numStreams = 2 }),
            ("mode", { $0.mode = .download }),
            ("reverse", { $0.reverse = .download }),
            ("prot", { $0.prot = .tcp }),
            ("omit", { $0.omit = 0 }),
        ]

        for (name, mutate) in serverMutations {
            var configuration = IperfConfiguration()
            configuration.role = .server
            mutate(&configuration)
            let copy = configuration

            XCTAssertEqual(copy.roleApplicabilityError(), .IECLIENTONLY, name)
        }

        var client = IperfConfiguration()
        client.timeSkewThreshold = 10
        let clientCopy = client
        XCTAssertEqual(clientCopy.roleApplicabilityError(), .IESERVERONLY)
    }

    func testRoleApplicabilityAllowsDefaultsAndDualRoleOptions() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let mutations: [(String, Mutation)] = [
            ("address", { $0.address = "::1" }),
            ("addressFamily", { $0.addressFamily = .ipv6 }),
            ("bindDevice", { $0.bindDevice = "lo0" }),
            ("port", { $0.port = 5_202 }),
            ("reporterInterval", { $0.reporterInterval = 0.5 }),
            ("logfile", { $0.logfile = "/tmp/iperf.log" }),
            ("verbose", { $0.verbose = true }),
            ("isAuth", { $0.isAuth = true }),
            ("usePkcs1Padding", { $0.usePkcs1Padding = true }),
            ("statsInterval", { $0.statsInterval = 0.5 }),
        ]

        XCTAssertNil(IperfConfiguration().roleApplicabilityError())
        var defaultServer = IperfConfiguration()
        defaultServer.role = .server
        XCTAssertNil(defaultServer.roleApplicabilityError())

        for role in [IperfRole.client, .server] {
            for (name, mutate) in mutations {
                var configuration = IperfConfiguration()
                configuration.role = role
                mutate(&configuration)

                XCTAssertNil(configuration.roleApplicabilityError(), "\(role) \(name)")
            }
        }
    }

    func testProtocolApplicabilityRejectsWrongProtocolOptions() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let testCases: [(String, IperfProtocol, Mutation, IperfError)] = [
            ("noDelay", .udp, { $0.noDelay = true }, .IETCPONLY),
            ("mss", .udp, { $0.mss = 1_400 }, .IETCPONLY),
            ("udpCounters64Bit", .tcp, { $0.udpCounters64Bit = true }, .IEUDPONLY),
            ("dontFragment", .tcp, { $0.dontFragment = true }, .IEUDPONLY),
        ]

        for (name, prot, mutate, expectedError) in testCases {
            var configuration = IperfConfiguration()
            configuration.prot = prot
            mutate(&configuration)

            XCTAssertEqual(configuration.protocolApplicabilityError(), expectedError, name)
        }
    }

    func testProtocolApplicabilityRejectsDontFragmentWithForcedIPv6() {
        var configuration = IperfConfiguration()
        configuration.prot = .udp
        configuration.addressFamily = .ipv6
        configuration.dontFragment = true

        XCTAssertEqual(configuration.protocolApplicabilityError(), .IEIPV4ONLY)
    }

    func testProtocolApplicabilityAllowsMatchingAndDualProtocolOptions() {
        var tcp = IperfConfiguration()
        tcp.noDelay = true
        tcp.mss = 1_400
        tcp.blockSize = 1_200
        XCTAssertNil(tcp.protocolApplicabilityError())

        var udpIPv4 = IperfConfiguration()
        udpIPv4.prot = .udp
        udpIPv4.addressFamily = .ipv4
        udpIPv4.udpCounters64Bit = true
        udpIPv4.dontFragment = true
        udpIPv4.blockSize = 1_200
        XCTAssertNil(udpIPv4.protocolApplicabilityError())

        var udpAutomaticFamily = udpIPv4
        udpAutomaticFamily.addressFamily = .any
        XCTAssertNil(udpAutomaticFamily.protocolApplicabilityError())

        var udpWithDisabledTCPOptions = IperfConfiguration()
        udpWithDisabledTCPOptions.prot = .udp
        udpWithDisabledTCPOptions.noDelay = false
        udpWithDisabledTCPOptions.mss = nil
        XCTAssertNil(udpWithDisabledTCPOptions.protocolApplicabilityError())

        var tcpWithDisabledUDPOptions = IperfConfiguration()
        tcpWithDisabledUDPOptions.udpCounters64Bit = false
        tcpWithDisabledUDPOptions.dontFragment = false
        XCTAssertNil(tcpWithDisabledUDPOptions.protocolApplicabilityError())
    }

    func testApplicabilityValidationPrecedence() {
        var invalidPort = IperfConfiguration()
        invalidPort.port = 0
        invalidPort.prot = .udp
        invalidPort.noDelay = true

        var wrongRole = IperfConfiguration()
        wrongRole.role = .server
        wrongRole.prot = .udp
        wrongRole.noDelay = true

        var wrongMode = IperfConfiguration()
        wrongMode.mode = .upload
        wrongMode.rcvTimeout = 1
        wrongMode.prot = .udp
        wrongMode.noDelay = true

        let testCases: [(IperfConfiguration, IperfError)] = [
            (invalidPort, .IEBADPORT),
            (wrongRole, .IECLIENTONLY),
            (wrongMode, .IERVRSONLYRCVTIMEOUT),
        ]

        for (index, testCase) in testCases.enumerated() {
            assertRunnerFails(
                testCase.0,
                with: testCase.1,
                description: "applicability precedence \(index)"
            )
        }
    }

    func testProtocolApplicabilityErrorsReachRunnerErrorState() {
        typealias Mutation = (inout IperfConfiguration) -> Void
        let testCases: [(String, Mutation, IperfError)] = [
            ("TCP-only", {
                $0.prot = .udp
                $0.noDelay = true
            }, .IETCPONLY),
            ("UDP-only", { $0.dontFragment = true }, .IEUDPONLY),
            ("IPv4-only", {
                $0.prot = .udp
                $0.addressFamily = .ipv6
                $0.dontFragment = true
            }, .IEIPV4ONLY),
        ]

        for (name, mutate, expectedError) in testCases {
            var configuration = IperfConfiguration()
            mutate(&configuration)
            assertRunnerFails(
                configuration,
                with: expectedError,
                description: "\(name) option fails before starting"
            )
        }
    }

    func testReceiveTimeoutApplicabilityMatchesClientMode() {
        var upload = IperfConfiguration()
        upload.mode = .upload
        upload.rcvTimeout = 1
        XCTAssertEqual(upload.roleApplicabilityError(), .IERVRSONLYRCVTIMEOUT)

        var download = IperfConfiguration()
        download.mode = .download
        download.rcvTimeout = 1
        XCTAssertNil(download.roleApplicabilityError())

        var bidirectional = IperfConfiguration()
        bidirectional.mode = .bidirectional
        bidirectional.rcvTimeout = 1
        XCTAssertNil(bidirectional.roleApplicabilityError())

        var server = IperfConfiguration()
        server.role = .server
        server.rcvTimeout = 1
        XCTAssertNil(server.roleApplicabilityError())
    }

    func testReceiveTimeoutRangeBoundariesPrecedeModeValidation() {
        for timeout in [0.1, 86_400] {
            var configuration = IperfConfiguration()
            configuration.mode = .upload
            configuration.rcvTimeout = timeout

            let failed = expectation(description: "valid receive timeout \(timeout) reaches mode validation")
            let runner = IperfRunner(with: configuration)
            var receivedError: IperfError?
            runner.start({ _ in }, { error in
                receivedError = error
                failed.fulfill()
            }, { _ in })

            wait(for: [failed], timeout: 2)
            XCTAssertEqual(receivedError, .IERVRSONLYRCVTIMEOUT)
        }
    }

    func testThroughputConversions() {
        let throughput = IperfThroughput(bytes: 1_000_000, seconds: 2)

        XCTAssertEqual(throughput.rawValue, 500_000)
        XCTAssertEqual(throughput.bps, 4_000_000)
        XCTAssertEqual(throughput.Kbps, 4_000)
        XCTAssertEqual(throughput.Mbps, 4)
        XCTAssertEqual(throughput.Gbps, 0.004)
    }

    func testThroughputOverNonPositiveDurationIsZero() {
        // An interval whose start and end times are equal reaches this
        // initializer; iperf3's per-stream report answers the same division
        // with zero rather than infinity.
        XCTAssertEqual(IperfThroughput(bytes: 901_644_288, seconds: 0).rawValue, 0)
        XCTAssertEqual(IperfThroughput(bytes: 0, seconds: 0).rawValue, 0)
        XCTAssertEqual(IperfThroughput(bytes: 1_000, seconds: -1).rawValue, 0)
        XCTAssertEqual(IperfThroughput(bytes: 1_000, seconds: .nan).rawValue, 0)
    }

    func testIntervalAggregationOverZeroDurationReportsZeroThroughput() {
        var first = IperfStreamIntervalResult()
        first.bytesTransferred = 450_822_144
        first.intervalDuration = 0
        first.startTime = 6.005
        first.endTime = 6.005

        var second = IperfStreamIntervalResult()
        second.bytesTransferred = 450_822_144
        second.intervalDuration = 0
        second.startTime = 6.005
        second.endTime = 6.005

        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [first, second]
        result.evaulate()

        XCTAssertEqual(result.totalBytes, 901_644_288)
        XCTAssertEqual(result.duration, 0)
        XCTAssertEqual(result.throughput.rawValue, 0)
        XCTAssertTrue(result.throughput.bps.isFinite)
        XCTAssertTrue(result.throughput.Mbps.isFinite)
    }

    func testShortEmptyIntervalIsSuppressedOnTheSameTermsAsTheCLI() {
        // iperf_print_intermediate reports an interval when any stream reaches
        // a tenth of the statistics interval or carries bytes, and returns
        // without printing otherwise.
        func stream(seconds: TimeInterval, bytes: Int) -> IperfStreamIntervalResult {
            var result = IperfStreamIntervalResult()
            result.startTime = 10
            result.endTime = 10 + seconds
            result.intervalTimeDiff = seconds
            result.intervalDuration = seconds
            result.bytesTransferred = bytes
            return result
        }

        // Short and empty on every stream: the CLI prints nothing.
        XCTAssertTrue(
            IperfRunner.isUnreportedShortInterval(
                [stream(seconds: 0.02, bytes: 0), stream(seconds: 0.02, bytes: 0)],
                statsInterval: 1
            )
        )
        XCTAssertTrue(
            IperfRunner.isUnreportedShortInterval([stream(seconds: 0, bytes: 0)], statsInterval: 1)
        )

        // Either half of the engine's test is enough to keep the interval.
        XCTAssertFalse(
            IperfRunner.isUnreportedShortInterval([stream(seconds: 0.02, bytes: 1)], statsInterval: 1)
        )
        XCTAssertFalse(
            IperfRunner.isUnreportedShortInterval([stream(seconds: 1, bytes: 0)], statsInterval: 1)
        )

        // One qualifying stream carries the whole delivery.
        XCTAssertFalse(
            IperfRunner.isUnreportedShortInterval(
                [stream(seconds: 0.02, bytes: 0), stream(seconds: 0.02, bytes: 4_096)],
                statsInterval: 1
            )
        )

        // The threshold is a tenth of the statistics interval, inclusive, and
        // tracks that interval rather than a fixed number of seconds.
        XCTAssertFalse(
            IperfRunner.isUnreportedShortInterval([stream(seconds: 0.1, bytes: 0)], statsInterval: 1)
        )
        XCTAssertTrue(
            IperfRunner.isUnreportedShortInterval([stream(seconds: 0.099, bytes: 0)], statsInterval: 1)
        )
        XCTAssertFalse(
            IperfRunner.isUnreportedShortInterval([stream(seconds: 0.099, bytes: 0)], statsInterval: 0.5)
        )

        // An empty list keeps today's delivery: it means the engine is
        // omitting, not that the interval was short and empty.
        XCTAssertFalse(IperfRunner.isUnreportedShortInterval([], statsInterval: 1))
    }

    func testRepeatDeliveryDetectionMatchesReReadEntries() {
        // The engine keeps one interval entry per stream, so a reporter call
        // with no intervening statistics gathering re-reads what was already
        // delivered. The two rows are identical in every identity field.
        func stream(
            _ direction: IperfDirection,
            start: TimeInterval,
            end: TimeInterval,
            bytes: Int
        ) -> IperfStreamIntervalResult {
            var result = IperfStreamIntervalResult()
            result.direction = direction
            result.startTime = start
            result.endTime = end
            result.bytesTransferred = bytes
            result.intervalDuration = end - start
            return result
        }

        // Sequences 0/1 of the reported table: a full-length interval repeated.
        let delivered = [
            stream(.download, start: 0, end: 1.0035, bytes: 2_483_290_112),
            stream(.download, start: 0, end: 1.0035, bytes: 2_483_290_112),
        ]
        XCTAssertTrue(IperfRunner.isRepeatDelivery(delivered, delivered))

        // Sequences 6/7: the zero-duration pair repeats the same way.
        let zeroDuration = [stream(.download, start: 6.005, end: 6.005, bytes: 901_644_288)]
        XCTAssertTrue(IperfRunner.isRepeatDelivery(zeroDuration, zeroDuration))

        // The first delivery of a run has nothing to compare against.
        XCTAssertFalse(IperfRunner.isRepeatDelivery(nil, delivered))
        XCTAssertFalse(IperfRunner.isRepeatDelivery([], []))

        // A genuinely new interval starts where the previous one ended.
        let next = [
            stream(.download, start: 1.0035, end: 2.0030, bytes: 2_417_164_288),
            stream(.download, start: 1.0035, end: 2.0030, bytes: 2_417_164_288),
        ]
        XCTAssertFalse(IperfRunner.isRepeatDelivery(delivered, next))

        // A difference in any single identity field is a distinct delivery,
        // including one stream out of several disagreeing.
        let oneStreamDiffers = [
            delivered[0],
            stream(.download, start: 0, end: 1.0035, bytes: 2_483_290_113),
        ]
        XCTAssertFalse(IperfRunner.isRepeatDelivery(delivered, oneStreamDiffers))
        XCTAssertFalse(
            IperfRunner.isRepeatDelivery(
                zeroDuration,
                [stream(.upload, start: 6.005, end: 6.005, bytes: 901_644_288)]
            )
        )
        XCTAssertFalse(
            IperfRunner.isRepeatDelivery(
                zeroDuration,
                [stream(.download, start: 6.005, end: 6.006, bytes: 901_644_288)]
            )
        )

        // A stream count change is never a repeat.
        XCTAssertFalse(IperfRunner.isRepeatDelivery(delivered, [delivered[0]]))
    }

    func testTCPIntervalAggregationIsRepeatable() {
        var first = IperfStreamIntervalResult()
        first.bytesTransferred = 1_000
        first.intervalDuration = 2
        first.startTime = 10
        first.endTime = 12

        var second = IperfStreamIntervalResult()
        second.bytesTransferred = 2_000
        second.intervalDuration = 2
        second.startTime = 10
        second.endTime = 12

        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [first, second]
        result.evaulate()

        XCTAssertEqual(result.totalBytes, 3_000)
        XCTAssertEqual(result.duration, 2)
        XCTAssertEqual(result.startTime, 10)
        XCTAssertEqual(result.endTime, 12)
        XCTAssertEqual(result.throughput.rawValue, 1_500)

        result.evaulate()

        XCTAssertEqual(result.totalBytes, 3_000)
        XCTAssertEqual(result.throughput.rawValue, 1_500)
    }

    func testBidirectionalIntervalAggregationKeepsDirectionsSeparate() {
        var uploadStream = IperfStreamIntervalResult()
        uploadStream.direction = .upload
        uploadStream.bytesTransferred = 1_000
        uploadStream.intervalDuration = 2
        uploadStream.startTime = 10
        uploadStream.endTime = 12

        var downloadStream = IperfStreamIntervalResult()
        downloadStream.direction = .download
        downloadStream.bytesTransferred = 3_000
        downloadStream.intervalDuration = 2
        downloadStream.startTime = 10
        downloadStream.endTime = 12

        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [uploadStream, downloadStream]
        result.evaluate()

        XCTAssertEqual(result.upload.streams.count, 1)
        XCTAssertEqual(result.upload.totalBytes, 1_000)
        XCTAssertEqual(result.upload.throughput.rawValue, 500)
        XCTAssertEqual(result.download.streams.count, 1)
        XCTAssertEqual(result.download.totalBytes, 3_000)
        XCTAssertEqual(result.download.throughput.rawValue, 1_500)
        XCTAssertEqual(result.totalBytes, 4_000)
        XCTAssertEqual(result.throughput.rawValue, 2_000)
    }

    func testUDPIntervalAggregationCalculatesPacketLossAndJitter() {
        var first = IperfStreamIntervalResult()
        first.bytesTransferred = 1_000
        first.intervalDuration = 1
        first.intervalPacketCount = 100
        first.intervalCntError = 4
        first.intervalOutoforderPackets = 2
        first.jitter = 0.01

        var second = IperfStreamIntervalResult()
        second.bytesTransferred = 2_000
        second.intervalDuration = 1
        second.intervalPacketCount = 200
        second.intervalCntError = 6
        second.intervalOutoforderPackets = 3
        second.jitter = 0.03

        var result = IperfIntervalResult(prot: .udp)
        result.streams = [first, second]
        result.evaulate()

        XCTAssertEqual(result.totalBytes, 3_000)
        XCTAssertEqual(result.totalPackets, 300)
        XCTAssertEqual(result.totalLostPackets, 10)
        XCTAssertEqual(result.totalOutoforderPackets, 5)
        XCTAssertEqual(result.averageJitter, 0.02, accuracy: 0.000001)
    }

    func testErrorMappingAndResultErrorState() {
        XCTAssertEqual(IperfError(rawValue: 29), .IESKEWTHRESHOLD)
        XCTAssertEqual(
            IperfError.IESKEWTHRESHOLD.debugDescription,
            "Invalid value specified as skew threshold"
        )
        XCTAssertEqual(IperfError(rawValue: 30), .IEIDLETIMEOUT)
        XCTAssertEqual(
            IperfError.IEIDLETIMEOUT.debugDescription,
            "Idle timeout parameter is not positive or larger than allowed limit"
        )
        XCTAssertEqual(IperfError(rawValue: 31), .IERCVTIMEOUT)
        XCTAssertEqual(
            IperfError.IERCVTIMEOUT.debugDescription,
            "Receive timeout value is incorrect or not in range"
        )
        XCTAssertEqual(IperfError(rawValue: 32), .IERVRSONLYRCVTIMEOUT)
        XCTAssertEqual(
            IperfError.IERVRSONLYRCVTIMEOUT.debugDescription,
            "Client receive timeout is valid only in receiving mode"
        )
        XCTAssertEqual(IperfError(rawValue: 142), .IEAUTHTEST)
        XCTAssertEqual(IperfError.IEAUTHTEST.debugDescription, "Test authorization failed")
        XCTAssertEqual(IperfError(rawValue: 402), .IETCPONLY)
        XCTAssertEqual(IperfError.IETCPONLY.debugDescription, "This option is TCP only")
        XCTAssertEqual(IperfError(rawValue: 403), .IEUDPONLY)
        XCTAssertEqual(IperfError.IEUDPONLY.debugDescription, "This option is UDP only")
        XCTAssertEqual(IperfError(rawValue: 404), .IEIPV4ONLY)
        XCTAssertEqual(IperfError.IEIPV4ONLY.debugDescription, "This option is IPv4 only")
        XCTAssertEqual(IperfError(rawValue: 405), .IECONNECTTIMEOUT)
        XCTAssertEqual(
            IperfError.IECONNECTTIMEOUT.debugDescription,
            "Client connection timeout is invalid or out of range"
        )

        let success = IperfIntervalResult(error: .IENONE)
        let failure = IperfIntervalResult(error: .IEAUTHTEST)
        XCTAssertFalse(success.hasError)
        XCTAssertTrue(failure.hasError)
    }

    func testErrorConformsToStandardProtocols() {
        let error = IperfError.IEAUTHTEST
        let expected = "Test authorization failed"

        // Error: can be thrown and caught as IperfError.
        func throwing() throws { throw error }
        XCTAssertThrowsError(try throwing()) { thrown in
            XCTAssertEqual(thrown as? IperfError, error)
        }

        // LocalizedError: localizedDescription and errorDescription map to the message.
        XCTAssertEqual(error.errorDescription, expected)
        XCTAssertEqual((error as Error).localizedDescription, expected)

        // CustomStringConvertible / interpolation matches debugDescription.
        XCTAssertEqual(error.description, expected)
        XCTAssertEqual("\(error)", expected)
        XCTAssertEqual(error.debugDescription, expected)
    }

    func testPublicCodableEnumsRoundTrip() throws {
        // The public option enums advertise Codable so callers can persist a
        // chosen configuration. Pin the encoded form and the round trip so a
        // rename of a case is caught as a breaking change.
        func assertRoundTrips<T: Codable & Equatable>(
            _ value: T, encodesTo json: String,
            file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let encoder = JSONEncoder()
            let data = try encoder.encode([value])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\(json)]", file: file, line: line)
            let decoded = try JSONDecoder().decode([T].self, from: data)
            XCTAssertEqual(decoded, [value], file: file, line: line)
        }

        try assertRoundTrips(IperfProtocol.udp, encodesTo: "\"udp\"")
        try assertRoundTrips(IperfAddressFamily.ipv6, encodesTo: "\"ipv6\"")
        try assertRoundTrips(IperfTestMode.bidirectional, encodesTo: "\"bidirectional\"")
        try assertRoundTrips(IperfRole.server, encodesTo: "115")
        try assertRoundTrips(IperfDirection.download, encodesTo: "1")
    }

    func testDecodingRemovedSCTPProtocolFails() {
        // `IperfProtocol.sctp` was removed because Apple platforms cannot provide
        // SCTP. Decoding a configuration persisted before the removal must fail
        // loudly rather than silently fall back to another transport, which is
        // the documented breaking behavior of that change.
        let json = Data(#"["sctp"]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([IperfProtocol].self, from: json)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted for an unknown protocol, got \(error)")
            }
        }
    }

    private func unreachableClientConfiguration() -> IperfConfiguration {
        var configuration = IperfConfiguration()
        configuration.address = "invalid.invalid"
        return configuration
    }

    private func assertRunnerFails(
        _ configuration: IperfConfiguration,
        with expectedError: IperfError,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let failed = expectation(description: description)
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
        XCTAssertEqual(receivedError, expectedError, file: file, line: line)
        XCTAssertEqual(states.last, .error, file: file, line: line)
    }
}
