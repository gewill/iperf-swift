import Darwin
import Foundation
import IperfCLib
import XCTest

final class IperfBoundedLogTests: XCTestCase {
    private let marker = Data(String(cString: iperf_log_truncation_marker()).utf8)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func append(_ chunks: [Data], to url: URL, limit: UInt64,
                        status: inout iperf_log_status) throws {
        status.limit = limit
        try withUnsafeMutablePointer(to: &status) { pointer in
            let file = try XCTUnwrap(iperf_bounded_log_open(url.path, pointer))
            for chunk in chunks {
                let written = chunk.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
                XCTAssertEqual(written, chunk.count)
                XCTAssertEqual(fflush(file), 0)
                if pointer.pointee.open_errno == 0 {
                    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64
                    XCTAssertLessThanOrEqual(size, limit)
                }
            }
            XCTAssertEqual(fclose(file), 0)
        }
    }

    func testBelowEqualAndAboveLimitAcrossWriteSizes() throws {
        let dir = try directory()
        for limit in [marker.count, 25, 64, 4096] {
            for size in [0, limit - 1, limit, limit + 1, limit * 10] {
                for chunkSize in [1, 7, 8192] {
                    let url = dir.appendingPathComponent(UUID().uuidString)
                    let input = Data(repeating: 65, count: size)
                    let chunks = stride(from: 0, to: size, by: chunkSize).map {
                        input.subdata(in: $0..<min($0 + chunkSize, size))
                    }
                    var status = iperf_log_status()
                    try append(chunks, to: url, limit: UInt64(limit), status: &status)
                    let output = try Data(contentsOf: url)
                    XCTAssertLessThanOrEqual(output.count, limit)
                    XCTAssertEqual(status.file_bytes, UInt64(output.count))
                    XCTAssertEqual(status.bytes_written, UInt64(output.count))
                    XCTAssertEqual(status.open_errno, 0)
                    XCTAssertEqual(status.write_errno, 0)
                    XCTAssertEqual(status.close_errno, 0)
                    if size > limit {
                        XCTAssertEqual(status.truncated, 1)
                        XCTAssertEqual(output, Data(input.prefix(limit - marker.count)) + marker)
                    } else {
                        XCTAssertEqual(status.truncated, 0)
                        XCTAssertEqual(output, input)
                    }
                }
            }
        }
    }

    func testUTF8PrefixAtEveryByteBoundaryAndSplitWrite() throws {
        let dir = try directory()
        let input = Data(String(repeating: "aé中🙂e\u{301}", count: 100).utf8)
        for limit in marker.count...(marker.count + 64) {
            for chunkSize in [1, 3, input.count] {
                let url = dir.appendingPathComponent(UUID().uuidString)
                let chunks = stride(from: 0, to: input.count, by: chunkSize).map {
                    input.subdata(in: $0..<min($0 + chunkSize, input.count))
                }
                var status = iperf_log_status()
                try append(chunks, to: url, limit: UInt64(limit), status: &status)
                let output = try Data(contentsOf: url)
                XCTAssertNotNil(String(data: output, encoding: .utf8))
                XCTAssertTrue(output.suffix(marker.count) == marker)
                XCTAssertTrue(input.starts(with: output.dropLast(marker.count)))
                XCTAssertLessThanOrEqual(output.count, limit)
            }
        }
    }

    func testExistingContentAndReopenNeverOverwriteOrRepeatMarker() throws {
        let dir = try directory()
        for existingSize in [0, 10, 64 - marker.count, 63, 64, 65] {
            let url = dir.appendingPathComponent(UUID().uuidString)
            let existing = Data(repeating: 88, count: existingSize)
            try existing.write(to: url)
            var status = iperf_log_status()
            try append([Data(repeating: 65, count: 200)], to: url, limit: 64, status: &status)
            let first = try Data(contentsOf: url)
            XCTAssertTrue(first.starts(with: existing))
            XCTAssertLessThanOrEqual(first.count, max(64, existingSize))
            XCTAssertEqual(status.open_errno, existingSize > 64 ? EFBIG : 0)
            XCTAssertEqual(status.truncated, existingSize > 64 ? 0 : 1)
            try append([Data(repeating: 66, count: 200)], to: url, limit: 64, status: &status)
            XCTAssertEqual(try Data(contentsOf: url), first)
        }
    }

