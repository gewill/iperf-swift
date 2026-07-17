//
//  IperfRunner.swift
//  iperf3-swift
//
//  Created by Igor Kim on 27.10.20.
//

import Foundation
import IperfCLib

/// High-level lifecycle states emitted by ``IperfRunner``.
public enum IperfRunnerState {
    case unknown
    case ready
    case initialising
    case running
    case error
    case stopping
    case finished
}

/// Low-level states reported by the embedded libiperf engine.
public enum IperfState: Int8 {
    case TEST_START = 1
    case TEST_RUNNING = 2
    case TEST_END = 4
    case PARAM_EXCHANGE = 9
    case CREATE_STREAMS = 10
    case SERVER_TERMINATE = 11
    case CLIENT_TERMINATE = 12
    case EXCHANGE_RESULTS = 13
    case DISPLAY_RESULTS = 14
    case IPERF_START = 15
    case IPERF_DONE = 16
    case ACCESS_DENIED = -1
    case SERVER_ERROR = -2
    
    case UNKNOWN = 0
}

/// Receives one interval result from libiperf.
public typealias reporterFunctionType = (_ result: IperfIntervalResult) -> Void
/// Receives a terminal libiperf or wrapper error.
public typealias errorFunctionType = (_ error: IperfError) -> Void
/// Receives a high-level runner lifecycle change.
public typealias runnerStateFunctionType = (_ state: IperfRunnerState) -> Void

/// Runs the embedded iperf3 engine as a client or server.
///
/// A runner performs its work on a background queue. Callback delivery is not
/// guaranteed on a specific queue, so callers must dispatch UI updates to the
/// main actor or main queue. Use one runner for one active test at a time.
public class IperfRunner {
    private var onReporterFunction: reporterFunctionType = {result in }
    private var onErrorFunction: errorFunctionType = {error in }
    private var onRunnerStateFunction: runnerStateFunctionType = {error in }
    
    private var configuration: IperfConfiguration? = nil
    private var observer: NSObjectProtocol? = nil
    private var currentTest: UnsafeMutablePointer<iperf_test>? = nil
    
    private var state: IperfRunnerState = .ready {
        willSet {
            onRunnerStateFunction(newValue)
        }
    }
    
    // MARK: Initializers

    /// Creates a runner with the configuration used by ``start(_:_:_:)``.
    /// - Parameter configuration: The client or server options for the run.
    public init(with configuration: IperfConfiguration) {
        self.configuration = configuration
    }
    
    // MARK: Callbacks
    private let reporterCallback: @convention(c) (UnsafeMutablePointer<iperf_test>?) -> Void = { refTest in
        iperf_reporter_callback(refTest)
        DispatchQueue.main.async {
            if let testPointer = refTest {
                let testUID = String(testPointer.hashValue)
                NotificationCenter.default.post(name: Notification.Name(IperfNotificationName.status.rawValue + testUID), object: refTest)
            }
        }
    }
    
    private func reporterNotificationCallback(notification: Notification) {
        if state != .running {
            return
        }
        guard let pointer = notification.object as? UnsafeMutablePointer<iperf_test>,
              let configuration = configuration else {
            return
        }
        
        let runningTest = pointer.pointee
        var result = IperfIntervalResult(prot: configuration.prot)
        result.debugDescription = "OK"
        result.state = IperfState(rawValue: runningTest.state) ?? .UNKNOWN
        result.reverse = runningTest.reverse
        if runningTest.bidirectional != 0 {
            result.mode = .bidirectional
        } else if runningTest.reverse != 0 {
            result.mode = .download
        } else {
            result.mode = .upload
        }
        
        if result.state == .EXCHANGE_RESULTS {
            state = .finished
        }

        if result.state == .IPERF_DONE {
            state = .finished
            if configuration.role == .server {
                return
            }
        }
        
        guard var stream: UnsafeMutablePointer<iperf_stream> = runningTest.streams.slh_first else {
            return
        }
        while true {
            let intervalResultsP: UnsafeMutablePointer<iperf_interval_results>? = extract_iperf_interval_results(OpaquePointer(stream))
            if let intervalResults = intervalResultsP?.pointee {
                if intervalResults.omitted == 0 {
                    var streamResult = IperfStreamIntervalResult(intervalResults)
                    let localEndpointIsSender = stream.pointee.sender != 0
                    streamResult.direction = configuration.role == .client
                        ? (localEndpointIsSender ? .upload : .download)
                        : (localEndpointIsSender ? .download : .upload)
                    result.streams.append(streamResult)
                }
            }
            if stream.pointee.streams.sle_next == nil {
                break
            }
            stream = stream.pointee.streams.sle_next
        }
        
        // Calculate sum/average over streams
        result.evaluate()
        
        onReporterFunction(result)
    }
    
