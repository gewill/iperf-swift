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
    /// A default value that the runner's state machine does not produce.
    case unknown
    /// The runner exists and no run has started yet.
    case ready
    /// The runner is validating the configuration and preparing the engine.
    case initialising
    /// The engine is executing the test and delivering interval results.
    case running
    /// The run failed; the error callback carries the ``IperfError``.
    case error
    /// ``IperfRunner/stop()`` was called and the run is shutting down.
    case stopping
    /// The run ended, after delivering the interval results of a completed run.
    case finished
}

/// Low-level states reported by the embedded libiperf engine.
public enum IperfState: Int8 {
    /// The engine has started the test.
    case TEST_START = 1
    /// The test is transferring data; periodic interval results carry this state.
    case TEST_RUNNING = 2
    /// The data transfer has ended; a server's closing summary interval
    /// carries this state.
    case TEST_END = 4
    /// The endpoints are exchanging test parameters.
    case PARAM_EXCHANGE = 9
    /// The endpoints are creating the test streams.
    case CREATE_STREAMS = 10
    /// The server ended the session.
    case SERVER_TERMINATE = 11
    /// The client ended the session.
    case CLIENT_TERMINATE = 12
    /// The endpoints are exchanging final results.
    case EXCHANGE_RESULTS = 13
    /// The engine is presenting final results; a client's closing summary
    /// interval carries this state.
    case DISPLAY_RESULTS = 14
    /// The engine is setting up before the test begins.
    case IPERF_START = 15
    /// The engine has completed the session.
    case IPERF_DONE = 16
    /// The server refused the connection because another test is active.
    case ACCESS_DENIED = -1
    /// The server reported an error to the client.
    case SERVER_ERROR = -2

    /// A state value the wrapper does not recognize.
    case UNKNOWN = 0
}

/// Receives one interval result from libiperf.
///
/// - Important: The closure runs synchronously on the engine's own thread,
///   inside the loop that drives the measurement timers. Return promptly and
///   hand any slow work — UI updates, disk writes, anything that can block on
///   a lock — to another queue.
///
///   Time spent in the closure is time the engine is not measuring. A closure
///   that blocks for a whole reporting interval stretches the intervals that
///   follow, and one that blocks for several delivers the backlog as a burst:
///   the engine advances each timer by exactly one period per firing, so a
///   3-second stall on a 1-second interval yields one result spanning the
///   stall and then several near-zero-duration results in the same instant,
///   whose throughput is arithmetically correct and practically meaningless.
public typealias reporterFunctionType = (_ result: IperfIntervalResult) -> Void
/// Receives a terminal libiperf or wrapper error.
public typealias errorFunctionType = (_ error: IperfError) -> Void
/// Receives a high-level runner lifecycle change.
public typealias runnerStateFunctionType = (_ state: IperfRunnerState) -> Void
/// Receives one raw JSON value emitted by libiperf's JSON streaming mode.
///
/// With ``IperfConfiguration/jsonStreamFullOutput`` enabled, the callback first
/// receives the `start`, `interval`, and `end` event objects, then receives the
/// complete summary document as its final value.
///
/// - Important: The closure runs under the same contract as
///   ``reporterFunctionType`` — synchronously on the engine's own thread,
///   inside the loop that drives the measurement timers — so blocking it
///   distorts the measurement it is reporting, in the way described there.
///
///   It additionally runs while the runner holds its internal state, so a
///   closure that blocks also stalls any other thread reading
///   ``IperfRunner/serverOutput`` or ``IperfRunner/jsonOutput``, or calling
///   ``IperfRunner/stop()`` or `start`. Reading those two properties from
///   inside the closure itself is safe and does not deadlock.
public typealias jsonStreamFunctionType = (_ json: String) -> Void

/// Runs the embedded iperf3 engine as a client or server.
///
/// A runner performs its work on a background queue. Callback delivery is not
/// guaranteed on a specific queue, so callers must dispatch UI updates to the
/// main actor or main queue. Use one runner for one active test at a time.
///
/// Dispatching is not only a thread-safety requirement: the reporter closure
/// runs inside the engine's timing loop, so a slow one distorts the
/// measurement it is reporting. See ``reporterFunctionType``.
public class IperfRunner {
    private let stateQueue = DispatchQueue(label: "com.gewill.IperfSwift.runner-state")
    private let stateQueueKey = DispatchSpecificKey<Void>()

    private var onReporterFunction: reporterFunctionType = {result in }
    private var onErrorFunction: errorFunctionType = {error in }
    private var onRunnerStateFunction: runnerStateFunctionType = {state in }
    private var onJSONStreamFunction: jsonStreamFunctionType = {json in }
    