    func testSmallBudgetAndOpenFailuresDiscardWithoutChangingExistingFile() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("existing")
        let existing = Data("original".utf8)
        try existing.write(to: url)
        for limit in [0, 1, marker.count - 1] {
            var status = iperf_log_status()
            try append([Data("new".utf8)], to: url, limit: UInt64(limit), status: &status)
            XCTAssertNotEqual(status.open_errno, 0)
            XCTAssertEqual(try Data(contentsOf: url), existing)
        }
        for path in [dir, dir.appendingPathComponent("missing/log")] {
            var status = iperf_log_status()
            try append([Data("new".utf8)], to: path, limit: 64, status: &status)
            XCTAssertNotEqual(status.open_errno, 0)
            XCTAssertEqual(status.bytes_written, 0)
        }
        XCTAssertEqual(chmod(url.path, 0), 0)
        defer { _ = chmod(url.path, 0o600) }
        var denied = iperf_log_status()
        try append([Data("new".utf8)], to: url, limit: 64, status: &denied)
        XCTAssertEqual(denied.open_errno, EACCES)
        XCTAssertEqual(denied.file_size_known, 0)
    }

    func testDisabledPersistentSinkDoesNotRecreateOrRetryItsPath() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("bounded")
        var status = iperf_log_status()
        try append([Data(repeating: 65, count: 100)], to: url, limit: 64, status: &status)
        XCTAssertEqual(status.truncated, 1)
        try FileManager.default.removeItem(at: url)
        // Simulate cache loss after the sink has already been disabled. A
        // persistent server must not create a new file or reset its budget.
        try withUnsafeMutablePointer(to: &status) { pointer in
            let file = try XCTUnwrap(iperf_bounded_log_open(url.path, pointer))
            XCTAssertGreaterThanOrEqual(fputs("new output", file), 0)
            XCTAssertEqual(fclose(file), 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(status.bytes_written, 64)
    }

    func testWriteAndCloseFailuresAreReportedWithoutRetryingOrFailingOutput() throws {
        for successfulBytes in [0, 5] {
            let spy = FailingLogSink(remaining: successfulBytes)
            let sink = try XCTUnwrap(funopen(Unmanaged.passUnretained(spy).toOpaque(), nil, {
                cookie, bytes, count in
                let spy = Unmanaged<FailingLogSink>.fromOpaque(cookie!).takeUnretainedValue()
                spy.writeCalls += 1
                guard spy.remaining > 0 else { errno = ENOSPC; return -1 }
                let accepted = min(Int(count), spy.remaining)
                spy.remaining -= accepted
                spy.bytes.append(UnsafePointer<UInt8>(OpaquePointer(bytes!)), count: accepted)
                return Int32(accepted)
            }, nil, { cookie in
                let spy = Unmanaged<FailingLogSink>.fromOpaque(cookie!).takeUnretainedValue()
                spy.closeCalls += 1
                errno = EIO
                return -1
            }))
            var status = iperf_log_status()
            status.limit = 128
            try withUnsafeMutablePointer(to: &status) { pointer in
                let file = try XCTUnwrap(iperf_bounded_log_wrap(sink, 0, pointer))
                let input = Data(repeating: 65, count: 90)
                XCTAssertEqual(input.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }, input.count)
                errno = EHOSTUNREACH
                XCTAssertEqual(fflush(file), 0)
                XCTAssertEqual(errno, EHOSTUNREACH)
                let callsAfterFailure = spy.writeCalls
                XCTAssertEqual(input.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }, input.count)
                XCTAssertEqual(fflush(file), 0)
                XCTAssertEqual(spy.writeCalls, callsAfterFailure)
                XCTAssertEqual(fclose(file), EOF)
            }
            XCTAssertEqual(status.write_errno, ENOSPC)
            XCTAssertEqual(status.close_errno, EIO)
            XCTAssertEqual(spy.closeCalls, 1)
            XCTAssertEqual(spy.bytes.count, successfulBytes)
            XCTAssertEqual(status.file_bytes, UInt64(successfulBytes))
        }
    }

    func testNativeJSONFileWritersRespectBudgetWithoutChangingCallbackRoute() throws {
        let dir = try directory()
        for stream in [false, true] {
            for limit: UInt64 in [0, 128] {
                let url = dir.appendingPathComponent(UUID().uuidString)
                let test = try XCTUnwrap(iperf_new_test())
                defer { iperf_free_test(test) }
                XCTAssertEqual(iperf_defaults(test), 0)
                iperf_set_test_logfile(test, url.path)
                test.pointee.logfile_status.limit = limit
                XCTAssertEqual(iperf_open_logfile(test), 0)
                iperf_set_test_json_output(test, 1)
                iperf_set_test_json_stream(test, stream ? 1 : 0)
                XCTAssertEqual(iperf_json_start(test), 0)
                let payload = String(repeating: "中文🙂", count: 512)
                XCTAssertNotNil(cJSON_AddStringToObject(test.pointee.json_end, "payload", payload))
                // Exercise libiperf's own JSON writers, including streaming's
                // direct fprintf path. This is not a network measurement test.
                XCTAssertEqual(iperf_json_finish(test), 0)
                iperf_close_logfile(test)
                let output = try Data(contentsOf: url)
                XCTAssertNotNil(String(data: output, encoding: .utf8))
                if limit == 0 {
                    XCTAssertGreaterThan(output.count, 128)
                    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: output))
                } else {
                    XCTAssertLessThanOrEqual(output.count, Int(limit))
                    XCTAssertEqual(test.pointee.logfile_status.truncated, 1)
                    XCTAssertEqual(output.suffix(marker.count), marker)
                    XCTAssertThrowsError(try JSONSerialization.jsonObject(with: output))
                }
            }
        }
    }
}

private final class FailingLogSink {
    var remaining: Int
    var bytes = Data()
    var writeCalls = 0
    var closeCalls = 0
    init(remaining: Int) { self.remaining = remaining }
}
