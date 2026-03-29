import Dispatch
import Foundation
@preconcurrency import SocketIO
import Testing
import SocketIOConcurrency

@Suite("SocketIOConcurrency integration tests")
struct SocketIOConcurrencyIntegrationTests {
    @Test("emitWithAckAsync and onAsync against local Socket.IO server")
    func socketRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] == "1" else {
            return
        }

        let serverDirectory = try #require(Bundle.module.resourceURL?.appending(path: "IntegrationServer"))
        let server = SocketIOServerProcess(workingDirectory: serverDirectory, port: 39091)

        try await server.start()
        do {
            let manager = SocketManager(
                socketURL: URL(string: "http://127.0.0.1:39091")!,
                config: [
                    .path("/socket.io/"),
                    .forceWebsockets(true),
                    .reconnects(false),
                    .log(false),
                ]
            )

            let socket = manager.defaultSocket

            try await connect(socket)
            defer { socket.disconnect() }

            let stream = socket.onAsync("pongEvent")
            var iterator = stream.makeAsyncIterator()

            let ack = try await socket.emitWithAckAsync("ping", "hello", timeout: 3.0)
            #expect(ack.count == 2)
            #expect(ack[0] as? String == "pong")
            #expect(ack[1] as? Int == 42)

            let eventData = try #require(try await iterator.next())
            #expect(eventData.count == 1)
            #expect(eventData[0] as? String == "hello")

            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    private func connect(_ socket: SocketIOClient) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let state = ContinuationState()

            let connectID = socket.once(clientEvent: .connect) { _, _ in
                guard state.tryResume() else { return }
                continuation.resume()
            }

            let errorID = socket.once(clientEvent: .error) { data, _ in
                guard state.tryResume() else { return }

                let message = data.first.map(String.init(describing:)) ?? "connect error"
                continuation.resume(
                    throwing: NSError(
                        domain: "SocketIOConcurrencyIntegration",
                        code: 2001,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                )
            }

            socket.connect()

            let handleQueue = socket.manager?.handleQueue ?? DispatchQueue.main
            handleQueue.asyncAfter(deadline: .now() + 8.0) {
                guard state.tryResume() else { return }

                socket.off(id: connectID)
                socket.off(id: errorID)
                continuation.resume(
                    throwing: NSError(
                        domain: "SocketIOConcurrencyIntegration",
                        code: 2002,
                        userInfo: [NSLocalizedDescriptionKey: "Connection timeout"]
                    )
                )
            }
        }
    }
}

private final class ContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard resumed == false else {
            return false
        }

        resumed = true
        return true
    }
}

private actor SocketIOServerProcess {
    private let workingDirectory: URL
    private let port: Int
    private let process: Process
    private let outputPipe: Pipe
    private var isReady = false

    init(workingDirectory: URL, port: Int) {
        self.workingDirectory = workingDirectory
        self.port = port
        process = Process()
        outputPipe = Pipe()
    }

    func start() async throws {
        process.currentDirectoryURL = workingDirectory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "server.mjs"]

        var environment = ProcessInfo.processInfo.environment
        environment["SOCKET_IO_TEST_PORT"] = String(port)
        process.environment = environment

        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard data.isEmpty == false else { return }

            let output = String(decoding: data, as: UTF8.self)
            Task { await self.consume(output: output) }
        }

        try process.run()

        let timeoutAt = Date().addingTimeInterval(10)
        while isReady == false {
            guard process.isRunning else {
                stop()
                throw NSError(
                    domain: "SocketIOConcurrencyIntegration",
                    code: 2003,
                    userInfo: [NSLocalizedDescriptionKey: "Socket.IO test server stopped unexpectedly"]
                )
            }

            guard Date() < timeoutAt else {
                stop()
                throw NSError(
                    domain: "SocketIOConcurrencyIntegration",
                    code: 2004,
                    userInfo: [NSLocalizedDescriptionKey: "Socket.IO test server did not become ready in time"]
                )
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil

        guard process.isRunning else {
            return
        }

        process.terminate()
        process.waitUntilExit()
    }

    private func consume(output: String) {
        if output.contains("READY:") {
            isReady = true
        }
    }
}
