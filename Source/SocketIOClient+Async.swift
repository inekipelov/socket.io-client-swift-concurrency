import Foundation
@preconcurrency import SocketIO

public extension SocketIOClient {
    /// Subscribes to a Socket.IO event and exposes payloads as an async stream.
    ///
    /// The stream yields raw event payload arrays exactly as provided by `socket.io-client-swift`.
    /// Handlers are removed automatically when the stream terminates.
    ///
    /// The stream finishes with `SocketIOClient.Error` when the socket emits `.disconnect` or `.error`.
    ///
    /// - Parameter event: Event name to subscribe to.
    /// - Parameter bufferingPolicy: Buffering policy for the produced async stream.
    /// - Returns: A typed event stream of `SocketIOClient.Payload` values.
    @preconcurrency
    func on(
        _ event: String,
        bufferingPolicy: SocketIOClient.AsyncThrowingStream<SocketIOClient.Payload, SocketIOClient.Error>.BufferingPolicy = .bufferingNewest(100)
    ) -> SocketIOClient.AsyncThrowingStream<SocketIOClient.Payload, SocketIOClient.Error> {
        SocketIOClient.AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let queue = self.manager?.handleQueue ?? DispatchQueue.main
            let state = SocketEventSubscriptionState()
            let queueKey = DispatchSpecificKey<UInt8>()
            let queueValue: UInt8 = 1
            queue.setSpecific(key: queueKey, value: queueValue)

            let registerHandlers = {
                let eventID = self.on(event) { data, _ in
                    do {
                        _ = continuation.yield(try SocketIOClient.Payload(socketValues: data))
                    } catch {
                        continuation.finish(throwing: SocketIOClient.Error(thrown: error, event: event))
                    }
                }

                let disconnectID = self.on(clientEvent: .disconnect) { data, _ in
                    continuation.finish(
                        throwing: SocketIOClient.Error.disconnected(
                            event: event,
                            reason: data.first as? String
                        )
                    )
                }

                let errorID = self.on(clientEvent: .error) { data, _ in
                    continuation.finish(
                        throwing: SocketIOClient.Error(clientEventPayload: data, fallbackEvent: event)
                    )
                }

                state.register(
                    .init(event: eventID, disconnect: disconnectID, error: errorID),
                    on: self
                )
            }

            if DispatchQueue.getSpecific(key: queueKey) == queueValue {
                registerHandlers()
            } else {
                queue.sync(execute: registerHandlers)
            }

            continuation.onTermination { _ in
                queue.async {
                    state.terminate(on: self)
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
    /// - Returns: Ack payload represented as `SocketIOClient.Payload`.
    /// - Throws: `SocketIOClient.Error`.
    @preconcurrency
    func emitWithAck(
        _ event: String,
        _ items: SocketData...,
        timeout: TimeInterval
    ) async throws(SocketIOClient.Error) -> SocketIOClient.Payload {
        try await emitWithAck(event, with: items, timeout: timeout)
    }

    /// Emits an event expecting an acknowledgement and awaits the ack payload.
    ///
    /// - Parameters:
    ///   - event: Event name to emit.
    ///   - items: Payload items conforming to `SocketData`.
    ///   - timeout: Timeout in seconds passed to `timingOut(after:)`.
    /// - Returns: Ack payload represented as `SocketIOClient.Payload`.
    /// - Throws: `SocketIOClient.Error`.
    @preconcurrency
    func emitWithAck(
        _ event: String,
        with items: [SocketData],
        timeout: TimeInterval
    ) async throws(SocketIOClient.Error) -> SocketIOClient.Payload {
        guard timeout > 0 else {
            throw SocketIOClient.Error.invalidTimeout(timeout)
        }

        do {
            try Task.checkCancellation()
        } catch {
            throw SocketIOClient.Error(thrown: error, event: event)
        }

        let continuationState = SocketAckContinuationState<SocketIOClient.Payload>()
        let queue = self.manager?.handleQueue ?? DispatchQueue.main

        let result: Result<SocketIOClient.Payload, SocketIOClient.Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                do {
                    _ = try items.map { try $0.socketRepresentation() }
                } catch {
                    continuation.resume(returning: .failure(SocketIOClient.Error(thrown: error, event: event)))
                    return
                }

                guard continuationState.register(continuation) else {
                    return
                }

                queue.async {
                    continuationState.withDispatchPermission {
                        self.emitWithAck(event, with: items).timingOut(after: timeout) { data in
                            let continuation = continuationState.consume()

                            guard let continuation else {
                                return
                            }

                            if let ackError = SocketIOClient.Error(ackData: data, event: event, timeout: timeout) {
                                continuation.resume(returning: .failure(ackError))
                                return
                            }

                            do {
                                continuation.resume(returning: .success(try SocketIOClient.Payload(socketValues: data)))
                            } catch {
                                continuation.resume(
                                    returning: .failure(SocketIOClient.Error(thrown: error, event: event))
                                )
                            }
                        }
                    }
                }
            }
        } onCancel: {
            continuationState.cancel()
        }

        return try result.get()
    }
}
