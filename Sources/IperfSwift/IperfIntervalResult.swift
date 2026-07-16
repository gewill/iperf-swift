//
//  IperfIntervalResult.swift
//  
//
//  Created by Igor Kim on 08.11.20.
//

import Foundation

/// Aggregated measurements for one direction during a reporting interval.
public struct IperfDirectionalIntervalResult {
    /// The data-flow direction represented by this aggregate.
    public let direction: IperfDirection
    /// Streams contributing to this direction.
    public let streams: [IperfStreamIntervalResult]
    /// Bytes transferred across the direction's streams.
    public let totalBytes: Int
    /// UDP packets transferred across the direction's streams.
    public let totalPackets: Int64
    /// UDP packets lost across the direction's streams.
    public let totalLostPackets: Int64
    /// Out-of-order UDP packets across the direction's streams.
    public let totalOutoforderPackets: Int64
    /// Mean UDP jitter across the direction's streams, in seconds.
    ///
    /// UDP jitter is measured at the receiving endpoint (RFC 3550), so the
    /// direction this endpoint sends always reports zero. During a
    /// bidirectional run, a client observes real-time jitter only in its
    /// download aggregate and a server only in its upload aggregate.
    public let averageJitter: Double
    /// Length of the reporting interval in seconds.
    public let duration: TimeInterval
    /// The interval start time reported by libiperf.
    public let startTime: TimeInterval
    /// The interval end time reported by libiperf.
    public let endTime: TimeInterval
    /// Aggregate throughput for this direction.
    public let throughput: IperfThroughput

    init(
        direction: IperfDirection,
        streams: [IperfStreamIntervalResult] = [],
        prot: IperfProtocol = .tcp
    ) {
        self.direction = direction
        self.streams = streams
        let aggregate = evaluate(streams: streams, prot: prot)
        totalBytes = aggregate.totalBytes
        totalPackets = aggregate.totalPackets
        totalLostPackets = aggregate.totalLostPackets
        totalOutoforderPackets = aggregate.totalOutoforderPackets
        averageJitter = aggregate.averageJitter
        duration = aggregate.duration
        startTime = aggregate.startTime
        endTime = aggregate.endTime
        throughput = aggregate.throughput
    }
}

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
    /// Measurements for streams sent from the client to the server.
    public var upload = IperfDirectionalIntervalResult(direction: .upload)
    /// Measurements for streams sent from the server to the client.
    public var download = IperfDirectionalIntervalResult(direction: .download)
    
    /// Bytes transferred across all streams during the interval.
    public var totalBytes: Int = 0
    /// UDP packets transferred across all streams during the interval.
    public var totalPackets: Int64 = 0
    /// UDP packets lost across all streams during the interval.
    public var totalLostPackets: Int64 = 0
    /// Out-of-order UDP packets across all streams during the interval.
    public var totalOutoforderPackets: Int64 = 0
    /// Mean UDP jitter across streams, in seconds.
    ///
    /// In bidirectional mode this average includes the locally sent streams,
    /// whose jitter is always zero because UDP jitter is measured at the
    /// receiving endpoint. Prefer the receiving direction's
    /// ``IperfDirectionalIntervalResult/averageJitter``.
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
    /// The client data-flow mode of the run, populated by ``IperfRunner``.
    ///
    /// Manually created results keep the default, ``IperfTestMode/download``.
    public var mode: IperfTestMode = .download
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
        upload = IperfDirectionalIntervalResult(
            direction: .upload,
            streams: streams.filter { $0.direction == .upload },
            prot: prot
        )
        download = IperfDirectionalIntervalResult(
            direction: .download,
            streams: streams.filter { $0.direction == .download },
            prot: prot
        )

        let aggregate = evaluate(streams: streams, prot: prot)
        totalBytes = aggregate.totalBytes
        totalPackets = aggregate.totalPackets
        totalLostPackets = aggregate.totalLostPackets
        totalOutoforderPackets = aggregate.totalOutoforderPackets
        averageJitter = aggregate.averageJitter
        averageRtt = 0.0
        duration = aggregate.duration
        startTime = aggregate.startTime
        endTime = aggregate.endTime
        throughput = aggregate.throughput
    }
}

private struct IperfIntervalAggregate {
    var totalBytes = 0
    var totalPackets: Int64 = 0
    var totalLostPackets: Int64 = 0
    var totalOutoforderPackets: Int64 = 0
    var averageJitter = 0.0
    var duration: TimeInterval = 0.0
    var startTime: TimeInterval = 0.0
    var endTime: TimeInterval = 0.0
    var throughput = IperfThroughput(bytesPerSecond: 0.0)
}

private func evaluate(
    streams: [IperfStreamIntervalResult],
    prot: IperfProtocol
) -> IperfIntervalAggregate {
    var aggregate = IperfIntervalAggregate()
    var sumJitter = 0.0

    for stream in streams {
        aggregate.totalBytes += stream.bytesTransferred
        if prot == .udp {
            aggregate.totalPackets += stream.intervalPacketCount
            aggregate.totalLostPackets += stream.intervalCntError
            aggregate.totalOutoforderPackets += stream.intervalOutoforderPackets
            sumJitter += stream.jitter
        }
    }

    if let first = streams.first {
        aggregate.startTime = first.startTime
        aggregate.endTime = first.endTime
        aggregate.duration = first.intervalDuration
        aggregate.throughput = IperfThroughput(
            bytes: aggregate.totalBytes,
            seconds: first.intervalDuration
        )
        if prot == .udp {
            aggregate.averageJitter = sumJitter / Double(streams.count)
        }
    }

    return aggregate
}
