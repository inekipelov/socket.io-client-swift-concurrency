import Foundation
import Testing
@testable import SocketIOConcurrency

@Suite("SocketIOClient.AsyncThrowingStream")
struct SocketIOClientAsyncThrowingStreamTests {
    @Test("yields values and finishes")
    func yieldsValuesAndFinishes() async throws {
        let stream = SocketIOClient.AsyncThrowingStream<Int, SocketIOClient.Error> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        }

        var values: [Int] = []
        for try await value in stream {
            values.append(value)
        }

        #expect(values == [1, 2])
    }

    @Test("finish(throwing:) propagates typed failure")
    func finishThrowingPropagatesTypedFailure() async {
        let expected = SocketIOClient.Error.ackTimedOut(event: "ack", timeout: 0.5)
        let stream = SocketIOClient.AsyncThrowingStream<Int, SocketIOClient.Error> { continuation in
            continuation.finish(throwing: expected)
        }

        var iterator = stream.makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("Expected typed stream failure")
        } catch let error {
            #expect(error == expected)
        }
    }

    @Test("onTermination is invoked")
    func onTerminationIsInvoked() async {
        let probe = TerminationProbe()
        let stream = SocketIOClient.AsyncThrowingStream<Int, SocketIOClient.Error> { continuation in
            continuation.onTermination { _ in
                Task { await probe.markTerminated() }
            }
            continuation.finish()
        }

        do {
            var iterator = stream.makeAsyncIterator()
            _ = try? await iterator.next()
        }

        for _ in 0..<50 {
            if await probe.wasTerminated() {
                break
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(await probe.wasTerminated())
    }

    @Test("contract uses typed throws")
    func contractUsesTypedThrows() {
        let emitWithAckSignature: (
            SocketIOClient,
            String,
            [SocketData],
            TimeInterval
        ) async throws(SocketIOClient.Error) -> SocketIOClient.Payload = { socket, event, items, timeout in
            try await socket.emitWithAck(event, with: items, timeout: timeout)
        }

        let payloadFromValues: ([Any]) throws(SocketIOClient.Error) -> SocketIOClient.Payload =
            SocketIOClient.Payload.init(socketValues:)
        let payloadFromValue: (Any) throws(SocketIOClient.Error) -> SocketIOClient.Payload =
            SocketIOClient.Payload.init(socketValue:)

        _ = emitWithAckSignature
        _ = payloadFromValues
        _ = payloadFromValue
    }
}

private actor TerminationProbe {
    private var terminated = false

    func markTerminated() {
        terminated = true
    }

    func wasTerminated() -> Bool {
        terminated
    }
}
