# Contributing to AppleTrace

Thanks for your interest in improving AppleTrace! This guide covers how to get
set up, what we expect from changes, and how to validate them.

## Getting Started

```bash
git clone https://github.com/everettjf/appletrace.git
cd appletrace
swift build
```

You will need Xcode 16+ (Swift 6, macOS 12+) to build the package, framework and
samples. Python 3 is only needed for the legacy `merge.py` tooling and its tests
(`python3 -m pip install -r requirements.txt`).

## Project Layout

- `appletrace/` — core tracing framework (Objective-C/C++ runtime, public headers).
- `appletrace/appletrace/src/objc/hook_objc_msgSend.m` — arm64/arm64e `objc_msgSend` hook.
- `Sources/` — SwiftPM targets: the C core wrapper, Swift API + macros, the
  SwiftTrace bridge, `AppleTraceKit` (decoder/merger) and the `appletrace` CLI.
- `loader/` — jailbreak AppleTraceLoader tweak (rootless / roothide).
- `merge.py`, `scripts/appletrace_cli.py`, `go.sh` — legacy Python tooling.
- `Tests/` — Swift package tests, Python regression tests, and host harnesses.

See [AGENTS.md](AGENTS.md) for repository conventions and
[ROADMAP.md](ROADMAP.md) for where the project is headed.

## Making Changes

- Keep changes scoped: don't mix instrumentation, tooling, and docs in one PR.
- The `objc_msgSend` hook targets arm64 and arm64e. Preserve the authenticated
  GOT signing and PAC/BTI wrapper behavior, and run the arm64e device smoke test
  after changing the hook.
- Avoid adding work to the tracing hot path; prefer caching/interning and
  per-thread state over per-event allocation.
- Update `README.md` / `README_CN.md` / the tutorials / `CHANGELOG.md` when
  workflows or APIs change.

## Testing

```bash
# Swift package: macros, runtime, async spans, concurrency, decoder
swift test

# Writer stress test and host hook test
./scripts/test_batching_stress.sh
./scripts/test_hook_host.sh

# objc_msgSend hook smoke tests on the Simulator
./scripts/test_objc_msgsend_hook.sh
./scripts/test_objc_msgsend_hook_experimental.sh

# Real device (binary + text trace modes), arm64 and arm64e
DEVICE_UDID=<udid> ./scripts/test_objc_msgsend_hook_device.sh
DEVICE_UDID=<udid> DEVICE_ARCH=arm64e ./scripts/test_objc_msgsend_hook_device.sh

# Jailbreak loader packages
./scripts/build_jailbreak_packages.sh

# Legacy Python tooling
python3 -m pytest Tests
```

When touching the framework, build the relevant Xcode targets and confirm a
trace renders correctly in [Perfetto](https://ui.perfetto.dev).

## Code Style

- **Objective-C:** [Google Objective-C Style Guide](https://google.github.io/styleguide/objcguide.html)
- **Swift:** follow the existing style (4-space indentation, doc comments on public API)
- **Python:** [PEP 8](https://www.python.org/dev/peps/pep-0008/)
- **Shell:** [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)

## Pull Requests

1. Fork and create a feature branch.
2. Make your change with tests where applicable.
3. Run the test commands above and note any manual testing (device, iOS version).
4. Open a PR describing the change and its motivation.
