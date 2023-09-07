//
//  File.swift
//
//
//  Created by Igor Kim on 08.11.20.
//

import Foundation
import IperfCLib

public enum IperfProtocol: String, Codable {
    case tcp
    case udp
    case sctp

    public var iperfConfigValue: Int32 {
        switch self {
        case .tcp:
            return Ptcp
        case .udp:
            return Pudp
        case .sctp:
            return Psctp
        }
    }
}

public enum IperfRole: Int8, Codable {
    case server = 115
    case client = 99
}

public enum IperfDirection: Int32, Codable {
    case download = 1
    case upload = 0
}

public struct IperfConfiguration {
    public var address: String? = "127.0.0.1"
    public var numStreams = 2
    public var role = IperfRole.client
    public var reverse = IperfDirection.download
    public var port = 5201
    public var prot = IperfProtocol.tcp

    public var rate: UInt64 = .init(1024 * 1024)

    public var duration: TimeInterval?
    public var numberOfBytes: UInt64?
    public var timeout: TimeInterval?
    public var tos: Int?

    public var reporterInterval: TimeInterval?
    public var statsInterval: TimeInterval?
    public var omit: Int = 0
    public var logfile: String?
    public var verbose: Bool = false
    
    // Authentication
    public var isAuth: Bool = false
    
    // Client
    public var publicKey: String = ""
    public var username: String = ""
    public var password: String = ""

    // Server
    public var privateKey: String = ""
    public var authorizedUsers: String = ""
    public var timeSkewThreshold: Int32 = 10
    
    public init() {}
}
