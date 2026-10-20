import Foundation
import IperfSwift
import XCTest

final class IperfRunCompletionTests: XCTestCase {
    func testValidationFailureCompletesOnceAndCanRestartFromReleaseCallback() throws {
        let released = expectation(description: "both generations released")
        released.expectedFulfillmentCount = 2
        var configuration = IperfConfiguration()
        configuration.logfileByteLimit = 1
        let runner = IperfRunner(with: configuration)
        var events: [String] = []
        var completions: [IperfRunCompletion] = []
        let lock = NSLock()
        runner.start({ _ in XCTFail("invalid run produced a measurement") }, { error in
            XCTAssertEqual(error, .IELOGFILELIMIT)
            lock.lock(); events.append("error-1"); lock.unlock()
        }, { _ in }, onResourcesReleased: { first in
            XCTAssertNil(first.logfile)
            XCTAssertEqual(runner.completion, first)
            lock.lock(); events.append("release-1"); completions.append(first); lock.unlock()
            var next = IperfConfiguration()
            next.port = 0
            runner.start(with: next, { _ in XCTFail("invalid run produced a measurement") }, { error in
                XCTAssertEqual(error, .IEBADPORT)
                lock.lock(); events.append("error-2"); lock.unlock()
            }, { _ in }, onResourcesReleased: { second in
                XCTAssertNil(second.logfile)
                XCTAssertEqual(runner.completion, second)
                lock.lock(); events.append("release-2"); completions.append(second); lock.unlock()
                released.fulfill()
            })
            released.fulfill()
        })
        wait(for: [released], timeout: 3)
        runner.stop()
        runner.stop()
        _ = runner.completion // Drain both queued no-op stops.
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(events, ["error-1", "release-1", "error-2", "release-2"])
        XCTAssertEqual(Set(completions.map(\.runID)).count, 2)
    }

    func testLimitRequiresAPathAndRoomForMarker() {
        for (path, limit) in [(nil, IperfConfiguration.minimumLogfileByteLimit),
                              ("unused", 0), ("unused", IperfConfiguration.minimumLogfileByteLimit - 1)] {
            var configuration = IperfConfiguration()
            configuration.logfile = path
            configuration.logfileByteLimit = limit
            let runner = IperfRunner(with: configuration)
            let released = expectation(description: "invalid logfile configuration released")
            runner.start({ _ in XCTFail("unexpected result") }, { error in
                XCTAssertEqual(error, .IELOGFILELIMIT)
            }, { _ in }, onResourcesReleased: { completion in
                XCTAssertNil(completion.logfile)
                released.fulfill()
            })
            wait(for: [released], timeout: 3)
        }
    }
}
