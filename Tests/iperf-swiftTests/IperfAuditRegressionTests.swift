import XCTest
import IperfCLib
@testable import IperfSwift

final class IperfAuditRegressionTests: XCTestCase {
    func testCIntervalTimestampsPreserveMicrosecondsAcrossSecondBoundaries() {
        var interval = iperf_interval_results()
        interval.interval_start_time = iperf_time(secs: 123, usecs: 999_999)
        interval.interval_end_time = iperf_time(secs: 124, usecs: 1)
        interval.interval_duration = 0.000002

        let result = IperfStreamIntervalResult(interval)
        XCTAssertEqual(result.startTime, 123.999999, accuracy: 0.000000001)
        XCTAssertEqual(result.endTime, 124.000001, accuracy: 0.000000001)
        XCTAssertEqual(result.intervalTimeDiff, 0.000002, accuracy: 0.000000000001)
        XCTAssertEqual(result.intervalDuration, Double(interval.interval_duration))
    }

    func testCIntervalWithEqualTimestampsHasZeroElapsedTime() {
        var interval = iperf_interval_results()
        interval.interval_start_time = iperf_time(secs: 123, usecs: 456_789)
        interval.interval_end_time = interval.interval_start_time

        let result = IperfStreamIntervalResult(interval)
        XCTAssertEqual(result.intervalTimeDiff, 0)
        XCTAssertEqual(result.startTime, result.endTime)
    }
}
