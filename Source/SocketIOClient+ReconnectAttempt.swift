import Foundation
@preconcurrency import SocketIO

public extension SocketIOClient {
    /// Typed representation of `.reconnectAttempt` payload from `socket.io-client-swift`.
    ///
    /// Upstream emits `reconnectAttempts - currentReconnectAttempt` as a single `Int`:
    /// https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L512
    enum ReconnectAttempt: Sendable, Equatable {
        /// Finite reconnect strategy: attempts remaining before giving up.
        case remaining(Int)
        /// Unlimited reconnect strategy (`reconnectAttempts == -1` in upstream), surfaced as negative raw values.
        case unlimited(raw: Int)

        init(rawRemainingAttempts value: Int) {
            if value >= 0 {
                self = .remaining(value)
            } else {
                self = .unlimited(raw: value)
            }
        }
    }
}
