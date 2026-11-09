//
//  RuntimeTests.swift
//  End-to-end checks that the Swift API drives the C core and writes a trace
//  that decodes correctly.
//

import AppleTraceKit
import Dispatch
import XCTest
@testable import AppleTrace

final class RuntimeTests: XCTestCase {
    func testDefaultFormatIsBinary() throws {
        withSpan("runtime-format-probe") {}
        flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: traceDirectory)
        if ProcessInfo.processInfo.environment["APPLETRACE_FORMAT"] == nil,
           ProcessInfo.processInfo.environment["APPLETRACE_BINARY"] == nil {
            XCTAssertTrue(names.contains("trace.appletracebin"), "binary fragment expected, got \(names)")
        }
    }

    func testSpanInstantCounterRoundTrip() throws {
        withSpan("unit-test-span") {
            _ = (1...1000).reduce(0, +)
        }
        traceInstant("unit-test-instant")
        traceCounter("unit-test-counter", 42)
        traceCounter("unit-test-counter-fraction", 2.5)

        let events = try TraceReader.events()
        let span = events.filter { $0.name == "unit-test-span" }
        XCTAssertEqual(span.map(\.phase), ["B", "E"])
        XCTAssertEqual(events.first { $0.name == "unit-test-instant" }?.phase, "i")
        XCTAssertEqual(events.first { $0.name == "unit-test-counter" }?.argument("value"), .integer(42))
        XCTAssertEqual(events.first { $0.name == "unit-test-counter-fraction" }?.argument("value"), .double(2.5))
        XCTAssertTrue(events.contains { $0.phase == "M" && $0.name == "process_name" })
        XCTAssertTrue(events.contains { $0.phase == "M" && $0.name == "thread_name" })
    }

    func testDynamicStringNames() throws {
        let name = TraceReader.uniqueName("dynamic")
        beginSection(name)
        endSection(name)
        withSpan(name + "-closure") {}

        XCTAssertEqual(try TraceReader.events(named: name).map(\.phase), ["B", "E"])
        XCTAssertEqual(try TraceReader.events(named: name + "-closure").map(\.phase), ["B", "E"])
    }

    func testNestedSpansCollapseIntoNestedCompleteEvents() throws {
        let outer = TraceReader.uniqueName("outer")
        let inner = TraceReader.uniqueName("inner")
        withSpan(outer) {
            withSpan(inner) {
                usleep(2000)
            }
        }
        flush()

        let all = try TraceMerger.events(in: URL(fileURLWithPath: traceDirectory))
        let outerEvent = try XCTUnwrap(all.first { $0.name == outer })
        let innerEvent = try XCTUnwrap(all.first { $0.name == inner })
        XCTAssertEqual(outerEvent.phase, "X")
        XCTAssertEqual(innerEvent.phase, "X")
        XCTAssertEqual(outerEvent.tid, innerEvent.tid)
        let outerStart = try XCTUnwrap(outerEvent.timestamp)
        let innerStart = try XCTUnwrap(innerEvent.timestamp)
        XCTAssertLessThanOrEqual(outerStart, innerStart)
        XCTAssertLessThanOrEqual(innerStart + (innerEvent.duration ?? 0), outerStart + (outerEvent.duration ?? 0))
        XCTAssertGreaterThanOrEqual(innerEvent.duration ?? 0, 1000)
    }

    func testConcurrentSpansAreBalancedPerThread() throws {
        let name = TraceReader.uniqueName("concurrent")
        let iterations = 64
        let perIteration = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            for _ in 0..<perIteration {
                withSpan(name) {}
            }
        }

        let events = try TraceReader.events(named: name)
        XCTAssertEqual(events.count, iterations * perIteration * 2)
        let byThread = Dictionary(grouping: events, by: \.tid)
        XCTAssertGreaterThan(byThread.count, 1, "expected work on several threads")
        for (tid, threadEvents) in byThread {
            var depth = 0
            for event in threadEvents {
                depth += event.phase == "B" ? 1 : -1
                XCTAssertGreaterThanOrEqual(depth, 0, "end before begin on thread \(tid)")
            }
            XCTAssertEqual(depth, 0, "unbalanced sections on thread \(tid)")
        }
    }

    func testDisabledTracingRecordsNothing() throws {
        let name = TraceReader.uniqueName("disabled")
        let original = isEnabled
        setEnabled(false)
        XCTAssertFalse(isEnabled)
        withSpan(name) {}
        traceInstant(name)
        traceCounter(name, 1)
        let id = newAsyncID()
        asyncBegin(name, id: id)
        asyncEnd(name, id: id)
        setEnabled(true)
        XCTAssertTrue(isEnabled)
        setEnabled(original)

        XCTAssertEqual(try TraceReader.events(named: name), [])
    }

    func testAsyncSpanAcrossThreads() throws {
        let name = TraceReader.uniqueName("async-api")
        let id = newAsyncID()
        XCTAssertNotEqual(id, newAsyncID(), "async ids must be unique")
        asyncBegin(name, id: id)
        let done = expectation(description: "ended on another thread")
        Thread.detachNewThread {
            asyncEnd(name, id: id)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        // Fragments are ordered per thread, not globally; viewers sort by ts.
        let events = try TraceReader.events(named: name).sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        XCTAssertEqual(events.map(\.phase), ["b", "e"])
        XCTAssertEqual(Set(events.compactMap(\.id)), [id])
        XCTAssertEqual(Set(events.map(\.tid)).count, 2, "begin and end should be on different threads")
    }

    func testWithAsyncSpanSurvivesSuspension() async throws {
        let name = TraceReader.uniqueName("with-async")
        let value = try await withAsyncSpan(name) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 5_000_000)
            return 7
        }
        XCTAssertEqual(value, 7)

        let events = try TraceReader.events(named: name).sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        XCTAssertEqual(events.map(\.phase), ["b", "e"])
        XCTAssertEqual(events.compactMap(\.id).count, 2)
        XCTAssertEqual(Set(events.compactMap(\.id)).count, 1)
    }

    func testObjCMsgSendHookIsLinkedButNotInstalledByDefault() {
        // The hook ships in the SwiftPM package (CAppleTrace). Installing it
        // inside the XCTest host is not done here; `swift run
        // AppleTraceAutoExample --hook` and the device scripts exercise it.
        XCTAssertFalse(isObjCMsgSendHookInstalled)
    }
}
