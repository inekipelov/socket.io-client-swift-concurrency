import Dispatch
import Foundation
import Testing
@testable import SocketIOConcurrency

@Suite("Socket handle queue context")
struct SocketHandleQueueContextTests {
    @Test("executes inline when already running on the handle queue")
    func executesInlineWhenAlreadyRunningOnQueue() async {
        let queue = DispatchQueue(label: "SocketHandleQueueContextTests.inline")

        let didExecuteInline = await withCheckedContinuation { continuation in
            queue.async {
                var didExecuteInline = false

                let returnedQueue = SocketHandleQueueContext.register(on: queue) {
                    didExecuteInline = true
                }

                continuation.resume(returning: didExecuteInline && returnedQueue === queue)
            }
        }

        #expect(didExecuteInline)
    }

    @Test("synchronously dispatches work onto the handle queue from outside")
    func synchronouslyDispatchesWorkOntoQueueFromOutside() {
        let queue = DispatchQueue(label: "SocketHandleQueueContextTests.sync")
        let probe = QueueExecutionProbe()

        let returnedQueue = SocketHandleQueueContext.register(on: queue) {
            probe.markExecuted()
        }

        #expect(returnedQueue === queue)
        #expect(probe.didExecute)
    }
}

private final class QueueExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var executed = false

    var didExecute: Bool {
        lock.lock()
        defer { lock.unlock() }
        return executed
    }

    func markExecuted() {
        lock.lock()
        executed = true
        lock.unlock()
    }
}
