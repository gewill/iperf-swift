# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows the embedded iperf3 engine: the major and minor components
track the engine version (currently 3.21), and the patch component is the
package release number.

## [Unreleased]

**Breaking:** `IperfIntervalResult.reverse` is read-only. Assign
`IperfIntervalResult.mode` instead.

### Added

- `IperfRunner.streamTotals` exposes the per-stream run totals the engine keeps
  in `iperf_stream_result` ([#149]) — the round-trip time range and sample
  count, the largest send congestion window and send window, retransmits and
  reordering. These are the figures `iperf3` prints in `end.streams[]`, and
  nothing in the wrapper reached them before, so a consumer wanting a run
  summary had to accumulate interval deltas and hope the reconstruction matched.
  Doing exactly that is the root of four separate test issues ([#135], [#137],
  [#145], [#151]).

  `IperfStreamRunResult.tcpSenderTotals` is one optional rather than a
  field-by-field one because the engine fills the whole group in a single pass
  guarded by three conditions at once: TCP, platform TCP info, and this endpoint
  being the sender. A receiving client and any UDP stream leave all of it
  untouched. The CLI prints zeros there — a `-R` client reports `mean_rtt` 0 —
  which reads as a measurement; this reports the absence instead.

### Changed

- `IperfIntervalResult` carries its direction in one property ([#143]).
  `mode` is now the direction of record and `reverse` is derived from it,
  instead of both being stored where they could disagree — their defaults did,
  pairing `.download` with a `0` flag, which is a state no run reports. libiperf
  tracks direction as two flags but rejects `--reverse` together with `--bidir`,
  so its three reachable states are exactly `IperfTestMode`'s cases, and
  deriving the flag from the mode reproduces the engine's own value in each. The
  opposite derivation is the lossy one: an upload and a bidirectional run both
  report `0`. `reverse`'s documentation said `0` meant upload, which was wrong
  for the bidirectional case. **Breaking:** `reverse` no longer has a setter;
  callers building a result — previews, test doubles — set `mode`. An
  interoperability test now checks all three directions against the CLI's
  `reverse`/`bidir` pair, bidirectional included.

### Deprecated

- `IperfIntervalResult.averageRtt` is deprecated and stays `0.0` ([#147]).
  Neither `iperf3` nor RFC 6298 defines a round-trip time aggregated across
  streams: the CLI sums bytes, packets and retransmits into `sum_sent` but
  reports RTT per stream only, and RFC 6298 gives each connection independent
  smoothed-RTT state with no rule for combining them. Populating the property
  would also average estimators rather than measurements — the engine reports
  SRTT, not a sample — and would have to decide what to do with the `-1` the
  engine returns where TCP info is unavailable. Read
  `IperfStreamIntervalResult.rtt` instead, in microseconds. `evaluate()` no
  longer resets the property, since it never computed it.

### Fixed

- Internal: a CLI server that fails to start is now reported where it happens
  ([#155]). `freePort()` releases its port before the caller binds it, so a
  server can lose the race and exit; forty call sites then waited a fixed
  interval and carried on without one, and the run failed later as whatever the
  client made of an absent peer — a lost server surfaced once as a client-side
  "Unable to start stream listener", which sent the investigation to the wrong
  place. They now check the process survived startup instead.

  The check is a liveness check rather than a connection probe on purpose:
  connecting would consume the single client a `-1` server will serve, and a
  `bind` probe cannot tell listening from not, since an `iperf3` server binds
  the wildcard address and a specific-address bind succeeds either way. The
  collision that matters is server against server — two tests handed the same
  port, the second failing with "Address already in use" — and a test
  reproduces exactly that to prove the check fires.
- Internal: the non-finite duration test no longer depends on DNS ([#150]). It
  reached the network through an unresolvable name, so the resolver's latency
  sat inside its two-second bound — the same run took 0.012s locally and over
  two seconds on a stalled CI runner. It now connects to a loopback port that
  was just released, which is refused immediately: ten local runs finish in
  0.001s. A documentation-range literal was measured first and rejected, failing
  with `IECTRLCLOSE` after three to four seconds because what happens to those
  packets depends on the local network.
- Internal: the byte-limit test no longer asserts an exact reconstructed byte
  total ([#151]). Summing reporter deltas is the only way a test can obtain a
  run total today, and the reconstruction depends on how the engine slices the
  final intervals, so an exact match against the target failed on CI while the
  run itself was correct — its wall clock, the signal that actually detects a
  `DURATION` cutoff, held at 12.957s. The byte check now pins the failure mode
  instead, requiring more than a `DURATION`-capped run would move at the test's
  pacing, and both byte-counting tests guard their accumulator with a lock
  rather than mutating it from the engine thread unsynchronised.
- Internal: the UDP block-size test no longer fails when the packet/byte race
  lands in the final interval ([#145]). Counting every delivery reconstructs the
  totals for every interval but the last, which has no next delivery to carry
  the compensating bytes, so a datagram straddling the final snapshot left the
  totals one datagram apart against an assertion with no tolerance. The check
  now requires the byte total to be a whole number of datagrams and bounds the
  packet-versus-byte shortfall at one datagram. That pair still pins the
  datagram size — divisibility alone does not, but a wrong size puts the
  shortfall orders of magnitude outside the bound.

## [3.21.15] - 2026-08-25

An audit of every `IperfConfiguration` default against the bundled engine,
continuing the work behind [#131]. Of 38 properties, 30 already matched and 3
deviated deliberately with the reason recorded; these are the four that differed
with nothing to explain them. A UDP interoperability test also regains the
block-size check it lost to a flake fix.

**Behavior change:** a client that never sets `mode` now measures the upload
direction, a server that never sets `address` now binds the wildcard address,
and a byte-limited run is no longer cut off after ten seconds.

### Changed

- `IperfConfiguration.mode` now defaults to `.upload` instead of `.download`
  ([#139]). `iperf_defaults()` never assigns `reverse`, so the engine's own
  client is a sender and `iperf3 -c host` uploads unless `--reverse` asks
  otherwise. The wrapper configures the engine directly rather than through the
  argument parser, so a default it does not restore is a silent divergence.
  **Behavior change:** a run that never set `mode` now measures the upload
  direction — set `mode = .download` to keep the previous measurement. Upload
  and download are different numbers on any asymmetric link, so a caller who set
  nothing was reading the direction they did not ask for. An interoperability
  test now compares the wrapper's default direction against the CLI's.
- `IperfConfiguration.address` is now unset by default instead of `"127.0.0.1"`
  ([#139]). A server therefore binds the wildcard address and accepts both IPv4
  and IPv6 exactly as `iperf3 -s` does, instead of listening on loopback alone
  and being unreachable from any other host. A client with no address still
  resolves to loopback. **Behavior change:** a server that relied on the default
  now accepts remote clients — set `address = "127.0.0.1"` to keep the previous
  binding. An explicit `"0.0.0.0"` is not equivalent to unset: the engine only
  arranges the dual-stack socket when no bind address is given, so that value
  yields an IPv4-only listener.
- `IperfConfiguration.timeSkewThreshold` now records why it defaults to `10`
  ([#139]). The engine's own default is `0`, which `check_authentication()`
  reads literally and which therefore rejects any clock difference at all;
  `iperf_parse_arguments()` substitutes `10` once a server private key has
  loaded, and the wrapper replicates that substituted value. No behavior change.
- Internal: the UDP interoperability test now reconstructs run totals by
  counting every delivery, so the datagram size it claims to verify is checked
  again ([#135], [#137]). The pairing assertion was dropped as flaky because
  interval snapshots race the UDP sender threads, which attribute a datagram to
  the packet count before its bytes; that removed the only thing tying the byte
  total to a datagram count, and the test passed with the engine sending
  400-byte datagrams. Counting every delivery — including the closing summary
  the test had excluded — makes the two agree exactly, with no tolerance to
  outgrow.

### Fixed

- A byte-limited client run is no longer cut off after ten seconds ([#139]).
  Setting `numberOfBytes` without a `duration` left the engine's default
  duration in place, so the transfer stopped at `DURATION` having moved less
  than the caller asked for, reporting success. The CLI's bytes-only semantics
  were also unreachable through the public API, because an explicit `duration`
  alongside `numberOfBytes` is rejected as `IEENDCONDITIONS`. The wrapper now
  clears the duration the way `iperf_parse_arguments()` does for `--bytes`
  without `-t`.

## [3.21.14] - 2026-08-17

A single-change release. A client that never set a stream count measured two
parallel streams where `iperf3` with the same arguments measured one, so the
wrapper and the CLI reported different throughput for what looked like the same
test.

**Behavior change:** a run that never sets `numStreams` now reports
single-stream throughput. Set it to `2` to keep the previous measurement.

### Changed

- `IperfConfiguration.numStreams` now defaults to `1`, the value the engine's
  own `iperf_defaults()` assigns, instead of `2` ([#131]). The wrapper
  configures the engine directly rather than through the argument parser, so a
  default it does not restore is a silent divergence: a caller who set nothing
  ran two parallel streams where `iperf3` with the same arguments ran one, and
  two streams and one measure differently on a fast path. The value dates to
  the initial import and no decision recorded it. **Behavior change:** a run
  that never set `numStreams` now reports the throughput of a single stream —
  set it to `2` to keep the previous measurement. An interoperability test now
  compares the wrapper's default stream count against the CLI's, so a divergence
  fails instead of going unnoticed.

## [3.21.13] - 2026-08-13

A dependency, correctness and hardening release. OpenSSL moves to 4.0.1, three
ways the engine could reach past its own run into the host process are closed,
and the synchronization script no longer loses local edits or races itself.

**Breaking:** exhaustive switches over `IperfError` must handle twenty-three new
cases, an application depending on `openssl-spm` directly must resolve 4.x, and
the minimum toolchain is Swift 5.7. **Behavior change:** the error closure is no
longer always terminal for a persistent server, and runs are serialized
process-wide.

### Changed

- The bundled OpenSSL is now 4.0.1 ([#125]), raising the `openssl-spm`
  requirement to `from: "4.0.1"`. Version 4 ships the library as a framework, so
  the vendored C gained a compatibility header that resolves either layout, and
  the public umbrella header now only forward-declares `EVP_PKEY` — the DocC
  symbol-graph pass does not load the framework's module map, so a public
  OpenSSL include broke documentation builds. **Breaking:** an application that
  also depends on `openssl-spm` directly must be able to resolve 4.x.
- The minimum supported toolchain is now Swift 5.7 / Xcode 14.0 ([#103]).
  This matches the optional-binding syntax already used by the package and the
  DocC 1.5.0 plugin, which is now pinned so dependency resolution cannot
  silently raise the minimum toolchain again.
- The atomic compatibility header the Apple platform build relies on is now
  project-owned and MIT-licensed ([#102]). It replaces a header derived from
  FFmpeg and carrying the LGPL, which the package shipped without disclosing in
  its license documentation. The replacement uses compiler atomic builtins
  while keeping the fields integer-typed, so the public iperf structures stay
  importable by Swift's Clang importer. No API or behavior change.
- `IperfError` now maps every error code the embedded engine defines ([#101]),
  adding twenty-three cases that previously surfaced as `.UNKNOWN`. **Breaking:**
  exhaustive switches over `IperfError` must handle the new cases.
- Internal: interoperability tests now resolve the CLI through a shared helper
  and require iperf 3.21 exactly ([#123]), instead of accepting whatever `iperf3`
  the runner happened to have. A CLI-versus-wrapper comparison against a
  different engine proves nothing about parity.
- Internal: error-code parity tests now derive the engine's complete error enum
  directly from `iperf_api.h` and compare both names and values with the Swift
  source and runtime cases ([#118]). A future engine sync that adds an error now
  fails without updating a second hand-maintained C list. `iperf_strerror` is
  not used for discovery because it lacks a case for the valid
  `IESETSCTPBINDX` code. The runtime check also rejects a wrapper error whose
  raw value falls inside the engine's range, which the value list it replaced
  covered, and the parser's own failure modes are pinned against fixtures so a
  future edit cannot make it agree by parsing less.
- Engine runs are serialized through one process-wide FIFO queue ([#114]). The
  vendored libiperf keeps its timer list and `i_errno` at process scope, so
  concurrent runners could race the timers and cross each other's errors. Only
  one embedded client or server now executes per process; a later runner stays
  in `IperfRunnerState/initialising` until the active one finishes or stops, and
  `stop()` on a queued runner cancels it without it ever entering
  `IperfRunnerState/running`. **Behavior change:** a persistent server blocks
  later runners until it is stopped.
- A server with `oneOff` disabled now keeps listening after a client finishes
  and after an idle timeout, matching the CLI ([#98]). It previously ended the
  run in both cases, so the persistent semantics the option describes were
  unreachable. `idleTimeout` now restarts an idle server; in one-off mode it
  still finishes the runner.

### Fixed

- Starting a run no longer changes the host process's `SIGPIPE` disposition
  ([#106]). `IperfRunner.start()` called `signal(SIGPIPE, SIG_IGN)`, which is
  process-wide and permanent, so an application that installed its own handler
  lost it to a measurement library and never got it back. The engine now sets
  `SO_NOSIGPIPE` on the sockets it creates and accepts, which confines the
  suppression to those descriptors.
- The engine no longer leaks the authorized-users buffer ([#122]). Setting
  `authorizedUsers` a second time dropped the previous allocation, and
  destroying a test never released the last one.
- Synthetic `IperfStreamIntervalResult` values now derive duration and
  throughput from `startTime` and `endTime`, matching the engine ([#86]). New
  code should provide those timestamps and omit `intervalDuration`; set
  `endTime` to `startTime + duration`. The previous initializer remains as a
  deprecated compatibility overload: when both timestamps are left at their
  default zero values, it
  preserves duration-only calls by synthesizing `endTime` from
  `intervalDuration`. **Behavior change:** when callers provide timestamps and
  a conflicting `intervalDuration`, the timestamps take precedence. The
  deprecated overload is intended for migration and may be removed in a future
  source-breaking release.
- A persistent server no longer ends because one client's test failed ([#98]).
  The engine returns `-1` from `iperf_run_server` for a failed client
  interaction — a rejected authentication, a stalled transfer, a control-channel
  error — and `-2` only when it cannot establish the listening socket. The
  restart condition accepted only non-negative codes, so any of the twenty-five
  `-1` paths ended the runner. A rejected password now ends that client's test
  and leaves the server listening, matching the CLI, whose own loop reports a
  `-1` and continues. The error is still delivered to the error closure, so the
  diagnostic is unchanged; what changes is that the runner stays
  `IperfRunnerState/running`. **Behavior change:** the error closure is no
  longer always terminal — read the runner's state alongside it.
- A one-off server reaching its idle timeout no longer terminates the host
  process ([#97]). The vendored engine called `exit(0)` on that path, taking
  the embedding application down with it; it now returns control and the runner
  reports `IperfRunnerState/finished`.
- `stop()` no longer risks closing a file descriptor the host has since reused
  ([#99]). The listener was closed while its descriptor stayed in the test, so a
  second `stop()` or the engine's own cleanup could close whatever the process
  had opened in its place. The descriptor is now invalidated atomically before
  the close, and cancellation, cleanup, and listener rebuilding share that rule.
- A failure to bind a socket to a device now reports `IEBINDDEV`, or
  `IEBINDDEVNOSUPPORT` where the platform does not support it, instead of being
  overwritten by the generic `IECONNECT`, `IELISTEN`, or `IESTREAMLISTEN` of the
  calling path ([#101]).
- Internal: `sync.sh` runs again and no longer loses the `flowlabel.h`
  `__linux__` guard. It asserted `#include <File.h>` in `include/iperf.h`, which
  that header does not contain, so the run aborted there; and the substitution
  that inserts the guard was rewritten into one that only normalizes an existing
  guard, which a pristine upstream checkout never has. The verification block
  now also covers the engine-error edits, so a substitution that stops matching
  fails the sync instead of passing silently ([#102]).
- Internal: the synchronization patch now records the engine-error changes
  ([#101]) made to `iperf_client_api.c`, `iperf_server_api.c`, `iperf_udp.c`,
  and `net.c`. They were present only in `Sources/IperfCLib/`, and `sync.sh`
  applies the patch to a freshly downloaded upstream tree before replacing the
  vendored sources, so the next run would have reverted them.
- Internal: `sync.sh` now uses a unique system temporary directory and refuses
  concurrent replacement of the generated source tree ([#110]). It no longer
  removes repository directories named `iperf3` or
  `Sources/IperfCLib.sync-tmp`; key source transformations require exact match
  counts, the Apple-platform `iperf_config.h` is a deterministic maintained
  input whose probe names must match the selected upstream tag, staging stays
  on the destination filesystem, and CI verifies that regenerating iperf 3.21
  produces a clean diff. Stale-lock errors now include the recovery command.

## [3.21.12] - 2026-08-06

A bug-fix release for stopped runs. The traffic measured between a run's last
periodic interval and the moment it was stopped now reaches the consumer, so a
summary built by summing intervals no longer reads low.

**Behavior change:** a stopped run delivers one more reporter callback than it
did in 3.21.11. Code counting callbacks to count intervals should read each
result's own duration and byte count.

### Fixed

- A stopped run now delivers its closing interval ([#84]). Every run ends with
  one delivery carrying `IperfState/DISPLAY_RESULTS`, holding the bytes
  measured since the previous interval; the engine gathers it whether the run
  reaches its duration or is stopped. `stop()` moves the runner to
  `IperfRunnerState/stopping` before the engine finishes, and the reporter
  ignored anything arriving outside `IperfRunnerState/running`, so that closing
  delivery was dropped for stopped runs only. A consumer summing interval bytes
  reported up to a full reporting period of traffic as missing — measured at
  24% of a four-second run, since the shortfall is a fixed period and the
  relative error grows as the run gets shorter. **Behavior change:** a stopped
  run now delivers one more reporter callback than it used to.

## [3.21.11] - 2026-08-06

A bug-fix release for server mode. A client going away no longer looks like a
failure, so a server that keeps listening is no longer interrupted by the most
ordinary way its run can end.

### Fixed

- A server whose client terminated no longer reports a failure ([#90]). The
  engine reports failure through its return code; `i_errno` is a global it also
  writes on paths that succeed. `CLIENT_TERMINATE` prints the run's summary,
  sets `IECLIENTTERM` and returns 0 — the engine's way of saying this run is
  over, which is why the CLI prints that line and goes back to listening. The
  wrapper read `i_errno` as the verdict and turned the completed run into
  `IperfRunnerState/error`; because `i_errno` is not thread-local, a receiver
  thread ending on the closed socket could overwrite it first, so the delivered
  code was usually `IESTREAMREAD` rather than anything describing the outcome.
  Such a run now reports `IperfRunnerState/finished` with no error callback,
  and the intervals measured before the client left are unaffected.

  A client that loses its server is unchanged: the engine returns -1 there, so
  it still reports `IESERVERTERM`. The asymmetry is the engine's own — a client
  has a duration to fall short of, while a server's run only ever ends when its
  client ends it.

## [3.21.10] - 2026-08-06

An API release. The library's measurement behavior is unchanged from 3.21.9;
what changes is that a consumer can now build interval results the engine did
not produce.

### Added

- A public initializer for `IperfStreamIntervalResult` ([#86]). Consumers can
  now build synthetic stream measurements and let `IperfIntervalResult`'s
  existing `evaluate()` derive the aggregates, so a result assembled outside
  the engine carries the same totals, throughput and UDP statistics the engine
  would have computed from the same streams. Only the fields feeding those
  aggregates are parameters; the interval's own length is derived from the
  supplied start and end, as the engine derives it from the same two
  timestamps.

  This unblocks delivering results through the real `reporterFunctionType`
  callback — SwiftUI previews, and test doubles that would otherwise have to
  reach past a consumer's own receiving path to place data. The engine's own
  construction is unchanged.

## [3.21.9] - 2026-08-06

A reporting-correctness and JSON streaming release. Interval callbacks now
match the engine's observable output more closely, and applications can consume
the JSON stream events as they are emitted, followed by the complete summary
document.

Expect fewer reporter callbacks than 3.21.8 delivered: a duplicate is no longer
repeated, and a run ending on a byte count no longer reports the empty trailing
interval. Code that counts callbacks to count intervals should read each
result's own duration and byte count, and code that treated the final short
callback as an end-of-run signal should use the `finished` runner state.

### Added

- JSON streaming support ([#83]). `IperfConfiguration.jsonStream` enables
  iperf3's `--json-stream`, and a new `onJSONStream` closure on `IperfRunner`
  receives each raw event — `start`, then one per interval, then `end` — as it
  is emitted. `jsonStreamFullOutput` appends the complete summary document as
  the closure's final value and retains it on `IperfRunner.jsonOutput`, which
  is readable from that final invocation onward. Setting `jsonStreamFullOutput`
  without `jsonStream` does nothing, matching the CLI, where
  `--json-stream-full-output` alone is ignored rather than rejected. The
  existing three-argument `start` overloads are unchanged, so callers that do
  not want the events need no edit.

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

[Unreleased]: https://github.com/gewill/iperf-swift/compare/v3.21.14...HEAD
[3.21.15]: https://github.com/gewill/iperf-swift/compare/v3.21.14...v3.21.15
[3.21.14]: https://github.com/gewill/iperf-swift/compare/v3.21.13...v3.21.14
[3.21.13]: https://github.com/gewill/iperf-swift/compare/v3.21.12...v3.21.13
[3.21.12]: https://github.com/gewill/iperf-swift/compare/v3.21.11...v3.21.12
[3.21.11]: https://github.com/gewill/iperf-swift/compare/v3.21.10...v3.21.11
[3.21.10]: https://github.com/gewill/iperf-swift/compare/v3.21.9...v3.21.10
[3.21.9]: https://github.com/gewill/iperf-swift/compare/v3.21.8...v3.21.9
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
[#83]: https://github.com/gewill/iperf-swift/pull/83
[#86]: https://github.com/gewill/iperf-swift/issues/86
[#90]: https://github.com/gewill/iperf-swift/issues/90
[#97]: https://github.com/gewill/iperf-swift/issues/97
[#98]: https://github.com/gewill/iperf-swift/issues/98
[#99]: https://github.com/gewill/iperf-swift/issues/99
[#101]: https://github.com/gewill/iperf-swift/issues/101
[#102]: https://github.com/gewill/iperf-swift/issues/102
[#103]: https://github.com/gewill/iperf-swift/issues/103
[#114]: https://github.com/gewill/iperf-swift/pull/114
[#106]: https://github.com/gewill/iperf-swift/issues/106
[#110]: https://github.com/gewill/iperf-swift/issues/110
[#118]: https://github.com/gewill/iperf-swift/issues/118
[#122]: https://github.com/gewill/iperf-swift/pull/122
[#123]: https://github.com/gewill/iperf-swift/pull/123
[#125]: https://github.com/gewill/iperf-swift/pull/125
[#131]: https://github.com/gewill/iperf-swift/issues/131
[#135]: https://github.com/gewill/iperf-swift/issues/135
[#137]: https://github.com/gewill/iperf-swift/issues/137
[#139]: https://github.com/gewill/iperf-swift/issues/139
[#143]: https://github.com/gewill/iperf-swift/issues/143
[#145]: https://github.com/gewill/iperf-swift/issues/145
[#147]: https://github.com/gewill/iperf-swift/issues/147
[#149]: https://github.com/gewill/iperf-swift/issues/149
[#150]: https://github.com/gewill/iperf-swift/issues/150
[#151]: https://github.com/gewill/iperf-swift/issues/151
[#155]: https://github.com/gewill/iperf-swift/issues/155
[#84]: https://github.com/gewill/iperfman/issues/84
