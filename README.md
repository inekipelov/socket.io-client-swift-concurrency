# SocketIOConcurrency

`SocketIOConcurrency` is a tiny Swift Package that adds async/await-friendly
APIs to `socket.io-client-swift` via a thin `SocketIOClient` extension.

The API keeps original Socket.IO naming (`on`, `emit`, `emitWithAck`) and adds
concurrency semantics through `SocketIOClient.AsyncThrowingStream`, `async`, and typed throws.

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white" alt="Swift 6.1"></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/iOS-13.0+-000000?logo=apple" alt="iOS 13.0+"></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-10.15+-000000?logo=apple" alt="macOS 10.15+"></a>
  <a href="https://developer.apple.com/tvos/"><img src="https://img.shields.io/badge/tvOS-13.0+-000000?logo=apple" alt="tvOS 13.0+"></a>
  <a href="https://developer.apple.com/watchos/"><img src="https://img.shields.io/badge/watchOS-6.0+-000000?logo=apple" alt="watchOS 6.0+"></a>
  <a href="https://developer.apple.com/visionos/"><img src="https://img.shields.io/badge/visionOS-1.0+-000000?logo=apple" alt="visionOS 1.0+"></a>
</p>

## Usage

Minimal async flow without callback nesting:

```swift
import SocketIOConcurrency

let manager = SocketManager(
    socketURL: URL(string: "http://127.0.0.1:39091")!,
    config: [.path("/socket.io/"), .forceWebsockets(true), .log(false)]
)
let socket = manager.defaultSocket

try await socket.connect()
defer { Task { try? await socket.disconnect() } }

let incomingTask = Task {
    for try await payload in socket.on("message:new") {
        print("incoming:", payload)
    }
}

let ack = try await socket.emitWithAck("message:send", "hello", timeout: 3.0)
print("ack:", ack)

incomingTask.cancel()
```

Literal-friendly payloads can be sent directly:

```swift
let payload: SocketIOClient.Payload = [
    "message": "hi",
    "attempt": 1,
    "ok": true,
]

await socket.emit("message:send", payload)
let ack = try await socket.emitWithAck("message:confirm", payload)
```

Public async extension surface:

| Method | Description |
| --- | --- |
| `on(_ event: String) -> AsyncThrowingStream<Payload, Error>` | Subscribes to a regular socket event and gives you a typed async stream with automatic handler cleanup. |
| `on(clientEvent event: SocketClientEvent) -> AsyncThrowingStream<ClientEventPayload, Error>` | Subscribes to Socket.IO lifecycle/client events (`connect`, `disconnect`, `error`, etc.) with structured payload mapping. |
| `onStatusChange() -> AsyncThrowingStream<SocketIOStatus, Error>` | Convenience stream for `.statusChange` events that yields only `SocketIOStatus` values. |
| `connect(withPayload payload: [String: Any]? = nil, timeout: TimeInterval = 5) async throws(Error)` | Connects and suspends until the socket is actually connected; throws typed timeout/cancel/error cases. |
| `disconnect(timeout: TimeInterval = 5) async throws(Error)` | Disconnects and waits for confirmed disconnection (including status fallback), with typed timeout/cancel handling. |
| `emit(_ event: String, _ items: SocketData...) async` | Emits an event and awaits write completion using variadic payload arguments. |
| `emit(_ event: String, with items: [SocketData]) async` | Emits an event and awaits write completion using an explicit payload array. |
| `emitWithAck(_ event: String, _ items: SocketData..., timeout: TimeInterval = 5) async throws(Error) -> Payload` | Emits an event expecting server acknowledgement and returns the ack payload as typed `Payload`. |
| `emitWithAck(_ event: String, with items: [SocketData], timeout: TimeInterval = 5) async throws(Error) -> Payload` | Same ack flow as above, but for array-based payload construction. |

`SocketIOClient.Payload` cases:

- `.string(String)`
- `.int(Int)`
- `.double(Double)`
- `.bool(Bool)`
- `.null`
- `.data(Data)`
- `.array([SocketIOClient.Payload])`
- `.object([String: SocketIOClient.Payload])`

`SocketIOClient.ClientEventPayload` cases:

- `.connect`
- `.connectWithPayload(payload: SocketIOClient.Payload)`
- `.disconnect(reason: SocketIOClient.DisconnectReason)`
- `.error(SocketIOClient.Error)`
- `.ping`
- `.pong`
- `.reconnect(reason: SocketIOClient.DisconnectReason)`
- `.reconnectAttempt(remaining: Int?)`
- `.statusChange(SocketIOStatus)`
- `.websocketUpgrade(headers: [String: String])`

`SocketIOClient.DisconnectReason` includes known cases (`pingTimeout`,
`namespaceLeave`, `gotDisconnect`, `manualDisconnect`, `reconnectFailed`,
`socketDisconnected`, etc.), plus `.none` and lossless `.unknown(String)`.

All throwable paths are normalized to `SocketIOClient.Error`.

## Error Contract

`SocketIOClient.Error` is the single public error type for this package:

- `cancelled`
- `invalidTimeout(TimeInterval)`
- `notConnected(event: String)`
- `ackTimedOut(event: String, timeout: TimeInterval)`
- `connectTimedOut(timeout: TimeInterval)`
- `disconnectTimedOut(timeout: TimeInterval)`
- `disconnected(event: String, reason: SocketIOClient.DisconnectReason)`
- `clientError(event: String?, message: String, source: SocketIOClient.Error.Source)`
- `invalidSocketData(event: String?, message: String)`
- `unsupportedPayloadType(typeName: String)`
- `unsupportedDictionaryKeyType(typeName: String)`

Mapping from original `socket.io-client-swift` signals:

| Original signal | `SocketIOClient.Error` |
| --- | --- |
| `.error` payload `[eventName, items, error]` | `invalidSocketData(...)` or `clientError(...)` |
| `.error` payload `["Tried emitting when not connected"]` | `notConnected(event:)` |
| ack payload `"NO ACK"` | `ackTimedOut(event:timeout:)` |
| `.disconnect` client event | `disconnected(event:reason:)` with typed `DisconnectReason` |

## Installation

Add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/inekipelov/socket.io-client-swift-concurrency.git", from: "0.1.0")
```

## Testing

```bash
swift test --no-parallel
```
