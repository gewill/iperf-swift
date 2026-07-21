import XCTest
@testable import IperfSwift

final class iperf_swiftTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
//        XCTAssertEqual(iperf_swift().text, "Hello, World!")
    }

    func testServerRejectsInvalidAuthenticationBeforeNetworking() {
        var serverConfiguration = IperfConfiguration()
        serverConfiguration.role = .server
        serverConfiguration.address = "invalid.invalid"
        serverConfiguration.isAuth = true
        serverConfiguration.privateKey = "invalid-private-key"
        serverConfiguration.authorizedUsers = "user,passwordHash\n"

        let server = IperfRunner(with: serverConfiguration)
        let rejected = expectation(description: "invalid authentication is rejected")
        var receivedError: IperfError?
        var states: [IperfRunnerState] = []

        server.start(
            { _ in },
            { error in
                receivedError = error
                rejected.fulfill()
            },
            { state in
                states.append(state)
            }
        )

        wait(for: [rejected], timeout: 2.0)
        XCTAssertEqual(receivedError, .IESETSERVERAUTH)
        XCTAssertEqual(states.last, .error)
    }

//    static var allTests = [
//        ("testExample", testExample),
//    ]
}
