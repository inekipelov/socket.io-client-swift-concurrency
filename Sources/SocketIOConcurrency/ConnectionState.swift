import Foundation

public enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case disconnected
    case reconnecting
}
