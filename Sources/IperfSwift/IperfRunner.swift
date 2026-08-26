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
    /// The runner is validating the configuration or waiting for the shared engine.
    case initialising
    /// The configuration was accepted and the run has been handed to the engine.
    ///
    /// This does not mean a server is accepting connections or that a client
    /// has connected. Both happen after this state is reported — the engine has
    /// not been called yet when it arrives — and either failing shows up later
    /// as ``IperfRunnerState/error``. A caller that must know a server is
    /// reachable should probe the port rather than read this as that signal.
    ///
    /// Interval results begin arriving once the engine is measuring.
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
/// Receives a libiperf or wrapper error.
///
/// Usually terminal: the runner moves to ``IperfRunnerState/error`` and the run
/// is over. The exception is a server with ``IperfConfiguration/oneOff``
/// disabled, where the engine rejecting one client — a failed authentication, a
/// stalled transfer — is reported here while the runner stays
/// ``IperfRunnerState/running`` and keeps listening, as the CLI does. Read the
/// runner's state rather than assuming this closure means the run has ended.
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
/// Vendored libiperf uses process-global timers and error storage. Consequently,
/// all ``IperfRunner`` instances share one FIFO engine queue: only one embedded
/// client or server can execute in a process at a time. A later runner remains
/// ``IperfRunnerState/initialising`` until the active run finishes or stops. A
/// persistent server therefore blocks later runners until it is stopped.
///
/// Dispatching is not only a thread-safety requirement: the reporter closure
/// runs inside the engine's timing loop, so a slow one distorts the
/// measurement it is reporting. See ``reporterFunctionType``.
public class IperfRunner {
    private static let engineQueue = DispatchQueue(
        label: "com.gewill.IperfSwift.libiperf-engine",
        qos: .userInitiated
    )

    private let stateQueue = DispatchQueue(label: "com.gewill.IperfSwift.runner-state")
    private let stateQueueKey = DispatchSpecificKey<Void>()

    private var onReporterFunction: reporterFunctionType = {result in }
    private var onErrorFunction: errorFunctionType = {error in }
    private var onRunnerStateFunction: runnerStateFunctionType = {state in }
    private var onJSONStreamFunction: jsonStreamFunctionType = {json in }
    
    private var configuration: IperfConfiguration? = nil
    private var currentTest: UnsafeMutablePointer<iperf_test>? = nil
    private var pendingRunID: UUID?
    
    private var state: IperfRunnerState = .ready {
        willSet {
            onRunnerStateFunction(newValue)
        }
    }

    private var storedServerOutput: String?
    private var storedJSONOutput: String?
    private var storedStreamTotals: [IperfStreamRunResult]?

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

