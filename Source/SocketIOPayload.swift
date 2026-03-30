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

extension SocketIOClient.Payload: SocketData {
    public func socketRepresentation() throws -> SocketData {
        SocketIOPayloadConverter.encode(payload: self)
    }
}

extension SocketIOClient.Payload: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

extension SocketIOClient.Payload: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: IntegerLiteralType) {
        self = .int(value)
    }
}

extension SocketIOClient.Payload: ExpressibleByFloatLiteral {
    public init(floatLiteral value: FloatLiteralType) {
        self = .double(value)
    }
}

extension SocketIOClient.Payload: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: BooleanLiteralType) {
        self = .bool(value)
    }
}

extension SocketIOClient.Payload: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension SocketIOClient.Payload: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: SocketIOClient.Payload...) {
        self = .array(elements)
    }
}

extension SocketIOClient.Payload: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, SocketIOClient.Payload)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension SocketIOClient.Payload {
    init(socketValues values: [Any]) throws(SocketIOClient.Error) {
        self = try SocketIOPayloadConverter.decode(socketValues: values)
    }

    init(socketValue value: Any) throws(SocketIOClient.Error) {
        self = try SocketIOPayloadConverter.decode(socketValue: value)
    }
}

private enum SocketIOPayloadConverter {
    static func decode(socketValues values: [Any]) throws(SocketIOClient.Error) -> SocketIOClient.Payload {
        if values.count == 1, let value = values.first {
            return try decode(socketValue: value)
        }

        var payloads: [SocketIOClient.Payload] = []
        payloads.reserveCapacity(values.count)

        for value in values {
            payloads.append(try decode(socketValue: value))
        }

        return .array(payloads)
    }

    static func decode(socketValue value: Any) throws(SocketIOClient.Error) -> SocketIOClient.Payload {
        switch value {
        case let value as SocketIOClient.Payload:
            return value
        case let value as String:
            return .string(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return decode(number: value)
        case let value as Data:
            return .data(value)
        case is NSNull:
            return .null
        case let value as [Any]:
            return try decode(socketValues: value)
        case let value as [String: Any]:
            var object: [String: SocketIOClient.Payload] = [:]
            object.reserveCapacity(value.count)

            for (key, item) in value {
                object[key] = try decode(socketValue: item)
            }

            return .object(object)
        case let value as NSArray:
            var payloads: [SocketIOClient.Payload] = []
            payloads.reserveCapacity(value.count)

            for item in value {
                payloads.append(try decode(socketValue: item))
            }

            return .array(payloads)
        case let value as NSDictionary:
            var object: [String: SocketIOClient.Payload] = [:]
            object.reserveCapacity(value.count)

            for (key, item) in value {
                guard let key = key as? String else {
                    throw SocketIOClient.Error.unsupportedDictionaryKeyType(
                        typeName: String(describing: type(of: key))
                    )
                }

                object[key] = try decode(socketValue: item)
            }

            return .object(object)
        default:
            throw SocketIOClient.Error.unsupportedPayloadType(typeName: String(describing: type(of: value)))
        }
    }

    static func encode(payload: SocketIOClient.Payload) -> SocketData {
        switch payload {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        case let .data(value):
            return value
        case let .array(values):
            var mapped: [Any] = []
            mapped.reserveCapacity(values.count)
            for value in values {
                mapped.append(encodeAny(payload: value))
            }

            return mapped
        case let .object(values):
            var mapped: [String: Any] = [:]
            mapped.reserveCapacity(values.count)
            for (key, value) in values {
                mapped[key] = encodeAny(payload: value)
            }

            return mapped
        }
    }

    private static func decode(number: NSNumber) -> SocketIOClient.Payload {
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

    private static func encodeAny(payload: SocketIOClient.Payload) -> Any {
        switch payload {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        case let .data(value):
            return value
        case let .array(values):
            var mapped: [Any] = []
            mapped.reserveCapacity(values.count)
            for value in values {
                mapped.append(encodeAny(payload: value))
            }

            return mapped
        case let .object(values):
            var mapped: [String: Any] = [:]
            mapped.reserveCapacity(values.count)
            for (key, value) in values {
                mapped[key] = encodeAny(payload: value)
            }

            return mapped
        }
    }
}
