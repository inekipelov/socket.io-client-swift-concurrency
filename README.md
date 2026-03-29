# SocketIOConcurrency

`SocketIOConcurrency` is a tiny Swift Package that adds async/await-friendly
APIs to `socket.io-client-swift` via a thin `SocketIOClient` extension.

The API keeps original Socket.IO naming (`on`, `emit`, `emitWithAck`) and adds
concurrency semantics through `AsyncThrowingStream`, `async`, and `async throws`.

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white" alt="Swift 6.1"></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/iOS-13.0+-000000?logo=apple" alt="iOS 13.0+"></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-10.15+-000000?logo=apple" alt="macOS 10.15+"></a>
  <a href="https://developer.apple.com/tvos/"><img src="https://img.shields.io/badge/tvOS-13.0+-000000?logo=apple" alt="tvOS 13.0+"></a>
  <a href="https://developer.apple.com/watchos/"><img src="https://img.shields.io/badge/watchOS-6.0+-000000?logo=apple" alt="watchOS 6.0+"></a>
  <a href="https://developer.apple.com/visionos/"><img src="https://img.shields.io/badge/visionOS-1.0+-000000?logo=apple" alt="visionOS 1.0+"></a>
</p>

## Usage

```swift
import SocketIOConcurrency

let manager = SocketManager(
    socketURL: URL(string: "http://127.0.0.1:39091")!,
    config: [.path("/socket.io/"), .forceWebsockets(true), .log(false)]
)
let socket = manager.defaultSocket

socket.connect()

let ack = try await socket.emitWithAck("ping", "hello", timeout: 3.0)
print(ack)

let stream = socket.on("pongEvent")
let task = Task {
    for try await payload in stream {
        print(payload)
    }
}

await socket.emit("echo", "value")

task.cancel()
socket.disconnect()
```

Public async extension surface:

- `on(_ event: String) -> AsyncThrowingStream<[any Sendable], Error>`
- `emit(_ event: String, _ items: SocketData...) async`
- `emit(_ event: String, with items: [SocketData]) async`
- `emitWithAck(_ event: String, _ items: SocketData..., timeout: TimeInterval) async throws -> [any Sendable]`
- `emitWithAck(_ event: String, with items: [SocketData], timeout: TimeInterval) async throws -> [any Sendable]`

All throwable paths are normalized to `SocketIOError`.

## Error Contract

`SocketIOError` is the single public error type for this package:

- `cancelled`
- `invalidTimeout(TimeInterval)`
- `notConnected(event: String)`
- `ackTimedOut(event: String, timeout: TimeInterval)`
- `disconnected(event: String, reason: String?)`
- `clientError(event: String?, message: String, source: SocketIOError.Source)`
- `invalidSocketData(event: String?, message: String)`
- `unsupportedPayloadType(typeName: String)`
- `unsupportedDictionaryKeyType(typeName: String)`

Mapping from original `socket.io-client-swift` signals:

| Original signal | `SocketIOError` |
| --- | --- |
| `.error` payload `[eventName, items, error]` | `invalidSocketData(...)` or `clientError(...)` |
| `.error` payload `["Tried emitting when not connected"]` | `notConnected(event:)` |
| ack payload `"NO ACK"` | `ackTimedOut(event:timeout:)` |
| `.disconnect` client event | `disconnected(event:reason:)` |

## Installation

Add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/inekipelov/socket.io-client-swift-concurrency.git", from: "0.1.0")
```

## Testing

```bash
swift test --no-parallel
```