    /// Per-stream totals for the run, as `iperf3` reports them in
    /// `end.streams[]`.
    ///
    /// Refreshed from the engine on every reporter callback, so it holds the
    /// run's final figures once the runner reports
    /// ``IperfRunnerState/finished`` and keeps whatever had accumulated when a
    /// run ends early. `nil` before the first interval arrives, and cleared
    /// when another run starts.
    ///
    /// These are run totals, not interval values: read
    /// ``IperfIntervalResult/streams`` for what a single interval measured.
    public var streamTotals: [IperfStreamRunResult]? {
        withState { storedStreamTotals }
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
        // Both engine flags decide the mode, and `reverse` derives from it.
        // The engine rejects reverse together with bidirectional, so these
        // three branches cover every state it can be in.
        if runningTest.bidirectional != 0 {
            result.mode = .bidirectional
        } else if runningTest.reverse != 0 {
            result.mode = .download
        } else {
            result.mode = .upload
        }
        
        let testCompletesRunner = configuration.role == .client || configuration.oneOff
        if result.state == .EXCHANGE_RESULTS && testCompletesRunner {
            state = .finished
        }

        if result.state == .IPERF_DONE {
            if testCompletesRunner {
                state = .finished
            }
            if configuration.role == .server {
                return
            }
        }
        
        guard var stream: UnsafeMutablePointer<iperf_stream> = runningTest.streams.slh_first else {
            return
        }
        var runTotals: [IperfStreamRunResult] = []
        while true {
            let localEndpointIsSender = stream.pointee.sender != 0
            let direction: IperfDirection = configuration.role == .client
                ? (localEndpointIsSender ? .upload : .download)
                : (localEndpointIsSender ? .download : .upload)

            let intervalResultsP: UnsafeMutablePointer<iperf_interval_results>? = extract_iperf_interval_results(OpaquePointer(stream))
            if let intervalResults = intervalResultsP?.pointee {
                if intervalResults.omitted == 0 {
                    var streamResult = IperfStreamIntervalResult(intervalResults)
                    streamResult.direction = direction
                    result.streams.append(streamResult)
                }
            }

            // Run totals live on the stream's result rather than on any
            // interval, and the engine keeps them current, so re-reading them
            // each time leaves the newest figures behind when the run ends —
            // including when it ends early.
            runTotals.append(
                IperfStreamRunResult(
                    direction: direction,
                    tcpSenderTotals: Self.tcpSenderTotals(of: stream)
                )
            )

            if stream.pointee.streams.sle_next == nil {
                break
            }
            stream = stream.pointee.streams.sle_next
        }
        storedStreamTotals = runTotals

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

    /// Reads one stream's run totals, or `nil` when the engine never sampled
    /// TCP info for it.
    ///
    /// `iperf_api.c` accumulates every one of these in a single pass guarded by
    /// three conditions at once: the protocol is TCP, the platform exposes TCP
    /// info, and this endpoint is the one sending. A receiving endpoint and any
    /// UDP stream therefore leave the whole group untouched, and the sample
    /// count is what distinguishes that from a run whose figures are genuinely
    /// zero. The CLI prints zeros either way.
    static func tcpSenderTotals(
        of stream: UnsafeMutablePointer<iperf_stream>
    ) -> IperfTCPSenderTotals? {
        guard let streamResult = stream.pointee.result else {
            return nil
        }
        let sampleCount = Int(streamResult.pointee.stream_count_rtt)
        guard sampleCount > 0 else {
            return nil
        }
        return IperfTCPSenderTotals(
            minRtt: Int(streamResult.pointee.stream_min_rtt),
            // Integer division over the engine's running sum, as the CLI does.
            meanRtt: Int(streamResult.pointee.stream_sum_rtt) / sampleCount,
            maxRtt: Int(streamResult.pointee.stream_max_rtt),
            rttSampleCount: sampleCount,
            maxSendCongestionWindow: Int(streamResult.pointee.stream_max_snd_cwnd),
            maxSendWindow: Int(streamResult.pointee.stream_max_snd_wnd),
            retransmits: Int(streamResult.pointee.stream_retrans),
            reorder: Int(streamResult.pointee.stream_reorder)
        )
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
                // We report the mapped error directly and clear it before the
                // shared engine queue advances to its next run.
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
            } else if let numberOfBytes = configuration.numberOfBytes, numberOfBytes != 0 {
                // A byte end condition with no duration is the CLI's
                // bytes-only run, where iperf_parse_arguments() clears the
                // duration so no time limit competes with the byte count. The
                // wrapper bypasses that parser, so without this the engine
                // keeps DURATION and the transfer stops after 10 seconds
                // having moved less than the caller asked for.
                iperf_set_test_duration(currentTest, 0)
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

    private func executeQueuedRun(runID: UUID) {
        let preparedRun = stateQueue.sync { () -> (
            UnsafeMutablePointer<iperf_test>,
            IperfConfiguration
        )? in
            guard pendingRunID == runID else {
                return nil
            }
            pendingRunID = nil

            guard let configuration = configuration else {
                onError(.INIT_ERROR)
                return nil
            }
            currentTest = iperf_new_test()
            guard let testPointer = currentTest else {
                onError(.INIT_ERROR)
                return nil
            }
            guard iperf_defaults(testPointer) >= 0 else {
                onError(.INIT_ERROR_DEFAULTS)
                return nil
            }
            if let applyError = applyConfiguration() {
                onError(applyError)
                return nil
            }

            // Route the C reporter callback back to this runner by the test's
            // address (see IperfRunnerRegistry).
            testPointer.pointee.reporter_callback = reporterCallback
            IperfRunnerRegistry.shared.register(self, for: testPointer)
            if configuration.jsonStream {
                iperf_set_test_json_callback(testPointer, jsonStreamCallback)
            }
            state = .running
            return (testPointer, configuration)
        }

        guard let (testPointer, configuration) = preparedRun else {
            return
        }
        runIperfProcess(testPointer: testPointer, configuration: configuration)
    }

    private func runIperfProcess(
        testPointer: UnsafeMutablePointer<iperf_test>,
        configuration: IperfConfiguration
    ) {
        var code: Int32 = 0
        var error = IperfError.IENONE
        var wasStopped = false

        repeat {
            i_errno = IperfError.IENONE.rawValue
            if configuration.role == .client {
                code = iperf_run_client(testPointer)
            } else {
                code = iperf_run_server(testPointer)
            }
            error = IperfError(rawValue: i_errno) ?? .UNKNOWN
            wasStopped = testPointer.pointee.done != 0
            i_errno = IperfError.IENONE.rawValue

            // The engine distinguishes a failed client interaction from a
            // failed server: it returns -1 for the former — a rejected
            // authentication, a stalled transfer, a control-channel error, all
            // of which it expects the caller to survive — and -2 only when the
            // listening socket itself could not be established. The CLI's own
            // loop reports a -1 and keeps listening, exiting only below that,
            // so a persistent server here has to do the same or one bad client
            // ends it.
            let shouldRestartServer = withState {
                guard configuration.role == .server,
                      !configuration.oneOff,
                      code >= -1,
                      currentTest == testPointer,
                      state == .running else {
                    return false
                }
                if code < 0 {
                    // Report the rejection the way the CLI prints it, without
                    // the terminal state change: the client's test failed, the
                    // server did not. The runner stays running, so a consumer
                    // that reads the state alongside the error can tell the
                    // difference.
                    onErrorFunction(error)
                }
                previousDeliveredStreams = nil
                iperf_reset_test(testPointer)
                return true
            }
            if !shouldRestartServer {
                break
            }
        } while true

        stateQueue.sync {
            guard currentTest == testPointer else {
                return
            }

            // The engine reports failure through the return code alone.
            // `i_errno` is process-global and may also be written by the
            // engine's worker threads, so this entire lifecycle remains on the
            // shared engine queue until the error is captured and the test is
            // freed.
            if code < 0 && !wasStopped {
                onError(error)
            } else {
                cleanState(expectedTest: testPointer)
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
        if isExit {
            pendingRunID = nil
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
    /// If a run is already active or waiting for the shared engine, this call
    /// is silently ignored: none of the supplied callbacks are invoked and the
    /// in-flight run is left untouched. Wait for
    /// ``IperfRunnerState/finished`` or ``stop()`` before starting another run.
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
    /// If a run is already active or waiting for the shared engine, this call
    /// is silently ignored.
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
            guard self.currentTest == nil, self.pendingRunID == nil else {
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
    /// If a run is already active or waiting for the shared engine, this call
    /// is silently ignored: none of the supplied callbacks are invoked and the
    /// in-flight run is left untouched. Wait for
    /// ``IperfRunnerState/finished`` or ``stop()`` before starting another run.
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
    /// If a run is already active or waiting for the shared engine, this call
    /// is silently ignored.
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

        guard currentTest == nil, pendingRunID == nil else {
            return
        }
        onReporterFunction = onReporter
        onErrorFunction = onError
        onRunnerStateFunction = onRunnerState
        onJSONStreamFunction = onJSONStream
        
        cleanState(isExit: false)
        storedServerOutput = nil
        previousDeliveredStreams = nil
        storedJSONOutput = nil
        storedStreamTotals = nil
        state = .initialising

        if let error = configurationError() {
            return self.onError(error)
        }

        let runID = UUID()
        pendingRunID = runID
        Self.engineQueue.async { [weak self] in
            self?.executeQueuedRun(runID: runID)
        }
    }
    
    /// Requests cancellation of the active or queued run.
    ///
    /// Calling this method when no test is active or queued has no effect. A
    /// queued run is cancelled without entering ``IperfRunnerState/running``.
    /// State changes are reported asynchronously through the runner-state
    /// callback.
    public func stop() {
        stateQueue.async {
            self.stopCurrentTest()
        }
    }

    private func stopCurrentTest() {
        guard let pointer = currentTest else {
            guard pendingRunID != nil else {
                return
            }
            pendingRunID = nil
            state = .stopping
            configuration = nil
            state = .finished
            return
        }
        
        state = .stopping
        if pointer.pointee.state != IPERF_DONE {
            pointer.pointee.done = 1
            if let configuration = configuration,
               configuration.role == .server {
                iperf_close_test_listener(OpaquePointer(pointer))
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
