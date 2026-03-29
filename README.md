# SocketIOConcurrency

Thin async/await extension layer for `socket.io-client-swift`.

## Installation

```swift
.package(url: "https://github.com/inekipelov/socket.io-client-swift-concurrency", branch: "main")
```

Link product `SocketIOConcurrency` and create your `SocketManager`/`SocketIOClient` as usual.

## API

`SocketIOClient` extension methods:

- `onAsync(_ event: String) -> AsyncThrowingStream<[Any], Error>`
- `emitAsync(_ event: String, _ items: SocketData...) async`
- `emitAsync(_ event: String, with items: [SocketData]) async`
- `emitWithAckAsync(_ event: String, _ items: SocketData..., timeout: TimeInterval) async throws -> [Any]`
- `emitWithAckAsync(_ event: String, with items: [SocketData], timeout: TimeInterval) async throws -> [Any]`

## Quick Start

```swift
import SocketIO
import SocketIOConcurrency

let manager = SocketManager(
    socketURL: URL(string: "http://127.0.0.1:39091")!,
    config: [.path("/socket.io/"), .forceWebsockets(true), .log(false)]
)
let socket = manager.defaultSocket

socket.connect()

let ack = try await socket.emitWithAckAsync("ping", "hello", timeout: 3.0)
print(ack) // ["pong", 42]

let stream = socket.onAsync("pongEvent")
let task = Task {
    for try await eventItems in stream {
        print(eventItems)
    }
}

await socket.emitAsync("echo", "value")
task.cancel()
socket.disconnect()
```

## Testing

```bash
swift test --no-parallel
```

Integration tests with local Socket.IO server:

```bash
npm install --prefix Tests/IntegrationServer
RUN_INTEGRATION_TESTS=1 swift test --filter SocketIOConcurrencyIntegrationTests --no-parallel
```
