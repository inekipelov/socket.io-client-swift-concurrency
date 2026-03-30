import Foundation
@preconcurrency import SocketIO

/// Canonical Socket.IO payload representation used by this package.
///
/// `socket.io-client-swift` delivers event and ack payloads as `[Any]`.
/// This enum provides a typed, recursive representation that keeps
/// JSON-like structures and binary blobs.
public extension SocketIOClient {
    enum Payload: Sendable, Equatable {
        /// A string value.
        case string(String)
        /// An integer numeric value.
        case int(Int)
        /// A floating-point numeric value.
        case double(Double)
        /// A boolean value.
        case bool(Bool)
        /// A null value.
        case null
        /// Binary payload data.
        case data(Data)
        /// A recursive ordered payload collection.
        case array([SocketIOClient.Payload])
        /// A recursive keyed payload object.
        case object([String: SocketIOClient.Payload])
    }
}

extension SocketIOClient.Payload {
    init(socketValues values: [Any]) throws(SocketIOClient.Error) {
        var payloads: [SocketIOClient.Payload] = []
        payloads.reserveCapacity(values.count)

        for value in values {
            payloads.append(try SocketIOClient.Payload(socketValue: value))
        }

        self = .array(payloads)
    }

    init(socketValue value: Any) throws(SocketIOClient.Error) {
        switch value {
        case let value as SocketIOClient.Payload:
            self = value
        case let value as String:
            self = .string(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = Self.numberPayload(from: value)
        case let value as Data:
            self = .data(value)
        case is NSNull:
            self = .null
        case let value as [Any]:
            var payloads: [SocketIOClient.Payload] = []
            payloads.reserveCapacity(value.count)

            for item in value {
                payloads.append(try SocketIOClient.Payload(socketValue: item))
            }

            self = .array(payloads)
        case let value as [String: Any]:
            var object: [String: SocketIOClient.Payload] = [:]
            object.reserveCapacity(value.count)

            for (key, item) in value {
                object[key] = try SocketIOClient.Payload(socketValue: item)
            }

            self = .object(object)
        case let value as NSArray:
            var payloads: [SocketIOClient.Payload] = []
            payloads.reserveCapacity(value.count)

            for item in value {
                payloads.append(try SocketIOClient.Payload(socketValue: item))
            }

            self = .array(payloads)
        case let value as NSDictionary:
            var object: [String: SocketIOClient.Payload] = [:]
            object.reserveCapacity(value.count)

            for (key, item) in value {
                guard let key = key as? String else {
                    throw SocketIOClient.Error.unsupportedDictionaryKeyType(
                        typeName: String(describing: type(of: key))
                    )
                }

                object[key] = try SocketIOClient.Payload(socketValue: item)
            }

            self = .object(object)
        default:
            throw SocketIOClient.Error.unsupportedPayloadType(typeName: String(describing: type(of: value)))
        }
    }

    private static func numberPayload(from number: NSNumber) -> SocketIOClient.Payload {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }

        if CFNumberIsFloatType(number) {
            return .double(number.doubleValue)
        }

        let int64 = number.int64Value
        if let int = Int(exactly: int64), Double(int64) == number.doubleValue {
            return .int(int)
        }

        return .double(number.doubleValue)
    }
}
