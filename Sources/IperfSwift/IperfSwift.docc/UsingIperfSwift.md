# Using IperfSwift

A complete walkthrough of the wrapper: configuring a run, driving the runner
lifecycle, reading interval results, and handling errors.

## Overview

Every run follows the same shape: build an ``IperfConfiguration``, hand it to an
``IperfRunner``, and receive ``IperfIntervalResult`` values through the reporter
callback while the test runs. This article links each API point to its reference
page — click any symbol to open its documentation.

Options that do not apply to the selected role, transport, or *forced* address
family are rejected before the run starts. Applicability is decided from the
``IperfConfiguration/role``, the ``IperfConfiguration/prot``, and — only when you
force one — the ``IperfConfiguration/addressFamily``. With
``IperfAddressFamily/any`` the resolved family stays a runtime decision, so
address-family–specific behavior (such as ``IperfConfiguration/dontFragment``) is
not decided during preflight.

Because a wrong-role or wrong-transport option fails preflight, there is no single
configuration that sets *every* property at once. The scenarios below are
therefore independent, and **each starts from a fresh call to
``IperfConfiguration/init()``**.
This matters: the configuration records which options you assign, so reusing one
instance across roles keeps that history and still fails with
``IperfError/IECLIENTONLY``.

## Shared base

These apply to either role and can appear in any scenario below:

```swift
var configuration = IperfConfiguration()
configuration.address = "192.0.2.1"
configuration.port = 5201
configuration.addressFamily = .any
configuration.bindDevice = interfaceName
configuration.reporterInterval = 1
configuration.logfile = logFilePath
configuration.verbose = true
configuration.rcvTimeout = 30
```

- ``IperfConfiguration/address`` — client destination, or server bind address
- ``IperfConfiguration/port`` — `--port`, defaults to `5201`
- ``IperfConfiguration/addressFamily`` — `-4` / `-6`, see ``IperfAddressFamily``
- ``IperfConfiguration/bindDevice`` — `--bind-dev` interface binding
- ``IperfConfiguration/reporterInterval`` — `--interval` between reporter callbacks
- ``IperfConfiguration/logfile`` — `--logfile` path for engine text output
- ``IperfConfiguration/verbose`` — verbose engine logging
- ``IperfConfiguration/rcvTimeout`` — `--rcv-timeout`; applies to a **server and a
  receiving client** (download or bidirectional). A client upload run instead
  fails with ``IperfError/IERVRSONLYRCVTIMEOUT``.

## Building a configuration

### TCP client

```swift
var configuration = IperfConfiguration()
configuration.role = .client
configuration.address = "192.0.2.1"
configuration.port = 5201
configuration.prot = .tcp
configuration.mode = .download          // upload, download, or bidirectional
configuration.numStreams = 4
configuration.rate = 0                   // 0 = unlimited (TCP default)
configuration.blockSize = 128 * 1024
configuration.socketBufferSize = 0       // 0 keeps socket autotuning
configuration.noDelay = true             // disable Nagle
configuration.mss = 1_400
configuration.duration = 10
configuration.timeout = 5                 // connect timeout, seconds
configuration.tos = 0x10                  // full ToS byte; see note on dscp
configuration.clientPort = 5301
configuration.repeatingPayload = true
configuration.getServerOutput = true
configuration.omit = 1
configuration.reporterInterval = 1
```