    // MARK: Private methods
    private func applyConfiguration() {
        guard let configuration = configuration else {
            return
        }
        
        var addr: UnsafePointer<Int8>? = nil
        if let address = configuration.address, !address.isEmpty {
            addr = NSString(string: address).utf8String
        }
        
        // Server/Client
        iperf_set_test_role(currentTest, configuration.role.rawValue)
        iperf_set_test_server_port(currentTest, Int32(configuration.port))
        
        if let reporterInterval = configuration.reporterInterval {
            iperf_set_test_reporter_interval(currentTest, Double(reporterInterval))
        }
        if let statsInterval = configuration.statsInterval ?? configuration.reporterInterval {
            iperf_set_test_stats_interval(currentTest, Double(statsInterval))
        }
        if configuration.omit > 0 {
            iperf_set_test_omit(currentTest, Int32(configuration.omit))
        }
        if let logfile = configuration.logfile {
            iperf_set_test_logfile(currentTest, logfile)
        }
        iperf_set_verbose(currentTest, configuration.verbose ? 1 : 0)
        
        if configuration.role == .server {
            if let addr = addr {
                iperf_set_test_bind_address(currentTest, addr)
            }
            if let bindDevice = configuration.bindDevice {
                iperf_set_test_bind_dev(currentTest, bindDevice)
            }
            
            if configuration.isAuth {
                iperf_set_test_server_rsa_privkey(currentTest, configuration.privateKey)
                iperf_set_test_server_authorized_users(currentTest, configuration.authorizedUsers)
                iperf_set_test_server_skew_threshold(currentTest, configuration.timeSkewThreshold)
            }
        }
        
        if configuration.role == .client {
            set_protocol(currentTest, configuration.prot.iperfConfigValue)
            switch configuration.mode {
            case .upload:
                iperf_set_test_bidirectional(currentTest, 0)
                iperf_set_test_reverse(currentTest, 0)
            case .download:
                iperf_set_test_bidirectional(currentTest, 0)
                iperf_set_test_reverse(currentTest, 1)
            case .bidirectional:
                iperf_set_test_reverse(currentTest, 0)
                iperf_set_test_bidirectional(currentTest, 1)
            }
            
            iperf_set_test_num_streams(currentTest, Int32(clamping: configuration.numStreams))

            var blksize: Int32
            switch configuration.prot {
            case .tcp:
                blksize = DEFAULT_TCP_BLKSIZE
            case .udp:
                // Zero selects libiperf's dynamic MSS-based datagram size.
                blksize = 0
            case .sctp:
                blksize = DEFAULT_SCTP_BLKSIZE
            }
            if let blockSize = configuration.blockSize {
                blksize = Int32(clamping: blockSize)
            }
            iperf_set_test_blksize(currentTest, blksize)

            if let rate = configuration.rate {
                iperf_set_test_rate(currentTest, rate)
            }
            if let socketBufferSize = configuration.socketBufferSize {
                iperf_set_test_socket_bufsize(currentTest, Int32(clamping: socketBufferSize))
            }
            if configuration.noDelay {
                iperf_set_test_no_delay(currentTest, 1)
            }
            if let mss = configuration.mss {
                iperf_set_test_mss(currentTest, Int32(clamping: mss))
            }
            
            if let addr = addr {
                iperf_set_test_server_hostname(currentTest, addr)
            }
            if let bindDevice = configuration.bindDevice {
                iperf_set_test_bind_dev(currentTest, bindDevice)
            }
            if let duration = configuration.duration {
                iperf_set_test_duration(currentTest, Int32(duration))
            }
            if let numberOfBytes = configuration.numberOfBytes {
                iperf_set_test_bytes(currentTest, UInt64(numberOfBytes))
            }
            if let timeout = configuration.timeout, timeout.isFinite, timeout > 0 {
                let milliseconds = min(timeout * 1000, Double(Int32.max))
                iperf_set_test_connect_timeout(currentTest, Int32(milliseconds))
            }
            if let dscp = configuration.dscp {
                iperf_set_test_dscp(currentTest, Int32(dscp))
            }
            
            if configuration.isAuth {
                iperf_set_test_client_rsa_pubkey(currentTest, configuration.publicKey)
                iperf_set_test_client_username(currentTest, configuration.username)
                iperf_set_test_client_password(currentTest, configuration.password)
            }
        }

        if configuration.isAuth {
            iperf_set_test_use_pkcs1_padding(currentTest, configuration.usePkcs1Padding ? 1 : 0)
        }
    }
    
