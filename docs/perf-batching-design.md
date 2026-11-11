# Design: Per-Thread Batched Trace Writing

Status: implemented in `appletrace/appletrace/src/appletrace.mm` (Phase 2 of
the original roadmap). **Verified** on Apple-silicon hosts and devices: the
simulator smoke tests and `scripts/test_batching_stress.sh` pass. Since 2.0 the
stress test covers 13 configurations (text and binary formats, a 1 ms
background drain, exit-time draining, SIGKILL, rollover, malformed config, an
unwritable directory, disabled tracing) with nested and dynamically named
sections. Instruments profiling (step 3) remains pending.

2.0 changes to the design below: batches are shipped to the writer queue while
the thread buffer's lock is held (so a thread's batches can never be reordered
by a racing flush), a background timer drains all buffers every
`APPLETRACE_FLUSH_INTERVAL_MS` (default 1000), and the app's background/exit
notifications drain and truncate fragments.
This document is the design of record; section 9 is the verification plan.

## 1. Problem

Today every trace event is written individually on a serial dispatch queue.
In `appletrace/appletrace/src/appletrace.mm`, `Trace::WriteSection` (and the
sibling `WriteInstant` / `WriteCounter` / `WriteAsync`) do, per event:

1. Build a `std::string` JSON line via repeated `operator+` (several small heap
   allocations).
2. `dispatch_async(queue_, ^{ log_.AddLine(line); })` — which heap-copies the
   block (capturing the `std::string`) and enqueues onto the serial queue.

Under the automatic `objc_msgSend` hook this path runs millions of times per
second. The per-event `dispatch_async` (block alloc + enqueue + cross-thread
handoff) and the per-event string allocations dominate, distort the timings we
are trying to measure, and balloon queue memory under bursts.

Goal: amortize the cost so the hot path appends to a thread-local buffer with no
allocation and no cross-thread handoff in the common case, while a background
thread does the actual mmap writes in bulk.

### Non-goals
- Changing the on-disk fragment format or the merge/exporter (`merge.py`).
- Lock-free data structures. A per-buffer `os_unfair_lock` is cheap enough; the
  hot path stays uncontended because each thread locks only its own buffer.
- Changing the public API or event semantics.

## 2. Overview

Introduce a per-thread accumulation buffer. The hot path appends formatted
bytes to its own buffer under that buffer's lock. When the buffer crosses a
size threshold it is handed to the existing serial writer queue in one
`dispatch_async`. A global registry of buffers lets `APTFlush` drain every
thread, preserving the current flush contract.

```
hot path (any thread)                 writer queue (serial, existing)
  append line -> tls buffer  --(threshold/flush)-->  log_.AddLine(batch)
```

The existing `LoggerManager` / `Logger` (mmap + rollover) is reused unchanged:
it already accepts a string and appends it; we just hand it a large batch
string instead of one line. `AddLine` should be complemented by an
`AddBlock(const std::string&)` that writes a multi-line batch and handles
rollover mid-batch (split on the rollover boundary, or roll then continue).

## 3. Data structures

```cpp
struct ThreadLog {
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    std::string pending;          // accumulated, newline-terminated lines
    bool registered = false;
};
```

- `static thread_local ThreadLog* tls_log = nullptr;` — the calling thread's
  buffer (raw pointer; storage owned by the registry).
- Registry, owned by the singleton `Trace`:
  ```cpp
  std::mutex registry_mutex_;
  std::vector<std::unique_ptr<ThreadLog>> thread_logs_;
  ```
- Tunables (env-configurable, mirror existing `APPLETRACE_BLOCK_SIZE_MB`
  pattern): `kFlushThresholdBytes` (default 32 KiB), reserved capacity for
  `pending` (e.g. 64 KiB) to avoid reallocation churn.

## 4. Behavior

### 4.1 Acquire this thread's buffer (lazy)

```cpp
ThreadLog* Trace::AcquireThreadLog() {
    if (tls_log) return tls_log;
    auto owned = std::make_unique<ThreadLog>();
    owned->pending.reserve(kReserveBytes);
    ThreadLog* raw = owned.get();
    {
        std::lock_guard<std::mutex> g(registry_mutex_);
        thread_logs_.push_back(std::move(owned));
    }
    raw->registered = true;
    tls_log = raw;
    InstallThreadExitFlush();   // see 4.4
    return raw;
}
```

### 4.2 Append (hot path)

`WriteSection`/`WriteInstant`/`WriteCounter`/`WriteAsync` keep building the line
string exactly as today, then instead of `dispatch_async` per event:

```cpp
void Trace::Emit(const std::string& line) {
    if (!IsEnabled() || !queue_) return;
    ThreadLog* tl = AcquireThreadLog();
    std::string batch_to_ship;
    {
        os_unfair_lock_lock(&tl->lock);
        tl->pending.append(line);
        tl->pending.push_back('\n');
        if (tl->pending.size() >= kFlushThresholdBytes) {
            batch_to_ship.swap(tl->pending);   // hand off ownership, O(1)
            tl->pending.reserve(kReserveBytes);
        }
        os_unfair_lock_unlock(&tl->lock);
    }
    if (!batch_to_ship.empty()) {
        dispatch_async(queue_, ^{ log_.AddBlock(batch_to_ship); });
    }
}
```

Notes:
- The lock is held only around the append/swap; the `dispatch_async` happens
  after unlocking.
- `swap` makes the handoff allocation-free; the freshly reserved buffer keeps
  the hot path allocation-free across batches.
