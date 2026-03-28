import Foundation

public enum SocketBridgeError: Error, Sendable {
    case notConnected
    case encodingFailed
    case decodingFailed
    case ackTimeout
    case transportError
    case cancelled
}
