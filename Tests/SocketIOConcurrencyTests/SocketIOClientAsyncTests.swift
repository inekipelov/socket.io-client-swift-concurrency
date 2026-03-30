import Dispatch
import Foundation
@preconcurrency import SocketIO
import Testing
@testable import SocketIOConcurrency

@Suite("SocketIOClient async extension")
struct SocketIOClientAsyncTests {
    @Test("on receives event payload")
    func onReceivesEvent() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")

        let stream = socket.on("pong")
        var iterator = stream.makeAsyncIterator()

        socket.handleEvent("pong", data: ["ok", 1], isInternalMessage: true)

        let payload = try #require(try await iterator.next())
        #expect(payload == .array([.string("ok"), .int(1)]))
    }

    @Test("on unsubscribes handlers on cancellation")
    func onUnsubscribesOnCancel() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let queue = manager.handleQueue

        let initialCount = await handlersCount(socket: socket, queue: queue)
        var stream: SocketIOClient.AsyncThrowingStream<SocketIOClient.Payload, SocketIOClient.Error>? = socket.on("pong")
        let registeredCount = await handlersCount(socket: socket, queue: queue)
        #expect(registeredCount == initialCount + 3)

        _ = stream
        stream = nil

        await drain(queue: queue)
        let finalCount = await handlersCount(socket: socket, queue: queue)
        #expect(finalCount == initialCount)
    }

    @Test("emit forwards event and items")
    func emitForwardsItems() async {
        let manager = makeManager()
        let socket = RecordingSocketIOClient(manager: manager, nsp: "/")

        await socket.emit("hello", with: ["one", 2])

        #expect(socket.lastEmittedEvent == "hello")
        #expect(socket.lastEmittedItems.count == 2)
        #expect(socket.lastEmittedItems[0] as? String == "one")
        #expect(socket.lastEmittedItems[1] as? Int == 2)
    }

    @Test("emitWithAck returns ack payload")
    func emitWithAckSuccess() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        socket.didConnect(toNamespace: "/", payload: nil)

        manager.handleQueue.asyncAfter(deadline: .now() + 0.05) {
            socket.handleAck(0, data: ["pong", 7])
        }

        let ack = try await socket.emitWithAck("ackEvent", "ping", timeout: 1.0)
        #expect(ack == .array([.string("pong"), .int(7)]))
    }

    @Test("emitWithAck throws on NO ACK timeout")
    func emitWithAckTimeout() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        socket.didConnect(toNamespace: "/", payload: nil)

        do {
            _ = try await socket.emitWithAck("noAck", timeout: 0.05)
            Issue.record("Expected ack timeout")
        } catch let error {
            guard case let .ackTimedOut(event, timeout) = error else {
                Issue.record("Expected .ackTimedOut, got \(error)")
                return
            }

            #expect(event == "noAck")
            #expect(timeout == 0.05)
        }
    }

    @Test("emitWithAck supports cancellation")
    func emitWithAckCancellation() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        socket.didConnect(toNamespace: "/", payload: nil)

        let task = Task<Void, Error> {
            _ = try await socket.emitWithAck("delayedAck", timeout: 2.0)
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected task cancellation")
        } catch let error as SocketIOClient.Error {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("emitWithAck throws invalid timeout error")
    func emitWithAckInvalidTimeout() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")

        do {
            _ = try await socket.emitWithAck("badTimeout", timeout: 0)
            Issue.record("Expected invalid timeout error")
        } catch let error {
            guard case let .invalidTimeout(timeout) = error else {
                Issue.record("Expected .invalidTimeout, got \(error)")
                return
            }

            #expect(timeout == 0)
        }
    }

    @Test("emitWithAck does not dispatch emit after early cancellation")
    func emitWithAckCancellationPreventsDispatch() async {
        let manager = makeManager()
        let queue = DispatchQueue(label: "SocketIOClientAsyncTests.emitWithAck.cancel")
        manager.handleQueue = queue
        queue.suspend()

        let probe = AckDispatchProbe()
        let socket = RecordingAckSocketIOClient(manager: manager, nsp: "/", probe: probe)
        socket.didConnect(toNamespace: "/", payload: nil)

        let task = Task<Void, Error> {
            _ = try await socket.emitWithAck("delayedAck", timeout: 2.0)
        }

        await Task.yield()
        task.cancel()
        _ = try? await task.value

        queue.resume()
        await drain(queue: queue)

        #expect(probe.value == 0)
    }

    @Test("on maps socket client error to typed SocketIOClient.Error")
    func onMapsClientErrorToTypedError() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on("typedErrorEvent")
        var iterator = stream.makeAsyncIterator()

        socket.handleClientEvent(.error, data: ["Tried emitting when not connected"])

        do {
            _ = try await iterator.next()
            Issue.record("Expected stream error")
        } catch let error {
            #expect(error == .notConnected(event: "typedErrorEvent"))
        }
    }

    @Test("on maps payload conversion failures to typed SocketIOClient.Error")
    func onMapsPayloadConversionFailureToTypedError() async {
        final class UnsupportedPayloadType {}

        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on("badPayload")
        var iterator = stream.makeAsyncIterator()

        socket.handleEvent("badPayload", data: [UnsupportedPayloadType()], isInternalMessage: true)

        do {
            _ = try await iterator.next()
            Issue.record("Expected stream error")
        } catch let error {
            guard case .unsupportedPayloadType = error else {
                Issue.record("Expected .unsupportedPayloadType, got \(error)")
                return
            }
        }
    }

    @Test("on maps primitives and nested structures to SocketIOClient.Payload")
    func onMapsPrimitivesAndNestedStructures() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on("richPayload")
        var iterator = stream.makeAsyncIterator()

        let binary = Data([0x01, 0x02])
        socket.handleEvent(
            "richPayload",
            data: [
                "text",
                42,
                3.5,
                true,
                NSNull(),
                binary,
                ["inner", 9],
                ["key": "value"],
            ],
            isInternalMessage: true
        )

        let payload = try #require(try await iterator.next())
        #expect(
            payload == .array([
                .string("text"),
                .int(42),
                .double(3.5),
                .bool(true),
                .null,
                .data(binary),
                .array([.string("inner"), .int(9)]),
                .object(["key": .string("value")]),
            ])
        )
    }

    @Test("on maps unsupported dictionary key type to typed SocketIOClient.Error")
    func onMapsUnsupportedDictionaryKeyTypeToTypedError() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on("badDictionary")
        var iterator = stream.makeAsyncIterator()

        let invalidDictionary = NSDictionary(dictionary: [NSNumber(value: 1): "value"])
        socket.handleEvent("badDictionary", data: [invalidDictionary], isInternalMessage: true)

        do {
            _ = try await iterator.next()
            Issue.record("Expected stream error")
        } catch let error {
            guard case .unsupportedDictionaryKeyType = error else {
                Issue.record("Expected .unsupportedDictionaryKeyType, got \(error)")
                return
            }
        }
    }

    @Test("normalizer infers engine source from message")
    func normalizerInfersEngineSource() {
        let error = SocketIOClient.Error(
            clientEventPayload: ["Engine URLSession became invalid"],
            fallbackEvent: "engineEvent"
        )

        guard case let .clientError(event, message, source) = error else {
            Issue.record("Expected .clientError, got \(error)")
            return
        }

        #expect(event == "engineEvent")
        #expect(message == "Engine URLSession became invalid")
        #expect(source == .engine)
    }

    @Test("on(clientEvent:) maps statusChange to SocketIOStatus")
    func onClientEventStatusChange() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on(clientEvent: .statusChange)
        var iterator = stream.makeAsyncIterator()

        socket.handleClientEvent(.statusChange, data: [SocketIOStatus.connected, SocketIOStatus.connected.rawValue])

        let payload = try #require(try await iterator.next())
        #expect(payload == .statusChange(.connected))
    }

    @Test("on(clientEvent:) maps error payload to normalized SocketIOClient.Error")
    func onClientEventError() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on(clientEvent: .error)
        var iterator = stream.makeAsyncIterator()

        socket.handleClientEvent(.error, data: ["Tried emitting when not connected"])

        let payload = try #require(try await iterator.next())
        #expect(payload == .error(.notConnected(event: SocketClientEvent.error.rawValue)))
    }

    @Test("on(clientEvent:) maps disconnect reason")
    func onClientEventDisconnect() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on(clientEvent: .disconnect)
        var iterator = stream.makeAsyncIterator()

        socket.handleClientEvent(.disconnect, data: ["Server closed"])

        let payload = try #require(try await iterator.next())
        #expect(payload == .disconnect(reason: "Server closed"))
    }

    @Test("on(clientEvent:) maps ping and pong")
    func onClientEventPingPong() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")

        let pingStream = socket.on(clientEvent: .ping)
        var pingIterator = pingStream.makeAsyncIterator()
        socket.handleClientEvent(.ping, data: [])
        #expect(try await pingIterator.next() == .ping)

        let pongStream = socket.on(clientEvent: .pong)
        var pongIterator = pongStream.makeAsyncIterator()
        socket.handleClientEvent(.pong, data: [])
        #expect(try await pongIterator.next() == .pong)
    }

    @Test("on(clientEvent:) invalid payload throws typed invalidSocketData")
    func onClientEventInvalidPayload() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let stream = socket.on(clientEvent: .statusChange)
        var iterator = stream.makeAsyncIterator()

        socket.handleClientEvent(.statusChange, data: ["invalid"])

        do {
            _ = try await iterator.next()
            Issue.record("Expected stream error")
        } catch let error {
            guard case .invalidSocketData(let event, _) = error else {
                Issue.record("Expected .invalidSocketData, got \(error)")
                return
            }

            #expect(event == SocketClientEvent.statusChange.rawValue)
        }
    }

    @Test("on(clientEvent:) unsubscribes one handler on cancellation")
    func onClientEventUnsubscribesOnCancel() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let queue = manager.handleQueue

        let initialCount = await handlersCount(socket: socket, queue: queue)
        var stream: SocketIOClient.AsyncThrowingStream<SocketIOClient.ClientEventPayload, SocketIOClient.Error>? =
            socket.on(clientEvent: .ping)
        let registeredCount = await handlersCount(socket: socket, queue: queue)
        #expect(registeredCount == initialCount + 1)

        _ = stream
        stream = nil

        await drain(queue: queue)
        let finalCount = await handlersCount(socket: socket, queue: queue)
        #expect(finalCount == initialCount)
    }

    private func makeManager() -> SocketManager {
        SocketManager(
            socketURL: URL(string: "http://127.0.0.1:39091")!,
            config: [.forceWebsockets(true), .log(false)]
        )
    }

    private func handlersCount(socket: SocketIOClient, queue: DispatchQueue) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: socket.handlers.count)
            }
        }
    }

    private func drain(queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }
}

private final class RecordingSocketIOClient: SocketIOClient {
    var lastEmittedEvent: String?
    var lastEmittedItems: [SocketData] = []

    override func emit(_ event: String, with items: [SocketData], completion: (() -> ())?) {
        lastEmittedEvent = event
        lastEmittedItems = items
        completion?()
    }
}

private final class RecordingAckSocketIOClient: SocketIOClient {
    private let probe: AckDispatchProbe

    init(manager: SocketManagerSpec, nsp: String, probe: AckDispatchProbe) {
        self.probe = probe
        super.init(manager: manager, nsp: nsp)
    }

    override func emitWithAck(_ event: String, with items: [SocketData]) -> OnAckCallback {
        probe.increment()
        return super.emitWithAck(event, with: items)
    }
}

private final class AckDispatchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
