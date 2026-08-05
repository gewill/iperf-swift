# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows the embedded iperf3 engine: the major and minor components
track the engine version (currently 3.21), and the patch component is the
package release number.

## [Unreleased]

### Changed

- The reporter no longer delivers a very short interval that moved no bytes
  ([#81]), matching what the engine reports. `iperf_print_intermediate` returns
  without printing when no stream reaches a tenth of the statistics interval or
  carries any bytes — the case its own comment describes, where a test ends
  with a brief interval that moved nothing because the control messages
  stopping the run queued behind the data. The wrapper had no equivalent check
  and delivered a result the CLI prints nothing for; a client ending on
  `numberOfBytes` produced one on every run. **Behavior change:** such a run
  now delivers one fewer reporter callback.

### Fixed

- The reporter no longer delivers the same interval twice ([#79]). The engine
  keeps one interval entry per stream and overwrites it in place, and every
  reporter call site reads that one entry — the periodic timer and the run's
  closing summary alike — so a reporter call with no intervening statistics
  gathering re-read what had already been delivered. A consumer summing
  interval bytes counted the repeat; the reported run came out 14.5% high. A
  delivery whose streams all match the previous one in direction, start time,
  end time and byte count is now suppressed. The comparison is exact equality,
  which no genuinely distinct interval can satisfy: a new entry starts where
  the previous one ended, and its byte counter is reset when it is appended.

## [3.21.8] - 2026-08-02

A bug-fix release. A zero-duration reporting interval no longer produces a
non-finite throughput, and the reporter closure's threading contract is now
documented.

### Changed

- Documented the reporter closure's threading contract ([#75]): it runs
  synchronously on the engine's thread, inside the loop that drives the
  measurement timers, so slow work in it distorts the measurement it reports. A
  closure blocking for about one reporting interval stretches the intervals that
  follow; one blocking for several delivers the backlog as a burst of
  near-zero-duration results, because the engine advances each timer by one
  period per firing. No behavior change.

### Fixed

- `IperfThroughput(bytes:seconds:)` now reports zero for a duration that is not
  greater than zero instead of dividing by it ([#73]). The engine can deliver an
  interval whose start and end times are equal — observed on a loopback TCP run
  with five streams and a one-second reporting interval — and the resulting
  infinity trapped as soon as a caller converted the rate to an integer. Zero
  matches the rate iperf3 reports for the same interval in its per-stream
  output.

## [3.21.7] - 2026-07-23

A documentation, test, and CI release. The library's observable behavior is
unchanged from 3.21.6.

### Added

- A DocC usage guide covering the full public API ([#59], [#61]): a copyable
  Quick Start, self-contained configuration scenarios, the authentication
  `username,sha256` hash format, the reporter states that mark a run's closing
  summary, and the client-oriented directional aggregates.
- Doc comments on every `IperfProtocol`, `IperfRunnerState`, `IperfState`, and
  `IperfError` case, and topic groups organizing the configuration, error, and
  interval-result symbol pages ([#65]).
- A README link to the hosted API reference on Swift Package Index ([#69]).

### Changed

- CI now builds the documentation with `--warnings-as-errors` ([#67]). A rename
  that leaves a DocC symbol link unresolved fails the build instead of silently
  degrading the published reference.

### Fixed

- Corrected the `authorizedUsers` documentation: the value must be the
  `username,sha256` content itself, not a file path. The wrapper configures the
  engine directly instead of going through the CLI argument parser that would
  open a path, so a path is tokenized as text and never matches a user.
- Corrected the `IperfRunner.serverOutput` documentation: the text is captured
  before a run's last reporter callback, so it is readable from that callback
  onward and always by the time the runner reports `finished`, and `nil` is a
  valid outcome when the server returns no output. The interoperability tests
  now read the value directly at `finished` instead of polling, so a regression
  back to asynchronous delivery fails the suite ([#63]).

## [3.21.6] - 2026-07-21

### Removed

- Removed the `IperfProtocol.sctp` case ([#29]). Apple platform builds of iperf3 are not
  compiled with SCTP, so the transport could never succeed; selecting it is now
  a compile-time error instead of a runtime `IperfError.IENOSCTP`. This
  supersedes the earlier change that made `.sctp` fail at runtime. The
  `IENOSCTP` error code is retained for callers that mirror the engine's error
  set. **Breaking:** code referencing `.sctp`, and persisted configurations that
  encode `"sctp"`, no longer compile or decode.

### Changed

- Documented the wrapper's option-exposure philosophy in the README and split
  the configuration mapping into supported and intentionally unsupported
  options.
- Explicitly configured options that do not apply to the selected endpoint role
  now fail before the run with `IESERVERONLY` / `IECLIENTONLY`, matching the
  iperf3 CLI ([#30]). Invalid receive-timeout values now report the newly
  exposed `IERCVTIMEOUT`; a valid timeout on a sending client reports the newly
  exposed `IERVRSONLYRCVTIMEOUT` error. **Breaking:** exhaustive switches over
  `IperfError` must handle these two new cases.
- Protocol-inapplicable options now fail before the run with the wrapper-defined
  `IETCPONLY`, `IEUDPONLY`, or `IEIPV4ONLY` errors instead of being silently
  ignored ([#31]). `blockSize` remains valid for both TCP read/write sizing and
  UDP datagram sizing. **Breaking:** exhaustive switches over `IperfError` must
  handle the three new cases.
- `blockSize` is now validated per transport before the run ([#35]): the generic
  `MAX_BLOCKSIZE` (1 MiB) cap is checked first for both transports and fails with
  `IEBLOCKSIZE`, so a UDP size above 1 MiB also reports `IEBLOCKSIZE`; only UDP
  sizes within that cap but outside the datagram range (`16...65507`) fail with
  `IEUDPBLOCKSIZE`. Non-positive values still select the defaults (128 KB for TCP,
  dynamic MSS-based for UDP).
- `clientPort` (`--cport`) is now validated before the run ([#36]): values
  outside `1...65535` fail with `IEBADPORT`, and parallel or bidirectional stream
  ranges that would run past 65535 are rejected up front. `clientPort` is
  client-only and rejected on a server with `IECLIENTONLY`.
- Setting a `duration` together with a nonzero `numberOfBytes` now fails with
  `IEENDCONDITIONS` before the run instead of letting the engine silently pick a
  single end condition ([#37]).
- Authentication is now preflighted ([#38]): incomplete or role-mismatched
  credentials fail with `IESETCLIENTAUTH` / `IESETSERVERAUTH`, RSA public/private
  keys are Base64/PEM-decoded and checked, and encrypted private keys are
  rejected up front rather than blocking on an interactive passphrase.
- `numStreams`, `socketBufferSize`, `mss`, and `tos` are now range-checked before
  the run ([#39]) with `IENUMSTREAMS`, `IEBUFSIZE`, `IEMSS`, and `IEBADTOS`;
  previously out-of-range values were silently clamped.
- `idleTimeout`, `reporterInterval`, and the client connection `timeout` are now
  validated for finite, in-range, and sufficiently precise values before any
  timer or socket is created ([#40]), instead of being silently ignored, rounded,
  or clamped. Exposes `IEIDLETIMEOUT` and the wrapper-specific `IECONNECTTIMEOUT`.
  **Breaking:** exhaustive switches over `IperfError` must handle the two new
  cases.
- `reporterInterval` now rejects nonzero values below iperf3's `MIN_INTERVAL`
  (0.1 s), matching the CLI's `0.1...60` contract ([#48]). Previously the wrapper
  accepted intervals down to 1 µs, which drove the embedded timer to fire on
  nearly every loop iteration and flooded the reporter callback with near-empty
  results. **Breaking:** a nonzero `reporterInterval` below 0.1 s now fails with
  `IEINTERVAL` before the run starts.
- `IperfError.IESKEWTHRESHOLD` (raw value 29) is now mapped instead of surfacing
  as `.UNKNOWN` ([#49]), mirroring the embedded engine's code for an invalid
  server skew threshold. **Breaking:** exhaustive switches over `IperfError` must
  handle the new case.
- Internal: preflight stream-count and socket-buffer bounds now use the engine's
  `MAX_STREAMS` / `MAX_TCP_BUFFER` macros instead of duplicated literals, so they
  track the vendored engine on sync ([#51]). No observable behavior change.

### Fixed

- The RSA-validation helpers (`iperf_validate_client_rsa_pubkey` /
  `iperf_validate_server_rsa_privkey`) stay defined even when the vendored C
  config is built without OpenSSL, preventing a latent undefined-symbol link
  failure; a dedicated CI check now compiles that `HAVE_SSL`-off branch ([#50]).

## [3.21.5] - 2026-07-20

### Added

- Declared tvOS 13+ as a supported platform ([#20]). The package already built
  on tvOS; the platform was missing from `Package.swift`.
- `IperfError` now conforms to `Error`, `LocalizedError`,
  `CustomStringConvertible`, and `CustomDebugStringConvertible` ([#12]). It can
  be thrown and caught directly, and `localizedDescription` / string
  interpolation yield the existing human-readable message.

### Changed

- Internal: the C reporter callback now routes interval results to its owning
  `IperfRunner` through an address-keyed registry instead of a global
  `NotificationCenter` broadcast whose name embedded the test pointer's
  `hashValue` ([#16]). Independent runners can no longer observe each other's
  callbacks, and a reused test address always resolves to its current owner.
  No public API or observable behavior changes.
- Housekeeping ([#13]): removed the vestigial `Tests/LinuxMain.swift` and
  `XCTestManifests.swift` (SwiftPM auto-discovers tests since 5.4), dropped a
  commented-out `tcp_info` field block, fixed a callback default-value
  parameter name, and clarified that `IperfIntervalResult.averageRtt` is
  currently unused.

## [3.21.4] - 2026-07-18

### Added

- Core performance parameters ([#1], [#4]): `blockSize` (`--length`),
  `socketBufferSize` (`--window`), `noDelay` (`--no-delay`), and `mss`
  (`--set-mss`); `numStreams` (`--parallel`) now also applies to UDP and SCTP
  clients, and `rate` (`--bitrate`) paces TCP/SCTP in addition to UDP.
- Mid-priority options ([#2], [#5]): `tos` (`--tos`), `clientPort` (`--cport`),
  `udpCounters64Bit` (`--udp-counters-64bit`), `repeatingPayload`
  (`--repeating-payload`), and `getServerOutput` (`--get-server-output`) with
  the new `IperfRunner.serverOutput` property; server-side `oneOff`
  (`--one-off`), `idleTimeout` (`--idle-timeout`), and `rcvTimeout`
  (`--rcv-timeout`).
- `addressFamily` (`-4`/`-6`) forcing IPv4 or IPv6, and `dontFragment`
  (`--dont-fragment`) for UDP clients ([#3], [#6]).

### Changed

- `rate` is now optional (`UInt64?`). Unset keeps the CLI defaults: unlimited
  for TCP/SCTP and 1 Mbit/s for UDP. Previously the property defaulted to
  1 Mbit/s and applied only to UDP.
- `statsInterval` is documented as unused: the embedded engine retains only
  the newest statistics sample per stream, so statistics always sample at
  `reporterInterval`.

### Fixed

- Connect-timeout values under one second are no longer truncated to zero.
- Integer configuration values are clamped instead of trapping on overflow.
- UDP tests with an unset `rate` no longer run unlimited; the wrapper
  restores the CLI's 1 Mbit/s default, which the engine only applies during
  command-line parsing.
- `IperfRunner.serverOutput` now also captures results from servers running
  in JSON mode (`iperf3 -s -J`), which arrive as `json_server_output`.

## [3.21.3] - 2026-07-17

### Added

- Bidirectional (`--bidir`) test mode with separate client-oriented
  upload/download aggregates and per-stream direction.
- GitHub Actions CI running the full test suite, including iperf3 CLI
  interoperability tests, on macOS.
- Declared supported platforms in `Package.swift`: macOS 10.15+ / iOS 13+.

### Changed

- README overhaul: badges, features, requirements, roadmap, and credits.
- The project continues independently of the unmaintained upstream
  `igorskh/iperf-swift`.
- Integration tests resolve the `openssl` executable from multiple Homebrew
  locations.

## [3.21.2] - 2026-07-13

### Fixed

- Correct UDP protocol configuration and reset aggregate RTT state.

### Added

- Comprehensive public API documentation and usage guidance.
- Official Swift-DocC plugin and Swift Package Index hosted-documentation
  configuration.
- Complete OpenSSL Apache-2.0 license text.

## [3.21.1] - 2026-07-10

### Added

- Deterministic iperf 3.21 synchronization (`sync.sh`) with compatibility
  verification.

### Changed

- OpenSSL is provided by `Lakr233/openssl-spm`, removing machine-specific
  Homebrew paths from consuming apps.

### Fixed

- Enforce server authentication and reject incomplete authentication
  configuration.

## [3.21] - 2026-05-15

### Changed

- Embedded engine updated to [iperf3 3.21](https://github.com/esnet/iperf/releases/tag/3.21).

### Added

- Native DSCP support (`dscp`, 0–63).

## [3.20] - 2026-01-26

### Changed

- Embedded engine updated to [iperf3 3.20](https://github.com/esnet/iperf/releases/tag/3.20).

## [3.19.1] - 2025-08-29

### Changed

- Embedded engine updated to [iperf3 3.19.1](https://github.com/esnet/iperf/releases/tag/3.19.1).

## [3.18] - 2024-12-26

### Changed

- Embedded engine updated to [iperf3 3.18](https://github.com/esnet/iperf/releases/tag/3.18).

## [3.17.1] - 2024-10-12

### Changed

- Embedded engine updated to iperf3 3.17.1.
- **Breaking:** OAEP padding is the default, matching iperf3 ≥ 3.17. Enable
  `usePkcs1Padding` only for compatibility with older, vulnerable versions —
  at your own risk.

## [3.16] - 2024-01-03

### Changed

- Embedded engine updated to [iperf3 3.16](https://github.com/esnet/iperf/releases/tag/3.16).

## [3.14] - 2023-08-14

### Changed

- Embedded engine updated to iperf3 3.14.

[Unreleased]: https://github.com/gewill/iperf-swift/compare/v3.21.8...HEAD
[3.21.8]: https://github.com/gewill/iperf-swift/compare/v3.21.7...v3.21.8
[3.21.7]: https://github.com/gewill/iperf-swift/compare/v3.21.6...v3.21.7
[3.21.6]: https://github.com/gewill/iperf-swift/compare/v3.21.5...v3.21.6
[3.21.5]: https://github.com/gewill/iperf-swift/compare/v3.21.4...v3.21.5
[3.21.4]: https://github.com/gewill/iperf-swift/compare/v3.21.3...v3.21.4
[3.21.3]: https://github.com/gewill/iperf-swift/compare/v3.21.2...v3.21.3
[3.21.2]: https://github.com/gewill/iperf-swift/compare/v3.21.1...v3.21.2
[3.21.1]: https://github.com/gewill/iperf-swift/compare/v3.21...v3.21.1
[3.21]: https://github.com/gewill/iperf-swift/compare/v3.20...v3.21
[3.20]: https://github.com/gewill/iperf-swift/compare/v3.19.1...v3.20
[3.19.1]: https://github.com/gewill/iperf-swift/compare/v3.18...v3.19.1
[3.18]: https://github.com/gewill/iperf-swift/compare/v3.17.1...v3.18
[3.17.1]: https://github.com/gewill/iperf-swift/compare/v3.16...v3.17.1
[3.16]: https://github.com/gewill/iperf-swift/compare/v3.14...v3.16
[3.14]: https://github.com/gewill/iperf-swift/releases/tag/v3.14
[#1]: https://github.com/gewill/iperf-swift/issues/1
[#2]: https://github.com/gewill/iperf-swift/issues/2
[#3]: https://github.com/gewill/iperf-swift/issues/3
[#4]: https://github.com/gewill/iperf-swift/pull/4
[#5]: https://github.com/gewill/iperf-swift/pull/5
[#6]: https://github.com/gewill/iperf-swift/pull/6
[#12]: https://github.com/gewill/iperf-swift/issues/12
[#13]: https://github.com/gewill/iperf-swift/issues/13
[#16]: https://github.com/gewill/iperf-swift/issues/16
[#20]: https://github.com/gewill/iperf-swift/issues/20
[#29]: https://github.com/gewill/iperf-swift/pull/29
[#30]: https://github.com/gewill/iperf-swift/issues/30
[#31]: https://github.com/gewill/iperf-swift/issues/31
[#35]: https://github.com/gewill/iperf-swift/issues/35
[#36]: https://github.com/gewill/iperf-swift/issues/36
[#37]: https://github.com/gewill/iperf-swift/issues/37
[#38]: https://github.com/gewill/iperf-swift/issues/38
[#39]: https://github.com/gewill/iperf-swift/issues/39
[#40]: https://github.com/gewill/iperf-swift/issues/40
[#48]: https://github.com/gewill/iperf-swift/issues/48
[#49]: https://github.com/gewill/iperf-swift/issues/49
[#50]: https://github.com/gewill/iperf-swift/issues/50
[#51]: https://github.com/gewill/iperf-swift/issues/51
[#59]: https://github.com/gewill/iperf-swift/issues/59
[#61]: https://github.com/gewill/iperf-swift/issues/61
[#63]: https://github.com/gewill/iperf-swift/issues/63
[#65]: https://github.com/gewill/iperf-swift/issues/65
[#67]: https://github.com/gewill/iperf-swift/issues/67
[#69]: https://github.com/gewill/iperf-swift/issues/69
[#73]: https://github.com/gewill/iperf-swift/issues/73
[#75]: https://github.com/gewill/iperf-swift/issues/75
[#79]: https://github.com/gewill/iperf-swift/issues/79
[#81]: https://github.com/gewill/iperf-swift/issues/81
