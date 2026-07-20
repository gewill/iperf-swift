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

    private func unreachableClientConfiguration() -> IperfConfiguration {
        var configuration = IperfConfiguration()
        configuration.address = "invalid.invalid"
        return configuration
    }
}
