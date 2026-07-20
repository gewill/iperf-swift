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
            ("clientPort", { $0.clientPort = 5_203 }),
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
}
