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
    public init(bytes initValue: Int, seconds: TimeInterval) {
        self.init(bytesPerSecond: Double(initValue) / seconds)
    }
}
