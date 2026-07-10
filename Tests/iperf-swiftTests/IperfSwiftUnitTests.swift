import XCTest
@testable import IperfSwift

final class IperfSwiftUnitTests: XCTestCase {
    func testConfigurationDefaultsAndCustomNetworkSettings() {
        var configuration = IperfConfiguration()

        XCTAssertEqual(configuration.role, .client)
        XCTAssertEqual(configuration.reverse, .download)
        XCTAssertEqual(configuration.prot, .tcp)
        XCTAssertFalse(configuration.isAuth)
        XCTAssertNil(configuration.bindDevice)
        XCTAssertNil(configuration.dscp)

        configuration.bindDevice = "lo0"
        configuration.dscp = 46

        XCTAssertEqual(configuration.bindDevice, "lo0")
        XCTAssertEqual(configuration.dscp, 46)
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
