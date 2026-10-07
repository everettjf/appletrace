# AppleTrace Optimization & Roadmap

> Status: AppleTrace is actively developed. This document captures the
> optimization opportunities, a competitive comparison, and a phased plan that
> drive the project forward. Items marked ✅ have shipped.

## 1. Where We Are Today

- **Platform**: arm64 and arm64e. The arm64e backend detects chained-fixup
  images, signs authenticated GOT replacements with the slot-specific PAC
  context, and uses PAC/BTI-aware wrappers. It is validated on iOS 27 hardware.
- **Tracing backends**: manual `APTBeginSection`/`APTEndSection` markers (plus
  `APTInstant` / `APTCounter` / `APTAsyncBegin` / `APTAsyncEnd`), plus a direct
  `objc_msgSend` / `objc_msgSendSuper2` rebind
  (`appletrace/appletrace/src/objc/hook_objc_msgSend.m`).
- **Runtime**: a single serial dispatch queue serializes one JSON line per event
  into an mmap-backed file (`appletrace/appletrace/src/appletrace.mm`).
- **Tooling**: `merge.py` / `scripts/appletrace_cli.py` merge fragments into a
  Perfetto-compatible `trace.json`; `go.sh` opens it in Perfetto.
- **Visualization**: Perfetto-only (`ui.perfetto.dev`); no Catapult/Chrome HTML.
- **CI**: Python merge tests + two simulator smoke tests (`.github/workflows`).

## 2. Optimization Opportunities

### 2.1 Hot-path performance (highest impact on trace fidelity)

The `objc_msgSend` hot path is far too heavy, which distorts the timings it is
meant to measure:

- `apt_copy_trace_name` (`hook_objc_msgSend.m:360`) does a `malloc` + `snprintf`
  to build `"[Class]selector"` on **every** message send, with no caching.
- `Trace::WriteSection` (`appletrace.mm:318`) builds a `std::string` JSON line and
  `dispatch_async`es it (block copy + enqueue) per event. Under full
  `objc_msgSend` tracing the serial queue becomes the bottleneck and memory
  balloons.

Recommended redesign:

- **String interning**: cache the formatted name keyed by `(Class, SEL)` so the
  hot path stores an integer id, not a freshly allocated string.
- **Per-thread ring buffers**: record fixed-size binary events
  `(timestamp, phase, tid, name_id)` lock-free per thread; flush in bulk on a
  background thread instead of one dispatch per event.
- **Defer formatting**: emit binary events at runtime and convert to JSON only in
  `merge.py` (or a new exporter), removing JSON string building from the hot path.

### 2.2 Visualization pipeline modernization (highest ROI / lowest risk)

- ✅ Visualization is now **Perfetto-only** (`ui.perfetto.dev`): it ingests the
  Chrome JSON `trace.json`, runs entirely in the browser (no download), and
  scales to far larger traces. The deprecated Catapult `trace2html` pipeline
  (`get_catapult.sh`, the HTML demo) has been removed.
- Longer term: emit the Perfetto protobuf format for streaming + smaller files.

### 2.3 Trace format & expressiveness

- ✅ Export `X` (complete) events by default to roughly halve file size vs.
  paired `B`/`E` (`merge.py`; `--raw` keeps the unpaired form).
- ✅ Emit `thread_name` metadata events so threads are labeled in Perfetto
  (previously only `process_name` was written).
- ✅ Add **counter** (`APTCounter`), **instant** (`APTInstant`), and
  **async/flow** (`APTAsyncBegin` / `APTAsyncEnd`) events to track work across
  dispatch queues.
- ✅ Stream `merge.py` output instead of loading every event into memory, so
  large captures don't exhaust RAM.

### 2.4 Filtering & control

- ✅ Add runtime class-prefix allow/deny lists
  (`APPLETRACE_TRACE_CLASS_ALLOW` / `APPLETRACE_TRACE_CLASS_DENY`).
