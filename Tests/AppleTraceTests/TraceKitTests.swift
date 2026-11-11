//
//  TraceKitTests.swift
//  Fragment decoding and merging (AppleTraceKit), including the tolerance
//  rules for fragments left behind by a killed process.
//

import AppleTraceKit
import Foundation
import XCTest

final class TraceKitTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appletrace-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ data: Data) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func binaryFragment(pid: UInt32, records: [(UInt8, UInt32, UInt64, UInt64, UInt64)], strings: [(UInt32, String)]) -> Data {
        var data = Data("APLTRC01".utf8)
        withUnsafeBytes(of: pid.littleEndian) { data.append(contentsOf: $0) }
        for (id, string) in strings {
            data.append(0x01)
            withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(string.utf8.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: Array(string.utf8))
        }
        for (phase, id, tid, ts, arg) in records {
            data.append(phase)
            withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: tid.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: ts.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: arg.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testFragmentsSortByNumericSuffix() throws {
        for name in ["trace_10.appletrace", "trace.appletracebin", "trace_2.appletrace", "notes.txt", "trace_x.appletrace"] {
            try write(name, Data())
        }
        XCTAssertEqual(
            try FragmentDecoder.fragments(in: directory).map(\.lastPathComponent),
            ["trace.appletracebin", "trace_2.appletrace", "trace_10.appletrace"]
        )
    }

    func testBinaryDecodingSharesStringsAcrossFragmentsAndStopsAtPadding() throws {
        let B = UInt8(ascii: "B"), E = UInt8(ascii: "E"), C = UInt8(ascii: "C"), M = UInt8(ascii: "M")
        var first = binaryFragment(
            pid: 9,
            records: [(M, 1, 0, 0, 2), (B, 0, 5, 10, 0), (C, 3, 5, 11, 2.5.bitPattern)],
            strings: [(0, "work"), (1, "thread_name"), (2, "Main Thread"), (3, "fps")]
        )
        first.append(Data(repeating: 0, count: 64))  // mmap padding
        try write("trace.appletracebin", first)
        // The second fragment references "work" (id 0) defined in the first.
        try write("trace_1.appletracebin", binaryFragment(pid: 9, records: [(E, 0, 5, 30, 0)], strings: []))

        let events = try TraceMerger.events(in: directory)
        XCTAssertEqual(events.map(\.phase), ["M", "C", "X"])
        XCTAssertEqual(events[0].argument("name"), .string("Main Thread"))
        XCTAssertEqual(events[1].argument("value"), .double(2.5))
        XCTAssertEqual(events[2].name, "work")
        XCTAssertEqual(events[2].timestamp, 10)
        XCTAssertEqual(events[2].duration, 20)
        XCTAssertEqual(events[2].pid, 9)
    }

    func testTaskRecordNamesTheFollowingAsyncBegin() throws {
        let T = UInt8(ascii: "T"), b = UInt8(ascii: "b"), e = UInt8(ascii: "e")
        let data = binaryFragment(
            pid: 4,
            records: [(T, 1, 3, 10, 77), (b, 0, 3, 10, 77), (b, 0, 3, 11, 78), (e, 0, 5, 20, 77)],
            strings: [(0, "FeedStore.refresh()"), (1, "refresh-task")]
        )
        let events = try FragmentDecoder.decode(data)
        XCTAssertEqual(events.map(\.phase), ["b", "b", "e"], "the T record itself is not an event")
        XCTAssertEqual(events[0].argument("task"), .string("refresh-task"))
        XCTAssertEqual(events[0].id, 77)
        XCTAssertNil(events[1].argument("task"), "only the begin with the same id gets the name")
        XCTAssertNil(events[2].argument("task"))

        let text = Data("""
        {"name":"load","cat":"appletrace","ph":"b","id":5,"pid":1,"tid":0,"ts":1,"args":{"task":"loader"}}

        """.utf8)
        XCTAssertEqual(try FragmentDecoder.decode(text).first?.argument("task"), .string("loader"))
    }

    func testUndefinedStringIsAnError() {
        let data = binaryFragment(pid: 1, records: [(UInt8(ascii: "B"), 42, 0, 0, 0)], strings: [])
        XCTAssertThrowsError(try FragmentDecoder.decode(data))
    }

    func testTextDecodingToleratesTruncatedTailFromKilledProcess() throws {
        var text = Data("""
        {"name":"process_name","ph":"M","pid":3,"tid":0,"args":{"name":"Demo \\"App\\""}}
        {"name":"a","cat":"appletrace","ph":"B","pid":3,"tid":0,"ts":1}
        {"name":"a","cat":"appletrace","ph":"E","pid":3,"tid":0,"ts":4}
        {"name":"b","cat":"appl
        """.utf8)
        text.append(Data(repeating: 0, count: 128))
        try write("trace.appletrace", text)

        let events = try TraceMerger.events(in: directory)
        XCTAssertEqual(events.map(\.phase), ["M", "X"])
        XCTAssertEqual(events[0].argument("name"), .string("Demo \"App\""))
        XCTAssertEqual(events[1].duration, 3)
    }

    func testCorruptLineInTheMiddleIsAnError() throws {
        try write("trace.appletrace", Data("""
        {"name":"a","ph":"B","pid":1,"tid":0,"ts":1}
        {"name":
        {"name":"a","ph":"E","pid":1,"tid":0,"ts":2}

        """.utf8))
        XCTAssertThrowsError(try TraceMerger.events(in: directory))
    }

    func testMergeWritesValidJSONAndKeepsUnmatchedEvents() throws {
        try write("trace.appletrace", Data("""
        {"name":"open","cat":"appletrace","ph":"B","pid":1,"tid":7,"ts":1}
        {"name":"stray","cat":"appletrace","ph":"E","pid":1,"tid":8,"ts":2}
        {"name":"job","cat":"appletrace","ph":"b","id":5,"pid":1,"tid":7,"ts":3}

        """.utf8))
        let summary = try TraceMerger.merge(directory: directory)
        XCTAssertEqual(summary.eventCount, 3)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: summary.output)) as? [[String: Any]]
        XCTAssertEqual(json?.compactMap { $0["ph"] as? String }, ["E", "b", "B"])
        XCTAssertEqual(json?[1]["id"] as? Int, 5)

        let raw = try TraceMerger.merge(directory: directory, output: directory.appendingPathComponent("raw.json"),
                                        options: MergeOptions(completeEvents: false))
        XCTAssertEqual(raw.eventCount, 3)
    }

    func testMissingDirectoryAndEmptyDirectoryFail() throws {
        XCTAssertThrowsError(try TraceMerger.events(in: directory.appendingPathComponent("missing")))
        XCTAssertThrowsError(try TraceMerger.events(in: directory))
    }
}
