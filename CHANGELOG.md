# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows the embedded iperf3 engine: the major and minor components
track the engine version (currently 3.21), and the patch component is the
package release number.

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
