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

    // Check dispatch eligibility under lock, then execute without lock.
    // This avoids deadlocks when the dispatched call can synchronously invoke
    // callbacks that consume the same continuation state.
    func withDispatchPermission(_ body: () -> Void) {
        lock.lock()
        let isAllowed = isCancelled == false && continuation != nil
        lock.unlock()

        guard isAllowed else {
            return
        }

        body()
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
