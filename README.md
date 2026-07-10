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

OpenSSL is required. You can use [openssl-spm](https://github.com/Lakr233/openssl-spm) for easy integration.

## Testing

The integration tests require a local `iperf3` executable with authentication support. On Apple Silicon, install it with Homebrew:

```sh
brew install iperf3 openssl@3
```

Run all tests:

```sh
swift test
```

The package defaults to Homebrew's Apple Silicon path. On another machine, set `OPENSSL_PREFIX` to the OpenSSL installation prefix.

Run only the iPerf CLI interoperability tests:

```sh
swift test --filter IperfCLIIntegrationTests
```

These tests start local Swift or `iperf3` 3.21 peers, generate temporary RSA keys and authorized-user data, and allocate random local ports. They cover successful authentication, rejection of incorrect credentials, macOS `bind-dev`, and macOS TCP connection statistics. The temporary files are removed after each test. Linux-only GSO/GRO kernel offload behavior requires a Linux CI runner and is not exercised by the macOS test suite.

## Sync [iPerf](https://github.com/esnet/iperf)

1. Run `sync.sh`

The script automatically handles upstream synchronization, applies necessary portability patches (e.g., `File.h` inclusion, `stdatomic` redirection), and restores project-specific functions like custom authentication logic.

All customization data is stored in the `iperf_sync/` directory.

## License

iperf-swift is released under the MIT license.
iperf is released under the BSD license.
See LICENSE for details.
