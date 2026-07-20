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

    /// The protocol identifier expected by libiperf.
    public var iperfConfigValue: Int32 {
        switch self {
        case .tcp:
            return Ptcp
        case .udp:
            return Pudp
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
/// Explicitly set options that do not apply to the selected role, transport,
/// or forced address family are rejected before the run starts.
public struct IperfConfiguration {
    private enum Field: Hashable {
        case numStreams
        case mode
        case prot
        case omit
        case timeSkewThreshold
    }

    private var explicitlySet: Set<Field> = []

    /// The remote server hostname/address for a client, or local bind address for a server.
    public var address: String? = "127.0.0.1"
    /// The interface used for socket binding, equivalent to `--bind-dev`.
    ///
    /// For example, use `lo0` for the loopback interface on macOS. Binding may
    /// require additional privileges on some platforms.
    public var bindDevice: String?
    /// The number of parallel client streams in `1...128`, equivalent to `--parallel`.
    public var numStreams = 2 {
        didSet { explicitlySet.insert(.numStreams) }
    }
    /// Whether the local endpoint runs as a client or server.
    public var role = IperfRole.client
    /// The data-flow mode for a client run.
    public var mode = IperfTestMode.download {
        didSet { explicitlySet.insert(.mode) }
    }
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
            if mode == .bidirectional && newValue == .upload { return }
            mode = newValue == .download ? .download : .upload
        }
    }
    /// The IP address family used for name resolution and sockets,
    /// equivalent to `-4`/`-6`.
    public var addressFamily: IperfAddressFamily = .any
    /// The server port to listen on or connect to. The iperf3 default is `5201`.
    public var port = 5201
    /// The transport protocol used by the data streams.
    public var prot = IperfProtocol.tcp {
        didSet { explicitlySet.insert(.prot) }
    }

    /// The target bitrate in bits per second, equivalent to `--bitrate`.
    ///
    /// Applies application-level pacing to any protocol. Leave unset for the
    /// CLI defaults: unlimited for TCP and 1 Mbit/s for UDP, which the
    /// wrapper enforces explicitly because the engine's own default is
    /// unlimited for every protocol.
    public var rate: UInt64?
    /// The read/write block size in bytes, equivalent to `--length`.
    ///
    /// This option applies to both transports. For UDP it is the exact datagram
    /// payload size. Leave unset or use a non-positive value for the iperf3
    /// defaults: 128 KB for TCP and a dynamic MSS-based size for UDP.
    public var blockSize: Int?
    /// The socket buffer size in `0...512 MiB`, equivalent to `--window`.
    /// Zero keeps socket autotuning/default behavior.
    public var socketBufferSize: Int?
    /// Disables Nagle's algorithm on TCP streams, equivalent to `--no-delay`.
    /// Enabling this for UDP fails with ``IperfError/IETCPONLY``.
    public var noDelay: Bool = false
    /// The TCP maximum segment size in `0...32,767`, equivalent to `--set-mss`.
    ///
    /// Zero keeps the engine default. Support depends on the platform and route;
    /// macOS rejects nonzero values on loopback
    /// connections, and the run then fails with ``IperfError/IESETMSS`` exactly
    /// like the official CLI. Setting this for UDP fails with
    /// ``IperfError/IETCPONLY``.
    public var mss: Int?

    /// The client test duration in seconds, equivalent to `--time`.
    ///
    /// Combining any explicitly set duration (including zero) with a nonzero
    /// ``numberOfBytes`` fails with ``IperfError/IEENDCONDITIONS``.
    public var duration: TimeInterval?
    /// The number of bytes the client should transmit before ending the test,
    /// equivalent to `--bytes`. Zero does not select a byte end condition.
    public var numberOfBytes: UInt64?
    /// The client connection timeout in seconds, equivalent to `--connect-timeout`.
    ///
    /// Zero keeps the engine default. Positive values are truncated to whole
    /// milliseconds and must fit in a signed 32-bit millisecond value.
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
    /// Leave unset to use ephemeral ports. Parallel streams use consecutive
    /// ports; bidirectional tests reserve a second consecutive range.
    public var clientPort: Int?
    /// Uses 64-bit packet counters in UDP test packets, equivalent to
    /// `--udp-counters-64bit`.
    ///
    /// Prevents 32-bit counter wrap-around in long or high-rate UDP tests.
    /// Enabling this for TCP fails with ``IperfError/IEUDPONLY``.
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
    /// Sets the IPv4 Do-Not-Fragment flag on UDP packets, equivalent to
    /// `--dont-fragment`. Enabling this for TCP or forced IPv6 fails with
    /// ``IperfError/IEUDPONLY`` or ``IperfError/IEIPV4ONLY`` respectively.
    ///
    /// Datagrams larger than the path MTU then fail to send, matching the
    /// CLI: the run completes with zero transferred packets. With
    /// ``addressFamily`` set to ``IperfAddressFamily/any``, the flag takes
    /// effect only when resolution selects IPv4.
    public var dontFragment: Bool = false

    // MARK: Server behavior

    /// Stops the server after handling one client connection, equivalent to
    /// `--one-off`. The runner then reaches ``IperfRunnerState/finished``
    /// without an explicit ``IperfRunner/stop()``.
    public var oneOff: Bool = false
    /// The number of seconds after which an idle server restarts, equivalent
    /// to `--idle-timeout`.
    ///
    /// Positive values are rounded up to whole seconds in `1...86,400`.
    public var idleTimeout: TimeInterval?
    /// The timeout in seconds for receiving data in an active test,
    /// equivalent to `--rcv-timeout` (which the CLI expresses in
    /// milliseconds). Valid values are `0.1...86_400`; the iperf3 default is
    /// 120 seconds.
    public var rcvTimeout: TimeInterval?

    /// The interval in seconds between reporter callbacks, equivalent to `--interval`.
    ///
    /// The wrapper uses this value for both libiperf's reporter and statistics
    /// intervals. Zero disables periodic callbacks; nonzero values must be in
    /// `0.000001...60`, matching the embedded timer's microsecond precision.
    public var reporterInterval: TimeInterval?
    /// Unused: statistics always sample at ``reporterInterval``.
    ///
    /// The embedded engine retains only the newest statistics sample per
    /// stream, so a decoupled statistics interval would drop traffic from
    /// interval results or produce empty reports. The wrapper therefore
    /// keeps both intervals in sync and ignores this property.
    public var statsInterval: TimeInterval?
    /// The number of initial seconds omitted from measurements, equivalent to `--omit`.
    public var omit: Int = 0 {
        didSet { explicitlySet.insert(.omit) }
    }
    /// The path used for libiperf log output, equivalent to `--logfile`.
    public var logfile: String?
    /// Enables verbose libiperf output.
    public var verbose: Bool = false
    
    // MARK: Authentication

    /// Enables iperf3 RSA authentication for this endpoint.
    ///
    /// Clients must also provide ``username``, ``password``, and a decodable
    /// ``publicKey``. Servers must provide a decodable ``privateKey``, nonempty
    /// ``authorizedUsers``, and a positive ``timeSkewThreshold``.
    public var isAuth: Bool = false
    /// Uses legacy PKCS#1 v1.5 padding for compatibility with iperf3 versions before 3.17.
    ///
    /// Keep this disabled to use the official OAEP default. PKCS#1 v1.5 is less secure.
    /// Enabling this while ``isAuth`` is false fails authentication preflight.
    public var usePkcs1Padding: Bool = false
    
    // MARK: Client authentication

    /// A PEM public key encoded as Base64 for authenticated client encryption.
    public var publicKey: String = ""
    /// The nonempty username sent by an authenticated client.
    public var username: String = ""
    /// The nonempty password sent by an authenticated client.
    public var password: String = ""

    // MARK: Server authentication

    /// An unencrypted PEM private key encoded as Base64 for authenticated server decryption.
    public var privateKey: String = ""
    /// Nonempty authorized-user content or a file path using iperf3's
    /// `username,sha256` format.
    public var authorizedUsers: String = ""
    /// The positive client/server clock-difference limit in seconds during server authentication.
    public var timeSkewThreshold: Int32 = 10 {
        didSet { explicitlySet.insert(.timeSkewThreshold) }
    }
    
    /// Creates a configuration using the wrapper's defaults.
    public init() {}
}

