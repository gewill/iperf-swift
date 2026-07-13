//
//  File.swift
//
//
//  Created by Igor Kim on 08.11.20.
//

import Foundation
import IperfCLib

/// The transport protocol used by the iperf3 data streams.
public enum IperfProtocol: String, Codable {
    case tcp
    case udp
    case sctp

    /// The protocol identifier expected by libiperf.
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

/// The local endpoint's iperf3 role.
public enum IperfRole: Int8, Codable {
    /// Listens for an iperf3 client, equivalent to `iperf3 --server`.
    case server = 115
    /// Connects to an iperf3 server, equivalent to `iperf3 --client`.
    case client = 99
}

/// The direction of data transfer from the client's point of view.
public enum IperfDirection: Int32, Codable {
    /// The server sends data to the client, equivalent to `iperf3 --reverse`.
    case download = 1
    /// The client sends data to the server, which is iperf3's default direction.
    case upload = 0
}

/// Options used to configure one iperf3 server or client run.
///
/// Values generally correspond to the options in the
/// [official iperf3 manual](https://software.es.net/iperf/invoking.html).
/// Options that are not applicable to the selected role or protocol are ignored.
public struct IperfConfiguration {
    /// The remote server hostname/address for a client, or local bind address for a server.
    public var address: String? = "127.0.0.1"
    /// The interface used for socket binding, equivalent to `--bind-dev`.
    ///
    /// For example, use `lo0` for the loopback interface on macOS. Binding may
    /// require additional privileges on some platforms.
    public var bindDevice: String?
    /// The number of parallel TCP streams, equivalent to `--parallel`.
    public var numStreams = 2
    /// Whether the local endpoint runs as a client or server.
    public var role = IperfRole.client
    /// The data-flow direction for a client run.
    public var reverse = IperfDirection.download
    /// The server port to listen on or connect to. The iperf3 default is `5201`.
    public var port = 5201
    /// The transport protocol used by the data streams.
    public var prot = IperfProtocol.tcp

    /// The target UDP bitrate in bits per second, equivalent to `--bitrate`.
    public var rate: UInt64 = .init(1024 * 1024)

    /// The client test duration in seconds, equivalent to `--time`.
    ///
    /// Leave either this value or ``numberOfBytes`` unset because iperf3 accepts
    /// only one test end condition.
    public var duration: TimeInterval?
    /// The number of bytes the client should transmit before ending the test,
    /// equivalent to `--bytes`.
    public var numberOfBytes: UInt64?
    /// The client connection timeout in seconds, equivalent to `--connect-timeout`.
    public var timeout: TimeInterval?
    /// The client DSCP value in the range `0...63`, equivalent to `--dscp`.
    public var dscp: Int?

    /// The interval in seconds between reporter callbacks, equivalent to `--interval`.
    ///
    /// The wrapper uses this value for both libiperf's reporter and statistics intervals.
    public var reporterInterval: TimeInterval?
    /// Reserved for a separate libiperf statistics interval.
    ///
    /// The current wrapper configures statistics with ``reporterInterval``;
    /// setting this property alone has no effect.
    public var statsInterval: TimeInterval?
    /// The number of initial seconds omitted from measurements, equivalent to `--omit`.
    public var omit: Int = 0
    /// The path used for libiperf log output, equivalent to `--logfile`.
    public var logfile: String?
    /// Enables verbose libiperf output.
    public var verbose: Bool = false
    
    // MARK: Authentication

    /// Enables iperf3 RSA authentication for this endpoint.
    public var isAuth: Bool = false
    /// Uses legacy PKCS#1 v1.5 padding for compatibility with iperf3 versions before 3.17.
    ///
    /// Keep this disabled to use the official OAEP default. PKCS#1 v1.5 is less secure.
    public var usePkcs1Padding: Bool = false
    
    // MARK: Client authentication

    /// A PEM public key encoded as Base64 for client credential encryption.
    public var publicKey: String = ""
    /// The username sent by an authenticated client.
    public var username: String = ""
    /// The password sent by an authenticated client.
    public var password: String = ""

    // MARK: Server authentication

    /// An unencrypted PEM private key encoded as Base64 for server-side decryption.
    public var privateKey: String = ""
    /// Authorized-user content or a file path using iperf3's `username,sha256` format.
    public var authorizedUsers: String = ""
    /// The allowed client/server clock difference in seconds during authentication.
    public var timeSkewThreshold: Int32 = 10
    
    /// Creates a configuration using the wrapper's defaults.
    public init() {}
}
