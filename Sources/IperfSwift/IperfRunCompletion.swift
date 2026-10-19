import Foundation
import IperfCLib

/// Final status of an opt-in bounded logfile, captured after its FILE closes.
///
/// Logging failures do not fail the measurement. A truncated text/JSON file is
/// only a prefix, not a complete report. The caller must exclusively own the
/// path while the run uses it; concurrent writers or external file changes
/// cannot be included in this budget.
public struct IperfLogfileResult: Equatable, Sendable {
    /// Maximum file size, including pre-existing bytes and a truncation marker.
    public let byteLimit: UInt64
    /// Bytes successfully appended by this run, across persistent-server resets.
    public let bytesWritten: UInt64
    /// Last observed file size, or nil if the file could not be inspected.
    /// An already oversized file is left untouched and may exceed byteLimit.
    public let fileBytes: UInt64?
    /// Output was discarded to respect the budget. The marker is written at
    /// most once per run; an existing file with too little room stays unchanged.
    public let isTruncated: Bool
    /// First POSIX error opening/preparing the sink, including EFBIG for an
    /// already oversized file. Nil means no error of this kind was observed.
    public let openError: Int32?
    /// First POSIX error writing output. No subsequent writes are attempted.
    public let writeError: Int32?
    /// First POSIX error closing the sink. The FILE is closed even on failure.
    public let closeError: Int32?

    init(_ status: iperf_log_status) {
        byteLimit = status.limit
        bytesWritten = status.bytes_written
        fileBytes = status.file_size_known != 0 ? status.file_bytes : nil
        isTruncated = status.truncated != 0
        openError = status.open_errno == 0 ? nil : status.open_errno
        writeError = status.write_errno == 0 ? nil : status.write_errno
        closeError = status.close_errno == 0 ? nil : status.close_errno
    }
}

/// One accepted start has relinquished all of its native resources.
///
/// Unlike `.finished`, this is a safe point to reclaim that run's exclusively
/// owned logfile. It also covers validation failure, queued cancellation and
/// releasing a queued runner without executing the engine. It does not mean
/// the measurement succeeded. A persistent server completes only after it exits,
/// not between clients.
/// Prefer unique paths per run. A completion for an older generation does not
/// authorize deleting a path that another run has since started using.
public struct IperfRunCompletion: Equatable, Sendable {
    /// Distinguishes generations even when the same runner is reused.
    public let runID: UUID
    /// Nil when bounded logging was disabled or no logfile open was attempted.
    public let logfile: IperfLogfileResult?
}

/// Called once after all native resources of an accepted start are released.
/// Ignored overlapping starts produce no completion. Delivery is asynchronous,
/// on no guaranteed queue; use the immutable payload rather than reading a
/// runner that may already have started another generation. Return promptly.
public typealias resourcesReleasedFunctionType = (IperfRunCompletion) -> Void
