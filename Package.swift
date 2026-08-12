// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IperfSwift",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
    ],
    products: [
        .library(
            name: "IperfSwift",
            targets: ["IperfCLib", "IperfSwift"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/openssl-spm.git",
            from: "4.0.1"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            exact: "1.5.0"
        ),
    ],
    targets: [
        .target(
            name: "IperfCLib",
            dependencies: [
                .product(name: "OpenSSL", package: "openssl-spm")
            ],
            path: "Sources/IperfCLib"
        ),
        .target(
            name: "IperfSwift",
            dependencies: ["IperfCLib"],
            path: "Sources/IperfSwift"
        ),
        .testTarget(
            name: "iperf-swiftTests",
            dependencies: ["IperfSwift"]),
    ]
)
