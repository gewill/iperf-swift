//
//  IperfStreamRunResult.swift
//  IperfSwift
//

import Foundation
import IperfCLib

/// Totals the engine accumulates for one stream across a whole run, as opposed
/// to the per-interval snapshots in ``IperfStreamIntervalResult``.
///
/// These are the values `iperf3` prints in its `end.streams[]` summary. Read
/// them from ``IperfRunner/streamTotals`` once a run has finished.
public struct IperfStreamRunResult {
    /// The stream's data-flow direction from the client's point of view.
    public let direction: IperfDirection

    /// TCP statistics for the run, or `nil` when the engine never sampled any.
    ///
    /// The engine collects these only while it is *sending* on a TCP stream on
    /// a platform that exposes TCP info, so a receiving endpoint has none: a
    /// client running ``IperfTestMode/download`` gets `nil` here, and so does
    /// any UDP stream. The CLI reports zeros in that case, which read as
    /// measurements rather than as absent data; this reports their absence.
    public let tcpSenderTotals: IperfTCPSenderTotals?

    /// Creates a run result, for previews and test doubles.
    public init(direction: IperfDirection, tcpSenderTotals: IperfTCPSenderTotals?) {
        self.direction = direction
        self.tcpSenderTotals = tcpSenderTotals
    }
}

/// TCP statistics accumulated over a run for one sending stream.
///
/// Every value here comes from the same sampling pass, so they are available
/// together or not at all — which is why ``IperfStreamRunResult/tcpSenderTotals``
/// is one optional rather than a field-by-field one.
public struct IperfTCPSenderTotals {
    /// The smallest round-trip time sampled during the run, in microseconds.
    ///
    /// The engine samples the kernel's *smoothed* estimate — `tcpi_srtt` on
    /// Apple platforms, `tcpi_rtt` elsewhere — which RFC 6298 defines as an
    /// exponentially weighted moving average maintained for the retransmission
    /// timer. Read these as that estimator's range over the run, not as raw
    /// latency samples.
    public let minRtt: Int
    /// The mean of the sampled round-trip times, in microseconds.
    ///
    /// Computed as the engine's running sum over its sample count, matching
    /// what the CLI prints as `mean_rtt`.
    public let meanRtt: Int
    /// The largest round-trip time sampled during the run, in microseconds.
    public let maxRtt: Int
    /// The number of round-trip samples behind ``minRtt``, ``meanRtt`` and
    /// ``maxRtt``. Always at least one; a stream with no samples reports no
    /// totals at all.
    public let rttSampleCount: Int
    /// The largest send congestion window observed during the run, in bytes.
    public let maxSendCongestionWindow: Int
    /// The largest send window observed during the run, in bytes.
    public let maxSendWindow: Int
    /// Segments retransmitted during the run.
    public let retransmits: Int
    /// The engine's reordering counter for the stream at the end of the run.
    public let reorder: Int

    /// Creates a set of totals, for previews and test doubles.
    public init(
        minRtt: Int,
        meanRtt: Int,
        maxRtt: Int,
        rttSampleCount: Int,
        maxSendCongestionWindow: Int,
        maxSendWindow: Int,
        retransmits: Int,
        reorder: Int
    ) {
        self.minRtt = minRtt
        self.meanRtt = meanRtt
        self.maxRtt = maxRtt
        self.rttSampleCount = rttSampleCount
        self.maxSendCongestionWindow = maxSendCongestionWindow
        self.maxSendWindow = maxSendWindow
        self.retransmits = retransmits
        self.reorder = reorder
    }
}
