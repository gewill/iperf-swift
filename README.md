# IperfSwift

`IperfSwift` is a Swift Package that embeds the iperf3 3.21 C engine and exposes
client and server execution through a Swift API. It supports TCP, UDP, SCTP
where the platform provides it, authentication, DSCP, interface binding,
interval results, and macOS TCP statistics.

iperf3 is developed by ESnet/Lawrence Berkeley National Laboratory. Refer to the
[official iperf3 manual](https://software.es.net/iperf/invoking.html) for protocol
behavior and option semantics.

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
        from: "3.21.1"
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
        configuration.reverse = .upload
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

To run a reverse test (`iperf3 --reverse`), use `.download`. For UDP, set
`prot = .udp` and configure `rate` in bits per second.

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
| `reverse` | `--reverse` | `.download` enables reverse mode |
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
interoperability, authentication, macOS interface binding, DSCP, and macOS TCP
statistics. Linux-only GSO/GRO behavior requires a Linux runner.

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
package release `3.21.1` embeds the official iperf3 `3.21` engine.

## License

Project-specific code is released under the [MIT License](LICENSE). The bundled
iperf code keeps the upstream license in [LICENSE-iperf](LICENSE-iperf), and the
OpenSSL dependency is documented in [LICENSE-OpenSSL.md](LICENSE-OpenSSL.md).
