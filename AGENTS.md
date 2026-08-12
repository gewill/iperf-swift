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
  Prefer the patch: `patch --forward` fails loudly when a hunk stops applying,
  which is what makes a drifting change visible. `sync.sh` also carries `perl`
  substitutions for edits the patch cannot express; they exit successfully when
  nothing matches, so each one needs a `grep -Fq` line in the verification
  block to turn a silent no-op into a failed sync.
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

## Repository First

AI conversations, temporary plans, and execution context are ephemeral.
Anything valuable for future development — requirements, constraints, design
rationale, validation conclusions — must be recorded in the repository: an
issue, pull request, commit, project documentation, or a necessary code
comment. A future maintainer should be able to understand the project's
important context from the repository alone.

Records are decision driven: code already explains *how*, so document what code
cannot express — why the current approach was chosen, why alternatives were
rejected, important limitations, and compatibility or architecture trade-offs.
Only decisions with long-term value need recording. Do not log obvious
implementation details, AI tool or model names, agent execution modes, full AI
reasoning, or step-by-step execution traces.

When executing a task, prioritize in order: a correct change, focused scope,
sufficient validation, and important decisions recorded in the repository.
Beyond that, minimize process and prose.

## Workflow

For non-trivial changes use a lightweight flow: Issue → Branch → Pull Request →
Squash Merge. Keep it light; do not add documentation work for its own sake.

- **Issue**: why the change is needed, the expected result, and any acceptance
  criteria. Simple tasks can stay short — no elaborate templates.
- **Implementation**: read the related issue and project documentation first,
  stay within the task scope, and avoid unrelated refactors or file changes.
  When behavior changes, update the necessary tests or documentation. Record
  significant design choices and their rationale; do not record every attempt.
- **Pull Request**: keep it to `## Summary` (what changed), `## Decision`
  (important decisions and why — omit if none), and `## Validation` (build,
  test, or manual verification results). No long implementation reports, file
  inventories, or restating what the diff already shows.
- **Human review**: the maintainer is responsible for all merged code. Before
  merging, confirm the change matches the task goal, contains no unrelated
  modifications, and has validation matched to its risk — without generating
  checkbox lists for form's sake.

## Git

Use Conventional Commits:

```text
<type>(<scope>): <subject>
```

Commit messages describe the final change concisely and may reference the
related issue or pull request; important context belongs in the issue, PR, or
project documentation rather than the commit body. Before committing, inspect
the real diff, run relevant tests, and stage only files belonging to the
change. The primary development branch is `develop`.
