import Foundation
@preconcurrency import SocketIO

public extension SocketIOClient {
    /// Connects to the server and waits until the socket becomes connected.
    ///
    /// - Parameters:
    ///   - payload: Optional payload sent on connect.
    ///   - timeout: Timeout in seconds for waiting on `.connect`.
    /// - Throws: `SocketIOClient.Error`.
    @preconcurrency
    func connect(
        withPayload payload: [String: SocketData]? = nil,
        timeout: TimeInterval = 5
    ) async throws(SocketIOClient.Error) {
        guard status != .connected else {
            return
        }

        let payloadBox = SocketConnectPayloadBox(payload)
        let connectState = SocketSingleEventSubscriptionState()
        let disconnectState = SocketSingleEventSubscriptionState()
        let errorState = SocketSingleEventSubscriptionState()

        try await executeClientOperation(
            eventContext: SocketClientEvent.connect.rawValue,
            timeout: timeout,
            subscriptions: [
                .init(event: .connect, state: connectState) { _ in
                    .success(())
                },
                .init(event: .disconnect, state: disconnectState) { data in
                    .failure(
                        .disconnected(
                            event: SocketClientEvent.connect.rawValue,
                            reason: SocketIOClient.DisconnectReason(rawReason: data.first as? String)
                        )
                    )
                },
                .init(event: .error, state: errorState) { data in
                    .failure(
                        SocketIOClient.Error(
                            clientEventPayload: data,
                            fallbackEvent: SocketClientEvent.connect.rawValue
                        )
                    )
                },
            ]
        ) { finish in
            do {
                let normalizedPayload = try SocketIOPayloadCodec.normalize(socketDataByKey: payloadBox.payload)
                self.connect(withPayload: normalizedPayload, timeoutAfter: timeout) {
                    finish(.failure(.connectTimedOut(timeout: timeout)))
                }
            } catch {
                finish(
                    .failure(
                        SocketIOClient.Error(
                            thrown: error,
                            event: SocketClientEvent.connect.rawValue
                        )
                    )
                )
            }
        }
    }

