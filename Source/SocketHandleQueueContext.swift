import Dispatch
@preconcurrency import SocketIO

enum SocketHandleQueueContext {
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private static let queueValue = ObjectIdentifier(SocketHandleQueueContext.self)

    static func queue(for manager: SocketManagerSpec?) -> DispatchQueue {
        let queue = manager?.handleQueue ?? DispatchQueue.main
        mark(queue)
        return queue
    }

    @discardableResult
    static func register(on queue: DispatchQueue, _ register: () -> Void) -> DispatchQueue {
        mark(queue)

        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            register()
        } else {
            queue.sync(execute: register)
        }

        return queue
    }

    private static func mark(_ queue: DispatchQueue) {
        queue.setSpecific(key: queueKey, value: queueValue)
    }
}