- ``IperfConfiguration/role`` — `--client` / `--server`, see ``IperfRole``
- ``IperfConfiguration/prot`` — `--tcp` / `--udp`, see ``IperfProtocol``
- ``IperfConfiguration/mode`` — `--reverse` / `--bidir`, see ``IperfTestMode``
- ``IperfConfiguration/numStreams`` — `--parallel`, `1...128`
- ``IperfConfiguration/rate`` — `--bitrate` application-level pacing
- ``IperfConfiguration/blockSize`` — `--length` read/write size
- ``IperfConfiguration/socketBufferSize`` — `--window` socket buffer
- ``IperfConfiguration/noDelay`` — `--no-delay`; UDP use fails with ``IperfError/IETCPONLY``
- ``IperfConfiguration/mss`` — `--set-mss`; UDP use fails with ``IperfError/IETCPONLY``
- ``IperfConfiguration/duration`` — `--time`; see the end-condition note below
- ``IperfConfiguration/timeout`` — `--connect-timeout`, expressed in seconds here
- ``IperfConfiguration/dscp`` — `--dscp` (`0...63`) and ``IperfConfiguration/tos`` —
  `--tos` (`0...255`). The runner always applies `dscp` first and `tos` second, so
  when both are set `tos` wins regardless of the order you assign them.
- ``IperfConfiguration/clientPort`` — `--cport` local bind port
- ``IperfConfiguration/repeatingPayload`` — `--repeating-payload`
- ``IperfConfiguration/getServerOutput`` — `--get-server-output`; see *Server output*
- ``IperfConfiguration/omit`` — `--omit` initial seconds excluded from results

> Tip: A byte end condition (``IperfConfiguration/numberOfBytes``) is mutually
> exclusive with a duration. Any non-`nil` ``IperfConfiguration/duration`` —
> **including an explicit `0`** — combined with a non-zero
> ``IperfConfiguration/numberOfBytes`` fails with ``IperfError/IEENDCONDITIONS``.

### UDP / IPv4 client

```swift
var configuration = IperfConfiguration()
configuration.role = .client
configuration.prot = .udp
configuration.addressFamily = .ipv4
configuration.address = "192.0.2.1"
configuration.rate = 100_000_000        // bits/s; unset UDP defaults to 1 Mbit/s
configuration.blockSize = 1_400          // exact datagram payload size
configuration.udpCounters64Bit = true
configuration.dontFragment = true
configuration.numberOfBytes = 50_000_000 // byte end condition (no duration set)
```

- ``IperfConfiguration/udpCounters64Bit`` — `--udp-counters-64bit`; TCP use fails
  with ``IperfError/IEUDPONLY``
- ``IperfConfiguration/dontFragment`` — `--dont-fragment`; TCP use fails with
  ``IperfError/IEUDPONLY`` and forced IPv6 fails with ``IperfError/IEIPV4ONLY``
- ``IperfConfiguration/numberOfBytes`` — `--bytes` end condition

### Server

```swift
var configuration = IperfConfiguration()
configuration.role = .server
configuration.address = "0.0.0.0"       // bind address
configuration.port = 5201
configuration.oneOff = true
configuration.idleTimeout = 60
configuration.rcvTimeout = 30
configuration.reporterInterval = 1
```

- ``IperfConfiguration/oneOff`` — `--one-off`; Client use fails with
  ``IperfError/IESERVERONLY``
- ``IperfConfiguration/idleTimeout`` — `--idle-timeout`, `1...86,400` seconds

### Authenticated client

Authentication uses iperf3's RSA scheme. Supply real credentials from your app —
the placeholders below stand for values you provide, not literals to copy, since
an undecodable key fails preflight with ``IperfError/IESETCLIENTAUTH``.

```swift
var configuration = IperfConfiguration()
configuration.role = .client
configuration.address = "192.0.2.1"
configuration.isAuth = true
configuration.username = username            // nonempty
configuration.password = password            // nonempty, supplied by the host app
configuration.publicKey = base64PEMPublicKey // Base64-encoded PEM, not a path
configuration.usePkcs1Padding = false        // keep OAEP (the 3.17+ default)
```

- ``IperfConfiguration/isAuth`` — enables the RSA scheme for this endpoint
- ``IperfConfiguration/username`` — `--username`
- ``IperfConfiguration/password`` — supplied directly by the host app
- ``IperfConfiguration/publicKey`` — Base64-encoded PEM public key content
- ``IperfConfiguration/usePkcs1Padding`` — `--use-pkcs1-padding`; used for **both**
  client encryption and server decryption

### Authenticated server

