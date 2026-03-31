import Foundation
@preconcurrency import SocketIO

final class SocketSingleEventSubscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var handlerID: UUID?
    private var terminated = false

    func register(_ handlerID: UUID, on socket: SocketIOClient) {
        lock.lock()
        if terminated {
            lock.unlock()
            socket.off(id: handlerID)
            return
        }

        self.handlerID = handlerID
        lock.unlock()
    }

    func terminate(on socket: SocketIOClient) {
        lock.lock()
        terminated = true
        let handlerID = self.handlerID
        self.handlerID = nil
        lock.unlock()

        guard let handlerID else {
            return
        }

        socket.off(id: handlerID)
    }
}
