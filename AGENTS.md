# Repository Guidelines

AppleTrace is an iOS/macOS tracing library that records Objective-C and Swift calls and exports Perfetto-compatible traces. Preserve low overhead and binary compatibility in the C/Objective-C++ core.

## Structure

- `appletrace/appletrace/src`: the C++ trace core (`appletrace.mm`), public header, and the arm64/arm64e `objc_msgSend` hook. Shared by the Xcode framework, SwiftPM, and the jailbreak loader.
- `Sources/CAppleTrace`: SwiftPM wrapper that compiles the core and the hook (non-arm64 builds get a stub hook).
- `Sources/AppleTrace`: Swift API and tracing macros; `Sources/AppleTraceMacrosPlugin`: macro implementations.
- `Sources/AppleTraceAuto`: automatic Swift tracing bridge (SwiftTrace; Simulator/macOS only).
- `Sources/AppleTraceKit`: fragment decoding and merging; `Sources/AppleTraceCLI`: the `appletrace` tool.
- `Tests/AppleTraceTests`: package, macro, runtime, and decoder tests. `Tests/stress`, `Tests/hook`: host harnesses. `Tests/*.py`: legacy Python exporter tests.
- `loader/`: jailbreak AppleTraceLoader tweak (rootless/roothide), packaged by `scripts/build_jailbreak_packages.sh`.
- `sample/`: Swift and Objective-C demo apps. `springboard/`: legacy SpringBoard experiment.
- `Tutorial/` and `docs/`: user-facing guides.

## Build and Test

```bash
swift build
swift test
swift run AppleTraceAutoExample
./scripts/test_batching_stress.sh
./scripts/test_hook_host.sh
```

Run package tests after Swift API or macro changes. For runtime or hook changes, also run the Simulator scripts (`scripts/test_objc_msgsend_hook*.sh`), exercise a real iOS device (`DEVICE_UDID=… [DEVICE_ARCH=arm64e] scripts/test_objc_msgsend_hook_device.sh`), and open the exported trace in Perfetto (`swift run appletrace open <dir>`). For loader changes, build the packages and test `appletrace jb record` on a rootless or roothide device.

## Conventions

- Keep event writes allocation-light and thread-safe. Ship a thread's batch while holding its buffer lock so per-thread order is preserved.
- Do not move trace-core work onto the main thread.
- Preserve the documented Objective-C API while adding Swift-friendly wrappers.
- The hook targets arm64 and arm64e; keep the PAC re-signing of authenticated GOT slots and the PAC/BTI-aware wrappers intact.
- Visualization is Perfetto-only; do not reintroduce a Catapult/Chrome HTML pipeline.
- Add regression coverage for macro expansion, nested calls, concurrent calls, disabled tracing, and malformed configuration.
- Never commit generated traces, app binaries, signing material, or local package caches.

Keep `README.md`, `README_CN.md`, the tutorials (`Tutorial/index.html`, `Tutorial/zh.html`), and `CHANGELOG.md` aligned. Use the canonical repository URL `https://github.com/everettjf/appletrace`.
