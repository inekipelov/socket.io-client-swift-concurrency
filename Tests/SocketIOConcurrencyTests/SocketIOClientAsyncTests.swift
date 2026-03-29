import Dispatch
import Foundation
@preconcurrency import SocketIO
import Testing
import SocketIOConcurrency

@Suite("SocketIOClient async extension")
struct SocketIOClientAsyncTests {
    @Test("on receives event payload")
    func onReceivesEvent() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")

        let stream = socket.on("pong")
        var iterator = stream.makeAsyncIterator()

        socket.handleEvent("pong", data: ["ok", 1], isInternalMessage: true)

        let data = try #require(try await iterator.next())
        #expect(data.count == 2)
        #expect(data[0] as? String == "ok")
        #expect(data[1] as? Int == 1)
    }

    @Test("on unsubscribes handlers on cancellation")
    func onUnsubscribesOnCancel() async throws {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        let queue = manager.handleQueue

        let initialCount = await handlersCount(socket: socket, queue: queue)
        var stream: AsyncThrowingStream<[any Sendable], Error>? = socket.on("pong")
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
        #expect(ack.count == 2)
        #expect(ack[0] as? String == "pong")
        #expect(ack[1] as? Int == 7)
    }

    @Test("emitWithAck throws on NO ACK timeout")
    func emitWithAckTimeout() async {
        let manager = makeManager()
        let socket = SocketIOClient(manager: manager, nsp: "/")
        socket.didConnect(toNamespace: "/", payload: nil)

        await #expect(throws: Error.self) {
            _ = try await socket.emitWithAck("noAck", timeout: 0.05)
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
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
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