- The block captures `batch_to_ship` by copy (move-into-block via `__block` or a
  `std::shared_ptr<std::string>` is a valid optimization to avoid the copy).

### 4.3 Flush (cross-thread, preserves contract)

`APTFlush` must drain every thread's pending bytes, then flush the logger.

```cpp
void Trace::Flush() {
    if (!queue_) return;
    std::vector<std::string> batches;
    {
        std::lock_guard<std::mutex> g(registry_mutex_);   // blocks new registrations
        for (auto& tl : thread_logs_) {
            os_unfair_lock_lock(&tl->lock);
            if (!tl->pending.empty()) {
                batches.emplace_back(std::move(tl->pending));
                tl->pending.clear();
                tl->pending.reserve(kReserveBytes);
            }
            os_unfair_lock_unlock(&tl->lock);
        }
    }
    dispatch_sync(queue_, ^{
        for (auto& b : batches) log_.AddBlock(b);
        log_.Flush();
    });
}
```

Holding `registry_mutex_` for the whole drain prevents a thread from exiting and
freeing its `ThreadLog` mid-iteration (thread-exit also takes this lock, 4.4).
The hot path is unaffected because it only takes the per-buffer `os_unfair_lock`.

### 4.4 Thread exit

A thread that produced events must flush and deregister before its `ThreadLog`
is destroyed. Use a `thread_local` RAII guard whose destructor runs at thread
exit (the singleton `Trace`, a function-local static, outlives all threads):

```cpp
struct ThreadExitFlusher { ~ThreadExitFlusher(); };
static thread_local ThreadExitFlusher tls_exit_flusher;   // referenced in AcquireThreadLog
```

`~ThreadExitFlusher` (and a pthread-key fallback if `thread_local` destructor
ordering is a concern):
1. Take `registry_mutex_`.
2. Find this thread's `ThreadLog`, move out `pending`.
3. Erase it from `thread_logs_` (so a concurrent `Flush` cannot touch it).
4. Release the mutex; if `pending` is non-empty, `dispatch_async` the final
   batch.
5. `tls_log = nullptr`.

### 4.5 Disable / enable and shutdown

- `SetEnabled(false)` keeps the buffers; `Emit` early-returns so nothing
  accumulates. No flush is forced (matches today's drop-while-disabled).
- Process teardown: the existing `Logger::Close` (called from destructors) still
  truncates the mmap file to the written size. Any thread-local buffers not yet
  shipped at process exit are best-effort; document that callers should
  `APTFlush()` (or `APTSyncWait()`) before reading traces, as today.

## 5. Ordering

Chrome/Perfetto sort events by `ts`, so batching does not require global
emission order. Within a thread, order is preserved (append order). Across
threads, `ts` is the source of truth. The merge step already concatenates
fragments; no change needed.

## 6. Reentrancy & hook interaction

The `objc_msgSend` hook calls `APTBeginSection`/`APTEndSection` under its
`gTraceGuard` thread-local guard, so any Objective-C calls made *inside* the
runtime (e.g. building thread names) are not re-traced. `Emit` must avoid
triggering traced `objc_msgSend` on the hot path — it already uses C++ `std`
types and C locks, which is fine. `AcquireThreadLog`'s first-call allocation is
plain C++ (`std::make_unique`, `std::vector`), no Objective-C dispatch.

## 7. Edge cases / risks to verify on device

- **Static init/destruction order**: `tls_exit_flusher` destructor must run
  while the singleton `Trace` and its `queue_`/`log_` are still valid. Verify
  with a worker thread that exits before `main` returns.
- **Flush during thread exit**: covered by `registry_mutex_` serialization;
  add a stress test (many short-lived threads + concurrent `APTFlush`).
- **`AddBlock` rollover**: ensure a batch larger than the remaining mmap space
  rolls to a new fragment without dropping or splitting a line mid-JSON. Unit
  this at the `Logger` level.
- **Memory bound**: per-thread `pending` is capped near `kFlushThresholdBytes`
  between ships; total ≈ threads × threshold. Confirm acceptable.
- **OOM on append**: if `append` throws `bad_alloc`, the event is lost; catch
  and drop rather than propagate into app code.

## 8. Optional follow-on: binary events at runtime

The second Phase 2 bullet ("defer JSON formatting to the exporter") can build on
this:

- Replace the per-event `std::string` JSON with a fixed-size binary record
  `{ uint8 phase, uint64 ts, uint64 tid, uint32 name_id, double aux }` appended
  to `pending` (now a byte buffer). `name_id` reuses the hook's interning table;
  the runtime writes a `name_id -> string` table once per fragment.
- The exporter (`merge.py`) gains a binary fragment reader that emits the same
  Chrome JSON it produces today.
- This removes all string formatting from the hot path and shrinks fragments
  further. It is a larger change and should land after the batching writer is
  proven.

## 9. Verification plan (macOS)

1. **[done]** Build the framework and run `scripts/test_objc_msgsend_hook.sh`
   and `scripts/test_objc_msgsend_hook_experimental.sh` — output must match
   today's.
2. **[done]** Run `scripts/test_batching_stress.sh`: it builds `appletrace.mm` +
   `Tests/stress/stress_main.mm` for the host, emits N threads × M begin/end
   pairs (worker threads exit before the flush to exercise the drain path), and
   asserts the merged trace contains exactly N×M `stress` complete events — no
   loss, no duplication. Run it a few times; concurrency bugs are intermittent.
3. **[pending]** Profile `TraceAllMsgDemo` with Instruments before/after; compare wall-clock
   overhead and peak queue memory. Target: large reduction in `dispatch_async`
   count and per-event allocations.
