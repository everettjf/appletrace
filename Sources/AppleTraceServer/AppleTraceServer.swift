import AppleTrace
import AppleTraceProtocol
import CryptoKit
import Darwin
import Foundation
import Network
import Security

public struct AppleTraceServerConfiguration: Sendable {
    public var port: UInt16
    public var bindToLoopback: Bool
    public var token: String

    public init(port: UInt16 = 0, bindToLoopback: Bool = true, token: String? = nil) {
        self.port = port
        self.bindToLoopback = bindToLoopback
        self.token = token ?? Self.randomToken()
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

public final class AppleTraceControlServer: @unchecked Sendable {
    public enum ServerError: Error {
        case invalidPort
    }

    public let configuration: AppleTraceServerConfiguration
    public private(set) var listeningPort: UInt16?

    private let queue = DispatchQueue(label: "com.everettjf.appletrace.server")
    private var listener: NWListener?
    private var webSocketSessions: [UUID: WebSocketSession] = [:]

    public init(configuration: AppleTraceServerConfiguration = .init()) {
        self.configuration = configuration
    }

    public func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ServerError.invalidPort
        }
        let parameters = NWParameters.tcp
        if configuration.bindToLoopback {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        }
        let listener = try NWListener(using: parameters, on: port)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            if case .ready = state {
                self.listeningPort = listener?.port?.rawValue
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let sessions = Array(webSocketSessions.values)
        webSocketSessions.removeAll()
        sessions.forEach { $0.cancel() }
        listeningPort = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let request = HTTPParser.parse(next) {
                self.respond(to: request, on: connection)
            } else if complete || error != nil || next.count >= (1 << 20) {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        if request.method == "GET", request.path == "/" || request.path.hasPrefix("/assets/") {
            sendConsoleAsset(path: request.path, on: connection)
            return
        }
        guard authorized(request) else {
            send(json: APIErrorPayload("unauthorized"), status: 401, reason: "Unauthorized", on: connection)
            return
        }

        if request.path == "/api/v1/stream",
           request.headers["upgrade"]?.lowercased() == "websocket",
           let key = request.headers["sec-websocket-key"] {
            let protocols = request.headers["sec-websocket-protocol"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            upgradeWebSocket(key: key, protocol: protocols.contains("appletrace-v1") ? "appletrace-v1" : nil, on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/api/v1/status"):
            send(json: statusPayload(), on: connection)
        case ("POST", "/api/v1/capture/start"):
            _ = startCapture()
            send(json: statusPayload(), on: connection)
        case ("POST", "/api/v1/capture/stop"):
            stopCapture()
            send(json: statusPayload(), on: connection)
        case ("POST", "/api/v1/filters"):
            do {
                let filters = try JSONDecoder().decode(FilterConfigurationPayload.self, from: request.body)
                apply(filters: filters)
                send(json: filters, on: connection)
            } catch {
                send(json: APIErrorPayload("invalid filter configuration"), status: 400, reason: "Bad Request", on: connection)
            }
        case ("GET", "/api/v1/artifacts"):
            send(json: artifacts(), on: connection)
        default:
            if request.method == "GET", request.path.hasPrefix("/api/v1/artifacts/") {
                sendArtifact(path: request.path, on: connection)
            } else {
                send(json: APIErrorPayload("not found"), status: 404, reason: "Not Found", on: connection)
            }
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        if request.headers["authorization"] == "Bearer \(configuration.token)" ||
            request.headers["x-appletrace-token"] == configuration.token {
            return true
        }
        let protocols = request.headers["sec-websocket-protocol"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return protocols.contains("appletrace-token.\(configuration.token)")
    }

    private func statusPayload() -> AgentStatusPayload {
        let metrics = traceMetrics
        return AgentStatusPayload(
            processId: getpid(),
            processName: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            architecture: Self.architecture,
            captureState: String(describing: captureState),
            objcHookInstalled: Self.isObjcHookInstalled(),
            traceDirectory: traceDirectory,
            metrics: .init(
                acceptedEvents: metrics.acceptedEvents,
                pendingBytes: metrics.pendingBytes,
                writeFailures: metrics.writeFailures
            )
        )
    }

    private func artifacts() -> [ArtifactPayload] {
        let directory = URL(fileURLWithPath: traceDirectory, isDirectory: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return ArtifactPayload(
                name: url.lastPathComponent,
                size: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func apply(filters: FilterConfigurationPayload) {
        typealias FilterFunction = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "APTSetObjcTraceClassFilters") else {
            return
        }
        let function = unsafeBitCast(symbol, to: FilterFunction.self)
        let allow = filters.allowClassPrefixes.joined(separator: ",")
        let deny = filters.denyClassPrefixes.joined(separator: ",")
        allow.withCString { allowPointer in
            deny.withCString { denyPointer in
                function(allow.isEmpty ? nil : allowPointer, deny.isEmpty ? nil : denyPointer)
            }
        }
    }

    private func sendArtifact(path: String, on connection: NWConnection) {
        let encodedName = String(path.dropFirst("/api/v1/artifacts/".count))
        guard let name = encodedName.removingPercentEncoding,
              !name.isEmpty,
              name == URL(fileURLWithPath: name).lastPathComponent else {
            send(json: APIErrorPayload("invalid artifact name"), status: 400, reason: "Bad Request", on: connection)
            return
        }
        let directory = URL(fileURLWithPath: traceDirectory, isDirectory: true).standardizedFileURL
        let file = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard file.deletingLastPathComponent() == directory,
              let body = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            send(json: APIErrorPayload("artifact not found"), status: 404, reason: "Not Found", on: connection)
            return
        }
        let response = HTTPResponse(
            status: 200,
            reason: "OK",
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"\(name.replacingOccurrences(of: "\"", with: ""))\"",
            ],
            body: body
        )
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendConsoleAsset(path: String, on connection: NWConnection) {
        let relativePath = path == "/" ? "index.html" : String(path.dropFirst())
        guard !relativePath.contains(".."),
              relativePath == URL(fileURLWithPath: relativePath).relativePath,
              let root = Bundle.module.resourceURL?.appendingPathComponent("Console", isDirectory: true),
              let body = try? Data(contentsOf: root.appendingPathComponent(relativePath), options: [.mappedIfSafe]) else {
            send(json: APIErrorPayload("asset not found"), status: 404, reason: "Not Found", on: connection)
            return
        }
        let contentType: String
        switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
        case "html": contentType = "text/html; charset=utf-8"
        case "css": contentType = "text/css; charset=utf-8"
        case "js": contentType = "text/javascript; charset=utf-8"
        case "svg": contentType = "image/svg+xml"
        default: contentType = "application/octet-stream"
        }
        let response = HTTPResponse(
            status: 200,
            reason: "OK",
            headers: [
                "Content-Type": contentType,
                "Cache-Control": relativePath == "index.html" ? "no-cache" : "public, max-age=31536000, immutable",
            ],
            body: body
        )
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func isObjcHookInstalled() -> Bool {
        typealias HookStatusFunction = @convention(c) () -> Bool
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "APTIsObjcMsgSendHookInstalled") else {
            return false
        }
        return unsafeBitCast(symbol, to: HookStatusFunction.self)()
    }

    private func send<T: Encodable>(json value: T, status: Int = 200, reason: String = "OK", on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        let response = HTTPResponse(
            status: status,
            reason: reason,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func upgradeWebSocket(key: String, protocol selectedProtocol: String?, on connection: NWConnection) {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let accept = Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
        var headers = [
            "Connection": "Upgrade",
            "Upgrade": "websocket",
            "Sec-WebSocket-Accept": accept,
        ]
        if let selectedProtocol { headers["Sec-WebSocket-Protocol"] = selectedProtocol }
        let response = HTTPResponse(
            status: 101,
            reason: "Switching Protocols",
            headers: headers
        )
        let identifier = UUID()
        let session = WebSocketSession(
            connection: connection,
            queue: queue,
            statusProvider: { [weak self] in self?.statusPayload() },
            onClose: { [weak self] in self?.webSocketSessions.removeValue(forKey: identifier) }
        )
        webSocketSessions[identifier] = session
        connection.send(content: response.encoded(), completion: .contentProcessed { error in
            if error == nil {
                session.start()
            } else {
                session.cancel()
            }
        })
    }

    private static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

private final class WebSocketSession {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let statusProvider: () -> AgentStatusPayload?
    private let onClose: () -> Void
    private var timer: DispatchSourceTimer?
    private var receiveBuffer = Data()
    private var closed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        statusProvider: @escaping () -> AgentStatusPayload?,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.statusProvider = statusProvider
        self.onClose = onClose
    }

    func start() {
        sendStatus()
        receive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sendStatus() }
        self.timer = timer
        timer.resume()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        connection.cancel()
        onClose()
    }

    private func sendStatus() {
        guard let status = statusProvider(),
              let payload = try? JSONEncoder().encode(status) else { return }
        send(WebSocketFrameCodec.encode(opcode: .text, payload: payload))
    }

    private func send(_ data: Data, then completion: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.cancel() } else { completion?() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            guard let decoded = WebSocketFrameCodec.decode(self.receiveBuffer) else {
                self.send(WebSocketFrameCodec.encode(opcode: .close)) { self.cancel() }
                return
            }
            self.receiveBuffer = decoded.remainder
            for frame in decoded.frames {
                guard frame.masked else {
                    self.send(WebSocketFrameCodec.encode(opcode: .close)) { self.cancel() }
                    return
                }
                switch frame.opcode {
                case .ping:
                    self.send(WebSocketFrameCodec.encode(opcode: .pong, payload: frame.payload))
                case .close:
                    self.send(WebSocketFrameCodec.encode(opcode: .close, payload: frame.payload)) { self.cancel() }
                    return
                default:
                    break
                }
            }
            if complete || error != nil {
                self.cancel()
            } else {
                self.receive()
            }
        }
    }
}
