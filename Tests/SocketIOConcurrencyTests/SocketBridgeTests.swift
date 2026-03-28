import Foundation
import Testing
@testable import SocketIOConcurrency

private enum TestEvent: String, Sendable {
    case ping
    case echo
    case fetch
}

private enum TestListener: String, Sendable {
    case pong
    case echoResponse
    case fetchResponse
}

private struct EchoPayload: Codable, Sendable, Equatable {
    let message: String
}

private struct PongPayload: Codable, Sendable, Equatable {
    let message: String
    let value: Int
}

@Suite("SocketBridge unit tests")
struct SocketBridgeTests {
    @Test("emit encodes payload and listen decodes payload")
    func emitAndListen() async throws {
        let transport = MockSocketBridgeTransport()
        let bridge = makeBridge(transport: transport)
        try await bridge.connect()

        let stream = await bridge.listen(.echoResponse, as: EchoPayload.self)

        try await bridge.emit(.echo, payload: EchoPayload(message: "hello"))
        let emitted = try #require(transport.lastEmit)
        #expect(emitted.event == TestEvent.echo.rawValue)

        let payload = try #require(emitted.items.first as? [String: String])
        #expect(payload["message"] == "hello")

        transport.emitEvent(TestListener.echoResponse.rawValue, payload: [["message": "world"]])

        var iterator = stream.makeAsyncIterator()
        let value = try #require(try await iterator.next())
        #expect(value == EchoPayload(message: "world"))
    }

    @Test("connection state stream publishes connecting connected disconnected")
    func connectionStates() async {
        let transport = MockSocketBridgeTransport()
        let bridge = makeBridge(transport: transport)

        let statesStream = await bridge.connectionStates()
        let collector = Task { () -> [ConnectionState] in
            var iterator = statesStream.makeAsyncIterator()
            var collected: [ConnectionState] = []
            while collected.count < 4, let state = await iterator.next() {
                collected.append(state)
            }
            return collected
        }

        transport.emitStatus(.connecting)
        transport.emitStatus(.connected)
        transport.emitStatus(.disconnected)

        let collected = await collector.value
        #expect(collected == [.disconnected, .connecting, .connected, .disconnected])
    }

    @Test("emitWithAck success decodes ack payload")
    func emitWithAckSuccess() async throws {
        let transport = MockSocketBridgeTransport()
        transport.setAckBehavior(.respond([["message": "pong", "value": 7]]))

        let bridge = makeBridge(transport: transport)
        try await bridge.connect()

        let response = try await bridge.emitWithAck(
            .ping,
            payload: EchoPayload(message: "ping"),
            timeout: .seconds(1),
            response: PongPayload.self
        )

        #expect(response == PongPayload(message: "pong", value: 7))
    }

    @Test("emitWithAck throws timeout when ack not received")
    func emitWithAckTimeout() async throws {
        let transport = MockSocketBridgeTransport()
        transport.setAckBehavior(.pending)

        let bridge = makeBridge(transport: transport)
        try await bridge.connect()

        await #expect(throws: SocketBridgeError.self) {
            _ = try await bridge.emitWithAck(
                .ping,
                payload: EchoPayload(message: "ping"),
                timeout: .milliseconds(120),
                response: PongPayload.self
            )
        }
    }

    @Test("emitWithAck cancellation propagates as cancelled")
    func emitWithAckCancellation() async throws {
        let transport = MockSocketBridgeTransport()
        transport.setAckBehavior(.pending)

        let bridge = makeBridge(transport: transport)
        try await bridge.connect()

        let task = Task {
            try await bridge.emitWithAck(
                .ping,
                payload: EchoPayload(message: "ping"),
                timeout: .seconds(10),
                response: PongPayload.self
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation error")
        } catch let error as SocketBridgeError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("request registers listener before emit and handles immediate response")
    func requestListenerFirst() async throws {
        let transport = MockSocketBridgeTransport()
        transport.setOnEmit { event, _ in
            if event == TestEvent.fetch.rawValue {
                transport.emitEvent(TestListener.fetchResponse.rawValue, payload: [["message": "pong", "value": 101]])
            }
        }

        let bridge = makeBridge(transport: transport)
        try await bridge.connect()

        let response = try await bridge.request(
            .fetch,
            payload: EchoPayload(message: "request"),
            expect: .fetchResponse,
            response: PongPayload.self,
            timeout: .seconds(1)
        )

        #expect(response == PongPayload(message: "pong", value: 101))
    }

    @Test("listener cleanup removes socket handler on cancellation")
    func listenerCleanupOnCancel() async throws {
        let transport = MockSocketBridgeTransport()
        let bridge = makeBridge(transport: transport)
        try await bridge.connect()

        let stream = await bridge.listen(.echoResponse, as: EchoPayload.self)
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        }

        consumer.cancel()
        _ = try? await consumer.value

        await Task.yield()
        await Task.yield()

        #expect(transport.offCallCount == 1)
    }

    private func makeBridge(transport: MockSocketBridgeTransport) -> SocketBridge<TestEvent, TestListener> {
        let configuration = SocketBridgeConfiguration(url: URL(string: "http://localhost:3000")!)
        return SocketBridge(configuration: configuration, transport: transport)
    }
}

