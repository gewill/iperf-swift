import IperfCLib

/// Metadata describing bounded output independently of measurement statistics.
/// A complete empty string has zero retained bytes; missing or discarded output
/// has no payload. Byte counts describe UTF-8, not characters or memory footprint.
public struct IperfServerOutputStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notRequested, waiting, missing, complete, truncated, discarded, invalid
    }

    public enum Format: Equatable, Sendable {
        case text, json
    }

    public enum Reason: Equatable, Sendable {
        case byteLimit, nodeLimit, depthLimit, invalidData, allocationFailure, readFailure
    }

    public let state: State
    public let format: Format?
    public let reason: Reason?
    public let retainedByteCount: Int
    /// Complete observed length when known. `nil` is unknown, never zero.
    public let observedByteCount: UInt64?

    static let notRequested = Self(state: .notRequested)
    static let waiting = Self(state: .waiting)
    static let missing = Self(state: .missing)

    private init(state: State) {
        self.state = state
        format = nil
        reason = nil
        retainedByteCount = 0
        observedByteCount = nil
    }

    init(_ output: iperf_server_output) {
        switch output.state {
        case IPERF_OUTPUT_MISSING: state = .missing
        case IPERF_OUTPUT_COMPLETE: state = .complete
        case IPERF_OUTPUT_TRUNCATED: state = .truncated
        case IPERF_OUTPUT_DISCARDED: state = .discarded
        default: state = .invalid
        }
        switch output.format {
        case IPERF_OUTPUT_TEXT: format = .text
        case IPERF_OUTPUT_JSON: format = .json
        default: format = nil
        }
        switch output.reason {
        case IPERF_OUTPUT_BYTE_LIMIT: reason = .byteLimit
        case IPERF_OUTPUT_NODE_LIMIT: reason = .nodeLimit
        case IPERF_OUTPUT_DEPTH_LIMIT: reason = .depthLimit
        case IPERF_OUTPUT_INVALID_DATA: reason = .invalidData
        case IPERF_OUTPUT_ALLOCATION_FAILURE: reason = .allocationFailure
        case IPERF_OUTPUT_READ_FAILURE: reason = .readFailure
        default: reason = nil
        }
        retainedByteCount = output.length
        observedByteCount = output.observed_bytes_complete != 0 ? output.observed_bytes : nil
    }
}
