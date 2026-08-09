//
//  errors.swift
//  iperf3-swift
//
//  Created by Igor Kim on 28.10.20.
//

import Foundation

/// Error codes emitted by libiperf and the Swift wrapper.
///
/// Values below `400` mirror the embedded iperf3 engine's `i_errno` values.
/// Values of `400` and above are defined by the Swift wrapper.
///
/// Conforms to `Error` so it can be thrown and bridged into `do`/`catch`, and
/// to `LocalizedError`/`CustomStringConvertible` so `localizedDescription` and
/// string interpolation yield the human-readable message.
public enum IperfError: Int32, CaseIterable, Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    /// An error code the wrapper does not recognize.
    case UNKNOWN = -1
    /// No error occurred.
    case IENONE = 0
    /* Parameter errors */
    /// The test cannot be both a server and a client.
    case IESERVCLIENT = 1
    /// The test must be either a client or a server.
    case IENOROLE = 2
    /// A configured option applies only to a server.
    case IESERVERONLY = 3
    /// A configured option applies only to a client.
    case IECLIENTONLY = 4
    /// The test duration exceeds the engine's `MAX_TIME` limit.
    case IEDURATION = 5
    /// The number of parallel streams exceeds `MAX_STREAMS`.
    case IENUMSTREAMS = 6
    /// The block size exceeds `MAX_BLOCKSIZE`.
    case IEBLOCKSIZE = 7
    /// The socket buffer size exceeds `MAX_TCP_BUFFER`.
    case IEBUFSIZE = 8
    /// The report interval is outside `MIN_INTERVAL...MAX_INTERVAL` seconds.
    case IEINTERVAL = 9
    /// The TCP maximum segment size exceeds `MAX_MSS`.
    case IEMSS = 10
    /// The operating system does not support `sendfile`.
    case IENOSENDFILE = 11
    /// The omit value is invalid.
    case IEOMIT = 12
    /// The requested feature is not implemented.
    case IEUNIMP = 13
    /// The `-F` transmit file could not be opened.
    case IEFILE = 14
    /// The burst count exceeds `MAX_BURST`.
    case IEBURST = 15
    /// More than one test end condition (`-t`, `-n`, `-k`) was specified.
    case IEENDCONDITIONS = 16
    /// The log file could not be opened.
    case IELOGFILE = 17
    /// The engine was built without SCTP support.
    case IENOSCTP = 18
    /// Unused by iperf3: a local port was specified without a local bind option.
    case IEBIND = 19
    /// The UDP block size is outside the valid range.
    case IEUDPBLOCKSIZE = 20
    /// The type-of-service value is invalid.
    case IEBADTOS = 21
    /// The client authentication options are incomplete or invalid.
    case IESETCLIENTAUTH = 22
    /// The server authentication options are incomplete or invalid.
    case IESETSERVERAUTH = 23
    /// The format argument to `-f` is invalid.
    case IEBADFORMAT = 24
    /// The test cannot be both reverse and bidirectional.
    case IEREVERSEBIDIR = 25
    /// The port number is outside the valid range.
    case IEBADPORT = 26
    /// The required total bandwidth is larger than the server's limit.
    case IETOTALRATE = 27
    /// The time interval for calculating the average data rate is invalid.
    case IETOTALINTERVAL = 28
    /// The time-skew threshold is invalid.
    case IESKEWTHRESHOLD = 29
    /// The idle timeout is not positive or exceeds the allowed limit.
    case IEIDLETIMEOUT = 30
    /// The receive timeout is out of range.
    case IERCVTIMEOUT = 31
    /// A client receive timeout is valid only in a receiving mode.
    case IERVRSONLYRCVTIMEOUT = 32
    /// The control-message send timeout is out of range.
    case IESNDTIMEOUT = 33
    /// File transfer is not supported by UDP.
    case IEUDPFILETRANSFER = 34
    /// The authorized-users file could not be accessed.
    case IESERVERAUTHUSERS = 35
    /// The control keepalive period is shorter than the full retry period.
    case IECNTLKA = 36
    /// The requested duration exceeds the server's maximum duration.
    case IEMAXSERVERTESTDURATIONEXCEEDED = 37
    /// A value or unit suffix is invalid.
    case IEUNITVAL = 38
    /* Test errors */
    /// The engine could not create a new test.
    case IENEWTEST = 100
    /// Test initialization failed.
    case IEINITTEST = 101
    /// The server could not listen for connections.
    case IELISTEN = 102
    /// The client could not connect to the server.
    case IECONNECT = 103
    /// The server could not accept a client connection.
    case IEACCEPT = 104
    /// The client could not send its cookie to the server.
    case IESENDCOOKIE = 105
    /// The server could not receive the client's cookie.
    case IERECVCOOKIE = 106
    /// Writing to the control socket failed.
    case IECTRLWRITE = 107
    /// Reading from the control socket failed.
    case IECTRLREAD = 108
    /// The control socket closed unexpectedly.
    case IECTRLCLOSE = 109
    /// An unknown control message was received.
    case IEMESSAGE = 110
    /// A control message could not be sent.
    case IESENDMESSAGE = 111
    /// A control message could not be received.
    case IERECVMESSAGE = 112
    /// The client could not send test parameters to the server.
    case IESENDPARAMS = 113
    /// The server could not receive test parameters from the client.
    case IERECVPARAMS = 114
    /// The endpoint could not package its results.
    case IEPACKAGERESULTS = 115
    /// The endpoint could not send its results.
    case IESENDRESULTS = 116
    /// The endpoint could not receive the remote endpoint's results.
    case IERECVRESULTS = 117
    /// A `select` call failed.
    case IESELECT = 118
    /// The client has terminated.
    case IECLIENTTERM = 119
    /// The server has terminated.
    case IESERVERTERM = 120
    /// The server is busy running another test.
    case IEACCESSDENIED = 121
    /// Setting TCP/SCTP `NODELAY` failed.
    case IESETNODELAY = 122
    /// Setting the TCP/SCTP maximum segment size failed.
    case IESETMSS = 123
    /// Setting the socket buffer size failed.
    case IESETBUF = 124
    /// Setting the IP type-of-service byte failed.
    case IESETTOS = 125
    /// Setting the IPv6 traffic class failed.
    case IESETCOS = 126
    /// Setting the IPv6 flow label failed.
    case IESETFLOW = 127
    /// Setting address reuse on the socket failed.
    case IEREUSEADDR = 128
    /// Setting the socket to non-blocking failed.
    case IENONBLOCKING = 129
    /// Setting the socket window size failed.
    case IESETWINDOWSIZE = 130
    /// The selected protocol is not registered with the engine.
    case IEPROTOCOL = 131
    /// Setting CPU affinity failed.
    case IEAFFINITY = 132
    /// The server could not become a daemon process.
    case IEDAEMON = 133
    /// Setting the TCP congestion-control algorithm failed.
    case IESETCONGESTION = 134
    /// Writing the PID file failed.
    case IEPIDFILE = 135
    /// Setting or clearing `IPV6_V6ONLY` failed.
    case IEV6ONLY = 136
    /// Setting SCTP fragmentation failed.
    case IESETSCTPDISABLEFRAG = 137
    /// Setting the SCTP number of streams failed.
    case IESETSCTPNSTREAM = 138
    /// Processing `sctp_bindx()` parameters failed.
    case IESETSCTPBINDX = 139
    /// Setting the socket pacing rate failed.
    case IESETPACING = 140
    /// The socket buffer size read back differs from the value written.
    case IESETBUF2 = 141
    /// Test authorization failed.
    case IEAUTHTEST = 142
    /// Binding the socket to a device failed.
    case IEBINDDEV = 143
    /// No message was received before the receive timeout expired.
    case IENOMSG = 144
    /// Setting the IP Do-Not-Fragment flag failed.
    case IESETDONTFRAGMENT = 145
    /// Binding to a device is not supported by the current system.
    case IEBINDDEVNOSUPPORT = 146
    /// A host device is valid only for an IPv6 link-local address.
    case IEHOSTDEV = 147
    /// Setting TCP `USER_TIMEOUT` failed.
    case IESETUSERTIMEOUT = 148
    /// Creating an engine thread failed.
    case IEPTHREADCREATE = 150
    /// Cancelling an engine thread failed.
    case IEPTHREADCANCEL = 151
    /// Joining an engine thread failed.
    case IEPTHREADJOIN = 152
    /// Initializing thread attributes failed.
    case IEPTHREADATTRINIT = 153
    /// Destroying thread attributes failed.
    case IEPTHREADATTRDESTROY = 154
    /// Setting control-socket keepalive failed.
    case IESETCNTLKA = 155
    /// Setting the control-socket keepalive idle period failed.
    case IESETCNTLKAKEEPIDLE = 156
    /// Setting the control-socket keepalive interval failed.
    case IESETCNTLKAINTERVAL = 157
    /// Setting the control-socket keepalive retry count failed.
    case IESETCNTLKACOUNT = 158
    /// Configuring the engine thread signal mask failed.
    case IEPTHREADSIGMASK = 159
    /// The server test duration expired.
    case IESERVERTESTDURATIONEXPIRED = 160
    /* Stream errors */
    /// The engine could not create a new stream.
    case IECREATESTREAM = 200
    /// The engine could not initialize a stream.
    case IEINITSTREAM = 201
    /// The stream listener could not be started.
    case IESTREAMLISTEN = 202
    /// A stream could not connect.
    case IESTREAMCONNECT = 203
    /// A stream connection could not be accepted.
    case IESTREAMACCEPT = 204
    /// Writing to a stream socket failed.
    case IESTREAMWRITE = 205
    /// Reading from a stream failed.
    case IESTREAMREAD = 206
    /// A stream closed unexpectedly.
    case IESTREAMCLOSE = 207
    /// A stream reported an invalid identifier.
    case IESTREAMID = 208
    /* Timer errors */
    /// The engine could not create a timer.
    case IENEWTIMER = 300
    /// The engine could not update a timer.
    case IEUPDATETIMER = 301

    /* Swift wrapper errors */
    /// `iperf_new_test` failed while the wrapper prepared the run.
    case INIT_ERROR = 400
    /// `iperf_defaults` failed while the wrapper prepared the run.
    case INIT_ERROR_DEFAULTS = 401
    /// A configured option applies only to TCP.
    case IETCPONLY = 402
    /// A configured option applies only to UDP.
    case IEUDPONLY = 403
    /// A configured option applies only to IPv4.
    case IEIPV4ONLY = 404
    /// The client connection timeout is invalid or out of range.
    case IECONNECTTIMEOUT = 405
    
    /// A human-readable description of the error code.
    public var debugDescription: String {
        switch self {
        case .UNKNOWN:
            return "Unknown error"
        case .IENONE:
            return "No error"
        /* Parameter errors */
        case .IESERVCLIENT:
            return "iPerf cannot be both server and client"
        case .IENOROLE:
            return "iPerf must either be a client (-c) or server (-s)"
        case .IESERVERONLY:
            return "This option is server only"
        case .IECLIENTONLY:
            return "This option is client only"
        case .IEDURATION:
            return "test duration too long. Maximum value = %dMAX_TIME"
        case .IENUMSTREAMS:
            return "Number of parallel streams too large. Maximum value = %dMAX_STREAMS"
        case .IEBLOCKSIZE:
            return "Block size too large. Maximum value = %dMAX_BLOCKSIZE"
        case .IEBUFSIZE:
            return "Socket buffer size too large. Maximum value = %dMAX_TCP_BUFFER"
        case .IEINTERVAL:
            return "Invalid report interval (min = %gMIN_INTERVAL max = %gMAX_INTERVAL seconds)"
        case .IEMSS:
            return "MSS too large. Maximum value = %dMAX_MSS"
        case .IENOSENDFILE:
            return "This OS does not support sendfile"
        case .IEOMIT:
            return "Bogus value for --omit"
        case .IEUNIMP:
            return "Not implemented yet"
        case .IEFILE:
            return "-F file couldn't be opened"
        case .IEBURST:
            return "Invalid burst count. Maximum value = %dMAX_BURST"
        case .IEENDCONDITIONS:
            return "Only one test end condition (-t -n -k) may be specified"
        case .IELOGFILE:
            return "Can't open log file"
        case .IENOSCTP:
            return "No SCTP support available"
        case .IEBIND:
            return "UNUSED:  Local port specified with no local bind option"
        case .IEUDPBLOCKSIZE:
            return "Block size invalid"
        case .IEBADTOS:
            return "Bad TOS value"
        case .IESETCLIENTAUTH:
            return "Bad configuration of client authentication"
        case .IESETSERVERAUTH:
            return "Bad configuration of server authentication"
        case .IEBADFORMAT:
            return "Bad format argument to -f"
        case .IEREVERSEBIDIR:
            return "iPerf cannot be both reverse and bidirectional"
        case .IEBADPORT:
            return "Bad port number"
        case .IETOTALRATE:
            return "Total required bandwidth is larger than server's limit"
        case .IETOTALINTERVAL:
            return "Invalid time interval for calculating average data rate"
        case .IESKEWTHRESHOLD:
            return "Invalid value specified as skew threshold"
        case .IEIDLETIMEOUT:
            return "Idle timeout parameter is not positive or larger than allowed limit"
        case .IERCVTIMEOUT:
            return "Receive timeout value is incorrect or not in range"
        case .IERVRSONLYRCVTIMEOUT:
            return "Client receive timeout is valid only in receiving mode"
        case .IESNDTIMEOUT:
            return "Send timeout value is incorrect or not in range"
        case .IEUDPFILETRANSFER:
            return "Cannot transfer file using UDP"
        case .IESERVERAUTHUSERS:
            return "Cannot access authorized users file"
        case .IECNTLKA:
            return "Control connection keepalive period should be larger than the full retry period"
        case .IEMAXSERVERTESTDURATIONEXCEEDED:
            return "Client's requested duration exceeds the server's maximum permitted limit"
        case .IEUNITVAL:
            return "Invalid unit value or suffix"
        /* Test errors */
        case .IENEWTEST:
            return "Unable to create a new test (check perror)"
        case .IEINITTEST:
            return "Test initialization failed (check perror)"
        case .IELISTEN:
            return "Unable to listen for connections (check perror)"
        case .IECONNECT:
            return "Unable to connect to server (check herror/perror) [from netdial]"
        case .IEACCEPT:
            return "Unable to accept connection from client (check herror/perror)"
        case .IESENDCOOKIE:
            return "Unable to send cookie to server (check perror)"
        case .IERECVCOOKIE:
            return "Unable to receive cookie from client (check perror)"
        case .IECTRLWRITE:
            return "Unable to write to the control socket (check perror)"
        case .IECTRLREAD:
            return "Unable to read from the control socket (check perror)"
        case .IECTRLCLOSE:
            return "Control socket has closed unexpectedly"
        case .IEMESSAGE:
            return "Received an unknown message"
        case .IESENDMESSAGE:
            return "Unable to send control message to client/server (check perror)"
        case .IERECVMESSAGE:
            return "Unable to receive control message from client/server (check perror)"
        case .IESENDPARAMS:
            return "Unable to send parameters to server (check perror)"
        case .IERECVPARAMS:
            return "Unable to receive parameters from client (check perror)"
        case .IEPACKAGERESULTS:
            return "Unable to package results (check perror)"
        case .IESENDRESULTS:
            return "Unable to send results to client/server (check perror)"
        case .IERECVRESULTS:
            return "Unable to receive results from client/server (check perror)"
        case .IESELECT:
            return "Select failed (check perror)"
        case .IECLIENTTERM:
            return "The client has terminated"
        case .IESERVERTERM:
            return "The server has terminated"
        case .IEACCESSDENIED:
            return "The server is busy running a test. Try again later."
        case .IESETNODELAY:
            return "Unable to set TCP/SCTP NODELAY (check perror)"
        case .IESETMSS:
            return "Unable to set TCP/SCTP MSS (check perror)"
        case .IESETBUF:
            return "Unable to set socket buffer size (check perror)"
        case .IESETTOS:
            return "Unable to set IP TOS (check perror)"
        case .IESETCOS:
            return "Unable to set IPv6 traffic class (check perror)"
        case .IESETFLOW:
            return "Unable to set IPv6 flow label"
        case .IEREUSEADDR:
            return "Unable to set reuse address on socket (check perror)"
        case .IENONBLOCKING:
            return "Unable to set socket to non-blocking (check perror)"
        case .IESETWINDOWSIZE:
            return "Unable to set socket window size (check perror)"
        case .IEPROTOCOL:
            return "Protocol does not exist"
        case .IEAFFINITY:
            return "Unable to set CPU affinity (check perror)"
        case .IEDAEMON:
            return "Unable to become a daemon process"
        case .IESETCONGESTION:
            return "Unable to set TCP_CONGESTION"
        case .IEPIDFILE:
            return "Unable to write PID file"
        case .IEV6ONLY:
            return "Unable to set/unset IPV6_V6ONLY (check perror)"
        case .IESETSCTPDISABLEFRAG:
            return "Unable to set SCTP Fragmentation (check perror)"
        case .IESETSCTPNSTREAM:
            return "Unable to set SCTP number of streams (check perror)"
        case .IESETSCTPBINDX:
            return "Unable to process sctp_bindx() parameters"
        case .IESETPACING:
            return "Unable to set socket pacing rate"
        case .IESETBUF2:
            return "Socket buffer size incorrect (written value != read value)"
        case .IEAUTHTEST:
            return "Test authorization failed"
        case .IEBINDDEV:
            return "Unable to bind to network device"
        case .IENOMSG:
            return "No message was received before the timeout expired"
        case .IESETDONTFRAGMENT:
            return "Unable to set IP Do-Not-Fragment flag"
        case .IEBINDDEVNOSUPPORT:
            return "Binding to a device is not supported on this system"
        case .IEHOSTDEV:
            return "A host device is valid only for an IPv6 link-local address"
        case .IESETUSERTIMEOUT:
            return "Unable to set TCP USER_TIMEOUT"
        case .IEPTHREADCREATE:
            return "Unable to create engine thread"
        case .IEPTHREADCANCEL:
            return "Unable to cancel engine thread"
        case .IEPTHREADJOIN:
            return "Unable to join engine thread"
        case .IEPTHREADATTRINIT:
            return "Unable to initialize thread attributes"
        case .IEPTHREADATTRDESTROY:
            return "Unable to destroy thread attributes"
        case .IESETCNTLKA:
            return "Unable to set control-socket keepalive"
        case .IESETCNTLKAKEEPIDLE:
            return "Unable to set control-socket keepalive idle period"
        case .IESETCNTLKAINTERVAL:
            return "Unable to set control-socket keepalive interval"
        case .IESETCNTLKACOUNT:
            return "Unable to set control-socket keepalive retry count"
        case .IEPTHREADSIGMASK:
            return "Unable to configure engine thread signal mask"
        case .IESERVERTESTDURATIONEXPIRED:
            return "Server test duration expired"
        /* Stream errors */
        case .IECREATESTREAM:
            return "Unable to create a new stream (check herror/perror)"
        case .IEINITSTREAM:
            return "Unable to initialize stream (check herror/perror)"
        case .IESTREAMLISTEN:
            return "Unable to start stream listener (check perror)"
        case .IESTREAMCONNECT:
            return "Unable to connect stream (check herror/perror)"
        case .IESTREAMACCEPT:
            return "Unable to accepte stream connection (check perror)"
        case .IESTREAMWRITE:
            return "Unable to write to stream socket (check perror)"
        case .IESTREAMREAD:
            return "Unable to read from stream (check perror)"
        case .IESTREAMCLOSE:
            return "Stream has closed unexpectedly"
        case .IESTREAMID:
            return "Stream has invalid ID"
        /* Timer errors */
        case .IENEWTIMER:
            return "Unable to create new timer (check perror)"
        case .IEUPDATETIMER:
            return "Unable to update timer (check perror)"
        case .INIT_ERROR:
            return "iperf_new_test failed"
        case .INIT_ERROR_DEFAULTS:
            return "iperf_defaults failed"
        case .IETCPONLY:
            return "This option is TCP only"
        case .IEUDPONLY:
            return "This option is UDP only"
        case .IEIPV4ONLY:
            return "This option is IPv4 only"
        case .IECONNECTTIMEOUT:
            return "Client connection timeout is invalid or out of range"
        }
    }

    /// A human-readable description of the error code.
    ///
    /// Mirrors ``debugDescription`` so string interpolation of an
    /// ``IperfError`` yields the same message.
    public var description: String {
        debugDescription
    }

    /// A localized message describing the error, used by
    /// `Error.localizedDescription`.
    ///
    /// The wrapper does not currently localize the messages, so this returns
    /// the same English text as ``debugDescription``.
    public var errorDescription: String? {
        debugDescription
    }
}
