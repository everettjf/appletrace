//
//  TraceMerger.swift
//  Merges a directory of AppleTrace fragments into one Perfetto-ready
//  `trace.json` (a Chrome JSON event array).
//

import Foundation

public struct MergeOptions: Sendable {
    /// Collapse matched `B`/`E` pairs into `X` complete events (roughly halves
    /// the event count). `false` keeps the raw begin/end events.
    public var completeEvents: Bool

    public init(completeEvents: Bool = true) {
        self.completeEvents = completeEvents
    }
}

public struct MergeSummary: Sendable {
    public var output: URL
    public var fragments: [URL]
    public var eventCount: Int
}

public enum TraceMergeError: Error, CustomStringConvertible {
    case notADirectory(URL)
    case noFragments(URL)

    public var description: String {
        switch self {
        case let .notADirectory(url): return "trace path is not a directory: \(url.path)"
        case let .noFragments(url): return "no trace fragments (trace*.appletrace / trace*.appletracebin) found in \(url.path)"
        }
    }
}

/// Pairs `B`/`E` events into `X` complete events, LIFO per `(pid, tid)` —
/// the nested model the runtime emits. Unmatched begins are flushed at the end
/// as raw `B` events (viewers close them at the end of the trace); unmatched
/// ends pass through.
public struct CompleteEventCollapser {
    private var open: [PairKey: [TraceEvent]] = [:]

    private struct PairKey: Hashable {
        var pid: Int64
        var tid: UInt64
    }

    public init() {}

    public mutating func process(_ event: TraceEvent, emit: (TraceEvent) throws -> Void) rethrows {
        let key = PairKey(pid: event.pid, tid: event.tid)
        switch event.phase {
        case "B":
            open[key, default: []].append(event)
        case "E":
            if var stack = open[key], let begin = stack.popLast() {
                open[key] = stack
                var complete = begin
                complete.phase = "X"
                let start = begin.timestamp ?? 0
                let end = event.timestamp ?? start
                complete.duration = end >= start ? end - start : 0
                for (key, value) in event.args {
                    if let index = complete.args.firstIndex(where: { $0.0 == key }) {
                        complete.args[index].1 = value
                    } else {
                        complete.args.append((key, value))
                    }
                }
                try emit(complete)
            } else {
                try emit(event)
            }
        default:
            try emit(event)
        }
    }

    public mutating func finish(emit: (TraceEvent) throws -> Void) rethrows {
        for key in open.keys.sorted(by: { ($0.pid, $0.tid) < ($1.pid, $1.tid) }) {
            for begin in open[key] ?? [] {
                try emit(begin)
            }
        }
        open.removeAll()
    }
}

public enum TraceMerger {
    /// Reads every fragment under `directory` in order and calls `emit` for
    /// each (optionally collapsed) event.
    public static func events(
        in directory: URL,
        options: MergeOptions = MergeOptions(),
        emit: (TraceEvent) throws -> Void
    ) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TraceMergeError.notADirectory(directory)
        }
        let fragments = try FragmentDecoder.fragments(in: directory)
        guard !fragments.isEmpty else {
            throw TraceMergeError.noFragments(directory)
        }

        var names: [UInt32: String] = [:]
        var collapser = CompleteEventCollapser()
        for fragment in fragments {
            let data = try Data(contentsOf: fragment, options: .mappedIfSafe)
            try FragmentDecoder.decode(data, file: fragment.lastPathComponent, names: &names) { event in
                if options.completeEvents {
                    try collapser.process(event, emit: emit)
                } else {
                    try emit(event)
                }
            }
        }
        if options.completeEvents {
            try collapser.finish(emit: emit)
        }
        return fragments
    }

    /// Every event under `directory`, in output order.
    public static func events(in directory: URL, options: MergeOptions = MergeOptions()) throws -> [TraceEvent] {
        var all: [TraceEvent] = []
        _ = try events(in: directory, options: options) { all.append($0) }
        return all
    }

    /// Writes `directory`'s events to `output` (default `<directory>/trace.json`)
    /// as a JSON array, streaming so large captures don't need to fit in memory.
    @discardableResult
    public static func merge(
        directory: URL,
        output: URL? = nil,
        options: MergeOptions = MergeOptions()
    ) throws -> MergeSummary {
        let target = output ?? directory.appendingPathComponent("trace.json")
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        var buffer = "["
        var count = 0
        let flushThreshold = 1 << 20

        func flush() {
            if let data = buffer.data(using: .utf8) {
                handle.write(data)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        let fragments: [URL]
        do {
            fragments = try events(in: directory, options: options) { event in
                if count > 0 {
                    buffer += ","
                }
                JSONWriter.append(event, to: &buffer)
                count += 1
                if buffer.utf8.count >= flushThreshold {
                    flush()
                }
            }
            buffer += "]\n"
            flush()
            handle.closeFile()
        } catch {
            handle.closeFile()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        return MergeSummary(output: target, fragments: fragments, eventCount: count)
    }
}
