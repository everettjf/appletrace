# Research: Tracing Swift Code in AppleTrace

Status: **Both routes implemented.** This document surveys how the industry
traces Swift, why AppleTrace's current `objc_msgSend` hook cannot, and lays out
the chosen direction: **source-level instrumentation via Swift macros as the
primary route**, with a SwiftTrace-backed runtime hook as the secondary route.

Implemented (SwiftPM package at the repo root — `Package.swift`, `Sources/`):
- **Primary (macros), `AppleTrace` target:** `withSpan(_:_:)` /
  `withAsyncSpan(_:_:)`, plus `beginSection` / `endSection` / `traceInstant` /
  `traceCounter` / `newAsyncID` / `asyncBegin` / `asyncEnd` / `flush` wrappers
  over the C core (string literals bind to `StaticString` overloads that pass
  the literal to the core without bridging); and `@Traced` / `@Traced("name")`
  (body macro) + `@TraceAll` (member-attribute macro, opt out with
  `@NotTraced`) that wrap function bodies in a span regardless of dispatch kind.
  Since 2.0 the span name is the signature qualified by its enclosing types
  (`FeedViewModel.reload(force:)`), and `async` functions get an async span
  (`b`/`e` with a per-call id) because an `await` may resume on another thread,
  which would break a same-thread begin/end section. Verified on Swift 6.2 with
  no experimental feature flags (`Tests/AppleTraceTests`) and on an iPhone 11
  (iOS 26.0.1).
- **Secondary (SwiftTrace bridge), `AppleTraceAuto` target:** bridges
  `johnno1962/SwiftTrace` so each traced method's entry/exit becomes an
  AppleTrace section (`AppleTraceAuto.trace(aClass:)` /
  `traceClasses(matchingPattern:)` / `traceBundle(containing:)`). Zero
  annotation; subject to SwiftTrace's blind spot (`final` / statically-dispatched
  methods — use the macros for those). **Simulator / macOS only**: SwiftTrace
  patches pointer-authenticated vtable slots, which is unsafe on real devices, so
  gate its use with `#if targetEnvironment(simulator)`. The macros are the
  on-device path. Verified via the runnable
  `AppleTraceAutoExample` target (`swift run AppleTraceAutoExample`); it can't be
  exercised from an XCTest bundle because SwiftTrace's metadata scanning needs a
  normal executable / app image.
- **Demo app:** `sample/AppleTraceSwiftDemo` (SwiftUI) consumes the local package
  and exercises both routes in one guided app — tap "Generate Trace" to run a
  multi-threaded workload (~490 events across 5 named tracks: macro-route spans,
  the SwiftTrace-hooked `ImageLoader`, counters, async arcs) and see the steps to
  open it in Perfetto. Verified on the iPhone 17 Simulator (~490 events, both
  routes) **and on a real iPhone 17 Pro** (~460 events, macro route only — the
  SwiftTrace route is `#if targetEnvironment(simulator)`-gated). Two device
  issues were fixed along the way: the app project needs
  `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks` or dyld can't load the
  embedded SwiftTrace framework; and the bridge subclasses the lightweight
  `Swizzle` (not `Decorated`, whose argument-reflection path hung in the iOS app
  context).

## 1. Problem

AppleTrace's automatic mode rebinds `objc_msgSend` (a fishhook-style symbol
rebind, see `appletrace/appletrace/src/objc/hook_objc_msgSend.m`) and records a
B/E pair around every Objective-C message send. That captures essentially all
Objective-C dynamic dispatch, but **most Swift calls never go through
`objc_msgSend`**, so a pure-Swift app is almost invisible to the auto-hook.

Swift deliberately avoids message dispatch for speed. Its calls resolve through
one of four mechanisms:

