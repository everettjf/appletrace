//
//  Statistics.swift
//  `appletrace summary` and `appletrace diff`: per-span timings and a
//  regression check against a baseline, for CI.
//

#if os(macOS)
import AppleTraceKit
import Foundation

enum StatisticsCommands {
    /// Exit status of `diff` when a span regressed (or went missing with
    /// `--fail-on-missing`). Errors exit with 1.
    static let regressionExitStatus: Int32 = 2

    static func prefixes(_ args: Arguments) -> [String] {
        args.values("--only")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: summary

    static func summary(_ args: Arguments) throws {
        guard !args.positional.isEmpty else {
            throw CLIError("summary needs at least one trace directory, trace JSON, or summary file")
        }
        let summary = try TraceStatistics.summarize(args.positional.map(expandPath)).filtered(prefixes: prefixes(args))
        let json = try summary.jsonData()

        if let output = args.value("-o", "--output") {
            let url = expandPath(output)
            try json.write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("Wrote summary of \(summary.spans.count) span(s) from \(summary.runs) run(s) → \(url.path)\n".utf8))
        }
        if args.has("--json") {
            FileHandle.standardOutput.write(json)
            print("")
            return
        }
        if args.value("-o", "--output") != nil && !args.has("--table") {
            return
        }

        let sortKey = args.value("--sort") ?? "total"
        let sorted: [SpanStatistics]
        switch sortKey {
        case "name":
            sorted = summary.spans.sorted { $0.name < $1.name }
        default:
            guard let metric = SpanMetric(rawValue: sortKey) else {
                throw CLIError("--sort expects one of name, \(SpanMetric.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            sorted = summary.spans.sorted { metric.value(of: $0) > metric.value(of: $1) }
        }
        guard let top = Int(args.value("--top") ?? "20"), top >= 0 else { throw CLIError("--top expects a number") }
        let shown = top == 0 ? sorted : Array(sorted.prefix(top))

        let header = ["span", "kind", "count", "total", "self", "mean", "p50", "p95", "max"]
        let rows = shown.map { span -> [String] in
            [span.name, span.kind.rawValue, String(span.count)]
                + [span.total, span.selfTime, span.mean, span.p50, span.p95, span.max].map(DurationFormat.string(microseconds:))
        }
        printTable(header: header, rows: rows, leftAligned: [0, 1])
        var footer = "\(summary.spans.count) span name(s) from \(summary.runs) run(s)"
        if shown.count < sorted.count {
            footer += ", top \(shown.count) by \(sortKey) shown (--top 0 for all)"
        }
        if summary.unfinished > 0 {
            footer += "; \(summary.unfinished) span(s) never ended"
        }
        print(footer)
    }

    // MARK: diff

    static func diff(_ args: Arguments) throws -> Int32 {
        guard args.positional.count == 2 else {
            throw CLIError("diff needs a baseline and a current trace (directory, trace JSON, or summary file)")
        }
        let baseline = try TraceStatistics.summarize([expandPath(args.positional[0])])
        let current = try TraceStatistics.summarize([expandPath(args.positional[1])])

        var options = ComparisonOptions(prefixes: prefixes(args))
        if let metric = args.value("--metric") {
            guard let parsed = SpanMetric(rawValue: metric) else {
                throw CLIError("--metric expects one of \(SpanMetric.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            options.metric = parsed
        }
        if let threshold = args.value("--threshold") {
            let number = threshold.hasSuffix("%") ? String(threshold.dropLast()) : threshold
            guard let percent = Double(number), percent >= 0, percent.isFinite else {
                throw CLIError("--threshold expects a percentage such as 10%")
            }
            options.threshold = percent / 100
        }
        if let minimum = args.value("--min-delta") {
            if options.metric.isDuration {
                guard let parsed = DurationFormat.parse(minimum) else {
                    throw CLIError("--min-delta expects a duration such as 1ms, 500us or 0.2s")
                }
                options.minimumDelta = parsed
            } else {
                guard let parsed = UInt64(minimum) else { throw CLIError("--min-delta expects a call count for --metric count") }
                options.minimumDelta = parsed
            }
        } else if !options.metric.isDuration {
            options.minimumDelta = 1
        }

        let comparison = TraceComparison(baseline: baseline, current: current, options: options)
        let failOnMissing = args.has("--fail-on-missing")
        let failed = !comparison.regressions.isEmpty || (failOnMissing && !comparison.removed.isEmpty)

        if args.has("--json") {
            printJSON(comparison, failed: failed)
        } else {
            printComparison(comparison, showAll: args.has("--all"))
        }
        return failed ? regressionExitStatus : 0
    }

    static func format(_ value: UInt64?, metric: SpanMetric) -> String {
        guard let value else { return "—" }
        return metric.isDuration ? DurationFormat.string(microseconds: value) : String(value)
    }

    static func printComparison(_ comparison: TraceComparison, showAll: Bool) {
        let metric = comparison.options.metric
        let shown = showAll ? comparison.changes : comparison.changes.filter { $0.status != .unchanged }
        if !shown.isEmpty {
            let rows = shown.map { change -> [String] in
                let relative = change.relativeChange.map { String(format: "%+.1f%%", $0 * 100) } ?? ""
                return [change.status.rawValue, change.name, format(change.baseline, metric: metric), format(change.current, metric: metric), relative]
            }
            printTable(header: ["status", "span", "baseline", "current", "change"], rows: rows, leftAligned: [0, 1])
        }
        let counts = Dictionary(grouping: comparison.changes, by: \.status).mapValues(\.count)
        let parts = [SpanChange.Status.regressed, .improved, .unchanged, .added, .removed].map { "\(counts[$0] ?? 0) \($0.rawValue)" }
        let threshold = String(format: "%g%%", comparison.options.threshold * 100)
        let minimum = format(comparison.options.minimumDelta, metric: metric)
        print("Compared \(metric.rawValue) (threshold \(threshold), min delta \(minimum)): \(parts.joined(separator: ", "))")
    }

    static func printJSON(_ comparison: TraceComparison, failed: Bool) {
        var out = "{\"metric\":\"\(comparison.options.metric.rawValue)\",\"threshold\":\(comparison.options.threshold)"
        out += ",\"minDelta\":\(comparison.options.minimumDelta),\"failed\":\(failed),\"changes\":["
        for (index, change) in comparison.changes.enumerated() {
            if index > 0 { out += "," }
            var object: [String: Any] = ["name": change.name, "kind": change.kind.rawValue, "status": change.status.rawValue]
            if let baseline = change.baseline { object["baseline"] = baseline }
            if let current = change.current { object["current"] = current }
            if let relative = change.relativeChange { object["change"] = relative }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            out += String(decoding: data, as: UTF8.self)
        }
        out += "]}"
        print(out)
    }

    static func printTable(header: [String], rows: [[String]], leftAligned: Set<Int>) {
        let all = [header] + rows
        var widths = [Int](repeating: 0, count: header.count)
        for row in all {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        for row in all {
            let cells = row.enumerated().map { index, cell -> String in
                let padding = String(repeating: " ", count: widths[index] - cell.count)
                return leftAligned.contains(index) ? cell + padding : padding + cell
            }
            print(cells.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
    }
}
#endif
