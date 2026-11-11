//
//  AppleTraceAutoExample
//  Runnable demonstration + smoke check for both Swift tracing routes.
//
//  Run it with:
//      APPLETRACE_DATA_DIR=/tmp/aptdemo swift run AppleTraceAutoExample
//  then merge and open the trace:
//      swift run appletrace open /tmp/aptdemo   # merge + open in Perfetto
//
//  It also doubles as the verification for the SwiftTrace bridge, which can't
//  be exercised from an XCTest bundle (SwiftTrace's metadata scanning needs a
//  normal executable / app image). Exits non-zero if the bridge didn't trace.
//

import Foundation
import AppleTrace
import AppleTraceAuto

// MARK: - A small workload

// Reached through a protocol so calls dispatch dynamically — what the
// SwiftTrace route can hook. (final / exact-typed calls are devirtualized and
// only the @Traced / @TraceAll macros can see them.)
protocol Service {
    func fetch()
    func parse()
}

// Note: not `final`. A final class is statically dispatched, which SwiftTrace
// can't hook (use @Traced / @TraceAll for those); this is the route's blind spot.
class FeedService: Service {
    func fetch() { Thread.sleep(forTimeInterval: 0.002) }
    func parse() { Thread.sleep(forTimeInterval: 0.001) }
}

// MARK: - Run

// Secondary route: zero-annotation auto-tracing via SwiftTrace.
AppleTraceAuto.trace(aClass: FeedService.self)

// Primary route: explicit scoped span (works regardless of dispatch).
withSpan("startup") {
    let service: Service = FeedService()
    for _ in 0..<3 {
        service.fetch()
        service.parse()
    }
}
traceInstant("ready")
flush()

// Verify the bridge actually captured the auto-traced methods. Binary
// fragments (the default) keep names in a plain string table, and text
// fragments are JSON lines, so a substring search works for both.
let dir = traceDirectory
let fragments = (try? FileManager.default
    .contentsOfDirectory(atPath: dir)
    .filter { $0.hasSuffix(".appletracebin") || $0.hasSuffix(".appletrace") }) ?? []
let text = fragments.reduce(into: "") { result, name in
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    if let data = try? Data(contentsOf: url) {
        result += String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }
}

let tracedFetch = text.contains("fetch")
let tracedParse = text.contains("parse")
let hasSpan = text.contains("startup")

print("AppleTrace example → directory: \(dir)")
print("  manual span 'startup': \(hasSpan ? "✅" : "❌")")
print("  SwiftTrace auto fetch(): \(tracedFetch ? "✅" : "❌")")
print("  SwiftTrace auto parse(): \(tracedParse ? "✅" : "❌")")
print("Open with:  swift run appletrace open \"\(dir)\"")

exit(hasSpan && tracedFetch && tracedParse ? 0 : 1)
