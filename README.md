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

**A lightweight, embeddable Objective-C tracer that produces shareable [Perfetto](https://ui.perfetto.dev) traces**

📖 **[Read the full Tutorial &amp; Usage Guide →](https://everettjf.github.io/AppleTrace/)**

[English](README.md) | [中文](README_CN.md)

</div>

> 🚀 **Maintained as needed.** AppleTrace captures your app's execution timeline —
> manual sections and/or every `objc_msgSend` — and renders it in Perfetto, right
> in the browser. With the arrival of the AI era, there is even more that can be
> explored and improved when the need arises.

![AppleTrace Demo](https://everettjf.github.io/stuff/appletrace/appletrace.gif)

---

## Table of Contents

- [What is AppleTrace?](#-what-is-appletrace)
- [Key Features](#-key-features)
- [Quick Start](#-quick-start)
- [How It Works](#-how-it-works)
- [Installation](#-installation)
- [Usage](#-usage)
- [Processing & Visualizing Traces](#-processing--visualizing-traces)
- [Platform & Hook Support](#-platform--hook-support)
- [Testing](#-testing)
- [Project Structure](#-project-structure)
- [FAQ](#-faq)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🎯 What is AppleTrace?

AppleTrace is an iOS/macOS tracing toolkit. You instrument your app — either by
adding manual `APTBeginSection` / `APTEndSection` markers, or by hooking every
`objc_msgSend` automatically — and AppleTrace records a timeline of events into
sandbox trace fragments. A small Python pipeline merges those fragments into a
single `trace.json` that you open directly in [Perfetto](https://ui.perfetto.dev)
to explore the call timeline, durations, threads, and counters.

![Demo Preview](image/appletrace-small.png)

*The trace visualization shows the method execution timeline and call relationships.*

---

## ✨ Key Features

- 📊 **Automatic method tracing** — direct `objc_msgSend` / `objc_msgSendSuper2`
  rebinding on arm64 captures Objective-C activity with no source changes.
- 🎯 **Manual sections** — `APTBeginSection` / `APTEndSection` (and the
  `APTBegin` / `APTEnd` / `APTScopeSection` helpers) mark exactly the regions you
  care about — the lowest-risk option, works on every OS version.
- 📈 **Rich event types** — instant markers (`APTInstant`), counter series
  (`APTCounter` for memory, FPS, queue depth, …), and async/flow events
  (`APTAsyncBegin` / `APTAsyncEnd`) that cross threads and dispatch queues.
- ⚡ **Built for the hot path** — `(Class, SEL)` name interning, a
  zero-allocation per-thread call stack, and per-thread batched writing keep
  `malloc` / `snprintf` / dispatch off the per-message path. An opt-in binary
  fragment format (`APPLETRACE_BINARY=1`) keeps string formatting off it entirely.
- 🧵 **Thread names** — Perfetto shows real thread names instead of bare ids.
- 🔍 **Runtime filtering** — scope automatic tracing with class-prefix allow/deny
  lists (`APPLETRACE_TRACE_CLASS_ALLOW` / `APPLETRACE_TRACE_CLASS_DENY`).
- 🌐 **Perfetto-first** — open `trace.json` at
  [ui.perfetto.dev](https://ui.perfetto.dev); nothing to install, runs in the
  browser, scales to large traces. Begin/end pairs export as `X` complete events
  by default to halve trace size.
- 🐍 **Python 3 tooling** — a unified CLI (`scripts/appletrace_cli.py`), streaming
  merge for large captures, automated tests, and GitHub Actions CI.

### Use Cases

- 🔍 **Performance analysis** — find hotspots and long methods on a real timeline.
- 🐛 **Debugging** — follow method execution flow across threads.
- 📚 **Learning** — see how iOS/macOS frameworks actually dispatch.
- 🛡️ **Security research** — analyze third-party app behavior.

---

## ⚡ Quick Start

```bash
# 1. Prerequisites (macOS)
brew install python git ldid          # ldid is only needed for re-signing loader builds

# 2. Clone
git clone https://github.com/everettjf/AppleTrace.git
cd AppleTrace

# 3. Optional: Python tooling for merging/tests
python3 -m pip install -r requirements.txt
```

### Try the Demo App (fastest way to see a trace)

`sample/AppleTraceSwiftDemo` is a self-contained showcase. Open it in Xcode,
run it on a Simulator (or device), and tap **Generate Trace** — it runs a
curated, multi-threaded workload (app-startup spans, parallel
`ImageDecoder` / `NetworkClient` / `DatabaseWriter` threads, async download
arcs, a 60-frame render loop with live FPS / memory counters) and writes a
complete trace. The screen then shows the on-disk trace directory and the
exact commands to merge and open it in Perfetto.

```bash
open sample/AppleTraceSwiftDemo/AppleTraceSwiftDemo.xcodeproj   # then Run + tap "Generate Trace"

# The app prints the trace directory; merge it and open Perfetto:
python3 merge.py -d "<trace directory shown in the app>"     # → trace.json
# or in one step:
sh go.sh "<trace directory shown in the app>"
```

On the Simulator the directory is already on your Mac. On a device, pull the
app container first (Xcode ▸ *Window ▸ Devices and Simulators ▸ Download
Container*, or `xcrun devicectl device copy from …`) — the app shows the full
command.

Two samples are included:

| Sample | Language | Shows |
|--------|----------|-------|
| `sample/AppleTraceSwiftDemo` | Swift | `withSpan` + `@Traced` / `@TraceAll` macros, counters / async, **and** the `AppleTraceAuto` SwiftTrace auto-hook |
| `sample/TraceAllMsgDemo` | Objective-C | Manual `APTBeginSection` sections **and** the automatic `objc_msgSend` hook |

The Swift demo consumes the local SwiftPM package, so open it from the repo
root (`open sample/AppleTraceSwiftDemo/AppleTraceSwiftDemo.xcodeproj`) and Xcode
resolves the `AppleTrace` / `AppleTraceAuto` products automatically.

### Mode A — Manual Instrumentation (recommended baseline)

```objc
#import <appletrace/appletrace.h>

- (void)yourMethod {
    APTBegin;            // section named "[ClassName yourMethod]"
    // ... your code ...
    APTEnd;
}
```

### Mode B — Automatic `objc_msgSend` Hook (arm64)

```objc
// From your app, after launch:
APTInstallObjcMsgSendHook();
```

```bash
# …or without code changes, via environment variable:
export APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1
```

### Capture & Visualize

```bash
# Run the app; fragments land in <app sandbox>/Library/appletracedata.
# Pull that folder from the simulator/device, then:

python3 merge.py -d /path/to/appletracedata     # → trace.json
# or merge AND open Perfetto in one step:
sh go.sh /path/to/appletracedata
```

Open [ui.perfetto.dev](https://ui.perfetto.dev) and drag in `trace.json` (or use
**Open trace file**).

---

## 🔧 How It Works

```
   Your app (instrumented)                Host tooling                 Browser
┌───────────────────────────┐      ┌──────────────────────┐      ┌────────────────┐
│ APTBeginSection / APTEnd…  │      │  merge.py /           │      │                │
│ APTInstant / APTCounter    │ ───► │  appletrace_cli.py    │ ───► │ ui.perfetto.dev│
│ APTAsyncBegin / …          │      │                       │      │                │
│ objc_msgSend auto-hook     │      │  fragments → trace.json│      │  drag & drop   │
└───────────────────────────┘      └──────────────────────┘      └────────────────┘
   per-thread batched writes              X-complete collapse
   → <sandbox>/Library/appletracedata     → single JSON array
```

1. **Instrument** — add manual markers, or install the `objc_msgSend` hook.
2. **Capture** — events accumulate in per-thread buffers and flush in bulk to
   trace fragments under `<app sandbox>/Library/appletracedata`.
3. **Merge** — pull the folder and run `merge.py`; begin/end pairs collapse into
   Perfetto `X` complete events.
4. **Visualize** — drag `trace.json` into Perfetto.

---

## 📦 Installation

### Requirements

| Requirement | Version | Used for |
|-------------|---------|----------|
| **macOS** | 10.15+ | Build environment |
| **Xcode** | 12+ | iOS/macOS builds (arm64) |
| **Python** | 3.9+ | Trace merging, CLI, and tests |
| **Perfetto** | Web | Visualization at [ui.perfetto.dev](https://ui.perfetto.dev) |
| **ldid** | Optional | Re-signing the loader's embedded framework |
| **LLDB** | Optional | Driving the dynamic hook mode |

### Build the framework

From the repository root:

```bash
# iOS device (arm64; add ARCHS=arm64e for an arm64e validation build)
xcodebuild -project appletrace/appletrace.xcodeproj -scheme appletrace \
  -configuration Release -sdk iphoneos build
```

> The automatic hook supports arm64 and arm64e.
> arm64e replacements in chained-fixup `__auth_got` slots are signed using the
> standard function-pointer PAC schema. The arm64e path is validated on an
> iPhone 17 Pro running iOS 27; the Simulator cannot exercise pointer authentication.

Embed the resulting `appletrace.framework` into your target (see
`sample/TraceAllMsgDemo` for both manual sections and the auto-hook). For
injecting into third-party apps, see the `loader/` project and
run `loader/resign.sh` after swapping in a rebuilt framework.

---

## 🛠️ Usage

### Manual Instrumentation

**Objective-C**

```objc
#import <appletrace/appletrace.h>

- (void)viewDidLoad {
    APTBegin;                 // auto-named "[ClassName viewDidLoad]"
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

void complexFunction() {
    APTBeginSection("processing");
    // ... C++ code ...
    APTEndSection("processing");
}

void saferCppFunction() {
    APTScopeSection("processing");   // RAII: ends automatically at scope exit
    // ... C++ code ...
}
```

### Tracing Swift (SwiftPM)

The `objc_msgSend` hook can't see Swift's static / vtable / witness dispatch, so
Swift is traced at the **source level**. Add the package
(`https://github.com/everettjf/AppleTrace.git`) and `import AppleTrace`:

```swift
import AppleTrace

// Scoped span (closes even on throw / early return):
withSpan("loadFeed") { try? loadFeed() }

// Or annotate — works for final classes, structs, and protocol methods alike,
// because the begin/end is inserted into the body at compile time:
@Traced
func decodeImage() { /* ... */ }

@TraceAll                 // stamps @Traced on every method with a body
final class FeedViewModel {
    func reload() { /* traced */ }
    func render() { /* traced */ }
}

APTFlush()  // (or AppleTrace.flush()) before pulling the trace
```

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
on-device path. See `docs/swift-tracing.md` and the runnable
`AppleTraceAutoExample` (`swift run AppleTraceAutoExample`).

### Instant Markers, Counters & Async Events

```objc
// Mark a point in time on the current thread's timeline
APTInstant("cache_miss");

// Plot a value over time (memory, FPS, queue depth, ...)
APTCounter("resident_mb", 142.5);
APTCounter("fps", 60);

// Track work that crosses threads / dispatch queues (matched by name + id)
uint64_t requestID = 42;
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
APTSyncWait();                           // Block until pending writes complete
NSLog(@"trace dir = %s", APTGetTraceDirectory());
BOOL hooked = APTIsObjcMsgSendHookInstalled();
```

### Environment Variables

```bash
export APPLETRACE_ENABLED=1
export APPLETRACE_DATA_DIR="$HOME/tmp/appletracedata"
export APPLETRACE_BLOCK_SIZE_MB=32
export APPLETRACE_KEEP_EXISTING=1

# Automatic objc_msgSend hook (arm64)
export APPLETRACE_AUTO_HOOK_OBJC_MSGSEND=1
# Only trace classes whose names start with these comma-separated prefixes
export APPLETRACE_TRACE_CLASS_ALLOW="MyApp,UI"
# Never trace classes with these prefixes (takes precedence over allow)
export APPLETRACE_TRACE_CLASS_DENY="NSKVO,_"

# Opt-in binary fragment format (keeps string formatting off the hot path)
export APPLETRACE_BINARY=1
```

---

## 📊 Processing & Visualizing Traces

```bash
# Merge all fragments into trace.json (X complete events by default)
python3 merge.py -d /path/to/appletracedata

# Keep raw begin/end events instead of collapsing them
python3 merge.py -d /path/to/appletracedata --raw

# Unified CLI
python3 scripts/appletrace_cli.py merge /path/to/appletracedata
python3 scripts/appletrace_cli.py open  /path/to/appletracedata   # merge + open Perfetto

# One-liner helper
sh go.sh /path/to/appletracedata
```

`merge.py` auto-discovers both text (`trace[_N].appletrace`) and binary
(`trace[_N].appletracebin`) fragments and decodes each by its magic header.
Then drag the resulting `trace.json` into [ui.perfetto.dev](https://ui.perfetto.dev).

Want to try it without building anything? Drag the prebuilt
[`sampledata/trace.json`](sampledata/trace.json) into Perfetto.

---

## 🧩 Platform & Hook Support

AppleTrace targets **arm64 and arm64e**.

| Mode | arm64 | arm64e |
|------|:-----:|:------:|
| Manual sections & explicit events (`APTBeginSection`, `APTInstant`, …) | ✅ | ✅ |
| Automatic `objc_msgSend` / `objc_msgSendSuper2` hook | ✅ | ✅ |

- **Manual sections** are the lowest-risk baseline and work on every iOS/macOS
  version.
- The **arm64 auto-hook** is validated end-to-end on the iOS Simulator and a host
  stress test — nested sends, `super` dispatch, cross-thread events, a
  10-argument call, and floating-point / small-aggregate ABI cases all survive
  the tracing wrapper.
- The **arm64e auto-hook** detects Mach-O chained fixups and re-signs each
  `__auth_got` replacement for its storage address with the IA key and zero
  discriminator, matching the platform function-pointer ABI. The wrapper also
  uses PAC-aware calls/returns and BTI landing pads. It is validated end-to-end
  on an arm64e iPhone 17 Pro running iOS 27 in both text and binary trace modes.

---

## ✅ Testing

```bash
# Python tooling (merge pipeline + binary fragment format)
python3 -m pytest tests

# objc_msgSend hook smoke tests (builds + runs the sample on a simulator)
./scripts/test_objc_msgsend_hook.sh
./scripts/test_objc_msgsend_hook_experimental.sh

# Same smoke test on a connected arm64 device (text + binary modes)
./scripts/test_objc_msgsend_hook_device.sh

# Force a genuine arm64e app/framework slice for PAC validation
DEVICE_ARCH=arm64e ./scripts/test_objc_msgsend_hook_device.sh

# Batched-writer concurrency stress test (host build, text + binary modes)
./scripts/test_batching_stress.sh
```

The experimental hook script additionally validates `super` dispatch,
cross-thread events, stack-passed and floating-point Objective-C arguments, and
small aggregate returns. The stress test asserts no events are lost or duplicated
across threads, flushes, and thread exits.

---

## 📁 Project Structure

```
AppleTrace/
├── appletrace/              # Core tracing framework (appletrace.xcodeproj)
│   └── appletrace/src/      # Framework source + objc_msgSend hook
├── loader/                  # Dynamic library loader + resign.sh
├── sample/
│   ├── AppleTraceSwiftDemo/ # Swift demo: macros + SwiftTrace auto-hook
│   └── TraceAllMsgDemo/     # Objective-C demo: manual + objc_msgSend hook
├── scripts/                 # CLI + smoke/stress test scripts
│   └── appletrace_cli.py    # Merge + open-in-Perfetto CLI
├── docs/                    # Binary format & batching design notes
├── tests/                   # Python regression tests + stress harness
├── sampledata/              # Demo trace.json for Perfetto
├── merge.py                 # Merge fragments → trace.json
├── appletrace_binary.py     # Binary fragment encoder/decoder
├── go.sh                    # Merge and open Perfetto
└── requirements.txt         # Python dev/test dependencies
```

---

## ❓ FAQ

**Is AppleTrace still maintained?**
Yes — maintained as needed. AppleTrace is no longer under active day-to-day
development, but the arrival of the AI era opens up more possibilities for
future improvements and targeted maintenance when useful.

**Does AppleTrace work on recent iOS versions?**
Manual instrumentation works on all iOS versions. The automatic hook mode targets
arm64 and arm64e — see
[Platform & Hook Support](#-platform--hook-support).

**Can I trace third-party apps?**
Yes — see the loader project and this Chinese guide:
[搭载 MonkeyDev 可 trace 第三方 App](http://everettjf.github.io/2017/10/12/appletrace-dancewith-monkeydev/).

**Why is Python 3 required?**
Python 2 reached end-of-life in 2020. The tooling requires Python 3.9+.

**Can I use this on macOS apps?**
Yes — AppleTrace works for both iOS and macOS applications.

---

## 🤝 Contributing

Contributions are welcome! Please read the [Contributing Guide](CONTRIBUTING.md)
and the [Agent Guide](AGENT.md) for repository conventions.

1. **Fork** the repository.
2. **Create** a feature branch: `git checkout -b feature/amazing-feature`
3. **Commit** your changes (run the test suite first).
4. **Push** and open a **Pull Request**.

**Code style:** [Google Objective-C Style Guide](https://google.github.io/styleguide/objcguide.html) ·
[PEP 8](https://www.python.org/dev/peps/pep-0008/) ·
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)

---

## 🛠️ Tech Stack

<div align="center">

![Objective-C](https://img.shields.io/badge/Objective--C-438EFF?style=flat-square&logo=apple)
![C](https://img.shields.io/badge/C-00599C?style=flat-square&logo=c)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat-square&logo=python)
![Xcode](https://img.shields.io/badge/Xcode-147EFB?style=flat-square&logo=xcode)
![Perfetto](https://img.shields.io/badge/Perfetto-2E2E2E?style=flat-square&logo=google)
![LLDB](https://img.shields.io/badge/LLDB-1A73E8?style=flat-square&logo=llvm)

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
