# Swift wrapper for iPerf

An easy to use Swift wrapper for [iPerf](https://github.com/esnet/iperf).

## Usage

An application using this package: [iPerf SwiftUI](https://github.com/igorskh/iperf-swiftui)

Package implements iPerf server and client.

Usage example:
```swift
class IperfRunnerController: ObservableObject, Identifiable {
    private var iperfRunner: IperfRunner?
    
    @Published var isDeleted = false
    @Published var runnerState: IperfRunnerState = .ready
    @Published var debugDescription: String = ""
    @Published var displayError: Bool = false
    @Published var results = [IperfIntervalResult]() {
        didSet {
            objectWillChange.send()
        }
    }
    
    func onResultReceived(result: IperfIntervalResult) {
        if result.streams.count > 0 {
            results.append(result)
        }
    }
    
    func onErrorReceived(error: IperfError) {
        DispatchQueue.main.async {
            self.displayError = error != .IENONE
            self.debugDescription = error.debugDescription
        }
    }
    
    func onNewState(state: IperfRunnerState) {
        if state != .unknown && state != runnerState {
            DispatchQueue.main.async {
                self.runnerState = state
            }
        }
    }
    
    func start() {
        self.formInput = formInput
        
        results = []
        debugDescription = ""
        
        iperfRunner = IperfRunner(with: IperfConfiguration())
        iperfRunner!.start(
            onResultReceived,
            onErrorReceived,
            onNewState
        )
    }
    
    func stop() {
        iperfRunner!.stop()
    }
}

```

## OpenSSL

OpenSSL is provided through [openssl-spm](https://github.com/Lakr233/openssl-spm). The package uses its XCFramework, so consuming apps do not inherit a Homebrew dylib path and can sign the OpenSSL binaries with the app.

## Testing

The integration tests require a local `iperf3` executable with authentication support. Install it with Homebrew:

```sh
brew install iperf3
```

Run all tests:

```sh
swift test
```

Run only the Swift Wrapper unit tests:

```sh
swift test --filter IperfSwiftUnitTests
```

Run only the iPerf CLI interoperability tests:

```sh
swift test --filter IperfCLIIntegrationTests
```

These tests start local Swift or `iperf3` 3.21 peers, generate temporary RSA keys and authorized-user data, and allocate random local ports. They cover successful authentication, rejection of incorrect credentials, macOS `bind-dev`, DSCP 46 socket configuration, and macOS TCP connection statistics. The temporary files are removed after each test. Linux-only GSO/GRO kernel offload behavior requires a Linux CI runner and is not exercised by the macOS test suite.

## TODO

- Gradually expand the test suite with focused unit tests for the Swift wrapper
  layer, including configuration mapping, lifecycle transitions, callbacks,
  error propagation, and result aggregation.
- Add more interoperability tests against the macOS command-line `iperf3`
  client and server, covering TCP, UDP, authentication, DSCP, interface
  binding, and representative failure cases.

## Sync [iPerf](https://github.com/esnet/iperf)

1. Run `sync.sh`

The script automatically handles upstream synchronization, applies necessary portability patches (e.g., `File.h` inclusion, `stdatomic` redirection), and restores project-specific functions like custom authentication logic.

All customization data is stored in the `iperf_sync/` directory.

## License

Project-specific code is released under the [MIT License](LICENSE).
The bundled iperf code keeps the upstream license in [LICENSE-iperf](LICENSE-iperf).
The OpenSSL dependency is documented in [LICENSE-OpenSSL.md](LICENSE-OpenSSL.md).
