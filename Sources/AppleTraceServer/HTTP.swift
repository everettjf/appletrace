import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String] = [:]
    var body = Data()

    func encoded() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = allHeaders["Connection"] ?? "close"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = headerRange.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + length else { return nil }
        return HTTPRequest(
            method: parts[0],
            path: parts[1],
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        )
    }
}

enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WebSocketFrame {
    var opcode: WebSocketOpcode
    var masked: Bool
    var payload: Data
}

enum WebSocketFrameCodec {
    static func encode(opcode: WebSocketOpcode, payload: Data = Data()) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        } else {
            frame.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }

    static func decode(_ data: Data) -> (frames: [WebSocketFrame], remainder: Data)? {
        var offset = 0
        var frames: [WebSocketFrame] = []
        while data.count - offset >= 2 {
            let first = data[offset]
            let second = data[offset + 1]
            guard first & 0x70 == 0, first & 0x80 != 0,
                  let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { return nil }
            let masked = second & 0x80 != 0
            var length = UInt64(second & 0x7F)
            var headerLength = 2
            if length == 126 {
                guard data.count - offset >= 4 else { break }
                length = UInt64(data[offset + 2]) << 8 | UInt64(data[offset + 3])
                headerLength = 4
            } else if length == 127 {
                guard data.count - offset >= 10 else { break }
                length = 0
                for byte in data[(offset + 2)..<(offset + 10)] {
                    length = length << 8 | UInt64(byte)
                }
                headerLength = 10
            }
            guard length <= 1 << 20 else { return nil }
            if opcode.rawValue >= 0x8 && length > 125 { return nil }
            let maskLength = masked ? 4 : 0
            guard length <= UInt64(Int.max),
                  data.count - offset >= headerLength + maskLength + Int(length) else { break }
            let maskStart = offset + headerLength
            let payloadStart = maskStart + maskLength
            var payload = Data(data[payloadStart..<(payloadStart + Int(length))])
            if masked {
                let mask = data[maskStart..<(maskStart + 4)]
                for index in payload.indices {
                    payload[index] ^= mask[mask.index(mask.startIndex, offsetBy: index % 4)]
                }
            }
            frames.append(.init(opcode: opcode, masked: masked, payload: payload))
            offset = payloadStart + Int(length)
        }
        return (frames, Data(data[offset...]))
    }
}
