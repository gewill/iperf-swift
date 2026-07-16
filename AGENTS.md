# iPerf Swift Agent Instructions

## Project Overview

`iperf-swift` is a Swift Package that exposes the iperf3 3.21 C engine through
the `IperfSwift` wrapper. It supports both client and server execution,
authentication, DSCP, interface binding, and interval statistics on Apple
platforms.

The package contains two layers:

- `Sources/IperfSwift/`: public Swift configuration, lifecycle, callbacks, and
  result models.
- `Sources/IperfCLib/`: vendored/adapted iperf3 C sources and headers.

`iperf_sync/` is the source-of-truth for recurring upstream synchronization:
`custom_files/` contains project compatibility files and `patches/` contains
the maintained changes applied by `sync.sh`.

## Dependencies

- Swift Package Manager is the package/build system.
- OpenSSL is provided by `Lakr233/openssl-spm` and pinned in
  `Package.resolved`. Do not add Homebrew include or linker paths to the
  package manifest; downstream apps must not inherit absolute Homebrew dylib
  references.
- CLI integration tests use a locally installed `iperf3` 3.21 executable.

## Change Boundaries

- Keep public API changes in `Sources/IperfSwift/` and preserve existing
  callback and lifecycle semantics.
- Keep upstream C changes in `iperf_sync/patches/modifications.patch` or
  `iperf_sync/custom_files/` so a future `sync.sh` run does not erase them.
- Do not edit generated build output, `.build/`, or Xcode DerivedData.
- Preserve third-party copyright headers in vendored C files. Keep the upstream
  iperf license in `LICENSE-iperf` and the OpenSSL dependency note in
  `LICENSE-OpenSSL.md`.
- Avoid machine-specific paths, especially `/opt/homebrew`, in package code.

## Behavior Verification

Before implementing, changing, testing, or documenting a feature, establish
what the correct behavior is — in this order:

1. **iperf3 CLI first.** Run the locally installed `iperf3` with the relevant
   flags and observe the real output, for example
   `iperf3 -c 127.0.0.1 -u -V --bidir`. The wrapper must match the CLI's
   observable semantics, not an assumption about them.
2. **Vendored C source second.** Confirm the mechanism in `Sources/IperfCLib/`
   — which side sets a flag, where a metric is computed, how parameters are
   exchanged — rather than reasoning from the public API alone.
3. **RFC third.** When a metric or protocol behavior has a formal definition,
   check the RFC and reflect that definition in documentation and tests. For
   example, UDP jitter is defined by RFC 3550 and is computed only at the
   receiving endpoint, so sender-side streams always report zero jitter.

Encode the verified behavior in tests: interoperability tests compare the
wrapper against the CLI's observable behavior, and unit tests pin semantics
derived from the source or the RFC. Do not treat a surprising observation as a
bug — and do not "fix" it — before confirming it is not defined behavior.

## Synchronization

Run `./sync.sh` to update the bundled iperf source. The script defaults to tag
`3.21` and stages all generated source in a temporary directory before
replacing `Sources/IperfCLib/`. Check `git diff` and `git diff --check` after a
sync. Do not manually edit only the generated source and assume the change will
survive the next sync.

## Testing

Use the smallest relevant check first, then the complete suite:

```sh
swift test
xcodebuild -scheme IperfSwift -destination 'platform=macOS' test
xcodebuild -scheme IperfSwift -destination 'platform=macOS,variant=Mac Catalyst' build
```

The tests cover Swift server/client behavior, local iperf3 interoperability,
authentication, interface binding, DSCP, and macOS TCP statistics. Continue
expanding both pure Swift unit tests and CLI interoperability tests. Linux-only
iperf features such as GSO/GRO require a Linux test runner.

When a test starts a server or subprocess, use a random local port and clean it
up with XCTest teardown. Do not commit private keys, passwords, logs, or
machine-specific test fixtures.

## Documentation

Update `README.md` when public setup, dependency, synchronization, or testing
behavior changes. Keep license information in `LICENSE`, `LICENSE-iperf`, and
`LICENSE-OpenSSL.md` rather than duplicating long legal text in the README.

## Git

Use Conventional Commits:

```text
<type>(<scope>): <subject>
```

Before committing, inspect the real diff, run relevant tests, and stage only
files belonging to the change. The primary development branch is `develop`.
