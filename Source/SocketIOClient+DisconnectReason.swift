import Foundation
@preconcurrency import SocketIO

public extension SocketIOClient {
    /// Typed interpretation of raw disconnect reason strings emitted by `socket.io-client-swift`.
    ///
    /// This enum maps known upstream string literals to stable cases and preserves
    /// all unknown values via `.unknown(String)`.
    enum DisconnectReason: Sendable, Equatable {
        /// Upstream literal: `"Ping timeout"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Engine/SocketEngine.swift#L501
        case pingTimeout
        /// Upstream literal: `"Namespace leave"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L254
        case namespaceLeave
        /// Upstream literal: `"Got Disconnect"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Client/SocketIOClient.swift#L386
        case gotDisconnect
        /// Upstream literal: `"Disconnect"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L242
        case manualDisconnect
        /// Upstream literal: `"reconnect"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Engine/SocketEngine.swift#L244
        case reconnect
        /// Upstream literal: `"Reconnect Failed"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L504
        case reconnectFailed
        /// Upstream literal: `"Socket Disconnected"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Engine/SocketEngine.swift#L720
        case socketDisconnected
        /// Upstream literal: `"Manager Deinit"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L167
        case managerDeinit
        /// Upstream literal: `"Adding new engine"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L179
        case addingNewEngine
        /// Upstream literal: `"manual reconnect"`.
        /// Source: https://github.com/socketio/socket.io-client-swift/blob/42da871d9369f290d6ec4930636c40672143905b/Source/SocketIO/Manager/SocketManager.swift#L470
        case manualReconnect
        /// No reason provided (`nil` or empty string).
        case none
        /// Any reason string that doesn't match known upstream literals.
        case unknown(String)

        /// Maps a raw disconnect reason string from upstream callbacks into a typed case.
        init(rawReason: String?) {
            guard let rawReason else {
                self = .none
                return
            }

            let normalized = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                self = .none
                return
            }

            switch normalized.lowercased() {
            case "ping timeout":
                self = .pingTimeout
            case "namespace leave":
                self = .namespaceLeave
            case "got disconnect":
                self = .gotDisconnect
            case "disconnect":
                self = .manualDisconnect
            case "reconnect":
                self = .reconnect
            case "reconnect failed":
                self = .reconnectFailed
            case "socket disconnected":
                self = .socketDisconnected
            case "manager deinit":
                self = .managerDeinit
            case "adding new engine":
                self = .addingNewEngine
            case "manual reconnect":
                self = .manualReconnect
            default:
                self = .unknown(normalized)
            }
        }
    }
}
