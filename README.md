# IperfSwift

[![CI](https://github.com/gewill/iperf-swift/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/gewill/iperf-swift/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gewill/iperf-swift)](https://github.com/gewill/iperf-swift/releases)
[![Swift 5.6+](https://img.shields.io/badge/Swift-5.6%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2013%2B%20%7C%20macOS%2010.15%2B-blue.svg)](#requirements)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

`IperfSwift` is a Swift Package that embeds the iperf3 3.21 C engine and exposes
client and server execution through a Swift API.

iperf3 is developed by ESnet/Lawrence Berkeley National Laboratory. Refer to the
[official iperf3 manual](https://software.es.net/iperf/invoking.html) for protocol
behavior and option semantics.

This repository is an independent continuation of
[igorskh/iperf-swift](https://github.com/igorskh/iperf-swift), which is no longer
maintained. Development continues here without upstream involvement.

## Features

- TCP, UDP, and SCTP (where the platform provides it) in client and server roles
- Upload, download (`--reverse`), and bidirectional (`--bidir`) tests
- iperf3 RSA authentication with OAEP and optional legacy PKCS#1 v1.5 padding
- DSCP marking and network-interface binding
- Per-interval callbacks with per-stream results
- macOS TCP statistics
- Self-contained package: the iperf3 engine is bundled and OpenSSL ships as an
  XCFramework, so no machine-specific library paths leak into consuming apps

## Requirements

- Swift 5.6+ (Xcode 13.4+)
- iOS 13+ or macOS 10.15+

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
        from: "3.21.3"
    )
]
```

Then add `IperfSwift` to the target dependencies and import it:

```swift
import IperfSwift
```

The package uses the OpenSSL XCFramework from
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

## Server example

```swift
var configuration = IperfConfiguration()
configuration.role = .server
configuration.address = "0.0.0.0"
configuration.port = 5201

let server = IperfRunner(with: configuration)
server.start(
    { result in print(result.throughput.Mbps) },
    { error in print(error.debugDescription) },
    { state in print(state) }
)
```

Keep the runner alive for the duration of the test. Work runs asynchronously,
and callbacks are not guaranteed to use a specific queue. Dispatch UI updates
to `MainActor` or the main queue. Terminal callback handling should be
idempotent because libiperf can emit more than one terminal state notification.

## Configuration mapping

The wrapper follows the official iperf3 options where the embedded API exposes
them:

| Swift property | iperf3 option | Notes |
| --- | --- | --- |
| `address` | `--client` / `--bind` | Client destination or server bind address |
| `port` | `--port` | Defaults to `5201` |
| `bindDevice` | `--bind-dev` | Supported on macOS by iperf3 3.21; privileges may be required elsewhere |
| `numStreams` | `--parallel` | Applied to TCP client tests |
| `mode` | `--reverse` / `--bidir` | Selects upload, download, or simultaneous bidirectional mode |
| `reverse` | `--reverse` | Compatibility accessor for upload/download mode |
| `rate` | `--bitrate` | UDP bits per second |
| `duration` | `--time` | Client-side whole-second duration |
| `numberOfBytes` | `--bytes` | Do not combine with another end condition |
| `timeout` | `--connect-timeout` | Swift value is expressed in seconds |
| `dscp` | `--dscp` | Numeric DSCP value in `0...63` |
| `reporterInterval` | `--interval` | Drives both reporting and statistics intervals |
| `omit` | `--omit` | Initial seconds excluded from measurements |

`statsInterval` is currently reserved; set `reporterInterval` to control
interval callbacks.

## Authentication

Authentication follows iperf3's official RSA scheme:

- The client uses `username`, `password`, and a Base64-encoded PEM `publicKey`.
- The server uses a Base64-encoded, unencrypted PEM `privateKey` and
  `authorizedUsers` in iperf3's `username,sha256` format.
- Keep `usePkcs1Padding` disabled to use OAEP, the iperf3 default since 3.17.
  Enable legacy PKCS#1 v1.5 padding only when interoperability requires it.
- Keep client and server clocks within `timeSkewThreshold` seconds.

See the official manual's
[authentication examples](https://software.es.net/iperf/invoking.html#examples)
for key generation and password hashing.

Do not commit private keys, passwords, or authorized-user data.

## Testing

The integration tests require a local `iperf3` 3.21 executable with
authentication support. On macOS it can be installed with Homebrew:

```sh
brew install iperf3
```

Run the complete Swift Package test suite:

```sh
swift test
```

Run a focused suite:

```sh
swift test --filter IperfSwiftUnitTests
swift test --filter IperfCLIIntegrationTests
```

The integration suite starts local Swift or CLI peers, creates temporary RSA
credentials, and allocates random local ports. It covers TCP and UDP
interoperability, bidirectional mode, authentication, macOS interface binding,
DSCP, and macOS TCP statistics. Linux-only GSO/GRO behavior requires a Linux
runner.

## Documentation

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

`sync.sh` defaults to the official `3.21` tag, stages the update in a temporary
directory, applies `iperf_sync/patches/modifications.patch`, restores
`iperf_sync/custom_files/`, and then replaces `Sources/IperfCLib/`. Do not keep
project-specific changes only in the generated C source because the next sync
will overwrite them.

## Versioning

The Swift package and embedded engine have separate versions. For example,
package release `3.21.3` embeds the official iperf3 `3.21` engine.

## Roadmap

Upcoming work is tracked in GitHub issues:

- [#1](https://github.com/gewill/iperf-swift/issues/1) — core performance
  parameters: `--length`, `--window`, TCP `--bitrate`, UDP `--parallel`,
  `--no-delay`, `--set-mss`
- [#2](https://github.com/gewill/iperf-swift/issues/2) — mid-priority options:
  UDP 64-bit counters, TOS, server timeouts, `--one-off`,
  `--get-server-output`, and more
- [#3](https://github.com/gewill/iperf-swift/issues/3) — options needing C
  shims: `--dont-fragment`, `-4`/`-6`

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