- A sampling mode (trace 1/N sends) is intentionally deferred: it does not
  compose with the nested begin/end model, so it is not on the near-term plan.

### 2.5 Housekeeping

- ✅ Add the `CONTRIBUTING.md` that the README references.
- ✅ Support and document arm64 and arm64e; keep x86_64 out of scope for the
  Objective-C hook.

## 3. Competitive Comparison

| Tool | Mechanism | Strengths | Position vs. AppleTrace |
|------|-----------|-----------|--------------------------|
| **Frida / frida-trace** | Dynamic injection | Cross-platform, scriptable, very active | Full-featured but heavier, needs debug/jailbreak posture |
| **InspectiveC** | fishhook `objc_msgSend` | Per-object / per-class / per-selector filtering | Closest in approach; richer filtering |
| **Instruments (os_signpost)** | OS-level | First-party, low overhead, strong timeline | Could be a low-overhead backend AppleTrace targets |
| **Perfetto** | Visualization + SDK | Modern standard, protobuf, scalable UI | Should be AppleTrace's visualization target |

**Differentiation**: AppleTrace's edge is being lightweight, embeddable directly
in an app (manual sections), and producing shareable artifacts. The roadmap
should lean into that rather than chasing Frida's full feature set.

## 4. Phased Plan

### Phase 1 — Modernize visualization (low risk, high value)
- ✅ Make Perfetto (`ui.perfetto.dev`) the only viewer; remove Catapult/Chrome.
- ✅ Add a `thread_name` metadata event so threads are labeled.
- ✅ Stream `merge.py` output.
- ✅ Collapse begin/end pairs into `X` complete events by default,
  roughly halving section-event count.

### Phase 2 — Hot-path performance
- ✅ Introduce `(Class, SEL)` name interning.
- ✅ Use a zero-allocation per-thread call stack (no per-message `malloc`).
- ✅ Move event recording to per-thread batched buffers with bulk background
  flushing, implemented per
  [docs/perf-batching-design.md](docs/perf-batching-design.md). The host stress
  harness verifies 200,000 paired events without loss or duplication.
- ✅ Defer JSON formatting to the exporter; emit binary events at runtime.
  Exporter/decoder is wired into `merge.py`; the native writer is available
  behind `APPLETRACE_BINARY=1` and covered by the same stress harness. See
  [docs/binary-fragment-format.md](docs/binary-fragment-format.md).

### Phase 3 — Expressiveness & control
- ✅ Add `APTInstant`, `APTCounter`, and `APTAsyncBegin`/`APTAsyncEnd` event APIs.
- ✅ Add runtime class-prefix allow/deny lists.

### Phase 4 — Reach & polish
- ✅ Add `CONTRIBUTING.md`.
- ✅ Support arm64 and arm64e, including authenticated GOT rebinding and
  PAC/BTI-aware wrappers.
- Explore an `os_signpost` backend and/or Perfetto protobuf export.

### Phase 5 — Local control plane
- ✅ Capture lifecycle and runtime metrics API.
- ✅ Runtime class-filter replacement with generation-safe intern caching.
- ✅ Rebind images added after installation through dyld's add-image callback.
- ✅ Versioned loopback HTTP/WebSocket control protocol with token auth.
- ✅ Embedded React control console and trace artifact download.
- ✅ Theos rootless/rootful tweak package, bundle allowlist, `appletraced`, and
  bidirectional Unix-socket Agent transport.
- ✅ Multi-Agent session broker with process-scoped commands and trace access.
- ✅ Daemon-hosted React console with connected-process selection.
- ✅ Agent heartbeats, stale-session eviction, stable reconnect identity, and
  bounded command writes.
- ✅ Bounded HTTP clients/input plus per-Agent trace quotas and oldest-first
  retention.
- ⏳ Validate the tweak on supported jailbroken devices and injector stacks;
  host builds cannot prove injection, sandbox, launchd, or PAC runtime behavior.
