import Foundation
@preconcurrency import SocketIO

public actor SocketBridge<Event, Listener>
where Event: RawRepresentable & Sendable,
      Listener: RawRepresentable & Sendable,
      Event.RawValue == String,
      Listener.RawValue == String {

    private let configuration: SocketBridgeConfiguration
    private let transport: SocketBridgeTransport

    private var connectionState: ConnectionState = .disconnected
    private var hasConnectedAtLeastOnce = false
    private var isConnected = false

    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var listenerRecords: [UUID: ListenerRecord] = [:]

    private struct ListenerRecord {
        let socketID: UUID
        let finish: (SocketBridgeError?) -> Void
    }

    public init(configuration: SocketBridgeConfiguration) {
        self.configuration = configuration
        self.transport = SocketIOTransport(configuration: configuration)

        _ = self.transport.onStatusChange { [weak self] status in
            guard let self else { return }
            Task {
                await self.handleTransportStatus(status)
            }
        }
    }

    internal init(configuration: SocketBridgeConfiguration, transport: SocketBridgeTransport) {
        self.configuration = configuration
        self.transport = transport

        _ = self.transport.onStatusChange { [weak self] status in
            guard let self else { return }
            Task {
                await self.handleTransportStatus(status)
            }
        }
    }

    public func connect() async throws {
        if isConnected {
            return
        }

        let states = connectionStates()
        transport.connect()

        do {
            _ = try await waitForState(in: states, timeout: configuration.connectTimeout) { $0 == .connected }
        } catch let error as SocketBridgeError {
            throw error
        } catch {
            throw SocketBridgeError.transportError
        }
    }

    public func disconnect() {
        transport.disconnect()
        isConnected = false
        transitionConnectionState(to: .disconnected)
        finishAllListeners(with: .cancelled)
    }

    public func connectionStates() -> AsyncStream<ConnectionState> {
        let streamID = UUID()

        return AsyncStream { continuation in
            stateContinuations[streamID] = continuation
            continuation.yield(connectionState)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.removeConnectionContinuation(streamID)
                }
            }
        }
    }

    public func listen<T: Decodable & Sendable>(_ listener: Listener, as type: T.Type = T.self) -> AsyncThrowingStream<T, Error> {
        let streamID = UUID()
        let decoderFactory = configuration.makeDecoder

        return AsyncThrowingStream { continuation in
            let socketID = transport.on(event: listener.rawValue) { payload in
                do {
                    let decoded: T = try Self.decodePayload(payload, as: type, makeDecoder: decoderFactory)
                    continuation.yield(decoded)
                } catch let error as SocketBridgeError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: SocketBridgeError.decodingFailed)
                }
            }

            listenerRecords[streamID] = ListenerRecord(
                socketID: socketID,
                finish: { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            )

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.removeListener(streamID)
                }
            }
        }
    }

    public func emit<T: Encodable & Sendable>(_ event: Event, payload: T?) async throws {
        guard isConnected else {
            throw SocketBridgeError.notConnected
        }

        do {
            let items = try Self.encodePayload(payload, makeEncoder: configuration.makeEncoder)
            transport.emit(event: event.rawValue, items: items)
        } catch let error as SocketBridgeError {
            throw error
        } catch {
            throw SocketBridgeError.encodingFailed
        }
    }

    public func emitWithAck<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        _ event: Event,
        payload: Req?,
        timeout: Duration,
        response: Res.Type
    ) async throws -> Res {
        guard isConnected else {
            throw SocketBridgeError.notConnected
        }

        let items: [Any]

        do {
            items = try Self.encodePayload(payload, makeEncoder: configuration.makeEncoder)
        } catch {
            throw SocketBridgeError.encodingFailed
        }

        let decoderFactory = configuration.makeDecoder
        let stream = AsyncThrowingStream<Res, Error> { continuation in
            transport.emitWithAck(
                event: event.rawValue,
                items: items,
                timeout: timeout.timeInterval
            ) { payload in
                if Self.isAckTimeoutPayload(payload) {
                    continuation.finish(throwing: SocketBridgeError.ackTimeout)
                    return
                }

                do {
                    let decoded: Res = try Self.decodePayload(payload, as: response, makeDecoder: decoderFactory)
                    continuation.yield(decoded)
                    continuation.finish()
                } catch let error as SocketBridgeError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: SocketBridgeError.decodingFailed)
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    continuation.finish(throwing: SocketBridgeError.cancelled)
                }
            }
        }

        return try await firstValue(from: stream, timeout: timeout, timeoutError: .ackTimeout)
    }

    public func request<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        _ event: Event,
        payload: Req?,
        expect listener: Listener,
        response: Res.Type,
        timeout: Duration
    ) async throws -> Res {
        guard isConnected else {
            throw SocketBridgeError.notConnected
        }

        let stream = listen(listener, as: response)
        try await emit(event, payload: payload)

        return try await firstValue(from: stream, timeout: timeout, timeoutError: .ackTimeout)
    }

    private func removeConnectionContinuation(_ streamID: UUID) {
        stateContinuations.removeValue(forKey: streamID)
    }

    private func removeListener(_ streamID: UUID) {
        guard let record = listenerRecords.removeValue(forKey: streamID) else {
            return
        }

        transport.off(id: record.socketID)
    }

    private func finishAllListeners(with error: SocketBridgeError?) {
        let activeListeners = listenerRecords.values
        listenerRecords.removeAll()

        for record in activeListeners {
            transport.off(id: record.socketID)
            record.finish(error)
        }
    }

    private func handleTransportStatus(_ status: SocketTransportStatus) {
        let nextState: ConnectionState

        switch status {
        case .connected:
            nextState = .connected
            hasConnectedAtLeastOnce = true
            isConnected = true
        case .connecting:
            nextState = hasConnectedAtLeastOnce ? .reconnecting : .connecting
        case .disconnected, .notConnected:
            nextState = .disconnected
            isConnected = false
        }

        transitionConnectionState(to: nextState)

        if nextState == .disconnected {
            finishAllListeners(with: .transportError)
        }
    }

    private func transitionConnectionState(to nextState: ConnectionState) {
        connectionState = nextState

        for continuation in stateContinuations.values {
            continuation.yield(nextState)
        }
    }

    private func waitForState(
        in stream: AsyncStream<ConnectionState>,
        timeout: Duration,
        predicate: @escaping @Sendable (ConnectionState) -> Bool
    ) async throws -> ConnectionState {
        do {
            return try await withThrowingTaskGroup(of: ConnectionState.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    while let state = await iterator.next() {
                        if predicate(state) {
                            return state
                        }
                    }

                    throw SocketBridgeError.transportError
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SocketBridgeError.transportError
                }

                defer {
                    group.cancelAll()
                }

                guard let state = try await group.next() else {
                    throw SocketBridgeError.cancelled
                }

                return state
            }
        } catch is CancellationError {
            throw SocketBridgeError.cancelled
        }
    }

    private func firstValue<T: Sendable>(
        from stream: AsyncThrowingStream<T, Error>,
        timeout: Duration,
        timeoutError: SocketBridgeError
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()

                    guard let value = try await iterator.next() else {
                        throw SocketBridgeError.transportError
                    }

                    return value
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw timeoutError
                }

                defer {
                    group.cancelAll()
                }

                guard let value = try await group.next() else {
                    throw SocketBridgeError.cancelled
                }

                return value
            }
        } catch is CancellationError {
            throw SocketBridgeError.cancelled
        } catch let error as SocketBridgeError {
            throw error
        } catch {
            throw SocketBridgeError.transportError
        }
    }

    private nonisolated static func encodePayload<T: Encodable>(
        _ payload: T?,
        makeEncoder: @Sendable () -> JSONEncoder
    ) throws -> [Any] {
        guard let payload else {
            return []
        }

        let jsonData = try makeEncoder().encode(payload)
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData)
        return [jsonObject]
    }

    private nonisolated static func decodePayload<T: Decodable>(
        _ payload: [Any],
        as type: T.Type,
        makeDecoder: @Sendable () -> JSONDecoder
    ) throws -> T {
        let object: Any = payload.count == 1 ? payload[0] : payload

        if JSONSerialization.isValidJSONObject(object) {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try makeDecoder().decode(T.self, from: data)
        }

        if JSONSerialization.isValidJSONObject(payload) {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try makeDecoder().decode(T.self, from: data)
        }

        throw SocketBridgeError.decodingFailed
    }

    private nonisolated static func isAckTimeoutPayload(_ payload: [Any]) -> Bool {
        guard let first = payload.first as? String else {
            return false
        }

        return first == SocketAckStatus.noAck.rawValue
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
