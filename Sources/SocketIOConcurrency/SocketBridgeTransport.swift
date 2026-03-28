import Foundation
@preconcurrency import SocketIO

internal enum SocketTransportStatus: Sendable {
    case connected
    case connecting
    case disconnected
    case notConnected
}

internal protocol SocketBridgeTransport: AnyObject {
    func connect()
    func disconnect()
    @discardableResult
    func on(event: String, callback: @escaping ([Any]) -> Void) -> UUID
    @discardableResult
    func onStatusChange(callback: @escaping (SocketTransportStatus) -> Void) -> UUID
    func off(id: UUID)
    func emit(event: String, items: [Any])
    func emitWithAck(event: String, items: [Any], timeout: TimeInterval, callback: @escaping ([Any]) -> Void)
}

internal final class SocketIOTransport: SocketBridgeTransport {
    private let manager: SocketManager
    private let socket: SocketIOClient

    internal init(configuration: SocketBridgeConfiguration) {
        var options: SocketIOClientConfiguration = [
            .log(configuration.log),
            .path(configuration.path),
            .reconnects(configuration.reconnects),
            .reconnectWait(configuration.reconnectWait),
            .forceWebsockets(configuration.forceWebSockets),
            .handleQueue(DispatchQueue(label: "SocketIOConcurrency.SocketQueue"))
        ]

        if configuration.compress {
            options.insert(.compress)
        }

        if configuration.headers.isEmpty == false {
            options.insert(.extraHeaders(configuration.headers))
        }

        manager = SocketManager(socketURL: configuration.url, config: options)
        socket = manager.socket(forNamespace: configuration.namespace)
    }

    func connect() {
        socket.connect()
    }

    func disconnect() {
        socket.disconnect()
    }

    @discardableResult
    func on(event: String, callback: @escaping ([Any]) -> Void) -> UUID {
        socket.on(event) { data, _ in
            callback(data)
        }
    }

    @discardableResult
    func onStatusChange(callback: @escaping (SocketTransportStatus) -> Void) -> UUID {
        socket.on(clientEvent: .statusChange) { data, _ in
            guard let status = data.first as? SocketIOStatus else { return }
            switch status {
            case .connected:
                callback(.connected)
            case .connecting:
                callback(.connecting)
            case .disconnected:
                callback(.disconnected)
            case .notConnected:
                callback(.notConnected)
            @unknown default:
                callback(.disconnected)
            }
        }
    }

    func off(id: UUID) {
        socket.off(id: id)
    }

    func emit(event: String, items: [Any]) {
        let socketItems = items.compactMap { $0 as? SocketData }
        socket.emit(event, with: socketItems, completion: nil)
    }

    func emitWithAck(event: String, items: [Any], timeout: TimeInterval, callback: @escaping ([Any]) -> Void) {
        let socketItems = items.compactMap { $0 as? SocketData }
        socket.emitWithAck(event, with: socketItems).timingOut(after: timeout, callback: callback)
    }
}