    /// Disconnects from the server and waits until the socket becomes disconnected.
    ///
    /// - Parameter timeout: Timeout in seconds for waiting on `.disconnect`.
    /// - Throws: `SocketIOClient.Error`.
    @preconcurrency
    func disconnect(timeout: TimeInterval = 5) async throws(SocketIOClient.Error) {
        guard status != .disconnected else {
            return
        }

        let disconnectState = SocketSingleEventSubscriptionState()
        let statusChangeState = SocketSingleEventSubscriptionState()
        let errorState = SocketSingleEventSubscriptionState()

        try await executeClientOperation(
            eventContext: SocketClientEvent.disconnect.rawValue,
            timeout: timeout,
            subscriptions: [
                .init(event: .disconnect, state: disconnectState) { _ in
                    .success(())
                },
                .init(event: .statusChange, state: statusChangeState) { data in
                    Self.isDisconnectedStatusChange(data) ? .success(()) : nil
                },
                .init(event: .error, state: errorState) { data in
                    .failure(
                        SocketIOClient.Error(
                            clientEventPayload: data,
                            fallbackEvent: SocketClientEvent.disconnect.rawValue
                        )
                    )
                },
            ]
        ) { finish in
            self.disconnect()
            let queue = self.manager?.handleQueue ?? DispatchQueue.main
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(.disconnectTimedOut(timeout: timeout)))
            }
        }
    }

    /// Subscribes to a Socket.IO event and exposes payloads as an async stream.
    ///
    /// Event payloads are mapped into `SocketIOClient.Payload`.
    /// If an event has exactly one argument, the stream yields that argument directly.
    /// Otherwise, the stream yields `.array([...])`.
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
            let payloadState = SocketSingleEventSubscriptionState()
            let disconnectState = SocketSingleEventSubscriptionState()
            let errorState = SocketSingleEventSubscriptionState()

            let queue = self.registerOnHandleQueue {
                self.registerEventHandler(event, into: payloadState) { data in
                    do {
                        _ = continuation.yield(try SocketIOClient.Payload(socketValues: data))
                    } catch {
                        continuation.finish(throwing: SocketIOClient.Error(thrown: error, event: event))
                    }
                }

                self.registerClientEventHandler(.disconnect, into: disconnectState) { data in
                    continuation.finish(
                        throwing: SocketIOClient.Error.disconnected(
                            event: event,
                            reason: SocketIOClient.DisconnectReason(rawReason: data.first as? String)
                        )
                    )
                }

                self.registerClientEventHandler(.error, into: errorState) { data in
                    continuation.finish(
                        throwing: SocketIOClient.Error(clientEventPayload: data, fallbackEvent: event)
                    )
                }
            }

            continuation.onTermination { _ in
                queue.async {
                    payloadState.terminate(on: self)
                    disconnectState.terminate(on: self)
                    errorState.terminate(on: self)
                }
            }
        }
    }

    /// Subscribes to a Socket.IO client event and exposes a type-driven payload stream.
    ///
    /// This mirrors the original callback-based `on(clientEvent:)` behavior:
    /// it listens only to the selected client event and doesn't auto-finish
    /// on `.disconnect` or `.error` unless those are the selected events.
    ///
    /// - Parameter event: Client event to subscribe to.
    /// - Returns: A typed event stream of `SocketIOClient.ClientEventPayload` values.
    @preconcurrency
    func on(
        clientEvent event: SocketClientEvent
    ) -> SocketIOClient.AsyncThrowingStream<SocketIOClient.ClientEventPayload, SocketIOClient.Error> {
        streamForClientEvent(
            event,
            bufferingPolicy: .unbounded,
            transform: { data throws(SocketIOClient.Error) -> SocketIOClient.ClientEventPayload in
                try SocketIOClient.ClientEventPayload(clientEvent: event, data: data)
            }
        )
    }

    /// Subscribes to `.statusChange` client events and yields only `SocketIOStatus`.
    ///
    /// This is a convenience wrapper over `on(clientEvent: .statusChange)` with
    /// strongly typed status values in the success path.
    ///
    /// - Returns: A typed event stream of `SocketIOStatus` values.
    @preconcurrency
    func onStatusChange() -> SocketIOClient.AsyncThrowingStream<SocketIOStatus, SocketIOClient.Error> {
        streamForClientEvent(
            .statusChange,
            bufferingPolicy: .unbounded,
            transform: { data throws(SocketIOClient.Error) -> SocketIOStatus in
                let payload = try SocketIOClient.ClientEventPayload(clientEvent: .statusChange, data: data)
                guard case let .statusChange(status) = payload else {
                    throw SocketIOClient.Error.invalidSocketData(
                        event: SocketClientEvent.statusChange.rawValue,
                        message: "Invalid statusChange payload: \(data)"
                    )
                }

                return status
            }
        )
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
        timeout: TimeInterval = 5
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
        timeout: TimeInterval = 5
    ) async throws(SocketIOClient.Error) -> SocketIOClient.Payload {
        guard timeout > 0 else {
            throw SocketIOClient.Error.invalidTimeout(timeout)
        }

        do {
            try Task.checkCancellation()
        } catch {
            throw SocketIOClient.Error(thrown: error, event: event)
        }

        guard status == .connected else {
            throw SocketIOClient.Error.notConnected(event: event)
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

private final class SocketConnectPayloadBox: @unchecked Sendable {
    let payload: [String: SocketData]?

    init(_ payload: [String: SocketData]?) {
        self.payload = payload
    }
}

private struct SocketClientOperationSubscription {
    let event: SocketClientEvent
    let state: SocketSingleEventSubscriptionState
    let resolve: @Sendable ([Any]) -> Result<Void, SocketIOClient.Error>?
}

private extension SocketIOClient {
    func streamForClientEvent<T: Sendable>(
        _ event: SocketClientEvent,
        bufferingPolicy: SocketIOClient.AsyncThrowingStream<T, SocketIOClient.Error>.BufferingPolicy,
        transform: @escaping @Sendable ([Any]) throws(SocketIOClient.Error) -> T
    ) -> SocketIOClient.AsyncThrowingStream<T, SocketIOClient.Error> {
        SocketIOClient.AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let state = SocketSingleEventSubscriptionState()

            let queue = self.registerOnHandleQueue {
                self.registerClientEventHandler(event, into: state) { data in
                    do {
                        _ = continuation.yield(try transform(data))
                    } catch {
                        continuation.finish(
                            throwing: SocketIOClient.Error(thrown: error, event: event.rawValue)
                        )
                    }
                }
            }

            continuation.onTermination { _ in
                queue.async {
                    state.terminate(on: self)
                }
            }
        }
    }

    @preconcurrency
    func executeClientOperation(
        eventContext: String,
        timeout: TimeInterval,
        subscriptions: [SocketClientOperationSubscription],
        start: @escaping @Sendable (_ finish: @escaping @Sendable (Result<Void, SocketIOClient.Error>) -> Void) -> Void
    ) async throws(SocketIOClient.Error) {
        guard timeout > 0 else {
            throw SocketIOClient.Error.invalidTimeout(timeout)
        }

        do {
            try Task.checkCancellation()
        } catch {
            throw SocketIOClient.Error(thrown: error, event: eventContext)
        }

        let continuationState = SocketAckContinuationState<Void>()
        let states = subscriptions.map(\.state)
        let queue = manager?.handleQueue ?? DispatchQueue.main
        let result: Result<Void, SocketIOClient.Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard continuationState.register(continuation) else {
                    return
                }

                queue.async {
                    continuationState.withDispatchPermission {
                        for subscription in subscriptions {
                            self.registerClientEventHandler(subscription.event, into: subscription.state) { data in
                                guard let result = subscription.resolve(data) else {
                                    return
                                }

                                self.finishOnce(
                                    using: continuationState,
                                    states: states,
                                    result: result
                                )
                            }
                        }

                        start { result in
                            self.finishOnce(
                                using: continuationState,
                                states: states,
                                result: result
                            )
                        }
                    }
                }
            }
        } onCancel: {
            continuationState.cancel()
            queue.async {
                self.terminate(states: states)
            }
        }

        _ = try result.get()
    }

    func finishOnce(
        using continuationState: SocketAckContinuationState<Void>,
        states: [SocketSingleEventSubscriptionState],
        result: Result<Void, SocketIOClient.Error>
    ) {
        guard let continuation = continuationState.consume() else {
            return
        }

        terminate(states: states)
        continuation.resume(returning: result)
    }

    func terminate(states: [SocketSingleEventSubscriptionState]) {
        for state in states {
            state.terminate(on: self)
        }
    }

    @preconcurrency
    func registerOnHandleQueue(_ register: () -> Void) -> DispatchQueue {
        let queue = manager?.handleQueue ?? DispatchQueue.main
        let queueKey = DispatchSpecificKey<UInt8>()
        let queueValue: UInt8 = 1
        queue.setSpecific(key: queueKey, value: queueValue)

        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            register()
        } else {
            queue.sync(execute: register)
        }

        return queue
    }

    @preconcurrency
    func registerEventHandler(
        _ event: String,
        into state: SocketSingleEventSubscriptionState,
        callback: @escaping ([Any]) -> Void
    ) {
        let handlerID = on(event) { data, _ in
            callback(data)
        }

        state.register(handlerID, on: self)
    }

    @preconcurrency
    func registerClientEventHandler(
        _ event: SocketClientEvent,
        into state: SocketSingleEventSubscriptionState,
        callback: @escaping ([Any]) -> Void
    ) {
        let handlerID = on(clientEvent: event) { data, _ in
            callback(data)
        }

        state.register(handlerID, on: self)
    }

    static func isDisconnectedStatusChange(_ data: [Any]) -> Bool {
        guard let first = data.first else {
            return false
        }

        if let status = first as? SocketIOStatus {
            return status == .disconnected
        }

        if let raw = first as? Int {
            return SocketIOStatus(rawValue: raw) == .disconnected
        }

        if
            let number = first as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        {
            return SocketIOStatus(rawValue: number.intValue) == .disconnected
        }

        return false
    }
}
