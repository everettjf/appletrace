# AppleTrace Roadmap

Status as of 2.0.0 (November 2026). Items marked ✅ have shipped; see
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
  tracing, decoder tolerance), a host stress test across 10 writer
  configurations, a host hook test, Simulator hook tests, and on-device runs on
  an iPhone 17 Pro (iOS 27) and an iPhone 11 (iOS 26.0.1).

## 2. Positioning

| Tool | Mechanism | Strength | Relation to AppleTrace |
|------|-----------|----------|------------------------|
| Instruments Processor Trace | Hardware trace (A18 / M4+, iOS 18.4+) | Every call, Swift included, ~1% overhead | Needs recent hardware and Instruments; no CI, no Perfetto export |
| `os_signpost` / OSSignposter | OS logging | First-party, low overhead | Candidate backend (see Phase 3) |
| ETTrace | Sampling + flame charts | One-command setup | Sampling, not exact per-call timelines |
| frida-trace | Dynamic instrumentation | Scriptable, cross-platform | Heavier; AppleTrace stays embeddable and Perfetto-native |
| InspectiveC, MTHawkeye, SMCallTrace | `objc_msgSend` hooks | — | Mostly unmaintained; no Swift or arm64e story |

AppleTrace's niche: an embeddable, open-source tracer that turns ObjC **and**
Swift call timelines into Perfetto traces on any device and OS version, in CI,
and in third-party apps on jailbroken devices.

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

### Phase 2 — Native Perfetto output
- Emit Perfetto protobuf (`TrackEvent`) from `AppleTraceKit` for smaller files
  and faster loading, with interned names, flow events linking `dispatch_async`
  submit/execute, and per-`Task` tracks for Swift concurrency.
- Debug annotations (arguments) on sections, behind an opt-in API.

### Phase 3 — Complementary backends
- `os_signpost` backend: the same API, viewable in Instruments.
- Hook `objc_alloc_init` / `objc_opt_class` / `objc_opt_self` so
  compiler-lowered sends appear in automatic traces.
- Jailbreak loader: optional inline hook of `objc_msgSend` through ElleKit's
  `MSHookFunction`, to cover apps whose `__DATA_CONST` is sealed (Apple's apps
  on iOS 26) and sends between system frameworks, which GOT rebinding can't reach.
- Experimental: convert Instruments `xctrace export` (incl. Processor Trace)
  into Perfetto traces.

### Phase 4 — Distribution
- Homebrew tap for the CLI; notarized release binaries.
- Sileo/Zebra repository for the loader packages.

### Non-goals
- A sampling profiler (ETTrace and Instruments cover it).
- Frida-style scripting.
- An x86_64 `objc_msgSend` hook.
