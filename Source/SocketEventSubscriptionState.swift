import Foundation
@preconcurrency import SocketIO

final class SocketEventSubscriptionState: @unchecked Sendable {
    struct Tokens {
        let event: UUID
        let disconnect: UUID
        let error: UUID
    }

    private let lock = NSLock()
    private var tokens: Tokens?
    private var terminated = false

    func register(_ tokens: Tokens, on socket: SocketIOClient) {
        lock.lock()
        if terminated {
            lock.unlock()
            socket.off(id: tokens.event)
            socket.off(id: tokens.disconnect)
            socket.off(id: tokens.error)
            return
        }

        self.tokens = tokens
        lock.unlock()
    }

    func terminate(on socket: SocketIOClient) {
        lock.lock()
        terminated = true
        let tokens = self.tokens
        self.tokens = nil
        lock.unlock()

        guard let tokens else {
            return
        }

        socket.off(id: tokens.event)
        socket.off(id: tokens.disconnect)
        socket.off(id: tokens.error)
    }
}
