import XCTest

// Deliberately not `@testable`. These tests see only what a consumer of the
// package sees, so an initializer or property that silently loses `public`
// fails the build here rather than in a downstream app.
import IperfSwift

final class IperfPublicAPITests: XCTestCase {
    func testSyntheticStreamDerivesDurationFromTimestamps() {
        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [
            IperfStreamIntervalResult(
                bytesTransferred: 1_000_000,
                startTime: 10,
                endTime: 11
            ),
        ]

        result.evaluate()

        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        XCTAssertEqual(result.throughput.rawValue, 1_000_000, accuracy: 0.001)
    }

    @available(*, deprecated, message: "Exercises the deprecated compatibility initializer.")
    func testDeprecatedDurationCannotContradictTimestamps() {
        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [
            IperfStreamIntervalResult(
                bytesTransferred: 500_000,
                intervalDuration: 99,
                startTime: 20,
                endTime: 21
            ),
        ]

        result.evaluate()

        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        XCTAssertEqual(result.throughput.rawValue, 500_000, accuracy: 0.001)
    }

    func testSyntheticStreamsAggregateTheSameWayEngineStreamsDo() {
        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [
            IperfStreamIntervalResult(
                direction: .upload,
                bytesTransferred: 1_000_000,
                startTime: 344_987,
                endTime: 344_988
            ),
            IperfStreamIntervalResult(
                direction: .upload,
                bytesTransferred: 500_000,
                startTime: 344_987,
                endTime: 344_988
            ),
        ]

        result.evaluate()

        XCTAssertEqual(result.totalBytes, 1_500_000)
        XCTAssertEqual(result.throughput.rawValue, 1_500_000, accuracy: 0.001)
        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        // Interval times stay on the clock the caller supplied. The engine
        // reports them from a monotonic clock, so an absolute-looking value is
        // the realistic case rather than an oddity.
        XCTAssertEqual(result.startTime, 344_987, accuracy: 0.001)
        XCTAssertEqual(result.endTime, 344_988, accuracy: 0.001)
        XCTAssertEqual(result.upload.totalBytes, 1_500_000)
        XCTAssertEqual(result.download.totalBytes, 0)
    }

    func testDirectionSplitsSyntheticStreamsIntoTheirOwnAggregates() {
        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [
            IperfStreamIntervalResult(
                direction: .upload,
                bytesTransferred: 400_000,
                startTime: 10,
                endTime: 11
            ),
            IperfStreamIntervalResult(
                direction: .download,
                bytesTransferred: 900_000,
                startTime: 10,
                endTime: 11
            ),
        ]

        result.evaluate()

        XCTAssertEqual(result.totalBytes, 1_300_000)
        XCTAssertEqual(result.upload.totalBytes, 400_000)
        XCTAssertEqual(result.download.totalBytes, 900_000)
        XCTAssertEqual(result.upload.throughput.rawValue, 400_000, accuracy: 0.001)
        XCTAssertEqual(result.download.throughput.rawValue, 900_000, accuracy: 0.001)
    }

    func testUDPCountersAggregateAcrossSyntheticStreams() {
        var result = IperfIntervalResult(prot: .udp)
        result.streams = [
            IperfStreamIntervalResult(
                direction: .download,
                bytesTransferred: 120_000,
                startTime: 5,
                endTime: 6,
                intervalPacketCount: 100,
                intervalCntError: 5,
                intervalOutoforderPackets: 2,
                jitter: 0.004
            ),
            IperfStreamIntervalResult(
                direction: .download,
                bytesTransferred: 60_000,
                startTime: 5,
                endTime: 6,
                intervalPacketCount: 50,
                intervalCntError: 1,
                intervalOutoforderPackets: 3,
                jitter: 0.002
            ),
        ]

        result.evaluate()

        XCTAssertEqual(result.totalPackets, 150)
        XCTAssertEqual(result.totalLostPackets, 6)
        XCTAssertEqual(result.totalOutoforderPackets, 5)
        XCTAssertEqual(result.averageJitter, 0.003, accuracy: 1e-9)
        XCTAssertEqual(result.download.averageJitter, 0.003, accuracy: 1e-9)
    }

    func testTCPResultsIgnoreUDPCountersJustAsTheEngineDoes() {
        var result = IperfIntervalResult(prot: .tcp)
        result.streams = [
            IperfStreamIntervalResult(
                direction: .upload,
                bytesTransferred: 200_000,
                startTime: 0,
                endTime: 1,
                intervalPacketCount: 100,
                intervalCntError: 7,
                intervalOutoforderPackets: 3,
                jitter: 0.5
            ),
        ]

        result.evaluate()

        // `computeIntervalAggregate` sums the packet counters only for UDP.
        // Supplying them on a TCP result must not invent statistics the
        // protocol does not carry.
        XCTAssertEqual(result.totalBytes, 200_000)
        XCTAssertEqual(result.totalPackets, 0)
        XCTAssertEqual(result.totalLostPackets, 0)
        XCTAssertEqual(result.totalOutoforderPackets, 0)
        XCTAssertEqual(result.averageJitter, 0)
    }

    func testAnEmptyStreamListLeavesAggregatesAtZero() {
        var result = IperfIntervalResult(prot: .tcp)
        result.streams = []

        result.evaluate()

        XCTAssertEqual(result.totalBytes, 0)
        XCTAssertEqual(result.throughput.rawValue, 0)
        XCTAssertEqual(result.duration, 0)
    }
}
