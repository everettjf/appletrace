//
//  TraceStatisticsTests.swift
//  Span statistics (`appletrace summary`) and baseline comparison
//  (`appletrace diff`).
//

import AppleTraceKit
import Foundation
import XCTest

final class TraceStatisticsTests: XCTestCase {
    private func section(_ name: String, _ phase: String, tid: UInt64 = 1, ts: UInt64) -> TraceEvent {
        TraceEvent(name: name, category: "appletrace", phase: phase, pid: 1, tid: tid, timestamp: ts)
    }

    private func summarize(_ runs: [[TraceEvent]]) -> TraceSummary {
        var builder = TraceStatisticsBuilder()
        for events in runs {
            events.forEach { builder.add($0) }
            builder.finishRun()
        }
        return builder.summary()
    }

    private func span(_ summary: TraceSummary, _ name: String) throws -> SpanStatistics {
        try XCTUnwrap(summary.spans.first { $0.name == name }, "no span \(name)")
    }

    func testSelfTimeSubtractsDirectChildrenOnly() throws {
        // outer [0, 100) ⊃ mid [10, 60) ⊃ leaf [20, 30); sibling [70, 90).
        let summary = summarize([[
            section("outer", "B", ts: 0),
            section("mid", "B", ts: 10),
            section("leaf", "B", ts: 20),
            section("leaf", "E", ts: 30),
            section("mid", "E", ts: 60),
            section("sibling", "B", ts: 70),
            section("sibling", "E", ts: 90),
            section("outer", "E", ts: 100),
        ]])
        XCTAssertEqual(try span(summary, "outer").total, 100)
        XCTAssertEqual(try span(summary, "outer").selfTime, 30)
        XCTAssertEqual(try span(summary, "mid").selfTime, 40)
        XCTAssertEqual(try span(summary, "leaf").selfTime, 10)
        XCTAssertEqual(try span(summary, "sibling").selfTime, 20)
        XCTAssertEqual(summary.spans.first?.name, "outer", "sorted by total, descending")
    }

    func testCompleteEventsInAnyOrderMatchRawPairs() throws {
        // Collapsed X events arrive child-first (in end order).
        let collapsed = [
            TraceEvent(name: "child", phase: "X", pid: 1, tid: 1, timestamp: 5, duration: 5),
            TraceEvent(name: "parent", phase: "X", pid: 1, tid: 1, timestamp: 0, duration: 20),
            TraceEvent(name: "other-thread", phase: "X", pid: 1, tid: 2, timestamp: 5, duration: 10),
        ]
        let summary = summarize([collapsed])
        XCTAssertEqual(try span(summary, "parent").selfTime, 15)
        XCTAssertEqual(try span(summary, "other-thread").selfTime, 10, "other threads are not children")
    }

    func testAsyncSpansPairByIdAcrossThreads() throws {
        let summary = summarize([[
            TraceEvent(name: "load", phase: "b", id: 7, pid: 1, tid: 1, timestamp: 0),
            TraceEvent(name: "load", phase: "b", id: 8, pid: 1, tid: 2, timestamp: 5),
            TraceEvent(name: "load", phase: "e", id: 7, pid: 1, tid: 3, timestamp: 40),
            TraceEvent(name: "load", phase: "e", id: 8, pid: 1, tid: 1, timestamp: 15),
            TraceEvent(name: "open", phase: "b", id: 9, pid: 1, tid: 1, timestamp: 50),
        ]])
        let load = try span(summary, "load")
        XCTAssertEqual(load.kind, .async)
        XCTAssertEqual(load.count, 2)
        XCTAssertEqual(load.total, 50)
        XCTAssertEqual(load.selfTime, 50)
        XCTAssertEqual(load.min, 10)
        XCTAssertEqual(load.max, 40)
        XCTAssertEqual(summary.unfinished, 1)
    }

    func testRunsCombineAndPercentilesUseNearestRank() throws {
        let runs = (1...20).map { index in
            [section("work", "B", ts: 0), section("work", "E", ts: UInt64(index) * 10)]
        }
        let work = try span(summarize(runs), "work")
        XCTAssertEqual(work.count, 20)
        XCTAssertEqual(work.p50, 100)
        XCTAssertEqual(work.p95, 190)
        XCTAssertEqual(work.mean, 105)
        XCTAssertEqual(summarize(runs).runs, 20)
    }

    func testUnmatchedEndIsIgnoredAndOpenBeginIsUnfinished() throws {
        let summary = summarize([[
            section("stray", "E", ts: 1),
            section("open", "B", ts: 2),
        ]])
        XCTAssertTrue(summary.spans.isEmpty)
        XCTAssertEqual(summary.unfinished, 1)
    }

    func testSummarizeReadsDirectoriesTraceJSONAndSavedSummaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appletrace-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        {"name":"step","cat":"appletrace","ph":"B","pid":1,"tid":0,"ts":10}
        {"name":"step","cat":"appletrace","ph":"E","pid":1,"tid":0,"ts":35}

