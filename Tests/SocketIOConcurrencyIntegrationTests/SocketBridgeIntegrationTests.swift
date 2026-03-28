import Foundation
import Testing
@testable import SocketIOConcurrency

private enum IntegrationEvent: String, Sendable {
    case ping
    case fetch
}

private enum IntegrationListener: String, Sendable {
    case pongEvent
    case fetchResponse
}

private struct PingRequest: Codable, Sendable {
    let value: Int
}

private struct PongResponse: Codable, Sendable, Equatable {
    let message: String
    let value: Int
}

@Suite("SocketBridge integration tests")
struct SocketBridgeIntegrationTests {
    @Test("connect, ack, and listener request against real Socket.IO server")
    func socketRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] == "1" else {
            return
        }

        let serverDirectory = try #require(Bundle.module.resourceURL?.appending(path: "IntegrationServer"))
        let server = SocketIOServerProcess(
            workingDirectory: serverDirectory,
            port: 39091
        )

        try await server.start()
        defer { Task { await server.stop() } }

        let configuration = SocketBridgeConfiguration(
            url: URL(string: "http://127.0.0.1:39091")!,
            namespace: "/",
            path: "/socket.io/",
            reconnects: true,
            reconnectWait: 1,
            forceWebSockets: true,
            compress: true,
            log: false,
            connectTimeout: .seconds(8)
        )

        let bridge = SocketBridge<IntegrationEvent, IntegrationListener>(configuration: configuration)
        try await bridge.connect()
        defer { Task { await bridge.disconnect() } }

        let ackResponse = try await bridge.emitWithAck(
            .ping,
            payload: PingRequest(value: 7),
            timeout: .seconds(3),
            response: PongResponse.self
        )
        #expect(ackResponse == PongResponse(message: "pong", value: 7))

        let listenerResponse = try await bridge.request(
            .fetch,
            payload: PingRequest(value: 42),
            expect: .fetchResponse,
            response: PongResponse.self,
            timeout: .seconds(3)
        )
        #expect(listenerResponse == PongResponse(message: "pong", value: 42))
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

        let deadline = ContinuousClock.now + .seconds(10)
        while isReady == false {
            guard process.isRunning else {
                stop()
                throw SocketBridgeError.transportError
            }
            guard ContinuousClock.now < deadline else {
                stop()
                throw SocketBridgeError.transportError
            }
            try await Task.sleep(for: .milliseconds(50))
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