    private func startIperfProcess() {
        DispatchQueue.global(qos: .userInitiated).async {
            i_errno = IperfError.IENONE.rawValue
            
            DispatchQueue.main.sync { self.state = .running }
            
            var code: Int32
            if let configuration = self.configuration,
               configuration.role == .client {
                code = iperf_run_client(self.currentTest)
            } else {
                code = iperf_run_server(self.currentTest)
            }
            if code < 0 || i_errno != IperfError.IENONE.rawValue,
               self.currentTest?.pointee.done == 0 {
                self.onError(IperfError.init(rawValue: i_errno) ?? .UNKNOWN)
            } else {
                guard let configuration = self.configuration else {
                    return self.cleanState()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (configuration.reporterInterval ?? 2.0)) {
                    if self.currentTest != nil {
                        self.cleanState()
                    }
                }
            }
        }
    }
    
    private func cleanState(isExit: Bool = true) {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        
        if isExit && configuration != nil {
            configuration = nil
        }
        if currentTest != nil {
            iperf_free_test(currentTest)
            currentTest = nil
        }
        if isExit && (state == .running || state == .stopping) {
            state = .finished
        }
    }
    
    private func onError(_ error: IperfError) {
        state = .error
        onErrorFunction(error)
        
        cleanState()
        // Reset global error code
        i_errno = IperfError.IENONE.rawValue
    }
    
    // MARK: Public methods

    /// Starts a run after replacing the runner's configuration.
    ///
    /// Use this overload when reusing a runner after a completed run.
    /// - Parameters:
    ///   - configuration: The client or server options for this run.
    ///   - onReporter: Called when an interval result is available.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    public func start(
        with configuration: IperfConfiguration,
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType)
    {
        self.configuration = configuration
        self.start(onReporter, onError, onRunnerState)
    }
    
    /// Starts a run with the configuration supplied at initialization.
    /// - Parameters:
    ///   - onReporter: Called when an interval result is available.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    public func start(
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType
    ) {
        signal(SIGPIPE, SIG_IGN)
        onReporterFunction = onReporter
        onErrorFunction = onError
        onRunnerStateFunction = onRunnerState
        
        cleanState(isExit: false)
        state = .initialising
        
        currentTest = iperf_new_test()
        guard let testPointer = currentTest else {
            return self.onError(.INIT_ERROR)
        }
        
        let code = iperf_defaults(currentTest)
        if code < 0 {
            return self.onError(.INIT_ERROR_DEFAULTS)
        }

        applyConfiguration()
        
        // Configure callbacks and notifications.
        testPointer.pointee.reporter_callback = reporterCallback
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(IperfNotificationName.status.rawValue + String(testPointer.hashValue)),
            object: nil,
            queue: nil,
            using: reporterNotificationCallback
        )
        
        startIperfProcess()
    }
    
    /// Requests cancellation of the active run.
    ///
    /// Calling this method when no test is active has no effect. State changes
    /// are reported asynchronously through the runner-state callback.
    public func stop() {
        guard let pointer = currentTest else {
            return
        }
        
        state = .stopping
        if pointer.pointee.state != IPERF_DONE {
            pointer.pointee.done = 1
            if let configuration = configuration,
               configuration.role == .server {
                shutdown(pointer.pointee.listener, SHUT_RDWR)
                close(pointer.pointee.listener)
            }
        }
    }
}
