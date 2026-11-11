//
//  FragmentDecoder.swift
//  Decodes AppleTrace trace fragments: JSON lines (`trace[_N].appletrace`) and
//  the binary format (`trace[_N].appletracebin`, docs/binary-fragment-format.md).
//

import Foundation

public enum TraceDecodingError: Error, CustomStringConvertible, Equatable {
    case notBinaryFragment
    case undefinedString(id: UInt32, file: String)
    case invalidJSON(file: String, line: Int)

    public var description: String {
        switch self {
        case .notBinaryFragment:
            return "not an AppleTrace binary fragment"
        case let .undefinedString(id, file):
            return "\(file): event references undefined string id \(id)"
        case let .invalidJSON(file, line):
            return "\(file):\(line): invalid JSON event"
        }
    }
}

public enum FragmentDecoder {
    public static let binaryMagic: [UInt8] = Array("APLTRC01".utf8)

    /// Fragments under `directory`, sorted by their numeric suffix
    /// (`trace`, `trace_1`, `trace_2`, …).
    public static func fragments(in directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var indexed: [(Int, URL)] = []
        for name in names {
            guard let index = fragmentIndex(of: name) else { continue }
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            indexed.append((index, url))
        }
        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// `trace.appletrace` → 0, `trace_12.appletracebin` → 12, other names → nil.
    static func fragmentIndex(of name: String) -> Int? {
        let stem: Substring
        if name.hasSuffix(".appletracebin") {
            stem = name.dropLast(".appletracebin".count)
        } else if name.hasSuffix(".appletrace") {
            stem = name.dropLast(".appletrace".count)
        } else {
            return nil
        }
        if stem == "trace" {
            return 0
        }
        guard stem.hasPrefix("trace_") else { return nil }
        let digits = stem.dropFirst("trace_".count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    public static func isBinary(_ data: Data) -> Bool {
        data.count >= binaryMagic.count && data.prefix(binaryMagic.count).elementsEqual(binaryMagic)
    }

    /// Decodes one fragment. `names` carries the binary string table across the
    /// fragments of one run: a thread defines a name only once, so a later
    /// fragment can reference an id defined in an earlier one.
    public static func decode(
        _ data: Data,
        file: String = "<memory>",
        names: inout [UInt32: String],
        emit: (TraceEvent) throws -> Void
    ) throws {
        if isBinary(data) {
            try decodeBinary(data, file: file, names: &names, emit: emit)
        } else {
            try decodeText(data, file: file, emit: emit)
        }
    }

    /// Convenience: every event of one fragment.
    public static func decode(_ data: Data, file: String = "<memory>") throws -> [TraceEvent] {
        var names: [UInt32: String] = [:]
        var events: [TraceEvent] = []
        try decode(data, file: file, names: &names) { events.append($0) }
        return events
    }

    // MARK: Binary

    static func decodeBinary(
        _ data: Data,
        file: String,
        names: inout [UInt32: String],
        emit: (TraceEvent) throws -> Void
    ) throws {
        guard isBinary(data) else { throw TraceDecodingError.notBinaryFragment }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let size = raw.count
            var offset = binaryMagic.count
            guard offset + 4 <= size else { return }
            let pid = Int64(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
            offset += 4

            while offset < size {
                let tag = raw[offset]
                offset += 1
                if tag == 0x00 {
                    break
                }
                if tag == 0x01 {
                    guard offset + 8 <= size else { break }
                    let nameID = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                    let length = Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
                    offset += 8
                    guard length <= size - offset else { break }
                    let bytes = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)])
                    names[nameID] = String(decoding: bytes, as: UTF8.self)
                    offset += length
                    continue
                }

                guard offset + 28 <= size else { break }
                let nameID = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                let tid = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt64.self).littleEndian
                let ts = raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt64.self).littleEndian
                let arg = raw.loadUnaligned(fromByteOffset: offset + 20, as: UInt64.self).littleEndian
                offset += 28

                guard let name = names[nameID] else {
                    throw TraceDecodingError.undefinedString(id: nameID, file: file)
                }
                let phase = String(UnicodeScalar(tag))
                var event = TraceEvent(name: name, phase: phase, pid: pid, tid: tid)
                switch phase {
                case "B", "E":
                    event.category = "appletrace"
                    event.timestamp = ts
                case "i":
                    event.category = "appletrace"
                    event.timestamp = ts
                    event.scope = "t"
                case "C":
                    event.category = "appletrace"
                    event.timestamp = ts
                    event.args = [("value", .number(Double(bitPattern: arg)))]
                case "b", "e":
                    event.category = "appletrace"
                    event.timestamp = ts
                    event.id = arg
                case "M":
                    guard arg <= UInt64(UInt32.max), let value = names[UInt32(arg)] else {
                        throw TraceDecodingError.undefinedString(id: UInt32(truncatingIfNeeded: arg), file: file)
                    }
                    event.args = [("name", .string(value))]
                default:
                    event.timestamp = ts
                }
                try emit(event)
            }
        }
    }

    // MARK: Text

    static func decodeText(_ data: Data, file: String, emit: (TraceEvent) throws -> Void) throws {
        let bytes = [UInt8](data)
        var lineNumber = 0
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: "\n") {
                end += 1
            }
            lineNumber += 1
            let line = bytes[start..<end]
            let nextStart = end + 1
            defer { start = nextStart }

            guard let first = line.first(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\t") }) else {
                continue
            }
            // Zero padding (an mmap block not truncated because the process
            // was killed) or other trailing garbage ends the fragment.
            if first != UInt8(ascii: "{") {
                return
            }

            let object = try? JSONSerialization.jsonObject(with: Data(line), options: [])
            guard let dictionary = object as? [String: Any], let event = TraceEvent(json: dictionary) else {
                // A record cut off mid-write by a killed process has no
                // trailing newline (only mmap zero padding): tolerate it, but
                // reject a complete line that is corrupt.
                let unterminated = end >= bytes.count
                if line.contains(0) || unterminated {
                    return
                }
                throw TraceDecodingError.invalidJSON(file: file, line: lineNumber)
            }
            try emit(event)
        }
    }
}

extension TraceEvent {
    /// Builds an event from a decoded JSON object (text fragment line).
    init?(json: [String: Any]) {
        guard let phase = json["ph"] as? String else { return nil }
        self.init(
            name: json["name"] as? String ?? "",
            category: json["cat"] as? String,
            phase: phase,
            id: TraceEvent.unsigned(json["id"]),
            pid: Int64(truncatingIfNeeded: TraceEvent.unsigned(json["pid"]) ?? 0),
            tid: TraceEvent.unsigned(json["tid"]) ?? 0,
            timestamp: TraceEvent.unsigned(json["ts"]),
            duration: TraceEvent.unsigned(json["dur"]),
            scope: json["s"] as? String
        )
        if let args = json["args"] as? [String: Any] {
            self.args = args.keys.sorted().map { ($0, TraceArgument(json: args[$0]!)) }
        }
    }

    static func unsigned(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber:
            let double = number.doubleValue
            return double < 0 ? 0 : number.uint64Value
        case let string as String:
            return UInt64(string)
        default:
            return nil
        }
    }
}