```swift
var configuration = IperfConfiguration()
configuration.role = .server
configuration.address = "0.0.0.0"
configuration.isAuth = true
configuration.privateKey = base64PEMPrivateKey // Base64-encoded unencrypted PEM
configuration.authorizedUsers = "alice,<sha256-hash>"
configuration.timeSkewThreshold = 10           // positive seconds
```

- ``IperfConfiguration/privateKey`` — Base64-encoded unencrypted PEM private key;
  invalid or incomplete server credentials fail with ``IperfError/IESETSERVERAUTH``
- ``IperfConfiguration/authorizedUsers`` — `username,sha256` content
- ``IperfConfiguration/timeSkewThreshold`` — `--time-skew-threshold`, must be positive

### Compatibility properties

- ``IperfConfiguration/reverse`` — a still-functional accessor for
  ``IperfConfiguration/mode``: it selects upload or download. In bidirectional
  mode the getter returns ``IperfDirection/upload``; writing ``IperfDirection/upload``
  does not cancel bidirectional mode, while writing ``IperfDirection/download``
  switches to a download run.
- ``IperfConfiguration/statsInterval`` — **ignored.** Statistics always sample at
  ``IperfConfiguration/reporterInterval``; the property is retained only for
  source compatibility.

## Running a test

Create an ``IperfRunner`` with ``IperfRunner/init(with:)`` and start it. The three
trailing closures are the reporter (``reporterFunctionType``), error
(``errorFunctionType``), and runner-state (``runnerStateFunctionType``) callbacks.

```swift
let runner = IperfRunner(with: configuration)

runner.start(
    { result in print("\(result.throughput.Mbps) Mbit/s") },
    { error in print("failed: \(error.debugDescription)") },
    { state in print("state: \(state)") }
)
```

- ``IperfRunner/start(_:_:_:)`` — starts with the configuration from
  ``IperfRunner/init(with:)``
- ``IperfRunner/start(with:_:_:_:)`` — replaces the configuration first, for
  reusing a runner after a completed run
- ``IperfRunner/stop()`` — requests cancellation of the active run

Callbacks are not guaranteed to run on a specific queue, so dispatch UI updates to
the main actor or main queue, and keep terminal-state handling idempotent because
the engine can report a terminal state more than once.

### Lifecycle states

``IperfRunnerState`` reports high-level progress. In practice the transitions are:

- **Success:** ``IperfRunnerState/initialising`` → ``IperfRunnerState/running`` →
  ``IperfRunnerState/finished``
- **Failure:** ``IperfRunnerState/initialising`` or ``IperfRunnerState/running`` →
  ``IperfRunnerState/error`` (a subsequent ``IperfRunnerState/finished`` is not
  guaranteed)
- **Cancellation:** ``IperfRunnerState/stopping`` → ``IperfRunnerState/finished``

``IperfRunnerState/ready`` is the state before the callbacks are installed, and
``IperfRunnerState/unknown`` is not produced by the runner's state machine. Note
that ``IperfRunnerState/finished`` can be reported *before* the final reporter
callback, because the engine marks completion while it is still assembling the
last interval, so do not treat `finished` as "all results delivered."

## Reading interval results

Each reporter callback delivers an ``IperfIntervalResult``:

- ``IperfIntervalResult/throughput`` — an ``IperfThroughput``; read
  ``IperfThroughput/Mbps`` (or ``IperfThroughput/bps``, ``IperfThroughput/Kbps``,
  ``IperfThroughput/Gbps``, or the underlying ``IperfThroughput/rawValue`` in
  bytes/second)
- ``IperfIntervalResult/totalBytes`` — bytes across all streams
- ``IperfIntervalResult/totalPackets`` / ``IperfIntervalResult/totalLostPackets`` /
  ``IperfIntervalResult/totalOutoforderPackets`` — UDP packet counters
- ``IperfIntervalResult/averageJitter`` — mean UDP jitter, in seconds
- ``IperfIntervalResult/averageRtt`` — **currently always `0.0`** (unused); read the
  per-stream ``IperfStreamIntervalResult/rtt`` for real RTT
