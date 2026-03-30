import Foundation
@preconcurrency import SocketIO

public extension SocketIOClient {
    enum ClientEventPayload: Sendable, Equatable {
        case connect(namespace: String)
        case connectWithPayload(namespace: String, payload: SocketIOClient.Payload)
        case disconnect(reason: String?)
        case error(SocketIOClient.Error)
        case ping
        case pong
        case reconnect(reason: String?)
        case reconnectAttempt(remaining: Int?)
        case statusChange(SocketIOStatus)
        case websocketUpgrade(headers: [String: String])
    }
}

extension SocketIOClient.ClientEventPayload {
    init(clientEvent event: SocketClientEvent, data: [Any]) throws(SocketIOClient.Error) {
        switch event {
        case .connect:
            guard (1...2).contains(data.count), let namespace = data[0] as? String else {
                throw Self.invalidData(event: event, data: data, expected: "[namespace] or [namespace, payload]")
            }

            if data.count == 1 {
                self = .connect(namespace: namespace)
                return
            }

            self = .connectWithPayload(
                namespace: namespace,
                payload: try SocketIOClient.Payload(socketValue: data[1])
            )
        case .disconnect:
            self = .disconnect(reason: try Self.optionalString(from: data, event: event, expected: "[reason?]"))
        case .error:
            self = .error(SocketIOClient.Error(clientEventPayload: data, fallbackEvent: event.rawValue))
        case .ping:
            guard data.isEmpty else {
                throw Self.invalidData(event: event, data: data, expected: "[]")
            }

            self = .ping
        case .pong:
            guard data.isEmpty else {
                throw Self.invalidData(event: event, data: data, expected: "[]")
            }

            self = .pong
        case .reconnect:
            self = .reconnect(reason: try Self.optionalString(from: data, event: event, expected: "[reason?]"))
        case .reconnectAttempt:
            self = .reconnectAttempt(
                remaining: try Self.optionalInt(
                    from: data,
                    event: event,
                    expected: "[remainingAttempts?]"
                )
            )
        case .statusChange:
            guard (1...2).contains(data.count) else {
                throw Self.invalidData(event: event, data: data, expected: "[SocketIOStatus, rawValue?]")
            }

            let status: SocketIOStatus
            if let typedStatus = data[0] as? SocketIOStatus {
                status = typedStatus
            } else if let rawStatus = data[0] as? Int, let resolved = SocketIOStatus(rawValue: rawStatus) {
                status = resolved
            } else {
                throw Self.invalidData(event: event, data: data, expected: "[SocketIOStatus, rawValue?]")
            }

            if data.count == 2 {
                guard let raw = data[1] as? Int, raw == status.rawValue else {
                    throw Self.invalidData(event: event, data: data, expected: "[SocketIOStatus, rawValue]")
                }
            }

            self = .statusChange(status)
        case .websocketUpgrade:
            guard data.count == 1 else {
                throw Self.invalidData(event: event, data: data, expected: "[[String: String]]")
            }

            guard let headers = try Self.headers(from: data[0], event: event) else {
                throw Self.invalidData(event: event, data: data, expected: "[[String: String]]")
            }

            self = .websocketUpgrade(headers: headers)
        }
    }

    private static func optionalString(
        from data: [Any],
        event: SocketClientEvent,
        expected: String
    ) throws(SocketIOClient.Error) -> String? {
        guard data.count <= 1 else {
            throw invalidData(event: event, data: data, expected: expected)
        }

        guard let first = data.first else {
            return nil
        }

        guard let value = first as? String else {
            throw invalidData(event: event, data: data, expected: expected)
        }

        return value
    }

    private static func optionalInt(
        from data: [Any],
        event: SocketClientEvent,
        expected: String
    ) throws(SocketIOClient.Error) -> Int? {
        guard data.count <= 1 else {
            throw invalidData(event: event, data: data, expected: expected)
        }

        guard let first = data.first else {
            return nil
        }

        if let value = first as? Int {
            return value
        }

        if let number = first as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let int64 = number.int64Value
            if let int = Int(exactly: int64) {
                return int
            }
        }

        throw invalidData(event: event, data: data, expected: expected)
    }

    private static func headers(
        from value: Any,
        event: SocketClientEvent
    ) throws(SocketIOClient.Error) -> [String: String]? {
        if let headers = value as? [String: String] {
            return headers
        }

        if let headers = value as? [String: Any] {
            var typed: [String: String] = [:]
            typed.reserveCapacity(headers.count)

            for (key, headerValue) in headers {
                guard let stringValue = headerValue as? String else {
                    throw invalidData(event: event, data: [value], expected: "[[String: String]]")
                }

                typed[key] = stringValue
            }

            return typed
        }

        if let headers = value as? NSDictionary {
            var typed: [String: String] = [:]
            typed.reserveCapacity(headers.count)

            for (key, headerValue) in headers {
                guard let key = key as? String, let stringValue = headerValue as? String else {
                    throw invalidData(event: event, data: [value], expected: "[[String: String]]")
                }

                typed[key] = stringValue
            }

            return typed
        }

        return nil
    }

    private static func invalidData(
        event: SocketClientEvent,
        data: [Any],
        expected: String
    ) -> SocketIOClient.Error {
        .invalidSocketData(
            event: event.rawValue,
            message: "Invalid payload for client event '\(event.rawValue)'. Expected \(expected), got \(data)"
        )
    }
}
