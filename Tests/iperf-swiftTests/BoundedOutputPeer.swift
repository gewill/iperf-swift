import Darwin
import Foundation

/// A deliberately limited TCP-upload peer for malformed result-exchange tests.
/// The handshake follows the vendored 3.22 control states; it drains real stream
/// bytes, then alters only the result frame. This is not CLI interoperability or
/// a throughput reference. All socket work runs on its own serial queue.
final class BoundedOutputPeer {
    enum Response: String {
        case missing, empty, largeText, largeJSON, malformed, excessiveLength, shortFrame, stall
    }

    private let listener: Int32
    private let lock = NSLock()
    private var descriptors: Set<Int32>
    private var stopped = false

    init(listener: Int32) {
        self.listener = listener
        descriptors = [listener]
    }

    /// Shutdown wakes the owning queue; only that queue closes descriptors.
    /// Keeping registration and close under the same lock prevents fd reuse.
    func stop() {
        lock.lock()
        stopped = true
        for descriptor in descriptors { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    func start(
        response: Response,
        onExchange: @escaping () -> Void = {},
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        DispatchQueue(label: "iperf.test.bounded-peer").async {
            let result = Result { try self.serve(response, onExchange: onExchange) }
            self.lock.lock()
            for descriptor in self.descriptors { close(descriptor) }
            self.descriptors.removeAll()
            self.lock.unlock()
            completion(result)
        }
    }

    private func serve(_ response: Response, onExchange: () -> Void) throws -> Int {
        let control = try acceptSocket()
        let cookie = try read(control, count: 37)
        try write(control, Data([9])) // PARAM_EXCHANGE
        let parameters = try readFrame(control)
        guard let options = try JSONSerialization.jsonObject(with: parameters) as? [String: Any],
              options["tcp"] as? Bool == true,
              options["parallel"] as? Int == 1,
              options["reverse"] == nil, options["bidirectional"] == nil else {
            throw POSIXError(.EPROTO)
        }
        try write(control, Data([10])) // CREATE_STREAMS
        let stream = try acceptSocket()
        guard try read(stream, count: 37) == cookie else { throw POSIXError(.EPROTO) }
        try write(control, Data([1, 2])) // TEST_START, TEST_RUNNING

        var received = 0
        let measurementDeadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            var sockets = [pollfd(fd: control, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: stream, events: Int16(POLLIN), revents: 0)]
            guard ProcessInfo.processInfo.systemUptime < measurementDeadline else {
                throw POSIXError(.ETIMEDOUT)
            }
            let ready = poll(&sockets, 2, 100)
            if ready < 0 { if errno == EINTR { continue }; throw posixError() }
            if sockets[1].revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let count = recv(stream, &buffer, buffer.count, MSG_DONTWAIT)
                if count > 0 { received += count }
            }
            if sockets[0].revents != 0 {
                guard try read(control, count: 1) == Data([4]) else { throw POSIXError(.EPROTO) }
                break // TEST_END
            }
        }
        guard received > 0 else { throw POSIXError(.ENODATA) }
        try write(control, Data([13])) // EXCHANGE_RESULTS
        guard var result = try JSONSerialization.jsonObject(with: readFrame(control)) as? [String: Any] else {
            throw POSIXError(.EPROTO)
        }
        result["sender_has_retransmits"] = -1
        // Preserve the stream ids, bytes and duration actually sent by the
        // client. The fixture's CPU and receiver statistics are not measured.
        result["cpu_util_total"] = 0
        result["cpu_util_user"] = 0
        result["cpu_util_system"] = 0
        switch response {
        case .missing: break
        case .empty: result["server_output_text"] = ""
        case .largeText: result["server_output_text"] = String(repeating: "網😀\n", count: 40_000)
        case .largeJSON: result["server_output_json"] = ["text": String(repeating: "x", count: 300_000)]
        case .malformed:
            try writeFrame(control, Data("{\"streams\":[}".utf8))
            return received
        case .excessiveLength:
            try writeHeader(control, UInt32.max)
            return received
        case .shortFrame:
            try writeHeader(control, 1_000)
            try write(control, Data("{\"streams\":".utf8))
            return received
        case .stall:
            try writeHeader(control, 1_000)
            try write(control, Data("{\"server_output_text\":\"".utf8))
            onExchange()
            // The SDK must stop or enforce its own 30-second frame deadline.
            // Keep the peer alive longer; EOF is evidence of SDK cleanup.
            let deadline = ProcessInfo.processInfo.systemUptime + 36
            while true {
                try wait(control, event: Int16(POLLIN), until: deadline)
                var byte: UInt8 = 0
                let count = recv(control, &byte, 1, MSG_DONTWAIT)
                if count == 0 { return received }
                if count < 0 && errno != EAGAIN && errno != EINTR { throw posixError() }
            }
        }
        try writeFrame(control, JSONSerialization.data(withJSONObject: result))
        try write(control, Data([14])) // DISPLAY_RESULTS
        guard try read(control, count: 1) == Data([16]) else { throw POSIXError(.EPROTO) }
        return received
    }

    private func acceptSocket() throws -> Int32 {
        try wait(listener, event: Int16(POLLIN), until: ProcessInfo.processInfo.systemUptime + 8)
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0 else { throw posixError() }
        lock.lock()
        descriptors.insert(descriptor)
        if stopped { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw posixError() }
        return descriptor
    }

    private func wait(_ fd: Int32, event: Int16, until deadline: TimeInterval) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw posixError() }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func read(_ fd: Int32, count: Int) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(fd, event: Int16(POLLIN), until: deadline)
            let received = data.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
            }
            if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard received > 0 else { throw POSIXError(.EPROTO) }
            offset += received
        }
        return data
    }

    private func write(_ fd: Int32, _ data: Data) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var offset = 0
        while offset < data.count {
            try wait(fd, event: Int16(POLLOUT), until: deadline)
            let sent = data.withUnsafeBytes {
                send(fd, $0.baseAddress!.advanced(by: offset), min(4096, data.count - offset), MSG_DONTWAIT | MSG_NOSIGNAL)
            }
            if sent < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard sent > 0 else { throw posixError() }
            offset += sent
        }
    }

    private func readFrame(_ fd: Int32) throws -> Data {
        let header = try read(fd, count: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 1_048_576 else { throw POSIXError(.EFBIG) }
        return try read(fd, count: count)
    }

    private func writeHeader(_ fd: Int32, _ count: UInt32) throws {
        var header = count.bigEndian
        try withUnsafeBytes(of: &header) { try write(fd, Data($0)) }
    }

    private func writeFrame(_ fd: Int32, _ data: Data) throws {
        try writeHeader(fd, UInt32(data.count))
        try write(fd, data)
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
