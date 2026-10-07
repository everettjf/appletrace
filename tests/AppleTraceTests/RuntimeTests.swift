//
//  RuntimeTests.swift
//  End-to-end check that the Swift API drives the C core and writes a trace.
//

import XCTest
@testable import AppleTrace

final class RuntimeTests: XCTestCase {
    func testWithSpanWritesFragment() throws {
        withSpan("unit-test-span") {
            _ = (1...1000).reduce(0, +)
        }
        traceInstant("unit-test-instant")
        traceCounter("unit-test-counter", 42)
        flush()

        let dir = traceDirectory
        let fragments = try FileManager.default
            .contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".appletrace") }
        XCTAssertFalse(fragments.isEmpty, "expected a trace fragment in \(dir)")

        let url = URL(fileURLWithPath: dir).appendingPathComponent(fragments[0])
        let bytes = try Data(contentsOf: url)
        // Fragments are zero-padded mmap blocks; strip the padding before search.
        let text = String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
        XCTAssertTrue(text.contains("unit-test-span"), "section name missing from trace")
        XCTAssertTrue(text.contains("unit-test-instant"), "instant missing from trace")
    }

    func testToggleEnabled() {
        let original = isEnabled
        setEnabled(false)
        XCTAssertFalse(isEnabled)
        setEnabled(true)
        XCTAssertTrue(isEnabled)
        setEnabled(original)
    }

    func testCaptureLifecycleAndMetrics() {
        stopCapture()
        XCTAssertEqual(captureState, .idle)

        XCTAssertTrue(startCapture())
        XCTAssertEqual(captureState, .recording)
        let before = traceMetrics.acceptedEvents
        traceInstant("capture-lifecycle-event")
        XCTAssertGreaterThanOrEqual(traceMetrics.acceptedEvents, before + 1)

        stopCapture()
        XCTAssertEqual(captureState, .idle)
        XCTAssertEqual(traceMetrics.writeFailures, 0)

        // Preserve the historical default for tests that follow in-process.
        XCTAssertTrue(startCapture())
    }
}
