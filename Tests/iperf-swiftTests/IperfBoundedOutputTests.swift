import Darwin
import Foundation
import IperfCLib
import XCTest

private final class ResultInput {
    let bytes: Data
    let fragment: Int
    var offset = 0
    var calls = 0
    var largestRequest = 0
    var failureAt: Int?
    var failure: Int32 = ECANCELED

    init(_ bytes: Data, fragment: Int = 4096) {
        self.bytes = bytes
        self.fragment = fragment
    }
}

private func readResultInput(_ context: UnsafeMutableRawPointer?, _ destination: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int32 {
    let input = Unmanaged<ResultInput>.fromOpaque(context!).takeUnretainedValue()
    input.calls += 1
    input.largestRequest = max(input.largestRequest, capacity)
    if let failureAt = input.failureAt, input.offset >= failureAt {
        errno = input.failure
        return -1
    }
    let count = min(capacity, input.fragment, input.bytes.count - input.offset)
    input.bytes.copyBytes(to: destination!, from: input.offset..<(input.offset + count))
    input.offset += count
    return Int32(count)
}

private final class CancelDeadline {
    let instant = DispatchTime.now().uptimeNanoseconds + 25_000_000
}

private func cancelResultRead(_ context: UnsafeMutableRawPointer?) -> Int32 {
    let deadline = Unmanaged<CancelDeadline>.fromOpaque(context!).takeUnretainedValue()
    return DispatchTime.now().uptimeNanoseconds >= deadline.instant ? 1 : 0
}

final class IperfBoundedOutputTests: XCTestCase {
    // Same final-control fields used by the CLI; the optional output can occur
    // before the measurements, so truncation must not discard later statistics.
    private let statistics = #""cpu_util_total":1,"cpu_util_user":0.5,"cpu_util_system":0.5,"sender_has_retransmits":1,"streams":[{"id":1,"bytes":123456,"retransmits":2,"jitter":0.001,"errors":3,"packets":100,"start_time":0,"end_time":1}]"#

    private struct Parsed {
        let core: [String: Any]?
        let text: String?
        let state: iperf_output_state
        let format: iperf_output_format
        let observed: UInt64
        let error: Int32
        let metrics: iperf_result_read_metrics
    }

    private func parsed(_ input: ResultInput, limit: Int = 256, declared: UInt32? = nil) throws -> Parsed {
        var output = iperf_server_output()
        var metrics = iperf_result_read_metrics()
        errno = 0
        let tree = iperf_read_bounded_results(declared ?? UInt32(input.bytes.count), limit, readResultInput,
            Unmanaged.passUnretained(input).toOpaque(), &output, &metrics)
        let error = errno
        defer { cJSON_Delete(tree); iperf_clear_server_output(&output) }
        var core: [String: Any]?
        if let tree {
            let raw = try XCTUnwrap(cJSON_PrintUnformatted(tree))
            defer { cJSON_free(raw) }
            core = try JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any]
        }
        return Parsed(core: core, text: output.value.map { String(cString: $0) }, state: output.state,
            format: output.format, observed: output.observed_bytes, error: error, metrics: metrics)
    }

    private func parsed(_ text: String, limit: Int = 256, fragment: Int = 4096) throws -> Parsed {
        try parsed(ResultInput(Data(text.utf8), fragment: fragment), limit: limit)
    }

    private func assertStatistics(_ result: Parsed, file: StaticString = #filePath, line: UInt = #line) throws {
        let core = try XCTUnwrap(result.core, file: file, line: line)
        let stream = try XCTUnwrap((core["streams"] as? [[String: Any]])?.first, file: file, line: line)
        XCTAssertEqual(stream["bytes"] as? Int, 123456, file: file, line: line)
        XCTAssertEqual(stream["packets"] as? Int, 100, file: file, line: line)
        XCTAssertEqual(stream["retransmits"] as? Int, 2, file: file, line: line)
        XCTAssertNil(core["server_output_text"], file: file, line: line)
        XCTAssertNil(core["server_output_json"], file: file, line: line)
    }

    func testFragmentedTextPreservesScalarsAndFollowingStatistics() throws {
        let payload = #"{"server_output_text":"A\u00e9\ud83d\ude42Z","# + statistics + "}"
        for fragment in [1, 3, 4096] {
            for (limit, expected) in [(1, "A"), (2, "A"), (3, "Aé"), (6, "Aé"), (7, "Aé🙂"), (8, "Aé🙂Z"), (9, "Aé🙂Z")] {
                let result = try parsed(payload, limit: limit, fragment: fragment)
                try assertStatistics(result)
                XCTAssertEqual(result.text, expected)
                XCTAssertEqual(result.observed, 8)
                XCTAssertEqual(result.state, limit < 8 ? IPERF_OUTPUT_TRUNCATED : IPERF_OUTPUT_COMPLETE)
                XCTAssertEqual(result.format, IPERF_OUTPUT_TEXT)
            }
        }
    }

    func testEmptyMissingAndInvalidOptionalOutputAreDistinct() throws {
        let absent = try parsed("{" + statistics + "}")
        XCTAssertEqual(absent.state, IPERF_OUTPUT_MISSING)
        XCTAssertNil(absent.text)
        for (field, state, text) in [
            (#""server_output_text":"""#, IPERF_OUTPUT_COMPLETE, "" as String?),
            (#""server_output_text":null"#, IPERF_OUTPUT_INVALID, nil),
            (#""server_output_text":123"#, IPERF_OUTPUT_INVALID, nil),
            (#""server_output_json":[]"#, IPERF_OUTPUT_INVALID, nil),
            (#""server_output_text":"ab\u0000cd""#, IPERF_OUTPUT_INVALID, nil)
        ] {
            let result = try parsed("{" + field + "," + statistics + "}")
            try assertStatistics(result)
            XCTAssertEqual(result.state, state)
            XCTAssertEqual(result.text, text)
        }
    }

    func testJSONIsCompleteOrDiscardedAndPreferredInEitherOrder() throws {
        let json = #"{"note":"é", "array": [1, true, null]}"#
        let compact = #"{"note":"é","array":[1,true,null]}"#
        for limit in [compact.utf8.count - 1, compact.utf8.count, compact.utf8.count + 1] {
            for fields in [#""server_output_text":"ignored","server_output_json":"# + json,
                           #""server_output_json":"# + json + #","server_output_text":"ignored""#] {
                let result = try parsed("{" + fields + "," + statistics + "}", limit: limit, fragment: 1)
                try assertStatistics(result)
                XCTAssertEqual(result.format, IPERF_OUTPUT_JSON)
                XCTAssertEqual(result.state, limit < compact.utf8.count ? IPERF_OUTPUT_DISCARDED : IPERF_OUTPUT_COMPLETE)
                XCTAssertEqual(result.text, limit < compact.utf8.count ? nil : compact)
                XCTAssertEqual(result.observed, UInt64(compact.utf8.count))
                if let text = result.text { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8))) }
            }
        }
    }

    func testLargeOptionalOutputDoesNotBecomeAFrameSizedBuffer() throws {
        for json in [false, true] {
            let large = String(repeating: "é", count: 2_000_000)
            let field = json ? #""server_output_json":{"data":""# + large + #""}"# : #""server_output_text":""# + large + #"""#
            let input = ResultInput(Data(("{" + field + "," + statistics + "}").utf8), fragment: 997)
            let result = try parsed(input, limit: 256)
            try assertStatistics(result)
            XCTAssertEqual(result.state, json ? IPERF_OUTPUT_DISCARDED : IPERF_OUTPUT_TRUNCATED)
            XCTAssertEqual(result.text, json ? nil : String(repeating: "é", count: 128))
            XCTAssertEqual(input.offset, input.bytes.count)
            XCTAssertLessThanOrEqual(input.largestRequest, 4096)
            XCTAssertLessThanOrEqual(result.metrics.peak_buffer_capacity, Int(IPERF_RESULT_CORE_MAX_BYTES) + 258)
            XCTAssertLessThan(result.metrics.core_json_bytes, 512)
        }
    }

    func testEscapedOutputKeyAndUnknownCoreFields() throws {
        let result = try parsed(#"{"server_output_\u0074ext":"quote: \" slash: \\ newline: \n","future":{"flag":true},"# + statistics + "}", fragment: 1)
        try assertStatistics(result)
        XCTAssertEqual(result.text, "quote: \" slash: \\ newline: \n")
        XCTAssertEqual((result.core?["future"] as? [String: Bool])?["flag"], true)
    }

    func testMalformedJSONAndUnicodeCannotDeliverPartialOutput() throws {
        let invalid = ["", "[]", "null", "{", "{}x", "{}{}", "{,}", #"{"x":1,}"#, #"{"x":[1,]}"#,
            #"{"x":01}"#, #"{"x":+1}"#, #"{"x":.1}"#, #"{"x":1.}"#, #"{"x":1e}"#,
            #"{"x":NaN}"#, #"{"x":tru}"#, #"{"x":"\q"}"#, #"{"x":"\uD800"}"#,
            #"{"x":"\uDC00"}"#, #"{"x":"\uD800\u0041"}"#,
            #"{"x":{"id\u0000hidden":1}}"#,
            #"{"streams":[],"STREAMS":[]}"#,
            #"{"server_output_text":"a","server_output_\u0074ext":"b"}"#]
        for text in invalid {
            let result = try parsed(text, fragment: 1)
            XCTAssertNil(result.core, text)
            XCTAssertNil(result.text, text)
            XCTAssertEqual(result.state, IPERF_OUTPUT_INVALID, text)
        }
        for bytes: [UInt8] in [[0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x82], [0x01]] {
            // Invalid bytes must still fail after the optional prefix filled.
            let data = Data(#"{"server_output_text":"full"#.utf8) + Data(bytes) + Data(#""}"#.utf8)
            let result = try parsed(ResultInput(data, fragment: 1), limit: 1)
            XCTAssertNil(result.core)
            XCTAssertNil(result.text)
            XCTAssertEqual(result.error, EPROTO)
        }
    }

    func testCoreByteAndDepthBudgetsHaveExactBoundaries() throws {
        let cap = Int(IPERF_RESULT_CORE_MAX_BYTES)
        for size in [cap - 1, cap, cap + 1] {
            let result = try parsed(#"{"x":""# + String(repeating: "a", count: size - 8) + #""}"#)
            XCTAssertEqual(result.core != nil, size <= cap)
            if size > cap { XCTAssertEqual(result.error, EFBIG) }
        }
        for depth in [63, 64, 65] {
            let result = try parsed(#"{"x":"# + String(repeating: "[", count: depth - 1) + "0" + String(repeating: "]", count: depth - 1) + "}")
            XCTAssertEqual(result.core != nil, depth <= 64)
            if depth > 64 { XCTAssertEqual(result.error, EFBIG) }
        }
    }

    func testMaximumBidirectionalStreamShapeFitsCoreBudget() throws {
        // send_results emits one object per stream; Both can create twice the
        // requested MAX_STREAMS. This checks the schema budget, not real traffic.
        let streams: [[String: Any]] = (1...(Int(MAX_STREAMS) * 2)).map { id in
            ["id": id, "bytes": 123_456_789_012, "retransmits": 42,
             "jitter": 0.001, "errors": 3, "omitted_errors": 1,
             "packets": 100, "omitted_packets": 10, "start_time": 0,
             "end_time": 30.5]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "cpu_util_total": 2, "cpu_util_user": 1, "cpu_util_system": 1,
            "sender_has_retransmits": 1, "streams": streams
        ])
        let result = try parsed(ResultInput(data, fragment: 17))
        let received = try XCTUnwrap(result.core?["streams"] as? [[String: Any]])
        XCTAssertEqual(received.count, 256)
        XCTAssertEqual(received.last?["bytes"] as? Int, 123_456_789_012)
        XCTAssertLessThan(result.metrics.core_json_bytes, Int(IPERF_RESULT_CORE_MAX_BYTES))
        XCTAssertLessThan(result.metrics.core_values, Int(IPERF_RESULT_CORE_MAX_VALUES))
    }

    func testNodeBudgetDiscardsOptionalTreeButRejectsOversizedCore() throws {
        let cap = Int(IPERF_RESULT_CORE_MAX_VALUES)
        for count in [cap - 2, cap - 1, cap] {
            let array = "[" + Array(repeating: "0", count: count).joined(separator: ",") + "]"
            let core = try parsed(#"{"x":"# + array + "}")
            XCTAssertEqual(core.core != nil, count + 1 <= cap)
            let optional = try parsed(#"{"server_output_json":{"x":"# + array + "}," + statistics + "}", limit: 100_000)
            try assertStatistics(optional)
            XCTAssertEqual(optional.state, count + 2 <= cap ? IPERF_OUTPUT_COMPLETE : IPERF_OUTPUT_DISCARDED)
        }
        let enormous = "[" + String(repeating: "0,", count: Int(IPERF_RESULT_MAX_VALUES)) + "0]"
        let result = try parsed(#"{"server_output_json":{"x":"# + enormous + "}," + statistics + "}")
        XCTAssertNil(result.core)
        XCTAssertEqual(result.error, EFBIG)
    }

    func testUntrustedLengthIsRejectedBeforeReadingOrAllocatingBuffers() throws {
        for length: UInt32 in [0, UInt32(IPERF_RESULT_FRAME_MAX_BYTES) + 1, UInt32.max] {
            let input = ResultInput(Data("{}".utf8))
            let result = try parsed(input, declared: length)
            XCTAssertNil(result.core)
            XCTAssertEqual(result.error, EFBIG)
            XCTAssertEqual(input.calls, 0)
            XCTAssertEqual(result.metrics.peak_buffer_capacity, 0)
        }
    }

    func testEOFReadErrorAndFrameAlignment() throws {
        let input = ResultInput(Data("{}\u{7}".utf8), fragment: 1)
        let valid = try parsed(input, declared: 2)
        XCTAssertNotNil(valid.core)
        XCTAssertEqual(input.offset, 2)
        let short = try parsed(ResultInput(Data("{}".utf8)), declared: 3)
        XCTAssertNil(short.core)
        XCTAssertEqual(short.error, EPROTO)
        for code in [ECANCELED, ETIMEDOUT, ECONNRESET] {
            let interrupted = ResultInput(Data(#"{"server_output_text":"already retained","streams":[]}"#.utf8), fragment: 1)
            interrupted.failureAt = 40
            interrupted.failure = code
            let result = try parsed(interrupted)
            XCTAssertNil(result.core)
            XCTAssertNil(result.text)
            XCTAssertEqual(result.error, code)
        }
    }

    private func sockets() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        guard descriptors[0] >= 0, descriptors[1] >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        addTeardownBlock { close(descriptors[0]); close(descriptors[1]) }
        return (descriptors[0], descriptors[1])
    }

    private func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            XCTAssertEqual(send(descriptor, bytes.baseAddress, bytes.count, 0), bytes.count)
        }
    }

    private func frame(_ text: String, declared: UInt32? = nil) -> Data {
        var count = (declared ?? UInt32(text.utf8.count)).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + Data(text.utf8)
    }

    func testSocketWriterFramesExactlyAndHonorsDeadlineAndCancellation() throws {
        let (reader, writer) = try sockets()
        XCTAssertEqual(iperf_write_bounded_results_socket(writer, "{}", 2, 1000, nil, nil), 0)
        var actual = Data(count: 6)
        let count = actual.withUnsafeMutableBytes { recv(reader, $0.baseAddress, 6, MSG_DONTWAIT) }
        XCTAssertEqual(count, 6)
        XCTAssertEqual(actual, frame("{}"))
        XCTAssertEqual(fcntl(writer, F_GETFL) & O_NONBLOCK, 0)
        for cancel in [false, true] {
            let (_, blocked) = try sockets()
            var capacity: Int32 = 4096
            XCTAssertEqual(setsockopt(blocked, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size)), 0)
            let payload = String(repeating: "x", count: 1_048_576)
            let cancellation = CancelDeadline()
            let start = DispatchTime.now().uptimeNanoseconds
            var cancelFunction: iperf_result_cancel_function?
            if cancel { cancelFunction = cancelResultRead }
            let result = payload.withCString {
                iperf_write_bounded_results_socket(blocked, $0, UInt32(payload.utf8.count),
                    cancel ? 30_000 : 25, cancelFunction,
                    Unmanaged.passUnretained(cancellation).toOpaque())
            }
            let error = errno
            XCTAssertEqual(result, -1)
            XCTAssertEqual(error, cancel ? ECANCELED : ETIMEDOUT)
            XCTAssertEqual(fcntl(blocked, F_GETFL) & O_NONBLOCK, 0)
            XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        }
    }

    func testSocketAdapterReadsOneFrameAndRejectsLengthBeforeBody() throws {
        for invalid in [false, true] {
            let (reader, writer) = try sockets()
            write(frame("{}", declared: invalid ? UInt32.max : nil) + Data([7]), to: writer)
            var output = iperf_server_output()
            var metrics = iperf_result_read_metrics()
            let tree = iperf_read_bounded_results_socket(reader, 256, 1000, nil, nil, &output, &metrics)
            let error = errno
            defer { cJSON_Delete(tree); iperf_clear_server_output(&output) }
            XCTAssertEqual(tree != nil, !invalid)
            XCTAssertEqual(metrics.bytes_read, invalid ? 0 : 2)
            if invalid { XCTAssertEqual(error, EFBIG) }
            var next: UInt8 = 0
            XCTAssertEqual(recv(reader, &next, 1, MSG_DONTWAIT), 1)
            XCTAssertEqual(next, invalid ? UInt8(ascii: "{") : 7)
        }
    }

    func testSocketDeadlineCoversBothPartialHeaderAndBody() throws {
        for data in [Data([0, 0]), frame("{", declared: 100)] {
            let (reader, writer) = try sockets()
            write(data, to: writer)
            var output = iperf_server_output()
            var metrics = iperf_result_read_metrics()
            let start = DispatchTime.now().uptimeNanoseconds
            let tree = iperf_read_bounded_results_socket(reader, 256, 25, nil, nil, &output, &metrics)
            let error = errno
            defer { cJSON_Delete(tree); iperf_clear_server_output(&output) }
            XCTAssertNil(tree)
            XCTAssertNil(output.value)
            XCTAssertEqual(error, ETIMEDOUT)
            XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        }
    }

    func testSocketCancellationWhileWaitingForHeaderOrBody() throws {
        for body in [false, true] {
            let (reader, writer) = try sockets()
            if body { write(frame("{", declared: 100), to: writer) }
            var output = iperf_server_output()
            var metrics = iperf_result_read_metrics()
            let cancellation = CancelDeadline()
            let start = DispatchTime.now().uptimeNanoseconds
            let tree = iperf_read_bounded_results_socket(reader, 256, 30_000, cancelResultRead,
                Unmanaged.passUnretained(cancellation).toOpaque(), &output, &metrics)
            let error = errno
            defer { cJSON_Delete(tree); iperf_clear_server_output(&output) }
            XCTAssertNil(tree)
            XCTAssertEqual(error, ECANCELED)
            XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 1_000_000_000)
        }
    }
}
