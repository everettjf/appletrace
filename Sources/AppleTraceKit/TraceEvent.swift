//
//  TraceEvent.swift
//  A Chrome / Perfetto JSON trace event, as produced by the AppleTrace runtime.
//

import Foundation

/// A JSON value carried in an event's `args`.
public enum TraceArgument: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([TraceArgument])
    case object([(String, TraceArgument)])

    public static func == (lhs: TraceArgument, rhs: TraceArgument) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// A counter value: integral values print without a fraction (`60`), as
    /// the text producer and the Python exporter do.
    public static func number(_ value: Double) -> TraceArgument {
        if !value.isFinite {
            return .integer(0)
        }
        if value.rounded() == value, abs(value) < 9.0e15 {
            return .integer(Int64(value))
        }
        return .double(value)
    }

    init(json: Any) {
        switch json {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .number(value.doubleValue)
            } else {
                self = .integer(value.int64Value)
            }
        case let value as [Any]:
            self = .array(value.map(TraceArgument.init(json:)))
        case let value as [String: Any]:
            self = .object(value.keys.sorted().map { ($0, TraceArgument(json: value[$0]!)) })
        default:
            self = .null
        }
    }
}

/// One trace event. Field order when serialized follows the runtime's text
/// producer: `name, cat, ph, id, pid, tid, ts, dur, s, args`.
public struct TraceEvent: Equatable, Sendable {
    public var name: String
    public var category: String?
    public var phase: String
    public var id: UInt64?
    public var pid: Int64
    public var tid: UInt64
    public var timestamp: UInt64?
    public var duration: UInt64?
    public var scope: String?
    public var args: [(String, TraceArgument)]

    public init(
        name: String,
        category: String? = nil,
        phase: String,
        id: UInt64? = nil,
        pid: Int64,
        tid: UInt64,
        timestamp: UInt64? = nil,
        duration: UInt64? = nil,
        scope: String? = nil,
        args: [(String, TraceArgument)] = []
    ) {
        self.name = name
        self.category = category
        self.phase = phase
        self.id = id
        self.pid = pid
        self.tid = tid
        self.timestamp = timestamp
        self.duration = duration
        self.scope = scope
        self.args = args
    }

    public static func == (lhs: TraceEvent, rhs: TraceEvent) -> Bool {
        lhs.name == rhs.name && lhs.category == rhs.category && lhs.phase == rhs.phase
            && lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.tid == rhs.tid
            && lhs.timestamp == rhs.timestamp && lhs.duration == rhs.duration
            && lhs.scope == rhs.scope
            && TraceArgument.object(lhs.args) == TraceArgument.object(rhs.args)
    }

    /// The value of `args[key]`, if present.
    public func argument(_ key: String) -> TraceArgument? {
        args.first { $0.0 == key }?.1
    }
}

// MARK: - JSON serialization

enum JSONWriter {
    static func append(_ event: TraceEvent, to out: inout String) {
        out += "{\"name\":"
        appendString(event.name, to: &out)
        if let category = event.category {
            out += ",\"cat\":"
            appendString(category, to: &out)
        }
        out += ",\"ph\":"
        appendString(event.phase, to: &out)
        if let id = event.id {
            out += ",\"id\":\(id)"
        }
        out += ",\"pid\":\(event.pid),\"tid\":\(event.tid)"
        if let timestamp = event.timestamp {
            out += ",\"ts\":\(timestamp)"
        }
        if let duration = event.duration {
            out += ",\"dur\":\(duration)"
        }
        if let scope = event.scope {
            out += ",\"s\":"
            appendString(scope, to: &out)
        }
        if !event.args.isEmpty {
            out += ",\"args\":"
            append(.object(event.args), to: &out)
        }
        out += "}"
    }

    static func append(_ value: TraceArgument, to out: inout String) {
        switch value {
        case let .string(string):
            appendString(string, to: &out)
        case let .integer(integer):
            out += String(integer)
        case let .double(double):
            out += double.isFinite ? "\(double)" : "0"
        case let .bool(bool):
            out += bool ? "true" : "false"
        case .null:
            out += "null"
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                append(item, to: &out)
            }
            out += "]"
        case let .object(members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                appendString(member.0, to: &out)
                out += ":"
                append(member.1, to: &out)
            }
            out += "}"
        }
    }

    static func appendString(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension TraceEvent {
    /// The event as a single-line JSON object.
    public var jsonString: String {
        var out = ""
        JSONWriter.append(self, to: &out)
        return out
    }
}
