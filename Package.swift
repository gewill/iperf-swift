// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let opensslPrefix = ProcessInfo.processInfo.environment["OPENSSL_PREFIX"] ?? "/opt/homebrew/opt/openssl@3"

let package = Package(
    name: "IperfSwift",
    products: [
        .library(
            name: "IperfSwift",
            targets: ["IperfCLib", "IperfSwift"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "IperfCLib",
            dependencies: [],
            path: "Sources/IperfCLib",
            cSettings: [
                .unsafeFlags(["-I", "\(opensslPrefix)/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(opensslPrefix)/lib"]),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto")
            ]
        ),
        .target(
            name: "IperfSwift",
            dependencies: ["IperfCLib"],
            path: "Sources/IperfSwift",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(opensslPrefix)/include"])
            ]
        ),
        .testTarget(
            name: "iperf-swiftTests",
            dependencies: ["IperfSwift"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(opensslPrefix)/include"])
            ]),
    ]
)