- ``IperfIntervalResult/duration``, ``IperfIntervalResult/startTime``,
  ``IperfIntervalResult/endTime`` — interval timing
- ``IperfIntervalResult/state`` — the low-level ``IperfState`` that produced it
- ``IperfIntervalResult/prot`` and ``IperfIntervalResult/mode`` — transport and mode
- ``IperfIntervalResult/streams`` — the per-stream measurements
- ``IperfIntervalResult/id`` — identity for collection use
- ``IperfIntervalResult/runnerState`` — currently remains
  ``IperfRunnerState/unknown`` in reporter results; observe the runner-state
  callback for lifecycle changes

Aggregates are derived from the streams; ``IperfIntervalResult/evaluate()``
recomputes them and is safe to call repeatedly.

Each ``IperfStreamIntervalResult`` exposes its ``IperfStreamIntervalResult/direction``
and, where the platform provides TCP info, ``IperfStreamIntervalResult/rtt``,
``IperfStreamIntervalResult/rttvar``, ``IperfStreamIntervalResult/sndCwnd``,
``IperfStreamIntervalResult/snd_wnd``, ``IperfStreamIntervalResult/pmtu``, and
``IperfStreamIntervalResult/intervalRetrans``.

### Bidirectional results

With ``IperfTestMode/bidirectional``, read the direction-specific aggregates
``IperfIntervalResult/upload`` and ``IperfIntervalResult/download`` — each an
``IperfDirectionalIntervalResult`` with its own ``IperfDirectionalIntervalResult/throughput``:

```swift
{ result in
    print("Upload:   \(result.upload.throughput.Mbps) Mbit/s")
    print("Download: \(result.download.throughput.Mbps) Mbit/s")
}
```

Directions are named from the client's point of view, so a server's receiving
side is ``IperfDirection/upload``.

The top-level fields combine both directions, but not uniformly: byte and packet
counters are summed and ``IperfIntervalResult/throughput`` is computed from the
summed bytes, while ``IperfIntervalResult/averageJitter`` is a mean across streams
(so it includes the sent direction's zero) and the timing fields come from the
first stream. Because UDP jitter is measured at the receiver (RFC 3550), a
bidirectional client sees real jitter only in
``IperfDirectionalIntervalResult/averageJitter`` on its download aggregate. Prefer
the per-direction aggregates when direction matters.

## Handling errors

A run's failure is delivered through the **error callback** as an ``IperfError``,
which conforms to `Error` and `LocalizedError`. Read
``IperfError/debugDescription`` (or ``IperfError/errorDescription``) for the
English message:

```swift
{ error in print("iperf3 failed: \(error.debugDescription)") }
```

> Important: Do **not** use ``IperfIntervalResult/hasError`` or
> ``IperfIntervalResult/error`` to detect a failed run. On a normal interval
> result the error is left at ``IperfError/UNKNOWN`` rather than
> ``IperfError/IENONE``, so ``IperfIntervalResult/hasError`` is `true` even for a
> healthy interval whose ``IperfIntervalResult/debugDescription`` is `"OK"`. The
> error callback is the authoritative failure channel.

## Server output

When ``IperfConfiguration/getServerOutput`` is `true`, the server's textual result
is exchanged just before completion and made available on
``IperfRunner/serverOutput``. Read it after the runner reports
``IperfRunnerState/finished``. It is client-only, may be `nil` even when requested,
and is cleared at the start of each run.

## Coverage note

This guide walks the full consumer-facing path. A few compatibility or
internal-value members are intentionally not featured: the misspelled
`evaulate()` alias (use ``IperfIntervalResult/evaluate()``), the raw
`IperfIntervalResult.reverse` integer flag (use ``IperfIntervalResult/mode``), the
enums' `iperfConfigValue` bridging accessors, and ``IperfConfiguration/statsInterval``
(covered above only as an ignored property).