extension IperfConfiguration {
    func hasAuthenticationOptionForSelectedRole() -> Bool {
        switch role {
        case .client:
            return usePkcs1Padding
                || !username.isEmpty
                || !password.isEmpty
                || !publicKey.isEmpty
        case .server:
            return usePkcs1Padding
                || !privateKey.isEmpty
                || !authorizedUsers.isEmpty
                || explicitlySet.contains(.timeSkewThreshold)
        }
    }

    /// Returns the iperf3-compatible error for an explicitly configured option
    /// that does not apply to the selected role or mode.
    func roleApplicabilityError() -> IperfError? {
        switch role {
        case .client:
            let hasServerOnlyOption = oneOff
                || idleTimeout != nil
                || !privateKey.isEmpty
                || !authorizedUsers.isEmpty
                || explicitlySet.contains(.timeSkewThreshold)
            if hasServerOnlyOption {
                return .IESERVERONLY
            }

            if mode == .upload, rcvTimeout != nil {
                return .IERVRSONLYRCVTIMEOUT
            }

        case .server:
            let hasTrackedClientOnlyOption = explicitlySet.contains(.numStreams)
                || explicitlySet.contains(.mode)
                || explicitlySet.contains(.prot)
                || explicitlySet.contains(.omit)
            let hasOptionalClientOnlyOption = rate != nil
                || duration != nil
                || numberOfBytes != nil
                || blockSize != nil
                || socketBufferSize != nil
                || mss != nil
                || tos != nil
                || dscp != nil
                || timeout != nil
                || clientPort != nil
            let hasBooleanClientOnlyOption = noDelay
                || repeatingPayload
                || getServerOutput
                || udpCounters64Bit
                || dontFragment
            let hasClientAuthenticationOption = !username.isEmpty
                || !publicKey.isEmpty
                || !password.isEmpty

            if hasTrackedClientOnlyOption
                || hasOptionalClientOnlyOption
                || hasBooleanClientOnlyOption
                || hasClientAuthenticationOption {
                return .IECLIENTONLY
            }
        }

        // The CLI classifies usePkcs1Padding as server-only, but the wrapper
        // uses it for client encryption as well as server decryption.
        return nil
    }

    /// Returns a wrapper-defined error for an enabled option that the selected
    /// transport or forced address family cannot honor.
    func protocolApplicabilityError() -> IperfError? {
        guard role == .client else {
            return nil
        }

        switch prot {
        case .tcp:
            if udpCounters64Bit || dontFragment {
                return .IEUDPONLY
            }

        case .udp:
            if noDelay || mss != nil {
                return .IETCPONLY
            }
            if dontFragment, addressFamily == .ipv6 {
                return .IEIPV4ONLY
            }
        }

        return nil
    }
}