        """.utf8).write(to: directory.appendingPathComponent("trace.appletrace"))

        let fromDirectory = try TraceStatistics.summarize([directory])
        XCTAssertEqual(try span(fromDirectory, "step").total, 25)

        let merged = try TraceMerger.merge(directory: directory)
        let fromJSON = try TraceStatistics.summarize([merged.output])
        XCTAssertEqual(fromJSON, fromDirectory)

        let wrapped = directory.appendingPathComponent("wrapped.json")
        let events = try JSONSerialization.jsonObject(with: Data(contentsOf: merged.output))
        try JSONSerialization.data(withJSONObject: ["traceEvents": events]).write(to: wrapped)
        XCTAssertEqual(try TraceStatistics.summarize([wrapped]), fromDirectory)

        let saved = directory.appendingPathComponent("summary.json")
        try fromDirectory.jsonData().write(to: saved)
        XCTAssertEqual(try TraceStatistics.summarize([saved]), fromDirectory)
        XCTAssertThrowsError(try TraceStatistics.summarize([saved, directory]))

        let combined = try TraceStatistics.summarize([directory, merged.output])
        XCTAssertEqual(combined.runs, 2)
        XCTAssertEqual(try span(combined, "step").count, 2)

        XCTAssertThrowsError(try TraceStatistics.summarize([directory.appendingPathComponent("missing")]))
        let garbage = directory.appendingPathComponent("garbage.json")
        try Data("{\"hello\":1}".utf8).write(to: garbage)
        XCTAssertThrowsError(try TraceStatistics.summarize([garbage]))
    }

    private func summary(_ spans: [(String, UInt64)]) -> TraceSummary {
        TraceSummary(runs: 1, unfinished: 0, spans: spans.map {
            SpanStatistics(name: $0.0, kind: .section, durations: [$0.1], selfTime: $0.1)
        })
    }

    func testComparisonClassifiesChanges() throws {
        let baseline = summary([("slower", 10_000), ("faster", 10_000), ("noise", 10_000), ("tiny", 100), ("gone", 5_000)])
        let current = summary([("slower", 12_000), ("faster", 8_000), ("noise", 10_900), ("tiny", 400), ("new", 5_000)])
        let comparison = TraceComparison(baseline: baseline, current: current)
        let status = Dictionary(uniqueKeysWithValues: comparison.changes.map { ($0.name, $0.status) })
        XCTAssertEqual(status["slower"], .regressed)
        XCTAssertEqual(status["faster"], .improved)
        XCTAssertEqual(status["noise"], .unchanged, "within the 10% threshold")
        XCTAssertEqual(status["tiny"], .unchanged, "+300% but under the 1 ms minimum delta")
        XCTAssertEqual(status["gone"], .removed)
        XCTAssertEqual(status["new"], .added)
        XCTAssertEqual(comparison.regressions.map(\.name), ["slower"])
        XCTAssertEqual(comparison.changes.first?.name, "slower", "regressions first")
        XCTAssertEqual(try XCTUnwrap(comparison.regressions.first?.relativeChange), 0.2, accuracy: 1e-9)

        let strict = TraceComparison(baseline: baseline, current: current,
                                     options: ComparisonOptions(threshold: 0.05, minimumDelta: 0))
        XCTAssertEqual(Set(strict.regressions.map(\.name)), ["slower", "noise", "tiny"])
    }

    func testComparisonFiltersByPrefixAndMetric() throws {
        let baseline = TraceSummary(runs: 1, unfinished: 0, spans: [
            SpanStatistics(name: "App.launch", kind: .section, durations: [10_000], selfTime: 10_000),
            SpanStatistics(name: "[UIView]layout", kind: .section, durations: [1_000], selfTime: 1_000),
        ])
        let current = TraceSummary(runs: 1, unfinished: 0, spans: [
            SpanStatistics(name: "App.launch", kind: .section, durations: [5_000, 5_000, 5_000], selfTime: 15_000),
            SpanStatistics(name: "[UIView]layout", kind: .section, durations: [9_000], selfTime: 9_000),
        ])
        let appOnly = TraceComparison(baseline: baseline, current: current, options: ComparisonOptions(prefixes: ["App."]))
        XCTAssertEqual(appOnly.changes.map(\.name), ["App.launch"])
        XCTAssertEqual(appOnly.regressions.map(\.name), ["App.launch"], "total went 10 ms → 15 ms")

        let byMean = TraceComparison(baseline: baseline, current: current,
                                     options: ComparisonOptions(metric: .mean, prefixes: ["App."]))
        XCTAssertEqual(byMean.changes.first?.status, .improved, "mean went 10 ms → 5 ms")

        let byCount = TraceComparison(baseline: baseline, current: current,
                                      options: ComparisonOptions(metric: .count, minimumDelta: 1, prefixes: ["App."]))
        XCTAssertEqual(byCount.regressions.map(\.name), ["App.launch"], "1 call → 3 calls")
    }

    func testDurationParsingAndFormatting() {
        XCTAssertEqual(DurationFormat.parse("1ms"), 1_000)
        XCTAssertEqual(DurationFormat.parse("1.5ms"), 1_500)
        XCTAssertEqual(DurationFormat.parse("500us"), 500)
        XCTAssertEqual(DurationFormat.parse("500µs"), 500)
        XCTAssertEqual(DurationFormat.parse("0.2s"), 200_000)
        XCTAssertEqual(DurationFormat.parse("250"), 250)
        XCTAssertNil(DurationFormat.parse("fast"))
        XCTAssertNil(DurationFormat.parse("-1ms"))
        XCTAssertEqual(DurationFormat.string(microseconds: 850), "850 µs")
        XCTAssertEqual(DurationFormat.string(microseconds: 12_340), "12.3 ms")
        XCTAssertEqual(DurationFormat.string(microseconds: 1_200_000), "1.20 s")
    }
}
