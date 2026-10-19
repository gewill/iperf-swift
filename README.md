# IperfSwift

[![CI](https://github.com/gewill/iperf-swift/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/gewill/iperf-swift/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gewill/iperf-swift)](https://github.com/gewill/iperf-swift/releases)
[![Swift 5.7+](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2013%2B%20%7C%20macOS%2010.15%2B%20%7C%20tvOS%2013%2B-blue.svg)](#requirements)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

`IperfSwift` is a Swift Package that embeds the iperf3 3.22 C engine and exposes
client and server execution through a Swift API.

iperf3 is developed by ESnet/Lawrence Berkeley National Laboratory. Refer to the
[official iperf3 manual](https://software.es.net/iperf/invoking.html) for protocol
behavior and option semantics.

This repository is an independent continuation of
[igorskh/iperf-swift](https://github.com/igorskh/iperf-swift), which is no longer
maintained. Development continues here without upstream involvement.

## Features

- TCP and UDP in client and server roles
- Upload, download (`--reverse`), and bidirectional (`--bidir`) tests
- iperf3 RSA authentication with OAEP and optional legacy PKCS#1 v1.5 padding
- DSCP marking and network-interface binding
- Per-interval callbacks with per-stream results, plus per-stream run totals
- JSON streaming with optional complete final output
- macOS TCP statistics
- Self-contained package: the iperf3 engine is bundled and OpenSSL ships as an
  XCFramework, so no machine-specific library paths leak into consuming apps

## Requirements

- Swift 5.7+ (Xcode 14.0+)
- iOS 13+, macOS 10.15+, or tvOS 13+

## Installation

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/gewill/iperf-swift.git
```

Or add the package to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/gewill/iperf-swift.git",
        from: "3.22.0"
    )
]
```

Then add `IperfSwift` to the target dependencies and import it:

```swift
import IperfSwift
```

The package uses the OpenSSL 4 XCFramework from
[`openssl-spm`](https://github.com/Lakr233/openssl-spm). Consuming apps therefore
do not inherit machine-specific Homebrew library paths.

## Client example

The following configuration corresponds approximately to
`iperf3 -c 192.0.2.1 -p 5201 -t 10 -i 1`:

```swift
import IperfSwift

final class NetworkTest {
    private var runner: IperfRunner?

    func start() {
        var configuration = IperfConfiguration()
        configuration.role = .client
        configuration.address = "192.0.2.1"
        configuration.port = 5201
        configuration.prot = .tcp
        configuration.mode = .upload
        configuration.duration = 10
        configuration.reporterInterval = 1

        let runner = IperfRunner(with: configuration)
        self.runner = runner

        runner.start(
            { result in
                print("\(result.throughput.Mbps) Mbit/s")
            },
            { error in
                print("iperf3 failed: \(error.debugDescription)")
            },
            { state in
                print("state: \(state)")
            }
        )
    }

    func stop() {
        runner?.stop()
    }
}
```

Set `mode = .download` to run a reverse test (`iperf3 --reverse`), or use
`.bidirectional` to send and receive simultaneously (`iperf3 --bidir`). For
UDP, set `prot = .udp` and configure `rate` in bits per second.

Bidirectional interval callbacks contain separate client-oriented aggregates:

```swift
configuration.mode = .bidirectional

runner.start(
    { result in
        print("Upload: \(result.upload.throughput.Mbps) Mbit/s")
        print("Download: \(result.download.throughput.Mbps) Mbit/s")
    },
    { error in print(error.debugDescription) },
    { state in print(state) }
)
```

Each stream also exposes its `direction`. Existing top-level aggregate fields,
such as `throughput` and `totalBytes`, contain the combined values for both
directions in bidirectional mode. UDP jitter is measured at the receiving
endpoint (RFC 3550), so a bidirectional client observes real-time jitter only
in `download.averageJitter` while the sent direction reports zero; the
top-level `averageJitter` averages that zero in. The existing `reverse`
property remains a compatibility accessor for selecting upload or download
mode.

Interval results describe one interval. For the figures `iperf3` prints in its
`end.streams[]` summary, read `runner.streamTotals` after the run:

```swift
for stream in runner.streamTotals ?? [] {
    guard let totals = stream.tcpSenderTotals else { continue }
    print("\(stream.direction): mean RTT \(totals.meanRtt) µs")
}
```

`tcpSenderTotals` is `nil` unless the engine sampled TCP info for that stream,
which it does only while *sending* over TCP: a `.download` client and any UDP
stream have none. The CLI prints zeros in those cases, which read as
measurements rather than as absent data.

## Server example

```swift
var configuration = IperfConfiguration()
configuration.role = .server
configuration.port = 5201

let server = IperfRunner(with: configuration)
server.start(
    { result in print(result.throughput.Mbps) },
    { error in print(error.debugDescription) },
    { state in print(state) }
)
```

Leaving `address` unset binds the wildcard address and accepts both IPv4 and
IPv6, like `iperf3 -s`. Set it to bind one interface — but note that an explicit
`"0.0.0.0"` gives an IPv4-only listener, because the engine only arranges the
dual-stack socket when no bind address is given.

Keep the runner alive for the duration of the test. Work runs asynchronously,
and callbacks are not guaranteed to use a specific queue. Dispatch UI updates
to `MainActor` or the main queue. Terminal callback handling should be
idempotent because libiperf can emit more than one terminal state notification.

The `.running` state precedes listening or connecting; the API has no
server-ready callback. A TCP readiness probe counts as a client interaction
and can end a `oneOff` server. When coordinating local peers, observe the
listener without connecting to it or trying to bind its port.

Vendored libiperf keeps timers and error state at process scope, so the package
serializes all `IperfRunner` instances through one FIFO engine queue. Only one
embedded client or server runs in a process at a time; later runners remain in
`.initialising` until the active run finishes or stops. A persistent server
therefore blocks later runners until `stop()` is called. Calling `stop()` on a
queued runner cancels it without entering `.running`.

## Design philosophy

The wrapper is a Swift library, not a re-export of the iperf3 CLI. Options are
surfaced according to a few guiding rules. The configuration tables below
record both the checks enforced today and known gaps that still have follow-up
work, so planned validation is not mistaken for shipped behavior:

1. **No value on Apple platforms → not exposed.** CLI-only conveniences (daemon
   mode and file-based data source) are intentionally omitted.
   Results arrive as structured Swift values through callbacks, so a small API
   is a feature rather than a gap.
2. **Invalid and knowable up front → made unrepresentable.** Where the type
   system can rule out a bad configuration it does. Transports the platform
   cannot provide are simply not offered as `IperfProtocol` cases, so selecting
   them is a compile-time error instead of a runtime surprise.
3. **Invalid but only knowable at runtime → an explicit, typed error.** Platform-
   or route-dependent limits (interface binding, MSS on loopback) surface as
   `IperfError` values and drive the runner to `.error`.
4. **Implemented applicability checks fail fast.** Explicitly tracked options
   used with the wrong endpoint role are rejected with `IESERVERONLY` /
   `IECLIENTONLY`. Enabled TCP-only and UDP-only options fail with `IETCPONLY` /
   `IEUDPONLY`; an IPv4-only option forced to IPv6 fails with `IEIPV4ONLY`.

The iperf3 CLI accepts protocol-inapplicable flags and silently ignores them.
The wrapper intentionally applies a stricter policy because the selected
transport is already known before a run starts. When `addressFamily` is
`.any`, the resolved family remains runtime-dependent; `dontFragment` takes
effect only when the resulting UDP socket is IPv4.

## Configuration mapping

### Optional bounded logs and resource release

`logfileByteLimit` is opt-in; `nil` keeps the existing CLI logfile behavior.
Set a byte limit together with `logfile` to retain a prefix within a fixed
file budget. The minimum is `IperfConfiguration.minimumLogfileByteLimit`;
invalid limits or a missing path fail preflight with `IELOGFILELIMIT`.

```swift
var configuration = IperfConfiguration()
configuration.logfile = ownedLogURL.path
configuration.logfileByteLimit = 8 * 1024 * 1024
let runner = IperfRunner(with: configuration)
runner.start(
    { interval in /* consume measurements promptly */ },
    { error in /* handle measurement errors */ },
    { state in /* update presentation */ },
    onResourcesReleased: { completion in
        // All native resources, including the logfile FILE, are now released.
        // Inspect completion.logfile before using or reclaiming the owned file.
    }
)
```

The budget includes existing bytes and at most one new `[iperf log truncated]`
marker per accepted run.
Overflow discards subsequent output without stopping measurement or callbacks.
The retained prefix ends at a UTF-8 scalar boundary for valid UTF-8 input; it
does not promise a whole grapheme, line, or JSON document. A bounded logfile is
not a replacement for structured result callbacks. At most the marker length
plus three bytes remain buffered until close, including after `fflush`, so an
exactly full file is not incorrectly labelled truncated.

The existing Swift JSON streaming callback route bypasses logfile output; its
file can be empty in both bounded and unbounded mode. This option limits only
actual file writes, not JSON callback payloads or captured server-output memory.

Existing content is never overwritten. If fewer than a marker's bytes remain,
new output is discarded and truncation is reported only in the completion. An
already oversized file is untouched and reports `EFBIG`; its existing size
is not claimed to satisfy the new limit. Only regular files are supported.
The caller must exclusively own the path throughout the run. Concurrent writers,
external replacement, filesystem allocation overhead, and other files are
outside this per-file byte budget. This does not promise persistent storage on
tvOS or a whole-app memory/disk budget.

With bounded logging enabled, open/write/close failures are recorded separately
in `IperfLogfileResult` and do not fail the measurement. The first write failure
disables later writes for that run. Default unbounded logging retains its
existing engine error behavior. A persistent server shares one budget across
client connections and closes/reopens its sink without repeating the marker.

The existing `.finished` callback timing is unchanged and can precede native
teardown. Use `onResourcesReleased` to delete an owned file safely. Each accepted
start completes once, including validation failure, queued cancellation, and
deallocation while queued; ignored overlapping starts do not complete. A
persistent server completes only when it exits. `completion.runID` identifies
the generation and `completion.logfile` is nil if bounded logging was disabled
or no file open was attempted. Callbacks have no guaranteed delivery queue and
must return promptly. The runner's `completion` property is cleared by a new
accepted start, so retain the callback payload when restarting.
Prefer a unique logfile path per run. If another run reuses a path before an
older completion is delivered, that completion does not authorize deleting the
new run's file; coordinate path ownership separately from the runner state.

The wrapper follows the official iperf3 options where the embedded API exposes
them. “Client” and “Server” below refer to the local Swift endpoint. Unless a
row narrows it, a client test supports upload, download, and bidirectional modes
over TCP or UDP and either address family.

Preflight currently runs implemented intrinsic and cross-field value checks,
then role/mode applicability. Authentication credential completeness and RSA
key decoding run next so wrong-role errors remain higher priority, followed by
protocol and forced-address-family applicability. Platform, DNS, route,
interface, and socket constraints remain runtime decisions.

### Endpoint and shared options

| Swift property | iperf3 option | Applies when | Constraints / current behavior |
| --- | --- | --- | --- |
| `role` | `--client` / `--server` | Endpoint selection | Defaults to Client |
| `address` | `--client` / `--bind` | Client / Server | Client destination or server bind address; unset by default, matching the engine, so a server binds the wildcard address and accepts IPv4 and IPv6 like `iperf3 -s`, and a client resolves to loopback. An explicit `"0.0.0.0"` narrows a server to IPv4 |
| `addressFamily` | `-4` / `-6` | Client / Server | Defaults to `.any`; DNS and the resolved socket family remain runtime decisions |
| `port` | `--port` | Client / Server | Defaults to `5201`; values outside `1...65535` fail with `IEBADPORT` |
| `bindDevice` | `--bind-dev` | Client / Server | Interface existence, platform support, and permissions are checked at runtime |
| `rcvTimeout` | `--rcv-timeout` | Server; Client download / bidirectional | `0.1...86,400` seconds; invalid values fail with `IERCVTIMEOUT`, while Client upload fails with `IERVRSONLYRCVTIMEOUT` |
| `reporterInterval` | `--interval` | Client / Server | Seconds; zero disables periodic callbacks, otherwise accepts `0.1...60` (iperf3's `MIN_INTERVAL`/`MAX_INTERVAL`); values below the minimum, out of range, or nonfinite fail with `IEINTERVAL` before timer creation |
| `statsInterval` | — | Ignored | Retained for compatibility; statistics always sample at `reporterInterval` |
| `logfile` | `--logfile` | Client / Server | Default unbounded mode reports file-open failures through the engine; bounded mode reports them separately at resource release |
| `logfileByteLimit` | — | Client / Server | Optional per-file byte budget; see bounded-log semantics above |
| `verbose` | `--verbose` | Client / Server | Enables verbose libiperf text logging |

### Client test options

| Swift property | iperf3 option | Applies when | Constraints / current behavior |
| --- | --- | --- | --- |
| `numStreams` | `--parallel` | Client · TCP / UDP | Defaults to `1`, matching the engine; requires `1...128`, otherwise fails with `IENUMSTREAMS`; an explicit Server assignment fails with `IECLIENTONLY` |
| `mode` | `--reverse` / `--bidir` | Client · TCP / UDP | Defaults to upload, matching the engine; selects upload, download (`--reverse`), or simultaneous bidirectional flow |
| `reverse` | `--reverse` | Client · TCP / UDP | Compatibility accessor for `mode`; a read/write round trip does not cancel bidirectional mode |
| `prot` | `--tcp` / `--udp` | Client | Defaults to TCP; an explicit Server assignment fails with `IECLIENTONLY` |
| `rate` | `--bitrate` | Client · TCP / UDP | Unset keeps the CLI defaults: unlimited TCP and 1 Mbit/s UDP |
| `blockSize` | `--length` | Client · TCP / UDP | Non-positive values select the default (TCP 128 KiB; UDP dynamic MSS); positive TCP values allow `1...1 MiB`, while UDP allows `16...65,507`; values above 1 MiB fail with `IEBLOCKSIZE`, and other invalid UDP values fail with `IEUDPBLOCKSIZE` |
| `socketBufferSize` | `--window` | Client · TCP / UDP | `0...512 MiB`; zero keeps socket autotuning/default behavior, while invalid values fail with `IEBUFSIZE` |
| `noDelay` | `--no-delay` | Client · TCP | Enabling it for UDP fails with `IETCPONLY` |
| `mss` | `--set-mss` | Client · TCP | `0...32,767`; zero keeps the engine default, intrinsic range failures return `IEMSS` before protocol applicability, UDP otherwise fails with `IETCPONLY`, and valid platform/route failures remain `IESETMSS` at runtime |
| `duration` | `--time` | Client · TCP / UDP | Truncated toward zero to whole seconds in `0...86,400`; invalid finite values fail with `IEDURATION`; nonfinite values match the CLI's zero parsing |
| `numberOfBytes` | `--bytes` | Client · TCP / UDP | A nonzero byte limit is an end condition; combining it with any explicitly set `duration` fails with `IEENDCONDITIONS`, while zero selects no byte end condition |
| `timeout` | `--connect-timeout` | Client | Swift unit is seconds; `nil` or zero keeps the engine default, otherwise accepts `0.001...2,147,483.647` and truncates fractional milliseconds; invalid/nonfinite values fail preflight with wrapper error `IECONNECTTIMEOUT` |
| `dscp` | `--dscp` | Client · TCP / UDP · IPv4 / IPv6 | Numeric `0...63`; invalid values fail with `IEBADDSCP` |
| `tos` | `--tos` | Client · TCP / UDP · IPv4 / IPv6 | Requires `0...255`, otherwise fails with `IEBADTOS`; applied after `dscp` and therefore wins |
| `clientPort` | `--cport` | Client · TCP / UDP | `1...65,535`; Server use fails with `IECLIENTONLY`; parallel streams use consecutive ports and bidirectional mode reserves two ranges, with overflow failing as `IEBADPORT` |
| `udpCounters64Bit` | `--udp-counters-64bit` | Client · UDP | Enabling it for TCP fails with `IEUDPONLY` |
| `repeatingPayload` | `--repeating-payload` | Client · TCP / UDP | Uses a repeating payload pattern instead of randomized bytes |
| `getServerOutput` | `--get-server-output` | Client · TCP / UDP | Makes the remote text result available through `IperfRunner.serverOutput` |
| `dontFragment` | `--dont-fragment` | Client · UDP · IPv4 | TCP fails with `IEUDPONLY`; forced IPv6 fails with `IEIPV4ONLY`; `.any` applies it only when resolution selects IPv4 |
| `omit` | `--omit` | Client · TCP / UDP | Initial `0...600` seconds excluded from measurements; invalid values fail with `IEOMIT` |

The CLI 3.22 and the wrapper both reject nonpositive `--parallel`, negative
`--window` / `--set-mss`, and invalid `--dscp` values. The wrapper checks them
during preflight, before entering libiperf.

The CLI also accepts nonfinite `--interval` input because its floating-point
comparisons do not reject `NaN`, and it does not range-check the integer
`--connect-timeout`. The wrapper rejects both cases before creating timers or
sockets; `timeout` uses seconds rather than the CLI's milliseconds.

### Server behavior

| Swift property | iperf3 option | Applies when | Constraints / current behavior |
| --- | --- | --- | --- |
| `oneOff` | `--one-off` | Server | Enabling it for Client fails with `IESERVERONLY`; enabled finishes after one client, while disabled resets after each client and listens until `stop()` |
| `idleTimeout` | `--idle-timeout` | Server | Positive seconds that round up into `1...86,400`; timeout restarts a persistent Server or finishes a one-off run without terminating the host process; invalid/nonfinite values fail with `IEIDLETIMEOUT` before role validation or timer work, while valid Client use fails with `IESERVERONLY` |

### Authentication options

Authentication fields are wrapper values rather than file-path-only CLI inputs.
Authentication-only fields fail preflight while `isAuth` is disabled. When it
is enabled, each role requires its complete credential group; wrong-role errors
remain higher priority than same-role credential completeness.

| Swift property | iperf3 option / source | Applies when | Constraints / current behavior |
| --- | --- | --- | --- |
| `isAuth` | Wrapper gate | Client / Server | Defaults to `false`; enabling it requires the complete credential group for the selected role |
| `usePkcs1Padding` | `--use-pkcs1-padding` | Authenticated Client / Server | Wrapper extension used for both client encryption and server decryption; enabling it while authentication is disabled fails with the selected role's authentication error |
| `username` | `--username` | Authenticated Client | Must be nonempty; Server use fails with `IECLIENTONLY` |
| `password` | `IPERF3_PASSWORD` / prompt replacement | Authenticated Client | Must be nonempty and is supplied directly by the host app; Server use fails with `IECLIENTONLY` |
| `publicKey` | `--rsa-public-key-path` content | Authenticated Client | Must be a decodable Base64-encoded PEM public key, not a file path; invalid or incomplete Client credentials fail with `IESETCLIENTAUTH`, while Server use fails with `IECLIENTONLY` |
| `privateKey` | `--rsa-private-key-path` content | Authenticated Server | Must be a decodable Base64-encoded unencrypted PEM private key, not a file path; invalid or incomplete Server credentials fail with `IESETSERVERAUTH`, while Client use fails with `IESERVERONLY` |
| `authorizedUsers` | `--authorized-users-path` extension | Authenticated Server | Must be nonempty `username,sha256` content, not a file path, because the wrapper bypasses the CLI parser that would open one; Client use fails with `IESERVERONLY` |
| `timeSkewThreshold` | `--time-skew-threshold` | Authenticated Server | Defaults to `10` seconds and must be positive; an explicit Client assignment fails with `IESERVERONLY` |

### Cross-field rules

| Combination | Current behavior | Follow-up |
| --- | --- | --- |
| `duration` + nonzero `numberOfBytes` | Fails before networking with `IEENDCONDITIONS`; an explicitly set zero duration still counts as a duration condition | Implemented |
| `dscp` + `tos` | `tos` is applied last and wins | Implemented |
| Authentication field + `isAuth == false` | Fails before networking with `IESETCLIENTAUTH` or `IESETSERVERAUTH` for the selected local role | Implemented |
| Explicit same-default role option | Assigning `numStreams`, `mode`, `prot`, `omit`, or `timeSkewThreshold` records caller intent, so wrong-role use still fails | Implemented |
| `dontFragment` + `addressFamily == .any` | Allowed; the flag takes effect only if resolution produces an IPv4 UDP socket | Runtime by design |
| `clientPort` + parallel/bidirectional streams | Highest port is `clientPort + numStreams - 1` for unidirectional tests and `clientPort + 2 × numStreams - 1` for bidirectional tests | Implemented; the highest port may equal `65,535` |

### Bounded server output

Set `serverOutputByteLimit` to `1...1_048_576` to opt into bounded raw server
output. The default `nil` preserves existing behavior. A client still needs
`getServerOutput = true`; a server applies its own budget when a client requests
output. The client option does not limit memory in an unmodified remote CLI.

```swift
configuration.getServerOutput = true
configuration.serverOutputByteLimit = 256 * 1024
// After final reporting:
// runner.serverOutput       — valid text prefix or complete compact JSON
// runner.serverOutputStatus — state, format, reason, retained/observed bytes
```

`serverOutputStatus` is `nil` when the budget is disabled. With a budget it
separates not-requested, waiting, missing, complete (including an empty string),
truncated text, discarded JSON, and invalid output. An unknown observed byte
count is `nil`, not zero. `localServerOutputStatus` reports the budgeted server's
collection metadata without copying its payload to Swift. A new accepted run
clears prior client output; overlapping starts do not. Persistent servers reset
collection and the negotiated request flag between clients.
In budgeted mode, a runner reports its terminal state after the native call
returns; a result-exchange failure cannot first announce
successful completion from a cleanup reporter callback.

The opt-in path bounds each stage:

- Text collection keeps at most the configured number of UTF-8 bytes, ending at
  a scalar boundary. JSON intervals are encoded into a bounded buffer and not
  accumulated in `json_intervals`; the complete document is sent only if its
  byte/node/depth limits pass. Partial JSON is never returned as a document.
- Server collection allocates at most `limit + 1` bytes plus `limit + 5` bytes
  of JSON scratch, in addition to the engine's current interval/start/end data.
  Result serialization uses a fixed `1 MiB + 6 × limit + 1029` byte buffer,
  allowing for worst-case JSON string escaping without concatenating all logs.
- Result reception uses a 4 KiB input chunk, a 1 MiB core-statistics buffer, and
  one output buffer of `limit + 1` bytes. cJSON parses only bounded core data:
  at most 16,384 values plus its root, depth 64. Optional JSON has the same
  retained value limit; the whole scanner is capped at 1,048,576 values.
- An optional oversized output is discarded or truncated while valid core
  statistics survive. Invalid grammar (including a number longer than the 63
  characters cJSON parses), excessive depth/core size, a frame over 64 MiB, or
  failed I/O ends that control exchange explicitly. Header and body
  share a 30-second absolute deadline; explicit stop is checked at least every
  100 ms while waiting. Normal measurement completion is not cancellation.
- Swift copies a received payload only once per run, after verifying ownership;
  its UTF-8 length is at most the configured limit, so JSON stays the compact
  document the budget measured. The client's own text report still prints
  received JSON under `Server JSON output:` formatted with `cJSON_Print`, like
  the unbudgeted client, from a transient tree that the same limits bound.
  JSON callbacks can also carry bounded output; callers remain responsible for
  their own retained callback history. These byte limits are not
  process-footprint measurements.

Budgeted servers add versioned `iperf_swift_server_output` metadata to the
result-control object so a budgeted receiver can distinguish sender truncation
or discard from absent output. An unmodified CLI ignores this extension and
still receives valid statistics plus the available standard output field.
Malformed metadata cannot upgrade a local truncation/discard into completeness.

Combining a budget with `jsonStream && jsonStreamFullOutput` fails preflight
with `IESERVEROUTPUTLIMIT`: unlimited full-history retention contradicts this
budget. Ordinary JSON streaming remains available. This option does not cap
FILE log writes, change measurement statistics, or establish a device memory
budget; those are separate contracts.

### JSON streaming

Set `jsonStream = true` and `jsonStreamFullOutput = true` to match
`--json-stream --json-stream-full-output`. `onJSONStream` receives the raw
`start`, `interval`, and `end` event objects, then the complete JSON document.
The final document is also available as `runner.jsonOutput`.

```swift
configuration.jsonStream = true
configuration.jsonStreamFullOutput = true

var events: [String] = []
runner.start(
    { _ in },
    { error in print(error.debugDescription) },
    { state in print(state) },
    onJSONStream: { events.append($0) }
)
```

### Unsupported options

These iperf3 capabilities are intentionally not exposed. See
[Design philosophy](#design-philosophy) for the reasoning.

| iperf3 capability | Status | Reason / future support |
| --- | --- | --- |
| SCTP transport (`--sctp`) | Not supported | Apple platform builds of iperf3 are not compiled with SCTP, so `IperfProtocol` offers only `.tcp` and `.udp` — selecting SCTP is a compile-time error rather than a runtime failure. The `IperfError.IENOSCTP` code is retained for callers mirroring the engine's error set. No plan to support it while Apple platforms lack SCTP. |
| Daemon / server persistence (`--daemon`) | Not exposed | The runner is an in-process object with an explicit lifecycle; background daemonization has no meaning inside a host app. Use `oneOff` or `idleTimeout` to bound a server's lifetime. |
| Monolithic-only JSON output (`--json`) | Not exposed | Use typed `IperfIntervalResult` callbacks, or enable `jsonStream` plus `jsonStreamFullOutput` when both live events and the complete JSON document are required. |
| File-based data source (`--file`) | Not exposed | Streaming a file as the payload is a CLI convenience with no library use case; block size and payload shape are controlled through `blockSize` and `repeatingPayload`. |

## Authentication

Authentication follows iperf3's official RSA scheme:

- The client uses `username`, `password`, and a Base64-encoded PEM `publicKey`.
- The server uses a Base64-encoded, unencrypted PEM `privateKey` and
  `authorizedUsers` in iperf3's `username,sha256` format. That content is
  tokenized with the CLI file's line rules: LF or CRLF endings, and a leading
  `#` marks a comment instead of an account.
- Keep `usePkcs1Padding` disabled to use OAEP, the iperf3 default since 3.17.
  Enable legacy PKCS#1 v1.5 padding only when interoperability requires it.
- Keep client and server clocks within `timeSkewThreshold` seconds.

Both RSA key properties accept Base64 of the PEM **text content**, never a file
path or Base64 of a path. The wrapper parses the text in memory, so callers do
not need key files. The private key stays on the server; this input format does
not mean sending the private key over the network. The upstream CLI's explicit
`--rsa-*-key-path` options retain their file-based behavior.

See the official manual's
[authentication examples](https://software.es.net/iperf/invoking.html#examples)
for key generation and password hashing.

Do not commit private keys, passwords, or authorized-user data.

## Testing

The integration tests require a local `iperf3` 3.22 executable with
authentication support. The current Homebrew bottle can advance beyond 3.22,
so build the pinned official CLI in an isolated prefix:

```sh
brew install openssl@3
iperf_test_prefix="$HOME/Library/Caches/iperf-swift/iperf3-3.22"
./Scripts/install_test_iperf3.sh "$iperf_test_prefix"
export IPERF3_PATH="$iperf_test_prefix/bin/iperf3"
export OPENSSL_PATH="$(brew --prefix openssl@3)/bin/openssl"
```

The installer checks official tag `3.22` against commit
`926bd905501b792bd082d2200d1d1a84aa543e3a`, then verifies the executable's
version and authentication support. CI uses the same script with a prefix
under `RUNNER_TEMP`; neither setup replaces a global `iperf3`. The tests still
reject other versions so the CLI baseline cannot drift from the embedded
3.22 engine. To use an existing 3.22 executable, set `IPERF3_PATH` explicitly:

```sh
IPERF3_PATH="/path/to/iperf3" swift test
```

The standalone test CLI uses Homebrew's OpenSSL 3, located with `brew --prefix`.
`OPENSSL_PATH` selects the executable that generates temporary authentication
credentials. OpenSSL linked by the Swift Package itself remains exclusively
the OpenSSL 4 XCFramework in `openssl-spm`; no Homebrew paths enter the package.

Run the complete Swift Package test suite:

```sh
swift test
```

Run a focused suite:

```sh
swift test --filter IperfSwiftUnitTests
swift test --filter IperfCLIIntegrationTests
swift test --filter IperfBoundedOutputTests
```

For Xcode's macOS test runner, explicitly forward the selected executables:

```sh
TEST_RUNNER_IPERF3_PATH="$IPERF3_PATH" \
TEST_RUNNER_OPENSSL_PATH="$OPENSSL_PATH" \
xcodebuild -scheme IperfSwift -destination 'platform=macOS' test
```

`xcodebuild` strips the `TEST_RUNNER_` prefix when passing these environment
variables to test processes; a shell-only override does not select the CLI there.

Run the standalone C checks after resolving/building the package:

```sh
./Scripts/verify_auth_safety.sh
./Scripts/verify_engine_regressions.sh
./Scripts/verify_bounded_output.sh
./Scripts/verify_no_ssl_stubs.sh
```

The first two use AddressSanitizer. Authentication checks cover both RSA padding
modes, exact plaintext capacity, malformed Base64 and failure cleanup. Engine
checks cover remote parameter bounds, UDP stride validation, watchdog worker
ownership, socket/FD cleanup, first UDP reply TOS, parallel bidirectional TCP
with timer cancellation, descriptor exhaustion, teardown of a zerocopy sender
blocked in `sendfile()`, descriptors released at test end, and stream sockets
after failed stream setup. The
engine checks also run the pinned `iperf3` CLI, found through `IPERF3_PATH`.
Set `SWIFT_BUILD_PATH` when using a SwiftPM scratch path instead of `.build`.

`./Scripts/verify_bounded_output.sh` separately instruments heap requests in the
actual collector, serializer, result-frame parser and cJSON under AddressSanitizer
and UndefinedBehaviorSanitizer. It checks large optional output, core byte/node
budgets and allocation-failure cleanup. The serialization probe deliberately
fails at an invalid fd after encoding, while CLI interoperability tests verify
successful real result exchange. Reported requested bytes exclude allocator
overhead, stack, engine interval/start/end data, Swift copies and device footprint.
The CLI budget matrix covers TCP/UDP, upload/download/Both, text/JSON output,
small/normal budgets, runner reuse, persistent-server reset and request-off rounds.
Standalone malformed-frame/socket tests do not by themselves prove runner-level
failure recovery; final platform, hostile-peer and combined logfile-budget
validation remain tracked in SDK #196 before release.

The integration suite starts local Swift or CLI peers, creates temporary RSA
credentials, and allocates random local ports. It covers TCP and UDP
interoperability, bidirectional mode, authentication, macOS interface binding,
DSCP, and macOS TCP statistics. Linux-only GSO/GRO behavior requires a Linux
runner.

## Documentation

The API reference is hosted on the
[Swift Package Index](https://swiftpackageindex.com/gewill/iperf-swift/documentation/iperfswift).

API documentation is built with the official
[`swift-docc-plugin`](https://github.com/swiftlang/swift-docc-plugin). Generate
the `IperfSwift` documentation archive with:

```sh
swift package generate-documentation --target IperfSwift
```

Preview it locally with:

```sh
swift package --disable-sandbox preview-documentation --target IperfSwift
```

## Synchronizing iperf3

The bundled C sources are generated from upstream iperf3. To update them, edit
the maintained files in `iperf_sync/` as needed and run:

```sh
./sync.sh
git diff
git diff --check
```

`sync.sh` defaults to the official `3.22` tag. It creates a unique system
temporary directory for checkout and a unique staging directory beside
`Sources/IperfCLib`, applies
`iperf_sync/patches/modifications.patch`, restores
`iperf_sync/custom_files/` (including the deterministic Apple-platform
`iperf_config.h`), and then replaces `Sources/IperfCLib/`. Repository
directories named `iperf3` or `Sources/IperfCLib.sync-tmp` are not used or
removed. Concurrent synchronization is rejected through `.iperf-sync.lock`
rather than allowing two processes to replace the generated tree at once. If a
terminated process leaves a stale lock and no synchronization is active, remove
it with `rmdir .iperf-sync.lock`. The maintained configuration's probe names are
checked against the selected upstream tag, and CI regenerates the 3.22 tree and
requires a clean diff. Do not keep project-specific changes only in the
generated C source because the next sync will overwrite them.

## Versioning

The Swift package and embedded engine have separate versions. For example,
package release `3.22.0` embeds the official iperf3 `3.22` engine. See
[CHANGELOG.md](CHANGELOG.md) for the release history.

## Roadmap

Coverage of the libiperf parameters exposed by the embedded API is complete
(the parameter work shipped through `3.21.4`). Remaining direction is tracked
in the GitHub issue tracker. Two enhancements are currently deferred until a
downstream consumer is ready to adopt them:

- [#14](https://github.com/gewill/iperf-swift/issues/14) — an async/await
  (`AsyncThrowingStream`) API for interval results
- [#15](https://github.com/gewill/iperf-swift/issues/15) — Swift concurrency
  readiness (`Sendable` annotations and strict-concurrency support)

## Credits

- [igorskh/iperf-swift](https://github.com/igorskh/iperf-swift) — the original
  project by Igor Kim, from which this repository originates
- [esnet/iperf](https://github.com/esnet/iperf) — the embedded iperf3
  measurement engine
- [Lakr233/openssl-spm](https://github.com/Lakr233/openssl-spm) — the packaged
  OpenSSL XCFramework

## License

Project-specific code is released under the [MIT License](LICENSE). The bundled
iperf code keeps the upstream license in [LICENSE-iperf](LICENSE-iperf), and the
OpenSSL dependency is documented in [LICENSE-OpenSSL.md](LICENSE-OpenSSL.md).
The Apple-platform build uses the project's MIT-licensed atomic compatibility
header so the C structures remain importable by Swift; it does not include the
former FFmpeg LGPL atomic compatibility source.
