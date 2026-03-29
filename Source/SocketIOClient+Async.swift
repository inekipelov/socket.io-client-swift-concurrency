import Foundation
@preconcurrency import SocketIO

public extension SocketIOClient {
    /// Subscribes to a Socket.IO event and exposes payloads as an async stream.
    ///
    /// The stream yields raw event payload arrays exactly as provided by `socket.io-client-swift`.
    /// Handlers are removed automatically when the stream terminates.
    ///
    /// The stream finishes with `SocketIOError` when the socket emits `.disconnect` or `.error`.
    ///
    /// - Parameter event: Event name to subscribe to.
    /// - Parameter bufferingPolicy: Buffering policy for the produced async stream.
    /// - Returns: An `AsyncThrowingStream` of raw payload items converted to `Sendable`.
    @preconcurrency
    func on(
        _ event: String,
        bufferingPolicy: AsyncThrowingStream<[any Sendable], Error>.Continuation.BufferingPolicy = .bufferingNewest(100)
    ) -> AsyncThrowingStream<[any Sendable], Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let queue = self.manager?.handleQueue ?? DispatchQueue.main
            let state = HandlerIDsBox()
            let queueKey = DispatchSpecificKey<UInt8>()
            let queueValue: UInt8 = 1
            queue.setSpecific(key: queueKey, value: queueValue)

            let registerHandlers = {
                let eventID = self.on(event) { data, _ in
                    do {
                        continuation.yield(try makeSendablePayload(from: data))
                    } catch {
                        continuation.finish(throwing: SocketIOError(thrown: error, event: event))
                    }
                }

                let disconnectID = self.on(clientEvent: .disconnect) { data, _ in
                    continuation.finish(
                        throwing: SocketIOError.disconnected(
                            event: event,
                            reason: data.first as? String
                        )
                    )
                }

                let errorID = self.on(clientEvent: .error) { data, _ in
                    continuation.finish(
                        throwing: SocketIOError(clientEventPayload: data, fallbackEvent: event)
                    )
                }

                state.store(eventID: eventID, disconnectID: disconnectID, errorID: errorID, socket: self)
            }

            if DispatchQueue.getSpecific(key: queueKey) == queueValue {
                registerHandlers()
            } else {
                queue.sync(execute: registerHandlers)
            }

