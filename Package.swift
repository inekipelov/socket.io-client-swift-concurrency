// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SocketIOConcurrency",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SocketIOConcurrency",
            targets: ["SocketIOConcurrency"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", .upToNextMinor(from: "16.1.1")),
    ],
    targets: [
        .target(
            name: "SocketIOConcurrency",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
            ],
            path: "Source"
        ),
        .testTarget(
            name: "SocketIOConcurrencyTests",
            dependencies: ["SocketIOConcurrency"],
            resources: [
                .copy("../IntegrationServer")
            ]
        ),
        .testTarget(
            name: "SocketIOConcurrencyIntegrationTests",
            dependencies: ["SocketIOConcurrency"],
            resources: [
                .copy("../IntegrationServer")
            ]
        ),
    ]
)
