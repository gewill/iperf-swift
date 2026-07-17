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

/// The IP address family used to resolve and connect, equivalent to `-4`/`-6`.
public enum IperfAddressFamily: String, Codable {
    /// Let the resolver pick the family, which is iperf3's default.
    case any
    /// Force IPv4, equivalent to `-4`.
    case ipv4
    /// Force IPv6, equivalent to `-6`.
    case ipv6

    /// The socket domain expected by libiperf.
    public var iperfConfigValue: Int32 {
        switch self {
        case .any:
            return AF_UNSPEC
        case .ipv4:
            return AF_INET
        case .ipv6:
            return AF_INET6
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

/// The data-flow mode for a client test.
public enum IperfTestMode: String, Codable {
    /// The client sends data to the server.
    case upload
    /// The server sends data to the client, equivalent to `iperf3 --reverse`.
    case download
    /// The client and server send data simultaneously, equivalent to `iperf3 --bidir`.
    case bidirectional
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
    /// The number of parallel client streams, equivalent to `--parallel`.
    public var numStreams = 2
    /// Whether the local endpoint runs as a client or server.
    public var role = IperfRole.client
    /// The data-flow mode for a client run.
    public var mode = IperfTestMode.download
    /// Compatibility access to the unidirectional client mode.
    ///
    /// Setting this property selects upload or download mode. In bidirectional
    /// mode, reading it returns ``IperfDirection/upload`` because libiperf's
    /// reverse flag is disabled. Assigning the value the property already
    /// returns leaves ``mode`` unchanged, so a read-write round trip does not
    /// cancel bidirectional mode.
    public var reverse: IperfDirection {
        get { mode == .download ? .download : .upload }
        set {
            if newValue == reverse { return }
            mode = newValue == .download ? .download : .upload
        }
    }
    /// The IP address family used for name resolution and sockets,
    /// equivalent to `-4`/`-6`.
    public var addressFamily: IperfAddressFamily = .any
    /// The server port to listen on or connect to. The iperf3 default is `5201`.
    public var port = 5201
    /// The transport protocol used by the data streams.
    public var prot = IperfProtocol.tcp

    /// The target bitrate in bits per second, equivalent to `--bitrate`.
    ///
    /// Applies application-level pacing to any protocol. Leave unset to use
    /// the iperf3 defaults: unlimited for TCP/SCTP and 1 Mbit/s for UDP.
    public var rate: UInt64?
    /// The read/write block size in bytes, equivalent to `--length`.
    ///
    /// For UDP this is the exact datagram payload size. Leave unset to use the
    /// iperf3 defaults: 128 KB for TCP, a dynamic MSS-based size for UDP, and
    /// 64 KB for SCTP.
    public var blockSize: Int?
    /// The socket buffer size in bytes, equivalent to `--window`.
    public var socketBufferSize: Int?
    /// Disables Nagle's algorithm on TCP streams, equivalent to `--no-delay`.
    public var noDelay: Bool = false
    /// The TCP maximum segment size, equivalent to `--set-mss`.
    ///
    /// Support depends on the platform and route; macOS rejects it on loopback
    /// connections, and the run then fails with ``IperfError/IESETMSS`` exactly
    /// like the official CLI.
    public var mss: Int?

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
    /// The full IP type-of-service byte in the range `0...255`, equivalent to `--tos`.
    ///
    /// Unlike ``dscp`` this also covers the ECN bits. When both are set,
    /// this value wins because it is applied last.
    public var tos: Int?
    /// The local port the client binds to, equivalent to `--cport`.
    ///
    /// Leave unset to use an ephemeral port.
    public var clientPort: Int?
    /// Uses 64-bit packet counters in UDP test packets, equivalent to
    /// `--udp-counters-64bit`.
    ///
    /// Prevents 32-bit counter wrap-around in long or high-rate UDP tests.
    public var udpCounters64Bit: Bool = false
    /// Fills payloads with a repeating pattern instead of random data,
    /// equivalent to `--repeating-payload`.
    ///
    /// Useful as a control when the link performs compression or
    /// deduplication, which inflates results for random payloads.
    public var repeatingPayload: Bool = false
    /// Requests the server-side results text after a client run, equivalent
    /// to `--get-server-output`.
    ///
    /// The text becomes available through ``IperfRunner/serverOutput``.
    public var getServerOutput: Bool = false
    /// Sets the IP Do-Not-Fragment flag on UDP packets, equivalent to
    /// `--dont-fragment`.
    ///
    /// Datagrams larger than the path MTU then fail to send, matching the
    /// CLI: the run completes with zero transferred packets.
    public var dontFragment: Bool = false

    // MARK: Server behavior

    /// Stops the server after handling one client connection, equivalent to
    /// `--one-off`. The runner then reaches ``IperfRunnerState/finished``
    /// without an explicit ``IperfRunner/stop()``.
    public var oneOff: Bool = false
    /// The number of seconds after which an idle server restarts, equivalent
    /// to `--idle-timeout`.
    public var idleTimeout: TimeInterval?
    /// The timeout in seconds for receiving data in an active test,
    /// equivalent to `--rcv-timeout` (which the CLI expresses in
    /// milliseconds). The iperf3 default is 120 seconds.
    public var rcvTimeout: TimeInterval?

    /// The interval in seconds between reporter callbacks, equivalent to `--interval`.
    ///
    /// Statistics sampling also follows this value unless ``statsInterval`` is set.
    public var reporterInterval: TimeInterval?
    /// The interval in seconds between libiperf statistics samples.
    ///
    /// Leave unset to sample statistics at ``reporterInterval``.
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
