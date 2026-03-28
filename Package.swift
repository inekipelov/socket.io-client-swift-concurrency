// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SocketIOConcurrency",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
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
            ]
        ),
        .testTarget(
            name: "SocketIOConcurrencyTests",
            dependencies: ["SocketIOConcurrency"]
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
