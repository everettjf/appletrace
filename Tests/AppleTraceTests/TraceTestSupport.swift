//
//  TraceTestSupport.swift
//  Reads back what the runtime wrote, through the same decoder the CLI uses.
//

import AppleTrace
import AppleTraceKit
import Foundation

enum TraceReader {
    /// Flushes and returns every raw event (no B/E collapsing) recorded so far
    /// by this test process.
    static func events() throws -> [TraceEvent] {
        AppleTrace.flush()
        let directory = URL(fileURLWithPath: AppleTrace.traceDirectory)
        return try TraceMerger.events(in: directory, options: MergeOptions(completeEvents: false))
    }

    /// Events whose name is `name`.
    static func events(named name: String) throws -> [TraceEvent] {
        try events().filter { $0.name == name }
    }

    /// A name unique to one test run, so tests sharing the process-wide trace
    /// never see each other's events.
    static func uniqueName(_ base: String) -> String {
        "\(base)-\(UUID().uuidString.prefix(8))"
    }
}
