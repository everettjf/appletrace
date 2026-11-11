//
//  TraceStatistics.swift
//  Per-span timing statistics for a trace (or several runs of one), and the
//  comparison of two of them, for performance checks in CI.
//

import Foundation

/// Timing statistics for every occurrence of one span name. Durations are in
/// microseconds.
public struct SpanStatistics: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A section (`B`/`E` or `X`): begins and ends on one thread.
        case section
        /// An async span (`b`/`e`): may begin and end on different threads.
        case async
    }

    public var name: String
    public var kind: Kind
    public var count: Int
    /// Sum of all durations.
    public var total: UInt64
    /// `total` minus the time spent in nested sections on the same thread.
    /// Equal to `total` for async spans.
    public var selfTime: UInt64
    public var min: UInt64
    public var max: UInt64
    public var mean: UInt64
    public var p50: UInt64
    public var p95: UInt64

    enum CodingKeys: String, CodingKey {
        case name, kind, count, total, selfTime = "self", min, max, mean, p50, p95
    }

    public init(name: String, kind: Kind, durations: [UInt64], selfTime: UInt64) {
        let sorted = durations.sorted()
        let total = sorted.reduce(UInt64(0), &+)
        self.name = name
        self.kind = kind
        self.count = sorted.count
        self.total = total
        self.selfTime = selfTime
        self.min = sorted.first ?? 0
        self.max = sorted.last ?? 0
        self.mean = sorted.isEmpty ? 0 : total / UInt64(sorted.count)
        self.p50 = Self.percentile(sorted, 0.50)
        self.p95 = Self.percentile(sorted, 0.95)
    }

    /// Nearest-rank percentile of an ascending array.
    static func percentile(_ sorted: [UInt64], _ quantile: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((quantile * Double(sorted.count)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
    }
}

/// Per-span statistics for one or more runs. Encodes to the JSON that
/// `appletrace summary --json` prints and `appletrace diff` accepts as a
/// baseline.
public struct TraceSummary: Codable, Equatable, Sendable {
    public static let formatIdentifier = "appletrace-summary"

    public var format: String
    public var version: Int
    /// Number of traces combined.
    public var runs: Int
    /// Spans that began but never ended (the process stopped first).
    public var unfinished: Int
    /// Sorted by total time, descending, then by name.
    public var spans: [SpanStatistics]

    public init(runs: Int, unfinished: Int, spans: [SpanStatistics]) {
        self.format = Self.formatIdentifier
        self.version = 1
        self.runs = runs
        self.unfinished = unfinished
        self.spans = spans.sorted {
            $0.total != $1.total ? $0.total > $1.total : ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue)
        }
    }

    /// Keeps only spans whose name starts with one of `prefixes` (all spans
    /// when `prefixes` is empty).
    public func filtered(prefixes: [String]) -> TraceSummary {
        guard !prefixes.isEmpty else { return self }
        var copy = self
        copy.spans = spans.filter { span in prefixes.contains { span.name.hasPrefix($0) } }
        return copy
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Accumulates span durations from trace events. Feed each trace's events with
/// ``add(_:)`` and close it with ``finishRun()``; several runs combine into one
/// summary (counts and percentiles over every occurrence).
public struct TraceStatisticsBuilder {
    private struct ThreadKey: Hashable {
        var pid: Int64
        var tid: UInt64
    }

    private struct AsyncKey: Hashable {
        var pid: Int64
        var name: String
        var id: UInt64
    }

    private struct SpanKey: Hashable {
        var name: String
        var kind: SpanStatistics.Kind
    }

    private struct Interval {
        var name: String
        var start: UInt64
        var duration: UInt64
        var end: UInt64 { start &+ duration }
    }

    private var openSections: [ThreadKey: [(name: String, start: UInt64)]] = [:]
    private var intervals: [ThreadKey: [Interval]] = [:]
    private var openAsync: [AsyncKey: [UInt64]] = [:]
    private var durations: [SpanKey: [UInt64]] = [:]
    private var selfTimes: [SpanKey: UInt64] = [:]
    private var runs = 0
    private var unfinished = 0

    public init() {}

    /// Adds one event. Accepts raw (`B`/`E`) and collapsed (`X`) sections and
    /// async `b`/`e` pairs; other phases are ignored.
    public mutating func add(_ event: TraceEvent) {
        let thread = ThreadKey(pid: event.pid, tid: event.tid)
        let timestamp = event.timestamp ?? 0
        switch event.phase {
        case "X":
            intervals[thread, default: []].append(
                Interval(name: event.name, start: timestamp, duration: event.duration ?? 0))
        case "B":
            openSections[thread, default: []].append((event.name, timestamp))
        case "E":
            // Unmatched ends (the begin predates the capture) are dropped.
            guard var stack = openSections[thread], let begin = stack.popLast() else { return }
            openSections[thread] = stack
            let duration = timestamp >= begin.start ? timestamp - begin.start : 0
            intervals[thread, default: []].append(Interval(name: begin.name, start: begin.start, duration: duration))
        case "b":
            guard let id = event.id else { return }
            openAsync[AsyncKey(pid: event.pid, name: event.name, id: id), default: []].append(timestamp)
        case "e":
            guard let id = event.id else { return }
            let key = AsyncKey(pid: event.pid, name: event.name, id: id)
            guard var starts = openAsync[key], let start = starts.popLast() else { return }
            openAsync[key] = starts.isEmpty ? nil : starts
            let duration = timestamp >= start ? timestamp - start : 0
            let span = SpanKey(name: event.name, kind: .async)
            durations[span, default: []].append(duration)
            selfTimes[span, default: 0] &+= duration
        default:
            break
        }
    }

    /// Ends the current trace: resolves section nesting (for self time) and
    /// counts spans left open.
    public mutating func finishRun() {
        for (_, list) in intervals {
            // Parents sort before their children: earlier start first, and for
            // equal starts the longer interval first.
            let ordered = list.sorted { $0.start != $1.start ? $0.start < $1.start : $0.duration > $1.duration }
            var childTime = [UInt64](repeating: 0, count: ordered.count)
            var stack: [Int] = []
            for (index, interval) in ordered.enumerated() {
                // Pop siblings and their descendants that ended before this one.
                while let top = stack.last, ordered[top].end <= interval.start {
                    stack.removeLast()
                }
                if let parent = stack.last, interval.end <= ordered[parent].end {
                    childTime[parent] &+= interval.duration
                }
                stack.append(index)
            }
            for (index, interval) in ordered.enumerated() {
                let span = SpanKey(name: interval.name, kind: .section)
                durations[span, default: []].append(interval.duration)
                let own = interval.duration >= childTime[index] ? interval.duration - childTime[index] : 0
                selfTimes[span, default: 0] &+= own
            }
        }
        unfinished += openSections.values.reduce(0) { $0 + $1.count }
        unfinished += openAsync.values.reduce(0) { $0 + $1.count }
        intervals.removeAll()
        openSections.removeAll()
        openAsync.removeAll()
        runs += 1
    }

    /// The statistics gathered so far. Call ``finishRun()`` first.
    public func summary() -> TraceSummary {
        let spans = durations.map { key, values in
            SpanStatistics(name: key.name, kind: key.kind, durations: values, selfTime: selfTimes[key] ?? 0)
        }
        return TraceSummary(runs: runs, unfinished: unfinished, spans: spans)
    }
}

public enum TraceStatisticsError: Error, CustomStringConvertible {
    case unreadable(URL)
    case cannotCombineSummaries

    public var description: String {
        switch self {
        case let .unreadable(url):
            return "\(url.path) is not a trace directory, a trace JSON file, or an appletrace summary"
        case .cannotCombineSummaries:
            return "a saved summary can't be combined with other inputs; pass trace directories or trace.json files"
        }
    }
}

public enum TraceStatistics {
    /// Summarizes each input as one run. An input is a fragment directory, a
    /// merged trace JSON (array or `{"traceEvents": [...]}`), or a saved
    /// summary (returned as is when it is the only input).
    public static func summarize(_ inputs: [URL]) throws -> TraceSummary {
        var builder = TraceStatisticsBuilder()
        for input in inputs {
            switch try load(input) {
            case let .summary(summary):
                guard inputs.count == 1 else { throw TraceStatisticsError.cannotCombineSummaries }
                return summary
            case let .directory(url):
                _ = try TraceMerger.events(in: url, options: MergeOptions(completeEvents: false)) { builder.add($0) }
            case let .events(events):
                events.forEach { builder.add($0) }
            }
            builder.finishRun()
        }
        return builder.summary()
    }

    private enum Input {
        case directory(URL)
        case events([TraceEvent])
        case summary(TraceSummary)
    }

    private static func load(_ url: URL) throws -> Input {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TraceStatisticsError.unreadable(url)
        }
        if isDirectory.boolValue {
            return .directory(url)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let json = try? JSONSerialization.jsonObject(with: data)
        if let object = json as? [String: Any] {
            if (object["format"] as? String) == TraceSummary.formatIdentifier {
                return .summary(try JSONDecoder().decode(TraceSummary.self, from: data))
            }
            if let events = object["traceEvents"] as? [[String: Any]] {
                return .events(events.compactMap(TraceEvent.init(json:)))
            }
        }
        if let events = json as? [[String: Any]] {
            return .events(events.compactMap(TraceEvent.init(json:)))
        }
        throw TraceStatisticsError.unreadable(url)
    }
}

// MARK: - Comparison

/// The statistic ``TraceComparison`` compares.
public enum SpanMetric: String, CaseIterable, Sendable {
    case total, `self`, mean, p50, p95, max, count

    public func value(of span: SpanStatistics) -> UInt64 {
        switch self {
        case .total: return span.total
        case .self: return span.selfTime
        case .mean: return span.mean
        case .p50: return span.p50
        case .p95: return span.p95
        case .max: return span.max
        case .count: return UInt64(span.count)
        }
    }

    /// Whether the value is a duration in microseconds (`count` is not).
    public var isDuration: Bool { self != .count }
}

public struct ComparisonOptions: Sendable {
    public var metric: SpanMetric
    /// Relative change that counts as a regression or improvement (0.1 = 10%).
    public var threshold: Double
    /// Smallest absolute change (µs, or calls for `count`) that counts, so tiny
    /// spans don't fail a check on noise.
    public var minimumDelta: UInt64
    /// Compare only spans whose name starts with one of these (all when empty).
    public var prefixes: [String]

    public init(metric: SpanMetric = .total, threshold: Double = 0.1, minimumDelta: UInt64 = 1_000, prefixes: [String] = []) {
        self.metric = metric
        self.threshold = threshold
        self.minimumDelta = minimumDelta
        self.prefixes = prefixes
    }
}

public struct SpanChange: Equatable, Sendable {
    public enum Status: String, Sendable {
        case regressed, improved, unchanged, added, removed
    }

    public var name: String
    public var kind: SpanStatistics.Kind
    public var baseline: UInt64?
    public var current: UInt64?
    public var status: Status

    /// `current / baseline - 1`, when both exist and the baseline is non-zero.
    public var relativeChange: Double? {
        guard let baseline, let current, baseline > 0 else { return nil }
        return Double(current) / Double(baseline) - 1
    }
}

public struct TraceComparison: Sendable {
    public var options: ComparisonOptions
    /// Every compared span: regressions first (largest relative change first),
    /// then removed, improved, added and unchanged spans.
    public var changes: [SpanChange]

    public var regressions: [SpanChange] { changes.filter { $0.status == .regressed } }
    public var removed: [SpanChange] { changes.filter { $0.status == .removed } }

    public init(baseline: TraceSummary, current: TraceSummary, options: ComparisonOptions = ComparisonOptions()) {
        self.options = options
        struct Key: Hashable {
            var name: String
            var kind: SpanStatistics.Kind
        }
        let base = baseline.filtered(prefixes: options.prefixes).spans
        let new = current.filtered(prefixes: options.prefixes).spans
        let baseByKey = Dictionary(base.map { (Key(name: $0.name, kind: $0.kind), $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(new.map { (Key(name: $0.name, kind: $0.kind), $0) }, uniquingKeysWith: { first, _ in first })

        var changes: [SpanChange] = []
        for key in Set(baseByKey.keys).union(newByKey.keys) {
            let before = baseByKey[key].map(options.metric.value(of:))
            let after = newByKey[key].map(options.metric.value(of:))
            let status: SpanChange.Status
            switch (before, after) {
            case let (before?, after?):
                let delta = after > before ? after - before : before - after
                let limit = Double(before) * options.threshold
                if delta < options.minimumDelta || Double(delta) <= limit {
                    status = .unchanged
                } else {
                    status = after > before ? .regressed : .improved
                }
            case (nil, _?):
                status = .added
            default:
                status = .removed
            }
            changes.append(SpanChange(name: key.name, kind: key.kind, baseline: before, current: after, status: status))
        }

        let rank: [SpanChange.Status: Int] = [.regressed: 0, .removed: 1, .improved: 2, .added: 3, .unchanged: 4]
        self.changes = changes.sorted { lhs, rhs in
            if lhs.status != rhs.status { return rank[lhs.status]! < rank[rhs.status]! }
            let left = lhs.relativeChange.map(abs) ?? 0
            let right = rhs.relativeChange.map(abs) ?? 0
            if left != right { return left > right }
            return lhs.name < rhs.name
        }
    }
}

// MARK: - Formatting

public enum DurationFormat {
    /// `850 µs`, `12.3 ms`, `1.20 s`.
    public static func string(microseconds value: UInt64) -> String {
        if value < 1_000 {
            return "\(value) µs"
        }
        if value < 1_000_000 {
            return String(format: "%.1f ms", Double(value) / 1_000)
        }
        return String(format: "%.2f s", Double(value) / 1_000_000)
    }

    /// Parses `500us`, `500µs`, `1.5ms`, `2s`; a bare number is microseconds.
    public static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("us", 1), ("µs", 1), ("ms", 1_000), ("s", 1_000_000)]
        for (suffix, scale) in units where trimmed.hasSuffix(suffix) {
            guard let number = Double(trimmed.dropLast(suffix.count)), number >= 0, number.isFinite else { return nil }
            return UInt64((number * scale).rounded())
        }
        guard let number = Double(trimmed), number >= 0, number.isFinite else { return nil }
        return UInt64(number.rounded())
    }
}
