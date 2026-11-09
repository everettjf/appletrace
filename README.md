# AppleTrace 🍎

[Discord](https://discord.gg/eGzEaP6TzR)

Repository: <https://github.com/everettjf/appletrace>

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/AppleTrace?style=flat-square&color=4ECDC4)](https://github.com/everettjf/AppleTrace/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/everettjf/AppleTrace?style=flat-square&color=4ECDC4)](https://github.com/everettjf/AppleTrace/network)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/everettjf/AppleTrace?style=flat-square)](https://github.com/everettjf/AppleTrace/commits/master)
[![Contributors](https://img.shields.io/github/contributors/everettjf/AppleTrace?style=flat-square)](https://github.com/everettjf/AppleTrace/graphs/contributors)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square&logo=apple)](https://github.com/everettjf/AppleTrace)

**A lightweight, embeddable Objective-C and Swift tracer that produces shareable [Perfetto](https://ui.perfetto.dev) traces**

📖 **[Read the full Tutorial &amp; Usage Guide →](https://everettjf.github.io/AppleTrace/)**

[English](README.md) | [中文](README_CN.md)

</div>

> 🚀 **Maintained as needed.** AppleTrace captures your app's execution timeline —
> manual sections, Swift macros, and/or every `objc_msgSend` — and renders it in
> Perfetto, right in the browser. Version 2.0 adds a one-command `appletrace` CLI,
> binary traces by default, async-safe Swift macros, and a rootless / roothide
> jailbreak loader. See the [CHANGELOG](CHANGELOG.md).

![AppleTrace Demo](https://everettjf.github.io/stuff/appletrace/appletrace.gif)

---

## Table of Contents

- [What is AppleTrace?](#-what-is-appletrace)
- [Key Features](#-key-features)
- [Quick Start](#-quick-start)
- [How It Works](#-how-it-works)
- [Installation](#-installation)
- [Usage](#-usage)
- [The `appletrace` CLI](#-the-appletrace-cli)
- [Tracing Any App on a Jailbroken Device](#-tracing-any-app-on-a-jailbroken-device)
- [Platform & Hook Support](#-platform--hook-support)
- [Testing](#-testing)
- [Project Structure](#-project-structure)
- [FAQ](#-faq)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🎯 What is AppleTrace?

AppleTrace is an iOS/macOS tracing toolkit. You instrument your app — with
manual `APTBeginSection` / `APTEndSection` markers, Swift `@Traced` macros, or by
hooking every `objc_msgSend` automatically — and AppleTrace records a timeline of
events into trace fragments in the app's sandbox. The `appletrace` command-line
tool pulls them off the device, merges them into a single `trace.json`, and opens
it in [Perfetto](https://ui.perfetto.dev) to explore the call timeline,
durations, threads, and counters.

![Demo Preview](image/appletrace-small.png)

*The trace visualization shows the method execution timeline and call relationships.*

---

## ✨ Key Features

- 📊 **Automatic method tracing** — direct `objc_msgSend` / `objc_msgSendSuper2`
  rebinding on arm64 and arm64e captures Objective-C activity with no source
  changes, including frameworks loaded later with `dlopen`.
- 🧩 **Swift macros** — `@Traced` / `@TraceAll` instrument Swift at compile time
  (final classes, structs, actors, protocol extensions). Names are qualified by
  type (`FeedViewModel.reload(force:)`), and `async` functions get async spans,
  so a call that resumes on another thread after `await` stays one slice.
- 🎯 **Manual sections** — `APTBeginSection` / `APTEndSection` (and the
  `APTBegin` / `APTEnd` / `APTScopeSection` helpers) mark exactly the regions you
  care about — the lowest-risk option, works on every OS version.
- 📈 **Rich event types** — instant markers (`APTInstant`), counter series
  (`APTCounter` for memory, FPS, queue depth, …), and async/flow events
  (`APTAsyncBegin` / `APTAsyncEnd`) that cross threads and dispatch queues.
- ⚡ **Built for the hot path** — binary trace fragments by default, `(Class,
  SEL)` name interning, pointer-cached name ids, and per-thread batched writing
  keep `malloc`, string formatting and dispatch off the per-event path.
- 💾 **Crash-tolerant capture** — buffers drain to a memory-mapped file every
  second, when the app enters the background, and at exit, so even a killed app
  leaves a readable trace.
- 🛠️ **One-command workflow** — `appletrace record` launches the app on a
  device, waits, stops it, pulls, merges, and opens Perfetto. No Python needed.
- 🔓 **Any app on a jailbroken device** — an AppleTraceLoader tweak for rootless
  and roothide jailbreaks, driven by `appletrace jb …` over SSH.
- 🔍 **Runtime filtering** — scope automatic tracing with class-prefix allow/deny
  lists (`APPLETRACE_TRACE_CLASS_ALLOW` / `APPLETRACE_TRACE_CLASS_DENY`).

### Use Cases

- 🔍 **Performance analysis** — find hotspots and long methods on a real timeline.
- 🐛 **Debugging** — follow method execution flow across threads.
- 📚 **Learning** — see how iOS/macOS frameworks actually dispatch.
- 🛡️ **Security research** — analyze third-party app behavior on a jailbroken device.

---

## ⚡ Quick Start

```bash
git clone https://github.com/everettjf/AppleTrace.git
cd AppleTrace
swift build -c release --product appletrace     # builds .build/release/appletrace
```

Prebuilt `appletrace` binaries, an `appletrace.xcframework`, and the jailbreak
packages are attached to each [GitHub release](https://github.com/everettjf/appletrace/releases).

### Try the Demo App (fastest way to see a trace)

`sample/AppleTraceSwiftDemo` runs a curated, multi-threaded workload
(app-startup spans, parallel `ImageDecoder` / `NetworkClient` / `DatabaseWriter`
threads, async download arcs, Swift-concurrency `@Traced async` methods, and a
60-frame render loop with live FPS / memory counters).

```bash
open sample/AppleTraceSwiftDemo/AppleTraceSwiftDemo.xcodeproj   # Run it on a device once to install it

# Then record it end to end — launch, wait, stop, pull, merge, open Perfetto:
swift run appletrace record --bundle-id com.everettjf.AppleTraceSwiftDemo \
  --env APPLETRACE_AUTORUN=1 --open
```

On the Simulator, tap **Generate Trace** and run the `swift run appletrace open
<dir>` command the app shows.

Two samples are included:

| Sample | Language | Shows |
|--------|----------|-------|
| `sample/AppleTraceSwiftDemo` | Swift | `withSpan` + `@Traced` / `@TraceAll` macros (incl. `async`), counters / async spans, **and** the `AppleTraceAuto` SwiftTrace auto-hook |
| `sample/TraceAllMsgDemo` | Objective-C | Manual `APTBeginSection` sections **and** the automatic `objc_msgSend` hook |

### Mode A — Manual Instrumentation (recommended baseline)

```objc
#import <appletrace/appletrace.h>

- (void)yourMethod {
    APTBegin;            // section named "[ClassName yourMethod]"
    // ... your code ...
    APTEnd;
}
```

### Mode B — Automatic `objc_msgSend` Hook (arm64 / arm64e)

```objc
APTInstallObjcMsgSendHook();   // or, from Swift: AppleTrace.installObjCMsgSendHook()
```

```bash
# …or without code changes, via environment variable (what `appletrace record --hook` sets):
export APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1
```

### Capture & Visualize

```bash
# Development-signed app on a connected device:
swift run appletrace record --bundle-id com.example.MyApp --duration 15 --hook --open

# Or pull / merge / open separately:
swift run appletrace pull --bundle-id com.example.MyApp -o mytrace
swift run appletrace open mytrace
```

`appletrace open` hands the trace to [ui.perfetto.dev](https://ui.perfetto.dev)
through a local page in your browser — the file is never uploaded. You can also
drag `trace.json` into Perfetto yourself.

---

## 🔧 How It Works

```
   Your app (instrumented)                 appletrace CLI (macOS)            Browser
┌────────────────────────────┐      ┌──────────────────────────┐      ┌────────────────┐
│ APTBeginSection / @Traced   │      │ record / pull (devicectl,│      │                │
│ APTInstant / APTCounter     │ ───► │   or SSH on jailbreak)   │ ───► │ ui.perfetto.dev│
│ APTAsyncBegin / async spans │      │ merge → trace.json       │      │                │
│ objc_msgSend auto-hook      │      │ open → local hand-off    │      │                │
└────────────────────────────┘      └──────────────────────────┘      └────────────────┘
   per-thread batches → mmap'd            X-complete collapse
   <sandbox>/Library/appletracedata       binary + text fragments
```

1. **Instrument** — add manual markers or Swift macros, or install the
   `objc_msgSend` hook.
2. **Capture** — events accumulate in per-thread buffers, are shipped in order
   to a serial writer, and land in memory-mapped binary fragments under
   `<app sandbox>/Library/appletracedata`.
3. **Merge** — `appletrace merge` decodes the fragments and collapses
   begin/end pairs into Perfetto `X` complete events.
4. **Visualize** — `appletrace open` loads `trace.json` into Perfetto.

---

## 📦 Installation

### Requirements

| Requirement | Version | Used for |
|-------------|---------|----------|
| **macOS** | 12+ | Build environment and the `appletrace` CLI |
| **Xcode** | 16+ (Swift 6 toolchain) | Package, framework, and samples |
| **iOS / macOS deployment target** | iOS 15+ / macOS 12+ | Apps that embed AppleTrace |
| **Perfetto** | Web | Visualization at [ui.perfetto.dev](https://ui.perfetto.dev) |
| **ldid**, **xz** | Optional | Building the jailbreak packages |
| **Python** | Optional, 3.9+ | Legacy `merge.py` tooling and its tests |

### Swift Package Manager

```swift
.package(url: "https://github.com/everettjf/appletrace.git", from: "2.0.0")
```

| Product | What it is |
|---------|-----------|
| `AppleTrace` | The C core + `objc_msgSend` hook, the Swift API, and the `@Traced` / `@TraceAll` macros |
| `AppleTraceAuto` | Optional SwiftTrace bridge (Simulator / macOS only) |
| `AppleTraceKit` | Fragment decoding and merging, for your own tooling |
| `appletrace` | The command-line tool |

### Framework (Objective-C / Xcode)

Use the `appletrace.xcframework` from the release, or build the framework:

```bash
xcodebuild -project appletrace/appletrace.xcodeproj -scheme appletrace \
  -configuration Release -sdk iphoneos build
```

> The automatic hook supports arm64 and arm64e. arm64e replacements in
> chained-fixup `__auth_got` slots are signed with the standard function-pointer
> PAC schema. Simulator / Intel slices build a stub whose install call returns
> `NO`.

---

## 🛠️ Usage

### Manual Instrumentation

**Objective-C**

```objc
#import <appletrace/appletrace.h>

- (void)viewDidLoad {
    APTBegin;                 // auto-named "[ClassName viewDidLoad]" (interned, no per-call allocation)
    [super viewDidLoad];
    APTEnd;
}

- (void)networkRequest {
    APTBeginSection("network");   // explicit section name
    // ... network code ...
    APTEndSection("network");
}
```

**C / C++**

```cpp
#include <appletrace/appletrace.h>

void saferCppFunction() {
    APTScopeSection("processing");   // RAII: ends automatically at scope exit
    APTScopeSection("inner");        // several per scope are fine
    // ... C++ code ...
}
```

### Tracing Swift (SwiftPM)

The `objc_msgSend` hook can't see Swift's static / vtable / witness dispatch, so
Swift is traced at the **source level**:

```swift
import AppleTrace

// Scoped span (closes even on throw / early return). String literals bind to a
// StaticString overload that passes the literal straight to the C core.
withSpan("loadFeed") { try? loadFeed() }

// Async work: an async span may begin and end on different threads.
let feed = try await withAsyncSpan("fetchFeed") { try await api.feed() }

// Annotate — the span name is qualified by type: "FeedViewModel.reload(force:)".
@TraceAll
final class FeedViewModel {
    func reload(force: Bool) { /* traced */ }
    func refresh() async throws { /* async span: survives thread hops at await */ }
    @NotTraced func hotPath() { /* excluded */ }
}

@Traced("feed.decode")       // explicit name
func decodeImage() { /* ... */ }
```

The runtime drains buffers every second, on backgrounding, and at exit; call
`AppleTrace.flush()` only when you read the trace in-process.

Want zero-annotation auto-tracing of a class hierarchy? The optional
`AppleTraceAuto` product bridges [SwiftTrace](https://github.com/johnno1962/SwiftTrace):

```swift
import AppleTraceAuto
AppleTraceAuto.trace(aClass: FeedViewModel.self)   // entry/exit → AppleTrace
```

`AppleTraceAuto` is **Simulator / macOS only** (SwiftTrace patches
pointer-authenticated vtable slots, unsafe on real devices — gate it with
`#if targetEnvironment(simulator)`), and it can't see `final` /
statically-dispatched methods. The macros have neither limitation and are the
on-device path. See [docs/swift-tracing.md](docs/swift-tracing.md).

### Instant Markers, Counters & Async Events

```objc
APTInstant("cache_miss");                 // a point in time
APTCounter("resident_mb", 142.5);         // a value over time

uint64_t requestID = APTNewAsyncID();     // process-unique id
APTAsyncBegin("image_load", requestID);
dispatch_async(queue, ^{
    // ... work on another thread ...
    APTAsyncEnd("image_load", requestID);
});
```

### Runtime Controls

```objc
APTSetEnabled(NO);                       // Temporarily pause recording
APTSetEnabled(YES);                      // Resume
BOOL on = APTIsEnabled();                // Query state
APTFlush();                              // Force buffered writes to disk
NSLog(@"trace dir = %s", APTGetTraceDirectory());
BOOL hooked = APTIsObjcMsgSendHookInstalled();
```

### Environment Variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `APPLETRACE_ENABLED` | `1` | Record at all (`0` to start paused) |
| `APPLETRACE_DATA_DIR` | `<sandbox>/Library/appletracedata` | Where fragments are written |
| `APPLETRACE_FORMAT` | `binary` | `binary` or `text` (JSON lines, for debugging). `APPLETRACE_BINARY=0/1` still works |
| `APPLETRACE_FLUSH_INTERVAL_MS` | `1000` | Background drain interval; `0` disables |
| `APPLETRACE_BLOCK_SIZE_MB` | `16` | Fragment size before rolling over (1–256) |
| `APPLETRACE_KEEP_EXISTING` | `0` | Keep previous traces (`appletracedata_N`) instead of replacing them |
| `APPLETRACE_AUTO_HOOK_OBJC_MSGSEND` | `0` | Install the `objc_msgSend` hook at load |
| `APPLETRACE_TRACE_CLASS_ALLOW` | — | Comma-separated class-name prefixes to trace |
| `APPLETRACE_TRACE_CLASS_DENY` | — | Prefixes never traced (wins over allow) |

Malformed values are logged and ignored (the default applies).

---

## 🖥️ The `appletrace` CLI

```text
appletrace merge <trace-dir> [-o trace.json] [--raw]
appletrace open <trace-dir | trace.json>
appletrace devices
appletrace pull   --bundle-id <id> [--device <udid|name>] [-o <dir>]
appletrace record --bundle-id <id> [--device <udid|name>] [--duration <sec>]
                  [--hook] [--allow <prefixes>] [--deny <prefixes>] [--text]
                  [--env KEY=VALUE]... [-o <dir>] [--open]
appletrace jb install|enable|disable|list|pull|record …
```

- `record` launches the app through `devicectl` with the matching `APPLETRACE_*`
  environment, waits, stops it, pulls `Library/appletracedata`, and merges.
  Use it for development-signed apps; use `appletrace jb record` for anything else.
- `merge` reads both binary and text fragments (including ones left by a killed
  process) and collapses begin/end pairs unless `--raw` is given.
- The Python `merge.py` / `scripts/appletrace_cli.py` / `go.sh` tools still work
  and produce the same output.

---

## 🔓 Tracing Any App on a Jailbroken Device

The AppleTraceLoader tweak injects AppleTrace into apps you choose, on
**rootless** (`/var/jb`, e.g. Dopamine) and **roothide** jailbreaks. It derives
the jailbreak root from its own path, so the same binaries work on both.

1. Install the package from the release (or build it with
   `./scripts/build_jailbreak_packages.sh`):
   - rootless: `appletrace-loader_<version>_iphoneos-arm64.deb`
   - roothide: `appletrace-loader_<version>_iphoneos-arm64e.deb`

   ```bash
   appletrace jb install appletrace-loader_2.0.0_iphoneos-arm64e.deb --host <device> [--port 22]
   ```

2. Record an app (it is relaunched with tracing enabled, then stopped, pulled and merged):

   ```bash
   appletrace jb record com.example.App --host <device> --duration 15 --hook \
     --allow "EX,App" --open
   ```

   Or step by step: `appletrace jb enable <bundle-id> --hook`, use the app,
   `appletrace jb pull <bundle-id>`, `appletrace open appletracedata-<bundle-id>`,
   and `appletrace jb disable <bundle-id>` when done.

`enable` writes `<jbroot>/var/mobile/Library/AppleTrace/<bundle-id>.plist` (the
`APPLETRACE_*` variables to apply). The loader only touches apps that have such a
file. SSH needs key-based login (`ssh-copy-id`); over USB you can forward port 22
with `iproxy 2222 22` and pass `--host 127.0.0.1 --port 2222`.

---

## 🧩 Platform & Hook Support

| Mode | arm64 | arm64e | x86_64 (Simulator / Intel Mac) |
|------|:-----:|:------:|:------:|
| Manual sections, Swift macros & explicit events | ✅ | ✅ | ✅ |
| Automatic `objc_msgSend` / `objc_msgSendSuper2` hook | ✅ | ✅ | — (stub returns `NO`) |
| Jailbreak loader (rootless / roothide) | ✅ | ✅ | — |

- **Manual sections and macros** are the lowest-risk baseline and work on every
  supported OS version.
- The **auto-hook** wraps every rebound send in an assembly trampoline that
  preserves integer, floating-point, stack-passed and aggregate-return ABI state;
  it is validated on the Simulator, on an arm64e iPhone 17 Pro (iOS 27), and on
  an iPhone 11 (iOS 26.0.1) in both arm64 and arm64e builds.
- With a deployment target of iOS 14+ / macOS 11+, clang emits
  `objc_alloc_init` / `objc_opt_*` calls instead of some `alloc`, `init`,
  `class` and `self` message sends, so those don't appear as hooked events.

---

## ✅ Testing

```bash
swift test                                     # macros, runtime, async spans, concurrency, decoder
./scripts/test_batching_stress.sh              # writer stress: formats, drains, SIGKILL, rollover, bad config
./scripts/test_objc_msgsend_hook.sh            # hook smoke test on the Simulator
./scripts/test_objc_msgsend_hook_experimental.sh
DEVICE_UDID=<udid> ./scripts/test_objc_msgsend_hook_device.sh                  # real device, arm64
DEVICE_UDID=<udid> DEVICE_ARCH=arm64e ./scripts/test_objc_msgsend_hook_device.sh
python3 -m pytest Tests                        # legacy Python exporter
```

The stress test runs 8 threads × 25,000 nested and dynamically named sections in
text and binary modes, with a 1 ms background drain, without an explicit flush,
after `SIGKILL`, across fragment rollover, with malformed configuration, with an
unwritable directory, and with tracing disabled — and asserts exact counts and
correct nesting every time.

---

## 📁 Project Structure

```
AppleTrace/
├── appletrace/              # Core tracing framework (appletrace.xcodeproj)
│   └── appletrace/src/      # C++ core + objc_msgSend hook (shared with SwiftPM)
├── Sources/
│   ├── CAppleTrace/         # SwiftPM wrapper around the core + hook
│   ├── AppleTrace/          # Swift API and macros
│   ├── AppleTraceMacrosPlugin/
│   ├── AppleTraceAuto/      # SwiftTrace bridge
│   ├── AppleTraceKit/       # Fragment decoder + merger
│   └── AppleTraceCLI/       # `appletrace` command-line tool
├── Tests/                   # Swift tests, Python tests, stress harness
├── loader/                  # Jailbreak AppleTraceLoader tweak (rootless / roothide)
├── sample/                  # Swift and Objective-C demo apps
├── scripts/                 # Test, stress and packaging scripts
├── docs/                    # Format and design notes
├── Tutorial/                # GitHub Pages tutorial
├── sampledata/              # Demo trace for Perfetto
└── merge.py, appletrace_binary.py, go.sh   # Legacy Python tooling
```

---

## ❓ FAQ

**Is AppleTrace still maintained?**
Yes — maintained as needed. With the arrival of the AI era, there is even more
that can be explored and improved when the need arises.

**Does AppleTrace work on recent iOS versions?**
Yes. Manual instrumentation and Swift macros work everywhere; the automatic hook
is validated on iOS 26 and iOS 27 hardware (arm64 and arm64e).

**Can I trace third-party apps?**
Yes, on a rootless or roothide jailbreak — see
[Tracing Any App on a Jailbroken Device](#-tracing-any-app-on-a-jailbroken-device).

**Is Python still required?**
No. The `appletrace` CLI replaces it. `merge.py` remains for existing scripts.

**Can I use this on macOS apps?**
Yes — AppleTrace works for both iOS and macOS applications.

**Why don't I see `[NSObject alloc]` / `init` in hooked traces?**
See the note in [Platform & Hook Support](#-platform--hook-support): the
compiler replaces those sends with direct runtime calls.

---

## 🤝 Contributing

Contributions are welcome! Please read the [Contributing Guide](CONTRIBUTING.md)
and [AGENTS.md](AGENTS.md) for repository conventions.

1. **Fork** the repository.
2. **Create** a feature branch: `git checkout -b feature/amazing-feature`
3. **Commit** your changes (run the test suite first).
4. **Push** and open a **Pull Request**.

---

## 🛠️ Tech Stack

<div align="center">

![Objective-C](https://img.shields.io/badge/Objective--C-438EFF?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![C++](https://img.shields.io/badge/C++-00599C?style=flat-square&logo=cplusplus)
![Xcode](https://img.shields.io/badge/Xcode-147EFB?style=flat-square&logo=xcode)
![Perfetto](https://img.shields.io/badge/Perfetto-2E2E2E?style=flat-square&logo=google)

</div>

---

## 🙏 Acknowledgements

Inspired by Facebook's [fbtrace](https://github.com/facebookarchive/fbtrace), and
built around Google's [Perfetto](https://perfetto.dev) and the
[Trace Event Format](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview).

---

## 📜 License

AppleTrace is released under the MIT License. See [LICENSE](LICENSE) for details.

---

## 📞 Support

<div align="center">

<a href="https://github.com/everettjf/AppleTrace/issues">
  <img src="https://img.shields.io/badge/Issues-Bug_Reports-FF6B6B?style=for-the-badge&logo=github" />
</a>
<a href="https://github.com/everettjf/AppleTrace/discussions">
  <img src="https://img.shields.io/badge/Discussions-Questions-4ECDC4?style=for-the-badge&logo=github" />
</a>
<a href="http://everettjf.github.io/2017/09/21/appletrace/">
  <img src="https://img.shields.io/badge/Docs-中文教程-45B7D1?style=for-the-badge&logo=readthedocs" />
</a>

**Made with ❤️ by [Everett](https://github.com/everettjf)**

</div>

---

## 📈 Star History

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/AppleTrace&type=Date)](https://star-history.com/#everettjf/AppleTrace&Date)

</div>
