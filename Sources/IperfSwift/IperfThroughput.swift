//
//  File.swift
//  
//
//  Created by Igor Kim on 08.11.20.
//

import Foundation

/// A throughput value stored as bytes per second.
public struct IperfThroughput {
    /// Throughput in bytes per second.
    public var rawValue: Double
    /// Throughput in bits per second.
    public var bps: Double {
        rawValue*8
    }
    
    /// Throughput in decimal kilobits per second.
    public var Kbps: Double {
        return bps / 1000
    }
    /// Throughput in decimal megabits per second.
    public var Mbps: Double {
        return Kbps / 1000
    }
    /// Throughput in decimal gigabits per second.
    public var Gbps: Double {
        return Mbps / 1000
    }
    
    /// Creates a throughput value from bytes per second.
    public init(bytesPerSecond initValue: Double) {
        rawValue = initValue
    }
    
    /// Creates a throughput value from a byte count and duration.
    ///
    /// A duration that is not greater than zero yields a rate of zero. The
    /// engine can report an interval whose start and end times are equal, and
    /// dividing by it would produce infinity or NaN — values that trap the
    /// moment a caller converts the rate to an integer. Zero matches the rate
    /// iperf3 reports for the same interval in its per-stream output.
    public init(bytes initValue: Int, seconds: TimeInterval) {
        guard seconds > 0 else {
            self.init(bytesPerSecond: 0)
            return
        }
        self.init(bytesPerSecond: Double(initValue) / seconds)
    }
}
