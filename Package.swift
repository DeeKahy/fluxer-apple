// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FluxerKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "FluxerKit", targets: ["FluxerKit"]),
    ],
    targets: [
        .target(name: "FluxerKit"),
        .testTarget(name: "FluxerKitTests", dependencies: ["FluxerKit"]),
    ]
)
