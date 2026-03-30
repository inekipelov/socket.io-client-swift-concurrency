import Foundation

final class SocketAckContinuationState<Value>: @unchecked Sendable {
    typealias AckResult = Result<Value, SocketIOClient.Error>
    typealias AckContinuation = CheckedContinuation<AckResult, Never>

    private let lock = NSLock()
    private var continuation: AckContinuation?
    private var isCancelled = false

    @discardableResult
    func register(_ continuation: AckContinuation) -> Bool {
        lock.lock()
        guard isCancelled == false else {
            lock.unlock()
            continuation.resume(returning: .failure(SocketIOClient.Error.cancelled))
            return false
        }

        self.continuation = continuation
        lock.unlock()
        return true
    }

    // Intentionally execute while holding the lock to serialize against `cancel()`
    // and preserve "no dispatch after early cancellation" semantics.
    func withDispatchPermission(_ body: () -> Void) {
        lock.lock()
        guard isCancelled == false, continuation != nil else {
            lock.unlock()
            return
        }

        body()
        lock.unlock()
    }

    func consume() -> AckContinuation? {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: .failure(SocketIOClient.Error.cancelled))
    }
}
