# SocketIOConcurrency

Async/await-first bridge for `socket.io-client-swift` with typed `Event` / `Listener` enums and Swift Testing coverage.

## Installation

Add the package dependency:

```swift
.package(url: "https://github.com/inekipelov/socket.io-client-swift-concurrency", branch: "main")
```

And link product `SocketIOConcurrency`.

## Quick Start

```swift
import Foundation
import SocketIOConcurrency

enum ChatEvent: String, Sendable {
    case ping
    case fetchRooms
}

enum ChatListener: String, Sendable {
    case pong
    case rooms
}

struct PingRequest: Codable, Sendable {
    let value: Int
}

struct PingResponse: Codable, Sendable {
    let message: String
    let value: Int
}

let configuration = SocketBridgeConfiguration(
    url: URL(string: "https://example.com")!,
    namespace: "/chat",
    path: "/socket.io/",
    headers: ["Authorization": "Bearer <token>"]
)

let bridge = SocketBridge<ChatEvent, ChatListener>(configuration: configuration)

try await bridge.connect()

let ack = try await bridge.emitWithAck(
    .ping,
    payload: PingRequest(value: 7),
    timeout: .seconds(3),
    response: PingResponse.self
)

let rooms = try await bridge.request(
    .fetchRooms,
    payload: Optional<PingRequest>.none,
    expect: .rooms,
    response: [String].self,
    timeout: .seconds(5)
)

await bridge.disconnect()
```

## API

- `SocketBridge<Event, Listener>`: actor with async-safe socket lifecycle.
- `connect() async throws`, `disconnect()`.
- `connectionStates() -> AsyncStream<ConnectionState>`.
- `listen(_:as:) -> AsyncThrowingStream<T, Error>`.
- `emit(_:payload:) async throws`.
- `emitWithAck(_:payload:timeout:response:) async throws`.
- `request(_:payload:expect:response:timeout:) async throws`.

## Migration from Combine-style bridge

- Replace `Publisher` listeners with `AsyncThrowingStream` from `listen`.
- Replace `sendPublisher` request/response with `request(... expect listener ...)`.
- Replace ack callback chains with `emitWithAck(... timeout ...)`.
- Keep your existing raw-value enum strategy: `enum Event: String`, `enum Listener: String`.

## Testing

Unit tests:

```bash
swift test --filter SocketIOConcurrencyTests
```

Integration tests (real local Socket.IO server):

```bash
npm install --prefix Tests/IntegrationServer
RUN_INTEGRATION_TESTS=1 swift test --filter SocketIOConcurrencyIntegrationTests --no-parallel
```
