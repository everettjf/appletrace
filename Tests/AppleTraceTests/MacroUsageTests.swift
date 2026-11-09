//
//  MacroUsageTests.swift
//  Compiles and runs code that actually applies @Traced / @TraceAll, proving
//  the macros work end-to-end (not just in expansion tests) and emit events.
//

import XCTest
@testable import AppleTrace

@Traced
private func tracedFreeFunction() {
    _ = (1...10).reduce(0, +)
}

@TraceAll
private final class TracedSample {
    func alpha() {
        beta()
    }

    func beta() {
        _ = (1...10).reduce(0, +)
    }

    @NotTraced
    func skipped() {}
}

@TraceAll
private struct OtherSample {
    func alpha() {}
}

private actor AsyncSample {
    var value = 0

    @Traced
    func refresh() async throws -> Int {
        try await Task.sleep(nanoseconds: 2_000_000)
        value += 1
        return value
    }

    @Traced("async-sample.custom")
    func custom() async {
        await Task.yield()
    }
}

final class MacroUsageTests: XCTestCase {
    func testMacrosEmitQualifiedSections() throws {
        tracedFreeFunction()
        TracedSample().alpha()
        TracedSample().skipped()
        OtherSample().alpha()

        let events = try TraceReader.events()
        let names = Set(events.map(\.name))
        XCTAssertTrue(names.contains("tracedFreeFunction()"), "@Traced free function missing")
        XCTAssertTrue(names.contains("TracedSample.alpha()"), "@TraceAll method alpha missing")
        XCTAssertTrue(names.contains("TracedSample.beta()"), "@TraceAll method beta missing")
        XCTAssertTrue(names.contains("OtherSample.alpha()"), "same-named method on another type must be distinct")
        XCTAssertFalse(names.contains("TracedSample.skipped()"), "@NotTraced member was traced")

        let alpha = events.filter { $0.name == "TracedSample.alpha()" }
        XCTAssertEqual(alpha.map(\.phase), ["B", "E"])
    }

    func testTracedAsyncFunctionsEmitMatchedAsyncSpans() async throws {
        let sample = AsyncSample()
        for _ in 0..<5 {
            _ = try await sample.refresh()
        }
        await sample.custom()

        let events = try TraceReader.events()
        let refresh = events.filter { $0.name == "AsyncSample.refresh()" }
        XCTAssertEqual(refresh.count, 10)
        XCTAssertTrue(refresh.allSatisfy { $0.phase == "b" || $0.phase == "e" }, "async functions must use async spans")
        let ids = Dictionary(grouping: refresh, by: { $0.id ?? 0 })
        XCTAssertEqual(ids.count, 5, "each call needs its own span id")
        for (_, pair) in ids {
            XCTAssertEqual(pair.map(\.phase).sorted(), ["b", "e"])
        }
        XCTAssertEqual(events.filter { $0.name == "async-sample.custom" }.map(\.phase).sorted(), ["b", "e"])
    }
}