    private var configuration: IperfConfiguration? = nil
    private var currentTest: UnsafeMutablePointer<iperf_test>? = nil
    
    private var state: IperfRunnerState = .ready {
        willSet {
            onRunnerStateFunction(newValue)
        }
    }

    private var storedServerOutput: String?
    private var storedJSONOutput: String?

    // The stream measurements behind the most recent delivered interval
    // result, used to recognize a re-read of the engine's unchanged entry.
    private var previousDeliveredStreams: [IperfStreamIntervalResult]?

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

    /// The complete JSON document from the most recent JSON streaming run.
    ///
    /// This is populated when both ``IperfConfiguration/jsonStream`` and
    /// ``IperfConfiguration/jsonStreamFullOutput`` are enabled. It becomes
    /// readable before the final invocation of the JSON stream callback and is
    /// cleared when another run starts.
    public var jsonOutput: String? {
        withState { storedJSONOutput }
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

    private let jsonStreamCallback: @convention(c) (
        UnsafeMutablePointer<iperf_test>?,
        UnsafeMutablePointer<CChar>?
    ) -> Void = { refTest, refJSON in
        guard let testPointer = refTest,
              let jsonPointer = refJSON,
              let runner = IperfRunnerRegistry.shared.runner(for: testPointer) else {
            return
        }
        runner.handleJSONStreamOutput(jsonPointer, from: testPointer)
    }

    fileprivate func handleJSONStreamOutput(
        _ jsonPointer: UnsafeMutablePointer<CChar>,
        from testPointer: UnsafeMutablePointer<iperf_test>
    ) {
        let json = String(cString: jsonPointer)
        withState {
            guard currentTest == testPointer else {
                return
            }
            if let finalOutput = iperf_get_test_json_output_string(testPointer),
               finalOutput == jsonPointer {
                storedJSONOutput = json
            }
            onJSONStreamFunction(json)
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
        // A stopped run is still a run until the engine says otherwise.
        // `stop()` sets the engine's `done` flag and moves the runner to
        // `.stopping`, but the engine then gathers one final measurement and
        // reports it under DISPLAY_RESULTS — the same closing delivery a run
        // that reaches its duration makes. Ignoring reporter calls while
        // stopping dropped that interval, so the bytes measured since the
        // previous one never reached the consumer: up to a full reporting
        // period, which a summary built by summing intervals reports as
        // missing traffic.
        if state != .running && state != .stopping {
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

        // The engine declines to report an interval that is both very short
        // and empty — iperf_print_intermediate returns before printing when no
        // stream reaches a tenth of the statistics interval or carries any
        // bytes. Its comment names the case: a test can end with a brief
        // interval that moved nothing, because the control messages stopping
        // the run queue behind the data. Matching that keeps the wrapper's
        // deliveries aligned with what the CLI reports.
        if IperfRunner.isUnreportedShortInterval(
            result.streams,
            statsInterval: runningTest.stats_interval
        ) {
            return
        }

        // The engine keeps one interval entry per stream and overwrites it in
        // place (add_to_interval_list), and every reporter call site reads that
        // one entry — the periodic timer and the run's closing summary alike.
        // A reporter call with no intervening statistics gathering therefore
        // re-reads what was already delivered, which a consumer summing
        // interval bytes counts twice. Identical start, end and byte count
        // across every stream means no measurement was added, so there is
        // nothing to deliver.
        if IperfRunner.isRepeatDelivery(previousDeliveredStreams, result.streams) {
            return
        }
        previousDeliveredStreams = result.streams

        onReporterFunction(result)
    }

    // Mirrors iperf_print_intermediate's own test: one stream reaching a tenth
    // of the statistics interval, or carrying any bytes, makes the interval
    // worth reporting. The length comes from the entry's own start and end
    // times, as it does in the engine, rather than from the duration field.
    //
    // An empty stream list is reported rather than suppressed. The engine
    // always has streams here; the wrapper's list is empty only while the
    // engine is omitting, which it filters out separately, and suppressing
    // those deliveries would change omit behavior rather than align it.
    static func isUnreportedShortInterval(
        _ streams: [IperfStreamIntervalResult],
        statsInterval: TimeInterval
    ) -> Bool {
        guard !streams.isEmpty else {
            return false
        }
        return !streams.contains { stream in
            stream.intervalTimeDiff >= statsInterval * 0.10 || stream.bytesTransferred > 0
        }
    }

    // Exact equality only: a re-read of an unchanged entry matches in every
    // identity field. Two genuinely distinct intervals cannot, because a new
    // entry starts where the previous one ended and its byte counter is reset
    // on append — so a match means either a re-read or an empty zero-length
    // interval, neither of which carries information.
    static func isRepeatDelivery(
        _ previous: [IperfStreamIntervalResult]?,
        _ current: [IperfStreamIntervalResult]
    ) -> Bool {
        guard let previous = previous, previous.count == current.count, !current.isEmpty else {
            return false
        }
        return zip(previous, current).allSatisfy { previous, current in
            previous.direction == current.direction
                && previous.startTime == current.startTime
                && previous.endTime == current.endTime
                && previous.bytesTransferred == current.bytesTransferred
        }
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
        if configuration.jsonStream {
            iperf_set_test_json_output(currentTest, 1)
            iperf_set_test_json_stream(currentTest, 1)
        }
        if configuration.jsonStreamFullOutput {
            iperf_set_test_json_stream_full_output(currentTest, 1)
        }
        
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

                // The engine reports failure through the return code alone.
                // `i_errno` is a global it also writes on paths that succeed:
                // a server whose client terminated takes the CLIENT_TERMINATE
                // branch, which prints the run's summary, sets IECLIENTTERM and
                // returns 0 — the engine's own way of saying this run is over,
                // not that it failed. Reading `i_errno` as the verdict turned
                // that completed run into an error, and since `i_errno` is not
                // thread-local, a receiver thread ending on the closed socket
                // could overwrite it first, so the reported code was whichever
                // landed last rather than the one describing the outcome.
                //
                // The asymmetry is the engine's: a client that loses its server
                // returns -1 (IESERVERTERM), because a client has a duration to
                // fall short of, while a server's run only ever ends when its
                // client ends it.
                if code < 0 && !wasStopped {
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
    ///   - onReporter: Called when an interval result is available. Runs on the
    ///     engine's thread and must return promptly; see ``reporterFunctionType``.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    public func start(
        with configuration: IperfConfiguration,
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType
    ) {
        start(
            with: configuration,
            onReporter,
            onError,
            onRunnerState,
            onJSONStream: { _ in }
        )
    }

    /// Starts a run after replacing the runner's configuration and installs a
    /// raw JSON streaming callback.
    ///
    /// If a run is already active, this call is silently ignored.
    /// - Parameters:
    ///   - configuration: The client or server options for this run.
    ///   - onReporter: Called when an interval result is available.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    ///   - onJSONStream: Called for each raw JSON value emitted by JSON
    ///     streaming mode; see ``jsonStreamFunctionType``.
    public func start(
        with configuration: IperfConfiguration,
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType,
        onJSONStream: @escaping jsonStreamFunctionType)
    {
        stateQueue.async {
            guard self.currentTest == nil else {
                return
            }
            self.configuration = configuration
            self.start(
                onReporter,
                onError,
                onRunnerState,
                onJSONStream: onJSONStream
            )
        }
    }
    
    /// Starts a run with the configuration supplied at initialization.
    ///
    /// If a run is already active, this call is silently ignored: none of
    /// the supplied callbacks are invoked and the in-flight run is left
    /// untouched. Wait for ``IperfRunnerState/finished`` or ``stop()`` before
    /// starting another run.
    /// - Parameters:
    ///   - onReporter: Called when an interval result is available. Runs on the
    ///     engine's thread and must return promptly; see ``reporterFunctionType``.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    public func start(
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType
    ) {
        start(
            onReporter,
            onError,
            onRunnerState,
            onJSONStream: { _ in }
        )
    }

    /// Starts a run with the configuration supplied at initialization and
    /// installs a raw JSON streaming callback.
    ///
    /// If a run is already active, this call is silently ignored.
    /// - Parameters:
    ///   - onReporter: Called when an interval result is available.
    ///   - onError: Called when the run fails.
    ///   - onRunnerState: Called when the high-level lifecycle state changes.
    ///   - onJSONStream: Called for each raw JSON value emitted by JSON
    ///     streaming mode; see ``jsonStreamFunctionType``.
    public func start(
        _ onReporter: @escaping reporterFunctionType,
        _ onError: @escaping errorFunctionType,
        _ onRunnerState: @escaping runnerStateFunctionType,
        onJSONStream: @escaping jsonStreamFunctionType
    ) {
        if DispatchQueue.getSpecific(key: stateQueueKey) == nil {
            stateQueue.async {
                self.start(
                    onReporter,
                    onError,
                    onRunnerState,
                    onJSONStream: onJSONStream
                )
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
        onJSONStreamFunction = onJSONStream
        
        cleanState(isExit: false)
        storedServerOutput = nil
        previousDeliveredStreams = nil
        storedJSONOutput = nil
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
        if configuration?.jsonStream == true {
            iperf_set_test_json_callback(testPointer, jsonStreamCallback)
        }

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
