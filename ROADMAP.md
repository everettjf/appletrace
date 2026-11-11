# AppleTrace Roadmap

Status as of 2.1.0 (November 2026). Items marked ✅ have shipped; see
[CHANGELOG.md](CHANGELOG.md) for details.

## 1. Where We Are

- **Capture**: manual sections and events (`APTBeginSection`, `APTInstant`,
  `APTCounter`, `APTAsyncBegin`/`APTAsyncEnd`), Swift `@Traced` / `@TraceAll`
  macros (type-qualified names, async spans for `async` functions), and the
  arm64/arm64e `objc_msgSend` / `objc_msgSendSuper2` hook (PAC-aware, rebinding
  images loaded later too).
- **Runtime**: per-thread buffers shipped in order to a serial writer that
  appends to memory-mapped fragments. Binary format by default; the text path
  formats straight into the thread buffer. Buffers drain every second, on
  backgrounding and at exit, so killed processes leave readable traces.
- **Tooling**: the Swift `appletrace` CLI (`merge`, `open`, `devices`, `pull`,
  `record`, `jb …`) built on `AppleTraceKit`. The Python `merge.py` remains for
  compatibility.
- **Distribution**: SwiftPM (`AppleTrace`, `AppleTraceAuto`, `AppleTraceKit`,
  `appletrace`), an XCFramework and CLI binary on each release, and
  rootless / roothide `.deb` packages for the jailbreak loader.
- **Validation**: Swift tests (macros, runtime, async, concurrency, disabled
  tracing, decoder tolerance), a host stress test across 13 writer
  configurations, a host hook test, Simulator hook tests, and on-device runs on
  an iPhone 17 Pro (iOS 27, arm64e) and an iPhone 11 (iOS 26.0.1, arm64 and
  arm64e, plus roothide).

## 2. Landscape (November 2026)

| Tool | Mechanism | Where it stands | Relation to AppleTrace |
|------|-----------|-----------------|------------------------|
| Instruments 27 | Sampling, signposts, Processor Trace | Adds Top Functions, a Swift Concurrency profile with call trees, a Swift Executors instrument, os_log overlays on thread tracks | Processor Trace still needs A18 / M4; no CI story, no Perfetto output |
| Perfetto (v54–v58) | Trace format + UI + Trace Processor | `util merge` combines traces; Trace Processor loads URLs and imports Instruments XML exports (with clock sync); new Data Explorer | Our viewer. Native import of Instruments exports makes our own converter unnecessary |
| Sentry UI Profiling, Datadog iOS Profiler, OpenTelemetry Swift 2.x / Embrace | Production sampling + RUM spans | Sentry GA (sentry-cocoa 9); Datadog in preview; OTel Swift 2.4 | Production monitoring; AppleTrace stays the exact, local, dev/CI tracer |
| ETTrace | Sampling + flame charts | Emerge Tools joined Sentry (May 2025) | Few standalone open-source iOS tracers remain |
| Swift Profile Recorder | In-process sampling | Open source (Oct 2025), server-side Swift | Not for iOS apps |
| frida 17.x | Dynamic instrumentation | Interceptor fixed on iOS 26+ (17.9.7); jailed spawn on 26.4 | Shows inline hooking works on iOS 26; heavier and script-driven |
| Jailbreaks | Dopamine 3.0 | iOS 26.0–26.0.1 on A12/A13 only | The jailbreak route serves a narrow device window; keep it lean |

Also relevant: Swift 6.2 task names (SE-0469, readable as `Task.name`) and
Enhanced Security / Memory Integrity Enforcement (hardened-process
entitlements on A19 devices), which may affect in-process hooking.

AppleTrace's niche: an embeddable, open-source tracer that records **exact**
ObjC and Swift call timelines on any device and OS version, gates performance
in CI, and opens in Perfetto — including in third-party apps on jailbroken
devices.

## 3. Plan

### Phase 1 — Correctness & workflow (2.0) ✅
- ✅ Async-safe `@Traced`; type-qualified names; `@Traced("name")`; `@NotTraced`.
- ✅ `StaticString` fast paths for literal names; `APTNewAsyncID`.
- ✅ Binary format by default; allocation-free text formatting; pointer-cached
  binary name ids; ordered batch shipping.
- ✅ Background / lifecycle / exit draining; strict config parsing.
- ✅ `objc_msgSend` hook in SwiftPM; stub on non-arm64; rebinding for late images.
- ✅ `appletrace` CLI replacing the Python pipeline.
- ✅ Rootless / roothide jailbreak loader + `appletrace jb`.
- ✅ Regression coverage for nesting, concurrency, disabled tracing, malformed
  configuration, killed processes, and rollover.

### Phase 2 — CI performance gates (2.1) ✅
The gap no other tool fills: exact, reproducible timings checked in CI.
- ✅ `appletrace summary <dir|trace.json>...`: per-span count, total, self,
  mean, p50, p95 and max, as a table or `--json`; several runs combine.
- ✅ `appletrace diff <base> <new> --threshold 10%`: compares traces or saved
  summaries and exits 2 on regressions, for pull-request checks.
- ✅ A Simulator recording loop and GitHub Actions job
  ([docs/ci-performance-gates.md](docs/ci-performance-gates.md)).
- ✅ Swift task names (Swift 6.2+, `Task.name`) recorded on async spans.

### Phase 3 — Native Perfetto output (2.2)
- Emit Perfetto protobuf (`TrackEvent`) from `AppleTraceKit`: smaller files,
  faster loading, interned names.
- Per-`Task` tracks for Swift concurrency (named by `Task.name`), and flow
  events linking `dispatch_async` submit/execute.
- Debug annotations (arguments) on sections, behind an opt-in API.
- A clock-sync marker so an AppleTrace trace and an Instruments export
  (`xctrace export`, which Perfetto imports natively) line up when combined with
  Perfetto's `util merge`. This replaces the earlier plan to write our own
  Instruments converter.

### Phase 4 — Complementary capture
- `os_signpost` backend: the same API, visible in Instruments 27 next to its
  Swift Concurrency and Top Functions views.
- Hook `objc_alloc_init` / `objc_opt_class` / `objc_opt_self` so
  compiler-lowered sends appear in automatic traces.
- Verify the hook in an app that turns on Enhanced Security (hardened process,
  MIE checked allocations) on the A19 iPhone 17 Pro, and document the result;
  so far it is validated only in apps without those entitlements.
- Jailbreak loader: optional inline hook of `objc_msgSend` through ElleKit's
  `MSHookFunction`, for apps whose `__DATA_CONST` is sealed (Apple's apps on
  iOS 26) and sends between system frameworks. Scoped to the devices
  jailbreakable today (A12/A13, iOS 26.0–26.0.1); also verify the rootless
  package on Dopamine 3.

### Phase 5 — Distribution
- Homebrew tap for the CLI; notarized release binaries.
- Sileo/Zebra repository (GitHub Pages) for the loader packages.

### Non-goals
- A sampling profiler, on device or in production (Instruments, Sentry,
  Datadog cover it).
- Production RUM or a hosted backend; an OpenTelemetry exporter may come later
  as an adapter, not a core feature.
- Frida-style scripting.
- An x86_64 `objc_msgSend` hook.
- Our own Instruments-to-Perfetto converter (Perfetto imports Instruments XML).
