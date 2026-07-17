import XCTest
@testable import IperfSwift

final class IperfSwiftUnitTests: XCTestCase {
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
}
