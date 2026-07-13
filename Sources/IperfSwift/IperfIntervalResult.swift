//
//  IperfIntervalResult.swift
//  
//
//  Created by Igor Kim on 08.11.20.
//

import Foundation

/// Aggregated measurements for one libiperf reporting interval.
public struct IperfIntervalResult: Identifiable {
    /// A stable identifier for use in SwiftUI collections.
    public var id = UUID()
    /// A wrapper lifecycle field that defaults to ``IperfRunnerState/unknown``.
    ///
    /// Interval callbacks currently report lifecycle changes separately through
    /// ``runnerStateFunctionType``.
    public var runnerState: IperfRunnerState = .unknown
    
    /// Per-stream measurements included in this interval.
    public var streams: [IperfStreamIntervalResult] = []
    
    /// Bytes transferred across all streams during the interval.
    public var totalBytes: Int = 0
    /// UDP packets transferred across all streams during the interval.
    public var totalPackets: Int64 = 0
    /// UDP packets lost across all streams during the interval.
    public var totalLostPackets: Int64 = 0
    /// Out-of-order UDP packets across all streams during the interval.
    public var totalOutoforderPackets: Int64 = 0
    /// Mean UDP jitter across streams, in seconds.
    public var averageJitter: Double = 0.0
    /// Reserved for an aggregate round-trip time value.
    public var averageRtt: Double = 0.0
    /// Length of the reporting interval in seconds.
    public var duration: TimeInterval = 0.0
    /// The low-level libiperf state that produced the result.
    public var state: IperfState = .UNKNOWN
    /// A human-readable status supplied by the wrapper.
    public var debugDescription: String = ""
    
    /// The interval start time reported by libiperf.
    public var startTime: TimeInterval = 0.0
    /// The interval end time reported by libiperf.
    public var endTime: TimeInterval = 0.0
    
    /// Aggregate throughput across streams.
    public var throughput = IperfThroughput.init(bytesPerSecond: 0.0)
    /// Whether ``error`` contains a failure.
    public var hasError: Bool {
        error != .IENONE
    }
    /// The libiperf or wrapper error associated with the result.
    public var error: IperfError = .UNKNOWN
    /// The transport protocol used for the interval.
    public var prot: IperfProtocol = .tcp
    /// The raw libiperf reverse-mode flag (`0` for upload, `1` for download).
    public var reverse: Int32 = 0
    
    /// Creates an interval result with no stream measurements.
    public init(
        runnerState: IperfRunnerState = .unknown,
        debugDescription: String = "",
        state: IperfState = .UNKNOWN,
        error: IperfError = .UNKNOWN,
        prot: IperfProtocol = .tcp
    ) {
        self.runnerState = runnerState
        self.debugDescription = debugDescription
        self.state = state
        self.error = error
        self.prot = prot
    }
    
    /// Recomputes aggregate values from ``streams``.
    ///
    /// The method resets existing aggregate values first, so repeated calls are safe.
    /// - Important: The misspelled name is retained for source compatibility.
    mutating public func evaulate() {
        totalBytes = 0
        totalPackets = 0
        totalLostPackets = 0
        totalOutoforderPackets = 0
        averageJitter = 0.0
        averageRtt = 0.0
        duration = 0.0
        startTime = 0.0
        endTime = 0.0
        throughput = IperfThroughput(bytesPerSecond: 0.0)

        var sumJitter: Double = 0.0
        for s in streams {
            totalBytes += s.bytesTransferred
            if self.prot == .udp {
                totalPackets += s.intervalPacketCount
                totalLostPackets += s.intervalCntError
                totalOutoforderPackets += s.intervalOutoforderPackets
                sumJitter += s.jitter
            }
        }
        if let first = streams.first {
            startTime = first.startTime
            endTime = first.endTime
            duration = first.intervalDuration
            
            if self.prot == .udp {
                averageJitter = sumJitter / Double(streams.count)
            }
            throughput = IperfThroughput(bytes: totalBytes, seconds: first.intervalDuration)
        }
    }
}
