// swift-tools-version:5.6
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
            from: "3.6.2"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            from: "1.1.0"
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
