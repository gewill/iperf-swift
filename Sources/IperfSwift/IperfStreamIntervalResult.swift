//
//  File.swift
//  
//
//  Created by Igor Kim on 08.11.20.
//

import Foundation
import IperfCLib

/// Measurements for one stream during one reporting interval.
public struct IperfStreamIntervalResult {
    /// The stream's data-flow direction from the client's point of view.
    public var direction = IperfDirection.upload
    var bytesTransferred: Int = 0
    var intervalDuration: Double = 0
    var intervalPacketCount: Int64 = 0
    var intervalOutoforderPackets: Int64 = 0
    var intervalCntError: Int64 = 0
    
    var packetCount: Int64 = 0
    var jitter: Double = 0
    var outoforderPackets: Int64 = 0
    var cnt_error: Int64 = 0
    var omitted: Int32 = 0
    
    /// TCP retransmissions during this interval.
    public var intervalRetrans: Int = 0
    /// TCP send window in bytes as reported by libiperf.
    public var snd_wnd: Int = 0
    /// Congestion window in bytes, populated from macOS `tcp_info` in iperf 3.21.
    public var sndCwnd: Int = 0
    /// Round-trip time in microseconds, when the platform exposes TCP info.
    public var rtt: Int = 0
    /// Round-trip time variance in microseconds.
    public var rttvar: Int = 0
    /// Path maximum transmission unit in bytes.
    public var pmtu: Int = 0
    
    var startTime: Double = 0
    var endTime: Double = 0
    
    var intervalTimeDiff = TimeInterval(0.0)

    init() {}

    /// Creates a synthetic stream measurement.
    ///
    /// The engine builds its own results from `iperf_interval_results`. This
    /// initializer exists for consumers that must produce results the library
    /// did not measure — SwiftUI previews, and test doubles that deliver
    /// through the real ``reporterFunctionType`` callback instead of reaching
    /// past a consumer's own receiving path.
    ///
    /// Only the fields that feed the aggregates are parameters. The cumulative
    /// counters the wrapper carries but never reads are left at zero, and the
    /// interval's own length is derived rather than accepted: the engine
    /// computes it from the same two timestamps, so taking it separately would
    /// only allow a stream whose length contradicts its own start and end.
    public init(
        direction: IperfDirection = .upload,
        bytesTransferred: Int = 0,
        startTime: Double = 0,
        endTime: Double = 0,
        intervalPacketCount: Int64 = 0,
        intervalCntError: Int64 = 0,
        intervalOutoforderPackets: Int64 = 0,
        jitter: Double = 0
    ) {
        self.direction = direction
        self.bytesTransferred = bytesTransferred
        self.startTime = startTime
        self.endTime = endTime
        self.intervalPacketCount = intervalPacketCount
        self.intervalCntError = intervalCntError
        self.intervalOutoforderPackets = intervalOutoforderPackets
        self.jitter = jitter
        intervalTimeDiff = max(endTime - startTime, 0)
        self.intervalDuration = intervalTimeDiff
    }

    /// Creates a synthetic stream measurement using the legacy duration input.
    ///
    /// When both timestamps retain their defaults, the duration supplies a
    /// compatible `endTime`. Explicit timestamps otherwise take precedence.
    @available(*, deprecated, message: "Supply startTime and endTime; duration is derived from them.")
    public init(
        direction: IperfDirection = .upload,
        bytesTransferred: Int = 0,
        intervalDuration: Double,
        startTime: Double = 0,
        endTime: Double = 0,
        intervalPacketCount: Int64 = 0,
        intervalCntError: Int64 = 0,
        intervalOutoforderPackets: Int64 = 0,
        jitter: Double = 0
    ) {
        let compatibleEndTime = startTime == 0 && endTime == 0
            ? startTime + max(intervalDuration, 0)
            : endTime
        self.init(
            direction: direction,
            bytesTransferred: bytesTransferred,
            startTime: startTime,
            endTime: compatibleEndTime,
            intervalPacketCount: intervalPacketCount,
            intervalCntError: intervalCntError,
            intervalOutoforderPackets: intervalOutoforderPackets,
            jitter: jitter
        )
    }

    init(_ results: iperf_interval_results) {
        var diff = iperf_time()
        var time1Pointer: UnsafeMutablePointer<iperf_time>?
        var time2Pointer: UnsafeMutablePointer<iperf_time>?
        
        var timeConv1 = results.interval_end_time
        withUnsafeMutablePointer(to: &timeConv1) { pointer in
            time1Pointer = pointer
        }
        var timeConv2 = results.interval_start_time
        withUnsafeMutablePointer(to: &timeConv2) { pointer in
            time2Pointer = pointer
        }
        
        startTime = Double(timeConv2.secs) + Double(timeConv2.usecs)*1e-6
        endTime = Double(timeConv1.secs) + Double(timeConv1.usecs)*1e-6
        
        iperf_time_diff(time1Pointer, time2Pointer, &diff)
        intervalTimeDiff = Double(diff.secs) + Double(diff.usecs)*1e-6
        
        bytesTransferred = results.bytes_transferred
        intervalDuration = Double(results.interval_duration)
        
        // MARK: UDP only results
        intervalPacketCount = results.interval_packet_count
        intervalOutoforderPackets = results.interval_outoforder_packets
        intervalCntError = results.interval_cnt_error
        packetCount = results.packet_count
        jitter = results.jitter
        outoforderPackets = results.outoforder_packets
        cnt_error = results.cnt_error
        
        omitted = results.omitted
        
        intervalRetrans = results.interval_retrans
        snd_wnd = results.snd_wnd
        sndCwnd = results.snd_cwnd
        rtt = results.rtt
        rttvar = results.rttvar
        pmtu = results.pmtu
    }
}
