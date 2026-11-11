# Changelog

## Unreleased (2.1)

### Added

- `appletrace summary`: per-span count, total, self, mean, p50, p95 and max
  durations for one or more runs, as a table or JSON (`-o` saves a baseline).
- `appletrace diff`: compares two traces or summaries span by span and exits
  with status 2 when a span regressed by more than `--threshold` and
  `--min-delta` (`--metric`, `--only`, `--fail-on-missing`, `--json`). See
  [docs/ci-performance-gates.md](docs/ci-performance-gates.md).
- `TraceStatistics`, `TraceStatisticsBuilder` and `TraceComparison` in
  `AppleTraceKit`.
- Swift async spans (`withAsyncSpan`, `@Traced` on `async` functions) record
  the current task's name (Swift 6.2 named tasks, OS 26 and later) as their
  `task` argument. C: `APTAsyncBeginWithTask()`.
- Binary fragments gain a `T` record carrying that task name; `appletrace
  merge` and `merge.py` attach it to the async begin that follows.

### Verified

- Swift tests (36), Python tests (27), `scripts/test_ci_gates.sh`, and the
  Swift demo app recorded three times against three times on an iOS 27.2
  Simulator: unchanged code passes with `--metric p50 --threshold 20%
  --min-delta 2ms`, and runs recorded under load are flagged.

## 2.0.0 — 2026-11-09

### Breaking

- **Binary fragments are the default.** The runtime writes
  `trace[_N].appletracebin`; set `APPLETRACE_FORMAT=text` (or the legacy
  `APPLETRACE_BINARY=0`) for JSON lines. `appletrace merge` and `merge.py`
  read both.
- **Minimum deployment targets are iOS 15 / macOS 12**, the oldest current
  Xcode accepts.
- **Swift macro span names changed** from `#function` (`reload()`) to
  type-qualified signatures (`FeedViewModel.reload()`), and `async` functions
  now emit async spans (`b`/`e`) instead of sections.
- **Malformed environment values are ignored** (logged, default applies)
  instead of being read leniently (e.g. `APPLETRACE_ENABLED=maybe` no longer
  means "on", `APPLETRACE_BLOCK_SIZE_MB=12abc` no longer means 12).
- The legacy MonkeyDev loader project, its committed 2018 binaries and
  `loader/resign.sh` are replaced by `loader/AppleTraceLoader.m` and
  `scripts/build_jailbreak_packages.sh`.

### Added

- `appletrace` command-line tool: `merge`, `open` (hands the trace to
  ui.perfetto.dev in your browser, never uploads it), `devices`, `pull`,
  `record` (launch → wait → stop → pull → merge → open), and `jb` subcommands.
- AppleTraceLoader for **rootless and roothide** jailbreaks, packaged as
  `iphoneos-arm64` and `iphoneos-arm64e` debs, configured per app by
  `appletrace jb enable`.
- `AppleTraceKit` library: fragment decoding and merging for your own tools.
- Swift: `@Traced("name")`, `@NotTraced`, `withAsyncSpan`, `newAsyncID()`,
  `installObjCMsgSendHook()`, `isObjCMsgSendHookInstalled`, and `StaticString`
  overloads that pass literals to the core without bridging.
- `@TraceAll` also traces initializers.
- C: `APTNewAsyncID()`, `APTSectionNameForMethod()`,
  `APTObjcMsgSendHookDiagnostics()` (images scanned, GOT slots rebound,
  protection failures).
- The loader writes `tmp/AppleTraceLoader.log` inside each traced app;
  `appletrace jb pull` prints it. `APPLETRACE_SSH_OPTIONS` passes extra
  ssh/scp options; every `jb` command except `install` works as `mobile`.
- `APPLETRACE_FORMAT` and `APPLETRACE_FLUSH_INTERVAL_MS`.
- The `objc_msgSend` hook ships in the SwiftPM `AppleTrace` product (previously
  declared but not linked).

### Fixed

- `@Traced` on `async` functions produced begin/end on different threads after
  an `await`, which broke pairing.
- Same-named methods on different types were merged under one span name.
- A thread's batches could reach the writer out of order when a flush raced a
  threshold ship, which could mis-pair nested sections.
- Events still buffered when an app was killed or terminated were lost; the
  runtime now drains every second, on backgrounding and at exit, and fragments
  are truncated to their real size at exit.
- Two `APTScopeSection` in one scope failed to compile (identical variable
  names).
- `APTBegin` / `APTEnd` allocated two `NSString`s per call; names are now
  interned per `(class, selector)`.
- The text writer and binary name lookup allocated per event; both are now
  allocation-free on repeat names.
- The hook did not rebind images loaded after installation.
- The hook failed to compile for x86_64 slices (now a stub returning `NO`).
- Simulator smoke test and sample projects failed to build with current Xcode
  (iOS 12 deployment target).
- `merge.py` raised on a record truncated by a killed process.

### Known limitations

- On iOS 26, Apple's own apps seal their read-only `__DATA_CONST`, so the hook
  cannot rebind their GOT; the loader detects this, leaves the app running, and
  reports it in `AppleTraceLoader.log`.

### Verified

- Swift tests (25), host stress test (13 configurations), host hook test,
  Simulator hook tests, and on-device runs on an iPhone 11 (iOS 26.0.1, arm64
  and arm64e) including the Swift demo recorded with `appletrace record` and
  loaded into Perfetto with `appletrace open`.
- Roothide jailbreak on the same iPhone 11: loader installed through Sileo;
  `appletrace jb record` on a Flutter App Store app (22,849 hooked sends, 10
  threads, all paired), with `--allow` filtering and `--text`; Notes and
  Calculator load the framework and keep running with their sealed GOT reported.

## 1.1 and earlier

See the git history.
