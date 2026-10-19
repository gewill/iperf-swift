import Darwin
import Foundation
import IperfCLib
import XCTest
@testable import IperfSwift

final class IperfOutputBudgetTests: XCTestCase {
    private func native(limit: Int, json: Bool = false) throws -> UnsafeMutablePointer<iperf_test> {
        let test = try XCTUnwrap(iperf_new_test())
        XCTAssertEqual(iperf_defaults(test), 0)
        iperf_set_test_role(test, IperfRole.server.rawValue)
        XCTAssertEqual(iperf_set_test_server_output_byte_limit(test, limit), 0)
        if json {
            iperf_set_test_json_output(test, 1)
            XCTAssertEqual(iperf_json_start(test), 0)
        }
        addTeardownBlock {
            iperf_free_test(test)
        }
        return test
    }

    private func collect(_ text: String, into test: UnsafeMutablePointer<iperf_test>) {
        text.withCString { pointer in
            withVaList([pointer]) { arguments in
                iperf_output_collect_printf(test, nil, "%s", arguments)
            }
        }
    }

    private func results(_ test: UnsafeMutablePointer<iperf_test>) throws -> [String: Any] {
        let object = try XCTUnwrap(cJSON_CreateObject())
        defer { cJSON_Delete(object) }
        XCTAssertEqual(iperf_output_add_server_results(test, object), 0)
        let printed = try XCTUnwrap(cJSON_PrintUnformatted(object))
        defer { cJSON_free(printed) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: printed).utf8)) as? [String: Any])
    }

    func testTextCollectionKeepsScalarPrefixAndExactObservedBytes() throws {
        for (limit, expected) in [(1, "A"), (2, "A"), (3, "Aé"), (6, "Aé"), (7, "Aé🙂"), (8, "Aé🙂Z")] {
            let test = try native(limit: limit)
            collect("Aé🙂Z", into: test)
            collect("tail", into: test)
            XCTAssertEqual(test.pointee.collected_server_output.length, expected.utf8.count)
            XCTAssertEqual(test.pointee.collected_server_output.observed_bytes, 12)
            XCTAssertEqual(test.pointee.collected_server_output.state, IPERF_OUTPUT_TRUNCATED)
            XCTAssertEqual(try results(test)["server_output_text"] as? String, expected)
            collect("after exchange", into: test)
            XCTAssertEqual(test.pointee.collected_server_output.observed_bytes, 12, "finalized output is immutable")
        }
    }

    func testLongLineDoesNotUseLegacy1024ByteCollectionBuffer() throws {
        let test = try native(limit: 8192)
        collect(String(repeating: "abcdef", count: 100_000), into: test)
        XCTAssertEqual(test.pointee.collected_server_output.length, 8192)
        XCTAssertEqual(test.pointee.collected_server_output.observed_bytes, 600_000)
        XCTAssertNil(test.pointee.server_output_list.tqh_first)
        XCTAssertEqual((try results(test)["server_output_text"] as? String)?.utf8.count, 8192)
    }

    func testJSONCollectorKeepsNoNativeHistoryAndFinalizesOnce() throws {
        let test = try native(limit: 4096, json: true)
        let interval = try XCTUnwrap(cJSON_Parse(#"{"streams":[{"bytes":123456,"seconds":1}]}"#))
        defer { cJSON_Delete(interval) }
        for _ in 0..<3 { iperf_output_collect_interval(test, interval) }
        XCTAssertEqual(cJSON_GetArraySize(test.pointee.json_intervals), 0)
        let first = try results(test)
        let second = try results(test)
        let json = try XCTUnwrap(first["server_output_json"] as? [String: Any])
        XCTAssertEqual((json["intervals"] as? [Any])?.count, 3)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: first, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: second, options: .sortedKeys))
        XCTAssertEqual(test.pointee.collected_server_output.state, IPERF_OUTPUT_COMPLETE)
        XCTAssertEqual(cJSON_GetArraySize(test.pointee.json_intervals), 0)
    }

    func testOversizedJSONIsDiscardedWithoutPartialPayload() throws {
        let test = try native(limit: 64, json: true)
        let interval = try XCTUnwrap(cJSON_Parse(#"{"streams":[{"bytes":123456,"seconds":1}]}"#))
        defer { cJSON_Delete(interval) }
        for _ in 0..<50 { iperf_output_collect_interval(test, interval) }
        let object = try results(test)
        XCTAssertNil(object["server_output_json"])
        XCTAssertNil(test.pointee.collected_server_output.value)
        XCTAssertEqual(test.pointee.collected_server_output.state, IPERF_OUTPUT_DISCARDED)
        XCTAssertEqual(test.pointee.collected_server_output.reason, IPERF_OUTPUT_BYTE_LIMIT)
        XCTAssertEqual(test.pointee.collected_server_output.observed_bytes_complete, 0)
        XCTAssertEqual(cJSON_GetArraySize(test.pointee.json_intervals), 0)
    }

    func testJSONDepthBoundaryIncludesTheResultEnvelope() throws {
        for (arrays, accepted) in [(61, true), (62, false)] {
            let test = try native(limit: 4096, json: true)
            let text = String(repeating: "[", count: arrays) + "0" + String(repeating: "]", count: arrays)
            let interval = try XCTUnwrap(cJSON_Parse(text))
            defer { cJSON_Delete(interval) }
            iperf_output_collect_interval(test, interval)
            XCTAssertEqual(test.pointee.collected_server_output.state,
                           accepted ? IPERF_OUTPUT_COMPLETE : IPERF_OUTPUT_DISCARDED)
            if accepted {
                XCTAssertNotNil(try results(test)["server_output_json"])
            } else {
                XCTAssertEqual(test.pointee.collected_server_output.reason, IPERF_OUTPUT_DEPTH_LIMIT)
            }
        }
    }

    func testJSONNodeAndDepthBudgetsDiscardWithoutRetainingATree() throws {
        for deep in [false, true] {
            let test = try native(limit: 1_048_576, json: true)
            let text = deep ? String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
                : "[" + Array(repeating: "0", count: 16_384).joined(separator: ",") + "]"
            let interval = try XCTUnwrap(cJSON_Parse(text))
            defer { cJSON_Delete(interval) }
            iperf_output_collect_interval(test, interval)
            XCTAssertEqual(test.pointee.collected_server_output.state, IPERF_OUTPUT_DISCARDED)
            XCTAssertEqual(test.pointee.collected_server_output.reason, deep ? IPERF_OUTPUT_DEPTH_LIMIT : IPERF_OUTPUT_NODE_LIMIT)
            XCTAssertNil(test.pointee.collected_server_output.value)
            XCTAssertEqual(cJSON_GetArraySize(test.pointee.json_intervals), 0)
        }
    }

    func testPeerMetadataCannotUpgradeLocallyInvalidOrTruncatedOutput() throws {
        let test = try native(limit: 3)
        collect("abcdef", into: test)
        for state in [IPERF_OUTPUT_TRUNCATED, IPERF_OUTPUT_INVALID] {
            var output = iperf_server_output()
            output.state = state
            output.format = IPERF_OUTPUT_TEXT
            output.reason = state == IPERF_OUTPUT_INVALID ? IPERF_OUTPUT_INVALID_DATA : IPERF_OUTPUT_BYTE_LIMIT
            let peer = try XCTUnwrap(cJSON_Parse(#"{"iperf_swift_server_output":{"version":1,"state":1,"format":1,"reason":0,"observed_bytes":10}}"#))
            defer { cJSON_Delete(peer) }
            iperf_output_apply_peer_status(&output, peer)
            XCTAssertEqual(output.state, state)
        }
        for text in [
            #"{"version":1,"state":2,"format":2,"reason":1}"#,
            #"{"version":1,"version":1,"state":1,"format":1,"reason":0}"#,
            #"{"version":1,"state":1,"format":1,"reason":1}"#
        ] {
            var output = iperf_server_output()
            output.state = IPERF_OUTPUT_COMPLETE
            output.format = IPERF_OUTPUT_TEXT
            let peer = try XCTUnwrap(cJSON_Parse("{\"iperf_swift_server_output\":" + text + "}"))
            defer { cJSON_Delete(peer); iperf_clear_server_output(&output) }
            iperf_output_apply_peer_status(&output, peer)
            XCTAssertEqual(output.state, IPERF_OUTPUT_INVALID)
        }
    }

    func testNativeResultExchangeUsesBudgetAndPeerStatusAfterNormalCompletion() throws {
        let core = #""cpu_util_total":1,"cpu_util_user":0.5,"cpu_util_system":0.5,"sender_has_retransmits":0,"streams":[]"#
        for (field, expected, payload) in [
            ("", IPERF_OUTPUT_MISSING, nil as String?),
            (#", "server_output_text":"""#, IPERF_OUTPUT_COMPLETE, ""),
            (#", "server_output_text":"a","iperf_swift_server_output":{"version":1,"state":2,"format":1,"reason":1,"observed_bytes":1000}"#, IPERF_OUTPUT_TRUNCATED, "a"),
            (#", "iperf_swift_server_output":{"version":1,"state":3,"format":2,"reason":1}"#, IPERF_OUTPUT_DISCARDED, nil),
            (#", "server_output_text":123"#, IPERF_OUTPUT_INVALID, nil)
        ] {
            let test = try native(limit: 64)
            iperf_set_test_role(test, IperfRole.client.rawValue)
            iperf_set_test_get_server_output(test, 1)
            test.pointee.done = 1 // Normal measurement completion, not explicit stop.
            var sockets: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
            defer { close(sockets[0]); close(sockets[1]); test.pointee.ctrl_sck = -1; iperf_set_error(0) }
            test.pointee.ctrl_sck = sockets[0]
            let body = Data(("{" + core + field + "}").utf8)
            var length = UInt32(body.count).bigEndian
            let frame = withUnsafeBytes(of: &length) { Data($0) } + body
            XCTAssertEqual(frame.withUnsafeBytes { send(sockets[1], $0.baseAddress, frame.count, 0) }, frame.count)
            XCTAssertEqual(iperf_exchange_results(test), 0)
            XCTAssertEqual(test.pointee.remote_cpu_util.0, 1)
            XCTAssertEqual(test.pointee.received_server_output_ready, 1)
            XCTAssertEqual(test.pointee.received_server_output.state, expected)
            XCTAssertEqual(test.pointee.received_server_output.value.map { String(cString: $0) }, payload)
            XCTAssertNil(test.pointee.server_output_text)
            XCTAssertNil(test.pointee.json_server_output)
            XCTAssertEqual(fcntl(sockets[0], F_GETFL) & O_NONBLOCK, 0)
        }
    }

    func testNativeResultExchangeRejectsOversizedAndMalformedFrames() throws {
        for oversized in [false, true] {
            let test = try native(limit: 64)
            iperf_set_test_role(test, IperfRole.client.rawValue)
            iperf_set_test_get_server_output(test, 1)
            test.pointee.done = 1
            var sockets: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
            defer { close(sockets[0]); close(sockets[1]); test.pointee.ctrl_sck = -1; iperf_set_error(0) }
            test.pointee.ctrl_sck = sockets[0]
            let body = Data("not-json".utf8)
            var length = (oversized ? UInt32.max : UInt32(body.count)).bigEndian
            let frame = withUnsafeBytes(of: &length) { Data($0) } + body
            XCTAssertEqual(frame.withUnsafeBytes { send(sockets[1], $0.baseAddress, frame.count, 0) }, frame.count)
            XCTAssertEqual(iperf_exchange_results(test), -1)
            XCTAssertEqual(iperf_get_error(), Int32(IERECVRESULTS))
            XCTAssertEqual(test.pointee.received_server_output.state, IPERF_OUTPUT_INVALID)
            XCTAssertNil(test.pointee.received_server_output.value)
            XCTAssertEqual(test.pointee.output_read_metrics.bytes_read, oversized ? 0 : UInt64(body.count))
        }
    }

    func testResetReclaimsUnfinishedJSONBeforePersistentRestart() throws {
        let test = try native(limit: 4096, json: true)
        for _ in 0..<20 {
            let interval = try XCTUnwrap(cJSON_Parse("{\"bytes\":123}"))
            iperf_output_collect_interval(test, interval)
            cJSON_Delete(interval)
            iperf_output_budget_reset(test)
            XCTAssertNil(test.pointee.json_top)
            XCTAssertNil(test.pointee.json_intervals)
            XCTAssertNil(test.pointee.json_start)
            XCTAssertNil(test.pointee.json_end)
            XCTAssertNil(test.pointee.collected_server_output.value)
            XCTAssertNil(test.pointee.output_scratch)
            XCTAssertEqual(iperf_json_start(test), 0)
        }
    }

    func testResetReleasesBuffersWithoutErasingExplicitStop() throws {
        let test = try native(limit: 64)
        collect("abc", into: test)
        iperf_request_test_stop(test)
        iperf_output_budget_reset(test)
        XCTAssertNil(test.pointee.collected_server_output.value)
        XCTAssertNil(test.pointee.output_scratch)
        XCTAssertEqual(iperf_output_stop_requested(test), 1)
        XCTAssertEqual(test.pointee.server_output_byte_limit, 64)
    }

    func testInvalidBudgetAndFullHistoryFailBeforeEngineStarts() {
        for (limit, full) in [(-1, false), (0, false), (1_048_577, false), (256, true)] {
            var config = IperfConfiguration()
            config.serverOutputByteLimit = limit
            config.jsonStream = full
            config.jsonStreamFullOutput = full
            let runner = IperfRunner(with: config)
            let failed = expectation(description: "invalid output configuration")
            runner.start({ _ in XCTFail("invalid configuration ran") }, { error in
                XCTAssertEqual(error, .IESERVEROUTPUTLIMIT)
                failed.fulfill()
            }, { state in XCTAssertNotEqual(state, .running) })
            wait(for: [failed], timeout: 2)
        }
    }
}
