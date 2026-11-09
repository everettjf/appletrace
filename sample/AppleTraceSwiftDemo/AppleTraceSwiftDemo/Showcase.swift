//
//  Showcase.swift
//  A curated Swift workload that exercises BOTH Swift tracing routes and emits
//  a rich Perfetto timeline (nested spans, named worker threads, async arcs,
//  counters, instants).
//
//  Route 1 — macros / withSpan: source-level instrumentation that works for
//  final classes, structs, and protocol methods (dispatch-agnostic).
//  Route 2 — AppleTraceAuto: zero-annotation hooking of a non-final class
//  hierarchy via SwiftTrace.
//

import Foundation
import AppleTrace
import AppleTraceAuto

// MARK: - Route 2 subject (non-final, reached through a protocol so it is
// vtable-dispatched — what SwiftTrace can hook).

protocol ImageLoading {
    func load(_ index: Int)
}

class ImageLoader: ImageLoading {
    func load(_ index: Int) {
        readBytes(index)
        resize(index)
    }

    func readBytes(_ index: Int) { usleep(UInt32(1200 + (index % 3) * 400)) }
    func resize(_ index: Int) { usleep(1500) }
}

// MARK: - Route 1 subjects (macros).

@Traced
func warmCaches() {
    usleep(3000)
}

// @TraceAll stamps @Traced on every method — note this is a `final` class, the
// exact case SwiftTrace can't hook, which the macro covers cleanly.
@TraceAll
final class FeedViewModel {
    func reload() {
        parse()
        layout()
    }

    func parse() { usleep(900) }
    func layout() { usleep(700) }
}

// `async` functions get an async span (its own Perfetto track), so a call that
// resumes on another thread after `await` is still drawn as one slice.
actor FeedStore {
    private var pages = 0

    @Traced
    func refresh() async -> Int {
        try? await Task.sleep(nanoseconds: 4_000_000)
        pages += 1
        return pages
    }

    @Traced("FeedStore.prefetch")
    func prefetch(_ count: Int) async {
        for _ in 0..<count {
            await Task.yield()
            usleep(500)
        }
    }
}

// MARK: - The showcase

enum SwiftShowcase {
    /// Runs the whole workload and flushes. Returns the trace directory.
    static func run() -> String {
        Thread.current.name = "Coordinator"   // names this track in Perfetto

        // Route 2 (Simulator / macOS only): auto-trace the ImageLoader hierarchy
        // with no annotations. SwiftTrace patches vtable function pointers, which
        // are pointer-authenticated on real devices (arm64e-style signing), so it
        // is unsupported on-device — the macros below cover those cases there.
        #if targetEnvironment(simulator)
        AppleTraceAuto.trace(aClass: ImageLoader.self)
        defer { AppleTraceAuto.stop() }
        #endif

        traceInstant("scenario_start")

        // Phase 1 — startup on the coordinator thread (Route 1).
        withSpan("App Launch") {
            warmCaches()
            traceCounter("Config Keys", 142)
            FeedViewModel().reload()
        }
        traceInstant("first_frame_ready")

        // Phase 2 — parallel named workers.
        let group = DispatchGroup()

        runNamed("ImageDecoder", group: group) {
            let loader: ImageLoading = ImageLoader()   // protocol -> vtable -> SwiftTrace
            for i in 1...8 {
                loader.load(i)
                traceCounter("Images Decoded", Double(i))
            }
        }

        runNamed("NetworkClient", group: group) {
            asyncBegin("GET /feed.json", id: 1001)
            withSpan("TLS Handshake") { usleep(9000) }
            asyncBegin("GET /avatar.png", id: 1002)
            withSpan("Download Body") {
                usleep(13000)
                traceCounter("Bytes Received", 48 * 1024)
            }
            withSpan("Parse JSON") { usleep(6000) }
            asyncEnd("GET /avatar.png", id: 1002)
            asyncEnd("GET /feed.json", id: 1001)
        }

        runNamed("DatabaseWriter", group: group) {
            for batch in 1...5 {
                withSpan("Write batch #\(batch)") { usleep(4000) }
                traceCounter("Rows Written", Double(batch * 40))
            }
        }

        group.wait()

        // Phase 3 — a 60-frame render loop with live counters.
        runNamed("RenderLoop", group: group) {
            var memoryMB = 82.0
            for frame in 0..<60 {
                withSpan("Frame") {
                    withSpan("Layout") { usleep(800) }
                    withSpan("Tick Animations") { usleep(500) }
                    withSpan("Draw") { usleep(1200) }
                    withSpan("Composite") { usleep(600) }
                }
                var fps = 60.0
                if frame % 7 == 0 { fps -= 4 } else if frame % 3 == 0 { fps -= 1.5 }
                traceCounter("FPS", fps)
                memoryMB += (frame % 10 == 0) ? 6 : 0.6
                if frame % 17 == 0 { memoryMB -= 4 }
                traceCounter("Memory (MB)", memoryMB)
                if frame == 0 { traceInstant("first_rendered_frame") }
                if frame == 30 { traceInstant("user_scrolled") }
            }
        }
        group.wait()

        // Phase 4 — Swift concurrency: @Traced async methods hop threads freely.
        let store = FeedStore()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { tasks in
                for _ in 0..<3 {
                    tasks.addTask { _ = await store.refresh() }
                }
                tasks.addTask { await store.prefetch(4) }
            }
            done.signal()
        }
        done.wait()

        traceInstant("scenario_complete")
        flush()   // batched per thread; flush before reading the trace
        return traceDirectory
    }

    /// Runs `body` on a freshly-named thread (so it becomes its own Perfetto
    /// track) and joins it via `group`.
    private static func runNamed(_ name: String, group: DispatchGroup, _ body: @escaping () -> Void) {
        group.enter()
        let thread = Thread {
            Thread.current.name = name   // surfaces as the track name
            body()
            group.leave()
        }
        thread.name = name
        thread.start()
    }
}
