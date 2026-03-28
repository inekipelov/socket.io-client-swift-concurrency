import Foundation

public struct SocketBridgeConfiguration: Sendable {
    public var url: URL
    public var namespace: String
    public var path: String
    public var headers: [String: String]
    public var reconnects: Bool
    public var reconnectWait: Int
    public var forceWebSockets: Bool
    public var compress: Bool
    public var log: Bool
    public var connectTimeout: Duration
    public var makeEncoder: @Sendable () -> JSONEncoder
    public var makeDecoder: @Sendable () -> JSONDecoder

    public init(
        url: URL,
        namespace: String = "/",
        path: String = "/socket.io/",
        headers: [String: String] = [:],
        reconnects: Bool = true,
        reconnectWait: Int = 5,
        forceWebSockets: Bool = true,
        compress: Bool = true,
        log: Bool = false,
        connectTimeout: Duration = .seconds(10),
        makeEncoder: @escaping @Sendable () -> JSONEncoder = { JSONEncoder() },
        makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }
    ) {
        self.url = url
        self.namespace = namespace
        self.path = path
        self.headers = headers
        self.reconnects = reconnects
        self.reconnectWait = reconnectWait
        self.forceWebSockets = forceWebSockets
        self.compress = compress
        self.log = log
        self.connectTimeout = connectTimeout
        self.makeEncoder = makeEncoder
        self.makeDecoder = makeDecoder
    }
}
