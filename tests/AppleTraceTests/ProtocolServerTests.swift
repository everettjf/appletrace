import XCTest
@testable import AppleTraceProtocol
@testable import AppleTraceServer

final class ProtocolServerTests: XCTestCase {
    func testProtocolPayloadRoundTrip() throws {
        let value = FilterConfigurationPayload(
            allowClassPrefixes: ["Example", "Feature"],
            denyClassPrefixes: ["UIKit"]
        )
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(FilterConfigurationPayload.self, from: data), value)
    }

    func testHTTPParserWaitsForCompleteBody() throws {
        let partial = Data("POST /api/v1/filters HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8)
        XCTAssertNil(HTTPParser.parse(partial))

        let complete = Data("POST /api/v1/filters HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let request = try XCTUnwrap(HTTPParser.parse(complete))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/filters")
        XCTAssertEqual(request.body, Data("{}".utf8))
    }

    func testWebSocketFrameCodecHandlesMaskedAndPartialFrames() throws {
        let payload = Data("ping".utf8)
        let mask: [UInt8] = [1, 2, 3, 4]
        var frame = Data([0x89, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })

        let partial = try XCTUnwrap(WebSocketFrameCodec.decode(frame.dropLast()))
        XCTAssertTrue(partial.frames.isEmpty)
        XCTAssertEqual(partial.remainder, frame.dropLast())

        let decoded = try XCTUnwrap(WebSocketFrameCodec.decode(frame))
        XCTAssertEqual(decoded.frames.count, 1)
        XCTAssertEqual(decoded.frames[0].opcode, .ping)
        XCTAssertTrue(decoded.frames[0].masked)
        XCTAssertEqual(decoded.frames[0].payload, payload)
        XCTAssertTrue(decoded.remainder.isEmpty)
    }

    func testConfigurationGeneratesStrongToken() {
        let first = AppleTraceServerConfiguration()
        let second = AppleTraceServerConfiguration()
        XCTAssertEqual(first.token.count, 32)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertTrue(first.bindToLoopback)
    }

    func testLoopbackServerAuthenticationAndStatus() async throws {
        let configuration = AppleTraceServerConfiguration(token: "test-token")
        let server = AppleTraceControlServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        var port: UInt16?
        for _ in 0..<100 {
            if let readyPort = server.listeningPort {
                port = readyPort
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let readyPort = try XCTUnwrap(port)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(readyPort)/api/v1/status"))

        let rootURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(readyPort)/"))
        let (consoleBody, consoleResponse) = try await URLSession.shared.data(from: rootURL)
        XCTAssertEqual((consoleResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: consoleBody, as: UTF8.self).contains("AppleTrace"))

        let (unauthorizedBody, unauthorizedResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(String(decoding: unauthorizedBody, as: UTF8.self).contains("unauthorized"))

        var request = URLRequest(url: url)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let status = try JSONDecoder().decode(AgentStatusPayload.self, from: body)
        XCTAssertEqual(status.protocolVersion, AppleTraceProtocolVersion.current)
        XCTAssertFalse(status.processName.isEmpty)

        var stopRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(readyPort)/api/v1/capture/stop")))
        stopRequest.httpMethod = "POST"
        stopRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (stopBody, _) = try await URLSession.shared.data(for: stopRequest)
        XCTAssertEqual(try JSONDecoder().decode(AgentStatusPayload.self, from: stopBody).captureState, "idle")

        var startRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(readyPort)/api/v1/capture/start")))
        startRequest.httpMethod = "POST"
        startRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (startBody, _) = try await URLSession.shared.data(for: startRequest)
        XCTAssertEqual(try JSONDecoder().decode(AgentStatusPayload.self, from: startBody).captureState, "recording")

        var traversalRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(readyPort)/api/v1/artifacts/%2E%2E%2Fsecret")))
        traversalRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (_, traversalResponse) = try await URLSession.shared.data(for: traversalRequest)
        XCTAssertEqual((traversalResponse as? HTTPURLResponse)?.statusCode, 400)
    }

    func testWebSocketStreamsStatusAndRespondsToPing() async throws {
        let configuration = AppleTraceServerConfiguration(token: "stream-token")
        let server = AppleTraceControlServer(configuration: configuration)
        try server.start()
        defer { server.stop() }

        var port: UInt16?
        for _ in 0..<100 {
            if let readyPort = server.listeningPort {
                port = readyPort
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let readyPort = try XCTUnwrap(port)
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(readyPort)/api/v1/stream"))
        let task = URLSession.shared.webSocketTask(
            with: url,
            protocols: ["appletrace-v1", "appletrace-token.stream-token"]
        )
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let first = try await task.receive()
        let firstStatus = try decodeStatus(from: first)
        XCTAssertEqual(firstStatus.protocolVersion, AppleTraceProtocolVersion.current)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        let second = try await task.receive()
        let secondStatus = try decodeStatus(from: second)
        XCTAssertEqual(secondStatus.processId, firstStatus.processId)
    }

    private func decodeStatus(from message: URLSessionWebSocketTask.Message) throws -> AgentStatusPayload {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw CocoaError(.coderInvalidValue)
        }
        return try JSONDecoder().decode(AgentStatusPayload.self, from: data)
    }
}