private final class MockSocketBridgeTransport: SocketBridgeTransport, @unchecked Sendable {
    enum AckBehavior {
        case respond([Any])
        case timeoutStatus
        case pending
    }

    private let lock = NSLock()
    private var ackBehavior: AckBehavior = .pending
    private var onEmit: ((String, [Any]) -> Void)?
    private var eventCallbacks: [String: [UUID: ([Any]) -> Void]] = [:]
    private var statusCallbacks: [UUID: (SocketTransportStatus) -> Void] = [:]

    private(set) var lastEmit: (event: String, items: [Any])?
    private(set) var offCallCount = 0

    func setAckBehavior(_ behavior: AckBehavior) {
        lock.withLock {
            ackBehavior = behavior
        }
    }

    func setOnEmit(_ callback: ((String, [Any]) -> Void)?) {
        lock.withLock {
            onEmit = callback
        }
    }

    func connect() {
        emitStatus(.connecting)
        emitStatus(.connected)
    }

    func disconnect() {
        emitStatus(.disconnected)
    }

    func on(event: String, callback: @escaping ([Any]) -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            var callbacks = eventCallbacks[event] ?? [:]
            callbacks[id] = callback
            eventCallbacks[event] = callbacks
        }
        return id
    }

    func onStatusChange(callback: @escaping (SocketTransportStatus) -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            statusCallbacks[id] = callback
        }
        return id
    }

    func off(id: UUID) {
        lock.withLock {
            offCallCount += 1
            for key in eventCallbacks.keys {
                eventCallbacks[key]?.removeValue(forKey: id)
            }
            statusCallbacks.removeValue(forKey: id)
        }
    }

    func emit(event: String, items: [Any]) {
        let onEmit: ((String, [Any]) -> Void)? = lock.withLock {
            lastEmit = (event, items)
            return self.onEmit
        }
        onEmit?(event, items)
    }

    func emitWithAck(event: String, items: [Any], timeout: TimeInterval, callback: @escaping ([Any]) -> Void) {
        let (ackBehavior, onEmit): (AckBehavior, ((String, [Any]) -> Void)?) = lock.withLock {
            lastEmit = (event, items)
            return (self.ackBehavior, self.onEmit)
        }

        switch ackBehavior {
        case .respond(let payload):
            callback(payload)
        case .timeoutStatus:
            callback(["NO ACK"])
        case .pending:
            break
        }

        onEmit?(event, items)
    }

    func emitEvent(_ event: String, payload: [Any]) {
        let callbacks: [([Any]) -> Void] = lock.withLock {
            Array(eventCallbacks[event, default: [:]].values)
        }

        for callback in callbacks {
            callback(payload)
        }
    }

    func emitStatus(_ status: SocketTransportStatus) {
        let callbacks: [(SocketTransportStatus) -> Void] = lock.withLock {
            Array(statusCallbacks.values)
        }

        for callback in callbacks {
            callback(status)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