            continuation.onTermination = { _ in
                queue.async {
                    state.terminate(socket: self)
                }
            }
        }
    }

    /// Emits an event with variadic payload items and awaits write completion.
    ///
    /// - Parameters:
    ///   - event: Event name to emit.
    ///   - items: Payload items conforming to `SocketData`.
    @preconcurrency
    func emit(_ event: String, _ items: SocketData...) async {
        await emit(event, with: items)
    }

    /// Emits an event with payload items and awaits write completion.
    ///
    /// - Parameters:
    ///   - event: Event name to emit.
    ///   - items: Payload items conforming to `SocketData`.
    @preconcurrency
    func emit(_ event: String, with items: [SocketData]) async {
        await withCheckedContinuation { continuation in
            let queue = self.manager?.handleQueue ?? DispatchQueue.main
            queue.async {
                self.emit(event, with: items, completion: {
                    continuation.resume()
                })
            }
        }
    }

    /// Emits an event expecting an acknowledgement and awaits the ack payload.
    ///
    /// - Parameters:
    ///   - event: Event name to emit.
    ///   - items: Payload items conforming to `SocketData`.
    ///   - timeout: Timeout in seconds passed to `timingOut(after:)`.
    /// - Returns: Raw ack payload items converted to `Sendable`.
    /// - Throws: `SocketIOError`.
    @preconcurrency
    func emitWithAck(_ event: String, _ items: SocketData..., timeout: TimeInterval) async throws -> [any Sendable] {
        try await emitWithAck(event, with: items, timeout: timeout)
    }

    /// Emits an event expecting an acknowledgement and awaits the ack payload.
    ///
    /// - Parameters:
    ///   - event: Event name to emit.
    ///   - items: Payload items conforming to `SocketData`.
    ///   - timeout: Timeout in seconds passed to `timingOut(after:)`.
    /// - Returns: Raw ack payload items converted to `Sendable`.
    /// - Throws: `SocketIOError`.
    @preconcurrency
    func emitWithAck(_ event: String, with items: [SocketData], timeout: TimeInterval) async throws -> [any Sendable] {
        guard timeout > 0 else {
            throw SocketIOError.invalidTimeout(timeout)
        }

        do {
            try Task.checkCancellation()
        } catch {
            throw SocketIOError(thrown: error, event: event)
        }
        let continuationBox = ContinuationBox<[any Sendable]>()
        let queue = self.manager?.handleQueue ?? DispatchQueue.main

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    _ = try items.map { try $0.socketRepresentation() }
                } catch {
                    continuation.resume(throwing: SocketIOError(thrown: error, event: event))
                    return
                }

                guard continuationBox.store(continuation) else {
                    return
                }

                queue.async {
                    continuationBox.beginDispatch {
                        self.emitWithAck(event, with: items).timingOut(after: timeout) { data in
                            let continuation = continuationBox.take()

                            guard let continuation else {
                                return
                            }

                            if let ackError = SocketIOError(ackData: data, event: event, timeout: timeout) {
                                continuation.resume(throwing: ackError)
                                return
                            }

                            do {
                                continuation.resume(returning: try makeSendablePayload(from: data))
                            } catch {
                                continuation.resume(throwing: SocketIOError(thrown: error, event: event))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            continuationBox.cancel()
        }
    }
}

private final class HandlerIDsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var eventID: UUID?
    private var disconnectID: UUID?
    private var errorID: UUID?
    private var terminated = false

    func store(eventID: UUID, disconnectID: UUID, errorID: UUID, socket: SocketIOClient) {
        lock.lock()
        if terminated {
            lock.unlock()
            socket.off(id: eventID)
            socket.off(id: disconnectID)
            socket.off(id: errorID)
            return
        }

        self.eventID = eventID
        self.disconnectID = disconnectID
        self.errorID = errorID
        lock.unlock()
    }

    func terminate(socket: SocketIOClient) {
        lock.lock()
        terminated = true
        let ids = [eventID, disconnectID, errorID]
        eventID = nil
        disconnectID = nil
        errorID = nil
        lock.unlock()

        for case let id? in ids {
            socket.off(id: id)
        }
    }
}

private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var isCancelled = false

    @discardableResult
    func store(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        guard isCancelled == false else {
            lock.unlock()
            continuation.resume(throwing: SocketIOError.cancelled)
            return false
        }

        self.continuation = continuation
        lock.unlock()
        return true
    }

    func beginDispatch(_ body: () -> Void) {
        lock.lock()
        guard isCancelled == false, continuation != nil else {
            lock.unlock()
            return
        }

        body()
        lock.unlock()
    }

    func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        return value
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(throwing: SocketIOError.cancelled)
    }
}

private func makeSendablePayload(from payload: [Any]) throws -> [any Sendable] {
    try payload.map(makeSendableValue)
}

private func makeSendableValue(_ value: Any) throws -> any Sendable {
    switch value {
    case let value as String:
        return value
    case let value as Int:
        return value
    case let value as Double:
        return value
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value
    case let value as Data:
        return value
    case let value as Date:
        return value
    case let value as URL:
        return value
    case is NSNull:
        return NSNull()
    case let value as [Any]:
        return try value.map(makeSendableValue)
    case let value as [String: Any]:
        return try value.mapValues(makeSendableValue)
    case let value as NSArray:
        return try value.map(makeSendableValue)
    case let value as NSDictionary:
        let pairs = try value.map { key, value -> (String, any Sendable) in
            guard let key = key as? String else {
                throw SocketIOError.unsupportedDictionaryKeyType(typeName: String(describing: type(of: key)))
            }

            return (key, try makeSendableValue(value))
        }

        return Dictionary(uniqueKeysWithValues: pairs)
    default:
        throw SocketIOError.unsupportedPayloadType(typeName: String(describing: type(of: value)))
    }
}
