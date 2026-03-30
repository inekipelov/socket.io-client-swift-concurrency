import Foundation

/// An async sequence with a strongly typed failure.
///
/// `AsyncThrowingStream` currently exposes continuations through initializers
/// constrained to `Failure == any Error`. This type bridges that gap by
/// wrapping an `AsyncStream<Result<Element, Failure>>` and surfacing
/// `next() async throws(Failure)`.
public extension SocketIOClient {
    struct AsyncThrowingStream<Element: Sendable, Failure: Swift.Error & Sendable>: AsyncSequence {
        /// The buffering policy used by the underlying stream.
        public typealias BufferingPolicy = AsyncStream<Result<Element, Failure>>.Continuation.BufferingPolicy
        /// The stream termination type.
        public typealias Termination = AsyncStream<Result<Element, Failure>>.Continuation.Termination

        private final class Storage: @unchecked Sendable {
            var continuation: AsyncStream<Result<Element, Failure>>.Continuation

            init(continuation: AsyncStream<Result<Element, Failure>>.Continuation) {
                self.continuation = continuation
            }
        }

        /// A continuation wrapper that emits values or a typed failure.
        public struct Continuation: Sendable {
            /// The result of yielding to the underlying stream.
            public typealias YieldResult = AsyncStream<Result<Element, Failure>>.Continuation.YieldResult

            private let storage: Storage

            fileprivate init(continuation: AsyncStream<Result<Element, Failure>>.Continuation) {
                storage = Storage(continuation: continuation)
            }

            /// Yields a value to the stream.
            @discardableResult
            public func yield(_ element: Element) -> YieldResult {
                storage.continuation.yield(.success(element))
            }

            /// Finishes the stream without an error.
            public func finish() {
                storage.continuation.finish()
            }

            /// Finishes the stream with a typed error.
            public func finish(throwing error: Failure) {
                storage.continuation.yield(.failure(error))
                storage.continuation.finish()
            }

            /// Registers a termination handler.
            public func onTermination(_ handler: @escaping @Sendable (Termination) -> Void) {
                storage.continuation.onTermination = handler
            }
        }

        /// The iterator for `SocketIOClient.AsyncThrowingStream`.
        public struct AsyncIterator: AsyncIteratorProtocol {
            private var base: AsyncStream<Result<Element, Failure>>.AsyncIterator

            fileprivate init(base: AsyncStream<Result<Element, Failure>>.AsyncIterator) {
                self.base = base
            }

            public mutating func next() async throws(Failure) -> Element? {
                guard let result = await base.next() else {
                    return nil
                }

                return try result.get()
            }
        }

        private let stream: AsyncStream<Result<Element, Failure>>

        /// Creates a typed async stream with the provided buffering policy.
        public init(
            _ elementType: Element.Type = Element.self,
            bufferingPolicy: BufferingPolicy = .unbounded,
            _ build: (Continuation) -> Void
        ) {
            stream = AsyncStream<Result<Element, Failure>>(bufferingPolicy: bufferingPolicy) { continuation in
                build(Continuation(continuation: continuation))
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator())
        }
    }
}
