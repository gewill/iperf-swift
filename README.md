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

Need compiling OpenSSL, see https://github.com/x2on/OpenSSL-for-iPhone

## Sync [iPerf](https://github.com/esnet/iperf)

Thanks to ndfred [sync.sh](https://github.com/ndfred/iperf-ios/blob/master/sync.sh)

1. Run `sync.sh`
2. Add `#include <File.h>` in `/Sources/IperfCLib/include/iperf.h` and `Sources/IperfCLib/include/iperf_util.h`
3. Add `#ifdef __linux__` in`Sources/IperfCLib/include/flowlabel.h`
4. Add `#if defined(HAVE_SSL)` in `Sources/IperfCLib/include/iperf_auth.h`

## License

iperf-swift is released under the MIT license.
iperf is released under the BSD license.
See LICENSE for details.
