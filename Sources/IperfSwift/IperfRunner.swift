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
    private let stateQueue = DispatchQueue(label: "com.gewill.IperfSwift.runner-state")
    private let stateQueueKey = DispatchSpecificKey<Void>()

    private var onReporterFunction: reporterFunctionType = {result in }
    private var onErrorFunction: errorFunctionType = {error in }
    private var onRunnerStateFunction: runnerStateFunctionType = {state in }
    
    private var configuration: IperfConfiguration? = nil
    private var currentTest: UnsafeMutablePointer<iperf_test>? = nil
    
    private var state: IperfRunnerState = .ready {
        willSet {
            onRunnerStateFunction(newValue)
        }
    }

    private var storedServerOutput: String?

    /// The remote server's textual results from the most recent client run.
    ///
    /// Populated at the end of a run that enabled
    /// ``IperfConfiguration/getServerOutput`` when the server returns output;
    /// `nil` otherwise. The text is exchanged during final reporting and
    /// captured before the run's last reporter callback, so it is readable from
    /// that callback onward and always by the time the runner reports
    /// ``IperfRunnerState/finished``. Treat `nil` as a valid outcome. Starting
    /// another run clears the previous value.
    public var serverOutput: String? {
        withState { storedServerOutput }
    }
    
    // MARK: Initializers

    /// Creates a runner with the configuration used by ``start(_:_:_:)``.
    /// - Parameter configuration: The client or server options for the run.
    public init(with configuration: IperfConfiguration) {
        self.configuration = configuration
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }
    
    // MARK: Callbacks

    // A @convention(c) function pointer cannot capture Swift context, so it
    // resolves the owning runner from the registry by the test's address and
    // calls back into it directly — no global NotificationCenter broadcast.
    private let reporterCallback: @convention(c) (UnsafeMutablePointer<iperf_test>?) -> Void = { refTest in
        let runner = refTest.flatMap { IperfRunnerRegistry.shared.runner(for: $0) }
        // Copy the server output before iperf_reporter_callback runs: the
        // engine frees both variants while displaying the final results.
        if let testPointer = refTest {
            runner?.captureServerOutput(from: testPointer)
        }
        iperf_reporter_callback(refTest)
        // Process the interval status after the engine has updated the test.
        if let testPointer = refTest {
            runner?.handleReporterStatus(testPointer)
        }
    }

    // Copies the server's textual (or JSON-mode) results out of the test
    // before the engine frees them. Runs on the libiperf worker thread.
    fileprivate func captureServerOutput(from testPointer: UnsafeMutablePointer<iperf_test>) {
        // A JSON-mode server delivers json_server_output instead of text,
        // matching the CLI's "Server JSON output" report.
        var output: String?
        if let text = testPointer.pointee.server_output_text {
            output = String(cString: text)
        } else if let json = testPointer.pointee.json_server_output,
                  let printed = cJSON_Print(json) {
            output = String(cString: printed)
            cJSON_free(printed)
        }
        guard let output = output else {
            return
        }
        withState {
            guard currentTest == testPointer else {
                return
            }
            storedServerOutput = output
        }
    }

    fileprivate func handleReporterStatus(_ pointer: UnsafeMutablePointer<iperf_test>) {
        withState {
            handleReporterStatusLocked(pointer)
        }
    }

    private func handleReporterStatusLocked(_ pointer: UnsafeMutablePointer<iperf_test>) {
        if state != .running {
            return
        }
        guard pointer == currentTest,
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
    private func withState<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return body()
        }
        return stateQueue.sync(execute: body)
    }

    static func durationSeconds(_ duration: TimeInterval?) -> Int32? {
        guard let duration = duration else {
            return nil
        }
        guard duration.isFinite else {
            // Match the CLI's atoi parsing of "nan" and "inf" as 0.
            return 0
        }

        let seconds = duration.rounded(.towardZero)
        guard (0...Double(MAX_TIME)).contains(seconds) else {
            return nil
        }

        return Int32(min(seconds, Double(Int32.max)))
    }

    static func endConditionError(
        duration: TimeInterval?,
        numberOfBytes: UInt64?
    ) -> IperfError? {
        if let duration,
           duration.isFinite,
           Self.durationSeconds(duration) == nil {
            return .IEDURATION
        }
        if duration != nil,
           let numberOfBytes,
           numberOfBytes != 0 {
            return .IEENDCONDITIONS
        }
        return nil
    }

    static func blockSizeError(_ blockSize: Int?, for prot: IperfProtocol) -> IperfError? {
        guard let blockSize, blockSize > 0 else {
            return nil
        }
        if blockSize > Int(MAX_BLOCKSIZE) {
            return .IEBLOCKSIZE
        }
        // Clang cannot import MIN_UDP_BLOCKSIZE / MAX_UDP_BLOCKSIZE because
        // they are expression macros. Keep their iperf 3.21 values together.
        if prot == .udp,
           !(16...65_507).contains(blockSize) {
            return .IEUDPBLOCKSIZE
        }
        return nil
    }

    static func resolvedBlockSize(_ blockSize: Int?, for prot: IperfProtocol) -> Int32 {
        guard let blockSize, blockSize > 0 else {
            return prot == .tcp ? DEFAULT_TCP_BLKSIZE : 0
        }
        return Int32(blockSize)
    }

    static func clientPortError(
        _ clientPort: Int?,
        numStreams: Int,
        mode: IperfTestMode
    ) -> IperfError? {
        guard let clientPort else {
            return nil
        }
        guard (1...Int(UInt16.max)).contains(clientPort) else {
            return .IEBADPORT
        }
        // numStreams has its own validation policy. Only evaluate the
        // consecutive-port range when it represents at least one stream.
        guard numStreams > 0 else {
            return nil
        }

        let directionCount = mode == .bidirectional ? 2 : 1
        let (portCount, overflow) = numStreams.multipliedReportingOverflow(by: directionCount)
        guard !overflow,
              portCount - 1 <= Int(UInt16.max) - clientPort else {
            return .IEBADPORT
        }
        return nil
    }

    static func authenticationError(for configuration: IperfConfiguration) -> IperfError? {
        let error: IperfError = configuration.role == .client
            ? .IESETCLIENTAUTH
            : .IESETSERVERAUTH

        guard configuration.isAuth else {
            return configuration.hasAuthenticationOptionForSelectedRole() ? error : nil
        }

        switch configuration.role {
        case .client:
            guard !configuration.username.isEmpty,
                  !configuration.password.isEmpty,
                  !configuration.publicKey.isEmpty,
                  iperf_validate_client_rsa_pubkey(configuration.publicKey) == 0 else {
                return error
            }
        case .server:
            guard !configuration.privateKey.isEmpty,
                  !configuration.authorizedUsers.isEmpty,
                  configuration.timeSkewThreshold > 0,
                  iperf_validate_server_rsa_privkey(configuration.privateKey) == 0 else {
                return error
            }
        }
        return nil
    }

    static func clientIntegerError(for configuration: IperfConfiguration) -> IperfError? {
        guard (1...Int(MAX_STREAMS)).contains(configuration.numStreams) else {
            return .IENUMSTREAMS
        }
        if let socketBufferSize = configuration.socketBufferSize,
           !(0...Int(MAX_TCP_BUFFER)).contains(socketBufferSize) {
            return .IEBUFSIZE
        }
        // ClangImporter surfaces a macro that is a literal (MAX_STREAMS = 128)
        // or a single-operation expression (MAX_TCP_BUFFER = 512 * MB), but not
        // a chained expression. MAX_MSS is `(32 * 1024 - 1)`, so keep its
        // iperf 3.21 value inline.
        if let mss = configuration.mss,
           !(0...32_767).contains(mss) {
            return .IEMSS
        }
        if let tos = configuration.tos,
           !(0...255).contains(tos) {
            return .IEBADTOS
        }
        return nil
    }

    static func idleTimeoutSeconds(_ idleTimeout: TimeInterval) -> Int32? {
        guard idleTimeout.isFinite, idleTimeout > 0 else {
            return nil
        }
        let seconds = idleTimeout.rounded(.up)
        guard seconds <= Double(MAX_TIME) else {
            return nil
        }
        return Int32(seconds)
    }

    static func connectTimeoutMilliseconds(_ timeout: TimeInterval) -> Int32? {
        let maximum = Double(Int32.max) / 1_000
        guard timeout.isFinite, (0.001...maximum).contains(timeout) else {
            return nil
        }
        let milliseconds = (timeout * 1_000).rounded(.towardZero)
        return Int32(milliseconds)
    }

    static func timeIntervalError(for configuration: IperfConfiguration) -> IperfError? {
        if let idleTimeout = configuration.idleTimeout,
           Self.idleTimeoutSeconds(idleTimeout) == nil {
            return .IEIDLETIMEOUT
        }
        if let reporterInterval = configuration.reporterInterval,
           reporterInterval != 0,
           (!reporterInterval.isFinite || !(MIN_INTERVAL...MAX_INTERVAL).contains(reporterInterval)) {
            return .IEINTERVAL
        }
        if let timeout = configuration.timeout,
           timeout != 0,
           Self.connectTimeoutMilliseconds(timeout) == nil {
            return .IECONNECTTIMEOUT
        }
        return nil
    }

    private func configurationError() -> IperfError? {
        guard let configuration = configuration else {
            return nil
        }

        guard (1...Int(UInt16.max)).contains(configuration.port) else {
            return .IEBADPORT
        }
        guard (0...Int(MAX_OMIT_TIME)).contains(configuration.omit) else {
            return .IEOMIT
        }
        if let rcvTimeout = configuration.rcvTimeout {
            let minimum = Double(MIN_NO_MSG_RCVD_TIMEOUT) / 1_000
            guard rcvTimeout.isFinite,
                  (minimum...Double(MAX_TIME)).contains(rcvTimeout) else {
                return .IERCVTIMEOUT
            }
        }
        if let timeIntervalError = Self.timeIntervalError(for: configuration) {
            return timeIntervalError
        }
        if let clientIntegerError = Self.clientIntegerError(for: configuration) {
            return clientIntegerError
        }
        if let blockSizeError = Self.blockSizeError(configuration.blockSize, for: configuration.prot) {
            return blockSizeError
        }
        if let clientPortError = Self.clientPortError(
            configuration.clientPort,
            numStreams: configuration.numStreams,
            mode: configuration.mode
        ) {
            return clientPortError
        }
        if let endConditionError = Self.endConditionError(
            duration: configuration.duration,
            numberOfBytes: configuration.numberOfBytes
        ) {
            return endConditionError
        }

        if configuration.role == .client {
            if let dscp = configuration.dscp, !(0...63).contains(dscp) {
                return .IEBADTOS
            }
        }

        if let roleError = configuration.roleApplicabilityError() {
            return roleError
        }
        if let authenticationError = Self.authenticationError(for: configuration) {
            return authenticationError
        }
        return configuration.protocolApplicabilityError()
    }

    /// Applies the configuration to ``currentTest``.
    ///
    /// - Returns: A terminal error when an option cannot be applied, such as
    ///   selecting a protocol the engine was not built to support; otherwise
    ///   `nil`.
    private func applyConfiguration() -> IperfError? {
        guard let configuration = configuration else {
            return nil
        }

        var addr: UnsafePointer<Int8>? = nil
        if let address = configuration.address, !address.isEmpty {
            addr = NSString(string: address).utf8String
        }
        
        // Server/Client
        iperf_set_test_role(currentTest, configuration.role.rawValue)
        iperf_set_test_server_port(currentTest, Int32(clamping: configuration.port))
        if configuration.addressFamily != .any {
            iperf_set_test_domain(OpaquePointer(currentTest), configuration.addressFamily.iperfConfigValue)
        }
        
        if let reporterInterval = configuration.reporterInterval {
            // Statistics must sample at the reporter interval: the embedded
            // engine keeps only the newest sample per stream, so decoupled
            // intervals would drop traffic from reports or produce empty ones.
            iperf_set_test_reporter_interval(currentTest, Double(reporterInterval))
            iperf_set_test_stats_interval(currentTest, Double(reporterInterval))
        }
        if configuration.omit > 0 {
            iperf_set_test_omit(currentTest, Int32(clamping: configuration.omit))
        }
        if let logfile = configuration.logfile {
            iperf_set_test_logfile(currentTest, logfile)
        }
        iperf_set_verbose(currentTest, configuration.verbose ? 1 : 0)
        
        if let rcvTimeout = configuration.rcvTimeout, rcvTimeout.isFinite, rcvTimeout > 0 {
            let seconds = min(rcvTimeout, Double(UInt32.max))
            var interval = iperf_time(
                secs: UInt32(seconds),
                usecs: UInt32((seconds - seconds.rounded(.down)) * 1_000_000)
            )
            iperf_set_test_rcv_timeout(OpaquePointer(currentTest), &interval)
        }

        if configuration.role == .server {
            if let addr = addr {
                iperf_set_test_bind_address(currentTest, addr)
            }
            if let bindDevice = configuration.bindDevice {
                iperf_set_test_bind_dev(currentTest, bindDevice)
            }
            if configuration.oneOff {
                iperf_set_test_one_off(currentTest, 1)
            }
            if let idleTimeout = configuration.idleTimeout,
               let seconds = Self.idleTimeoutSeconds(idleTimeout) {
                iperf_set_test_idle_timeout(OpaquePointer(currentTest), seconds)
            }
            
            if configuration.isAuth {
                iperf_set_test_server_rsa_privkey(currentTest, configuration.privateKey)
                iperf_set_test_server_authorized_users(currentTest, configuration.authorizedUsers)
                iperf_set_test_server_skew_threshold(currentTest, configuration.timeSkewThreshold)
            }
        }
        
        if configuration.role == .client {
            if set_protocol(currentTest, configuration.prot.iperfConfigValue) < 0 {
                // set_protocol only fails for a transport the engine did not
                // register. TCP and UDP are always available, so this is not
                // expected in practice; surface it explicitly rather than
                // silently continuing with the default protocol.
                //
                // set_protocol has set the process-global i_errno to IEPROTOCOL.
                // We report the mapped error directly, so clear the global to
                // avoid leaving it set: a concurrent runner resets i_errno
                // before its run and reads it right after, and a value left here
                // is a (narrow) opportunity to be misread as that runner's
                // failure.
                i_errno = IperfError.IENONE.rawValue
                return .IEPROTOCOL
            }
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
            
            iperf_set_test_num_streams(currentTest, Int32(configuration.numStreams))

            iperf_set_test_blksize(
                currentTest,
                Self.resolvedBlockSize(configuration.blockSize, for: configuration.prot)
            )

            if let rate = configuration.rate {
                iperf_set_test_rate(currentTest, rate)
            } else if configuration.prot == .udp {
                // The CLI applies its 1 Mbit/s UDP default during argument
                // parsing, which the wrapper bypasses; without this the
                // engine would run UDP unlimited.
                iperf_set_test_rate(currentTest, UInt64(UDP_RATE))
            }
            if let socketBufferSize = configuration.socketBufferSize {
                iperf_set_test_socket_bufsize(currentTest, Int32(socketBufferSize))
            }
            if configuration.noDelay {
                iperf_set_test_no_delay(currentTest, 1)
            }
            if let mss = configuration.mss {
                iperf_set_test_mss(currentTest, Int32(mss))
            }
            
            if let addr = addr {
                iperf_set_test_server_hostname(currentTest, addr)
            }
            if let bindDevice = configuration.bindDevice {
                iperf_set_test_bind_dev(currentTest, bindDevice)
            }
            if let duration = Self.durationSeconds(configuration.duration) {
                iperf_set_test_duration(currentTest, duration)
            }
            if let numberOfBytes = configuration.numberOfBytes {
                iperf_set_test_bytes(currentTest, UInt64(numberOfBytes))
            }
            if let timeout = configuration.timeout,
               let milliseconds = Self.connectTimeoutMilliseconds(timeout) {
                iperf_set_test_connect_timeout(currentTest, milliseconds)
            }
            if let dscp = configuration.dscp {
                iperf_set_test_dscp(currentTest, Int32(clamping: dscp))
            }
            // Applied after dscp on purpose: both write the same tos field,
            // and the full type-of-service byte wins when both are set.
            if let tos = configuration.tos {
                iperf_set_test_tos(currentTest, Int32(tos))
            }
            if let clientPort = configuration.clientPort {
                iperf_set_test_bind_port(currentTest, Int32(clamping: clientPort))
            }
            if configuration.udpCounters64Bit {
                iperf_set_test_udp_counters_64bit(currentTest, 1)
            }
            if configuration.repeatingPayload {
                iperf_set_test_repeating_payload(currentTest, 1)
            }
            if configuration.getServerOutput {
                iperf_set_test_get_server_output(currentTest, 1)
            }
            if configuration.dontFragment {
                iperf_set_dont_fragment(currentTest, 1)
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

        return nil
    }

    private func startIperfProcess(
        testPointer: UnsafeMutablePointer<iperf_test>,
        configuration: IperfConfiguration
    ) {
        state = .running
        DispatchQueue.global(qos: .userInitiated).async {
            i_errno = IperfError.IENONE.rawValue

            var code: Int32
            if configuration.role == .client {
                code = iperf_run_client(testPointer)
            } else {
                code = iperf_run_server(testPointer)
            }
            let error = IperfError(rawValue: i_errno) ?? .UNKNOWN
            let wasStopped = testPointer.pointee.done != 0
            i_errno = IperfError.IENONE.rawValue

            self.stateQueue.async {
                guard self.currentTest == testPointer else {
                    return
                }

                if (code < 0 || error != .IENONE) && !wasStopped {
                    self.onError(error)
                } else {
                    self.cleanState(expectedTest: testPointer)
                }
            }
        }
    }
    
    private func cleanState(
        isExit: Bool = true,
        expectedTest: UnsafeMutablePointer<iperf_test>? = nil
    ) {
        if let expectedTest = expectedTest, currentTest != expectedTest {
            return
        }

        if isExit && configuration != nil {
            configuration = nil
        }
        if let testPointer = currentTest {
            // Unregister before freeing so a reused address never resolves to
            // this runner after its test is gone.
            IperfRunnerRegistry.shared.unregister(testPointer)
            iperf_free_test(testPointer)
            self.currentTest = nil
        }
        if isExit && (state == .running || state == .stopping) {
            state = .finished
        }
    }
    
    private func onError(_ error: IperfError) {
        state = .error
        onErrorFunction(error)
        
        cleanState()
    }
    
    // MARK: Public methods

    /// Starts a run after replacing the runner's configuration.
    ///
    /// Use this overload when reusing a runner after a completed run.
    ///
    /// If a run is already active, this call is silently ignored: none of
    /// the supplied callbacks are invoked and the in-flight run is left
    /// untouched. Wait for ``IperfRunnerState/finished`` or ``stop()`` before
    /// starting another run.
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
        stateQueue.async {
            guard self.currentTest == nil else {
                return
            }
            self.configuration = configuration
            self.start(onReporter, onError, onRunnerState)
        }
    }
    
    /// Starts a run with the configuration supplied at initialization.
    ///
    /// If a run is already active, this call is silently ignored: none of
    /// the supplied callbacks are invoked and the in-flight run is left
    /// untouched. Wait for ``IperfRunnerState/finished`` or ``stop()`` before
    /// starting another run.
    /// - Parameters:
    ///   - onReporter: Called when an interval result is available.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    public func start(
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType
    ) {
        if DispatchQueue.getSpecific(key: stateQueueKey) == nil {
            stateQueue.async {
                self.start(onReporter, onError, onRunnerState)
            }
            return
        }

        guard currentTest == nil else {
            return
        }
        signal(SIGPIPE, SIG_IGN)
        onReporterFunction = onReporter
        onErrorFunction = onError
        onRunnerStateFunction = onRunnerState
        
        cleanState(isExit: false)
        storedServerOutput = nil
        state = .initialising

        if let error = configurationError() {
            return self.onError(error)
        }
        
        currentTest = iperf_new_test()
        guard let testPointer = currentTest else {
            return self.onError(.INIT_ERROR)
        }
        
        let code = iperf_defaults(currentTest)
        if code < 0 {
            return self.onError(.INIT_ERROR_DEFAULTS)
        }

        if let applyError = applyConfiguration() {
            return self.onError(applyError)
        }

        // Route the C reporter callback back to this runner by the test's
        // address (see IperfRunnerRegistry).
        testPointer.pointee.reporter_callback = reporterCallback
        IperfRunnerRegistry.shared.register(self, for: testPointer)

        guard let configuration = configuration else {
            return onError(.INIT_ERROR)
        }
        startIperfProcess(testPointer: testPointer, configuration: configuration)
    }
    
    /// Requests cancellation of the active run.
    ///
    /// Calling this method when no test is active has no effect. State changes
    /// are reported asynchronously through the runner-state callback.
    public func stop() {
        stateQueue.async {
            self.stopCurrentTest()
        }
    }

    private func stopCurrentTest() {
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

/// Maps a live `iperf_test` pointer to the ``IperfRunner`` that owns it.
///
/// The libiperf reporter callback is a `@convention(c)` function pointer and
/// cannot capture Swift context, so it resolves its owning runner through this
/// registry instead of a global `NotificationCenter` broadcast. Entries are
/// keyed by the test's address and removed when the test is freed, so a reused
/// address always resolves to its current owner, and independent runners never
/// receive each other's callbacks. The stored reference is weak so a
/// registered runner can still deallocate.
private final class IperfRunnerRegistry {
    static let shared = IperfRunnerRegistry()

    private let lock = NSLock()
    private var runners: [UnsafeMutableRawPointer: WeakRunner] = [:]

    private struct WeakRunner {
        weak var runner: IperfRunner?
    }

    func register(_ runner: IperfRunner, for test: UnsafeMutablePointer<iperf_test>) {
        let key = UnsafeMutableRawPointer(test)
        lock.lock()
        runners[key] = WeakRunner(runner: runner)
        lock.unlock()
    }

    func unregister(_ test: UnsafeMutablePointer<iperf_test>) {
        let key = UnsafeMutableRawPointer(test)
        lock.lock()
        runners.removeValue(forKey: key)
        lock.unlock()
    }

    func runner(for test: UnsafeMutablePointer<iperf_test>) -> IperfRunner? {
        let key = UnsafeMutableRawPointer(test)
        lock.lock()
        let runner = runners[key]?.runner
        lock.unlock()
        return runner
    }
}