| Dispatch | Used for | Goes through `objc_msgSend`? |
|---|---|---|
| **Static** (direct branch to a symbol) | `struct` / `enum` methods, `final` classes, global/free functions, and most internal methods under Whole-Module Optimization | ❌ never |
| **vtable** (per-class function-pointer table) | non-`final` `class` methods | ❌ |
| **witness table** (per-conformance table) | `protocol` requirements | ❌ |
| **`objc_msgSend`** | only `@objc dynamic` members and overrides on `NSObject` subclasses | ✅ |

Consequence: in a modern Swift codebase the auto-hook sees only the thin `@objc`
surface. This is a structural limitation of the technique, not a bug. (Background:
[Method Dispatch in Swift](https://blog.jacobstechtavern.com/p/swift-method-dispatch),
[ObjC vs Swift dispatch](https://www.untitledkingdom.com/blog/objective-c-vs-swift-messages-dispatch).)

## 2. Landscape of approaches

Five families of solution exist, with representative open-source projects.

### 2.1 Sampling / backtrace (language-agnostic) — *root fix*

Instead of hooking each method, periodically capture the call stack of every
thread (or capture a synchronous backtrace at a few high-frequency native
trigger points), symbolicate, then diff consecutive stacks to reconstruct
per-function durations as Perfetto slices. Because it works on **native call
stacks**, it covers Swift, C, and Objective-C uniformly.

- **[bytedance/btrace (RheaTrace)](https://github.com/bytedance/btrace)** — the
  closest comparable to AppleTrace: **also Perfetto-based**, supports iOS,
  embeddable, no Instruments required. btrace 3.0 uses a **hybrid model**:
  *synchronous* backtraces triggered by hooks on high-frequency native points
  (allocation, locks, I/O) plus *asynchronous* periodic sampling of all threads
  for continuity. It computes durations by comparing consecutive stacks, then
  emits Perfetto. (See its
  [INTRODUCTION](https://github.com/bytedance/btrace/blob/master/INTRODUCTION.MD).)
- Apple **Instruments → Time Profiler** — same idea (periodic sampling), but
  not embeddable and doesn't export Perfetto.

  - Coverage: ★★★ (all languages). Accuracy: statistical, not exact enter/exit.
  - Effort: ★★★ (high). Risk: async-signal-safe stack walking, thread
    suspension/dedup, symbolication, overhead control.

### 2.2 Swift runtime metadata hooking — *precise, with blind spots*

Patch Swift class **vtables** (and patchable **witness tables**) so each slot
points at a trampoline that logs the method, then chains to the original.

- **[johnno1962/SwiftTrace](https://github.com/johnno1962/SwiftTrace)** — mature
  (8 yrs). Replaces vtable pointers with an assembly trampoline. Can trace
  non-`final` class methods and struct methods reached **through a protocol**
  (witness table is patchable). **Cannot** trace `final`/internal methods under
  WMO because those are statically linked at the call site — explicitly stated
  in its README.
- **[p-x9/swift-hook](https://github.com/p-x9/swift-hook)** — newer Swift method
  /function hooking library in the same spirit.

  - Coverage: ★★ (misses static dispatch). Accuracy: exact per-method.
  - Effort: ★★ (medium). Risk: tracks Swift ABI / metadata layout, fragile
    across toolchain versions.

### 2.3 Compiler instrumentation — *fullest coverage, needs a rebuild*

Clang's **`-finstrument-functions`** inserts `__cyg_profile_func_enter/exit`
calls at every function boundary
([how it works](https://balau82.wordpress.com/2010/10/06/trace-and-profile-function-calls-with-gcc/)).
For C/C++/Objective-C this catches **everything, including static dispatch**.

  - Caveat for Swift: there is **no first-class Swift frontend equivalent**.
    Options would be a SIL instrumentation pass or repurposing
    `-sanitize-coverage=func` (built for fuzzing) — both non-trivial and
    unofficial. Realistically this path covers the C/C++/ObjC parts of a mixed
    app well, and Swift only with significant toolchain work.
  - Coverage: ★★★ (C/C++/ObjC), Swift TBD. Accuracy: exact. Effort: ★★ for
    ObjC/C++, ★★★ for Swift. Risk: must compile target with the flag; large
    overhead; not usable on prebuilt frameworks.

### 2.4 os_signpost / manual instrumentation bridge — *low effort*

Apple's **os_signpost** ("Points of Interest") is the official low-overhead
manual primitive, visualized in Instruments. The AppleTrace analogue is simply
giving Swift users an ergonomic manual API on top of the existing pipeline.

  - Coverage: only what the developer marks. Effort: ★ (low). Risk: minimal.

### 2.5 Interpose / dynamic replacement — *single-point only*

- **[steipete/InterposeKit](https://github.com/steipete/InterposeKit)**, Swift's
  `@_dynamicReplacement` — good for hooking specific functions, not whole-app
  tracing. Not a fit for "trace everything," but useful building blocks.

## 3. Recommendation for AppleTrace (phased)

Given AppleTrace's positioning (lightweight, embeddable, Perfetto-only, arm64),
go low-risk → root-fix:

- **Phase 1 — Swift-friendly manual API (quick win, low risk).** A Swift overlay
  exposing the existing `APT*` calls idiomatically: a scoped `withSpan("…") {}`,
  `APTBeginSection`/`APTEndSection` wrappers, instants/counters/async, and —
  Swift 5.9+ — a `@Traced` **macro** that wraps a function body in begin/end.
  Reuses the current writer/merge pipeline; near-zero runtime risk; immediately
  unblocks Swift users for the code they care about.

- **Phase 2 — sampling/backtrace tracer (the actual Swift fix).** Follow btrace's
  asynchronous model: periodic multi-thread stack capture + arm64 unwinding +
  symbolication (`dladdr` + `swift_demangle`) + stack-diffing into Perfetto
  slices. This is what genuinely makes pure Swift traceable automatically.
  Largest effort; highest payoff.

- **Phase 3 — optional precision add-ons.**
  - 3a: SwiftTrace-style vtable/witness hooking for exact per-method traces
    (accepting the `final`/static blind spot).
  - 3b: opt-in `-finstrument-functions` for users who control their build and
    want exact, full coverage of the C/C++/ObjC layers.

## 4. Decision points

1. **Precise vs. complete:** exact per-method (hook-based, has blind spots) or
   statistical-but-complete (sampling, the btrace route)?
2. **Rebuild acceptable?** Is requiring `-finstrument-functions` / a custom
   build step acceptable for any user segment, or must we work on prebuilt apps?
3. **Phase 1 standalone?** Ship the Swift manual API + `@Traced` macro first for
   fast value, independent of the bigger Phase 2 work?
4. **Overhead budget & accuracy bar:** what runtime overhead and timing
   resolution are acceptable in production-like builds?

## 5. References

- AppleTrace internals: `appletrace/appletrace/src/objc/hook_objc_msgSend.m`,
  `docs/perf-batching-design.md`, `docs/binary-fragment-format.md`.
- [bytedance/btrace](https://github.com/bytedance/btrace) ·
  [INTRODUCTION](https://github.com/bytedance/btrace/blob/master/INTRODUCTION.MD)
- [johnno1962/SwiftTrace](https://github.com/johnno1962/SwiftTrace) ·
  [p-x9/swift-hook](https://github.com/p-x9/swift-hook) ·
  [steipete/InterposeKit](https://github.com/steipete/InterposeKit)
- [Method Dispatch in Swift](https://blog.jacobstechtavern.com/p/swift-method-dispatch) ·
  [ObjC vs Swift dispatch](https://www.untitledkingdom.com/blog/objective-c-vs-swift-messages-dispatch)
- [`-finstrument-functions` overview](https://balau82.wordpress.com/2010/10/06/trace-and-profile-function-calls-with-gcc/)
</content>
