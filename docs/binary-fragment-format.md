# AppleTrace Binary Fragment Format

Status: **default output format since 2.0** (`APPLETRACE_FORMAT=text` selects
JSON lines). Decoded by `AppleTraceKit` (the `appletrace merge` CLI) and by the
legacy `appletrace_binary.py` / `merge.py`. Verified by the host stress test
(`scripts/test_batching_stress.sh`) and on-device runs.

## Why

The text format writes one JSON line per event, so every event pays for string
formatting on (or near) the hot path. The binary format keeps formatting off the
hot path entirely: each unique event name is interned once, and events are
fixed-layout records that reference a name by id. The exporter (`merge.py`)
decodes fragments back into the exact Chrome/Perfetto JSON it already produces,
so Perfetto/visualization is unchanged.

## Layout (little-endian)

```
header:
    magic   : 8 bytes  = "APLTRC01"
    pid     : uint32

records (repeated until 0x00 tag or EOF):
    0x00            end / zero padding  -> stop decoding
    0x01            string definition   -> name_id:uint32  len:uint32  utf8[len]
    <ASCII phase>   event               -> name_id:uint32  tid:uint64  ts:uint64  arg:uint64
```

- A string definition assigns `name_id -> string`. The producer emits it the
  first time a name is used; later events reference the id. Decoders build the
  table in stream order, so fragments are self-contained.
- `pid` is constant per fragment (per process) and is injected into every
  decoded event.
- `ts` is microseconds since trace start (ignored for `M`).

### Phase tags and `arg`

| phase | meaning            | `arg`                              | decoded JSON extras            |
|-------|--------------------|------------------------------------|--------------------------------|
| `B`   | section begin      | 0                                  | `cat`, `ts`                    |
| `E`   | section end        | 0                                  | `cat`, `ts`                    |
| `i`   | instant            | 0                                  | `cat`, `ts`, `s:"t"`           |
| `C`   | counter            | IEEE-754 double bits of the value  | `cat`, `ts`, `args.value`      |
| `b`   | async begin        | async id                           | `cat`, `ts`, `id`              |
| `e`   | async end          | async id                           | `cat`, `ts`, `id`              |
| `M`   | metadata           | name_id of the value string        | `args.name` (no `cat`/`ts`)    |

Counter values are decoded as an integer when integral (e.g. `60`), else a
float (e.g. `142.5`), matching the text producer.

## Robustness

- Decoding stops at a `0x00` tag, so zero padding left by a crashed process
  (an mmap region not truncated on clean close) is tolerated, exactly like the
  text path's trailing-garbage handling.
- Truncated records at EOF stop decoding instead of raising.
- An event referencing an undefined `name_id` is a hard error (corruption).

## Exporter integration

- `appletrace_binary.py` provides `MAGIC`, `is_binary_fragment(bytes)`,
  `decode(bytes)`, and an `Encoder` (reference producer, used by tests).
- `merge.py` discovers `trace[_N].appletrace` (text) and
  `trace[_N].appletracebin` (binary) fragments, detects each file by magic, and
  decodes accordingly. Both feed the same `X`-complete-event collapsing.

## Runtime producer (implemented)

The native writer in `appletrace.mm` is the default (`APPLETRACE_FORMAT=binary`):

- Appends fixed-layout records to the per-thread batch buffer (byte buffers
  after the batching change) instead of JSON text.
- Interning is **per thread**: each thread keeps its own `(string -> name_id)`
  map and emits a string definition the first time it uses a name, drawing a
  globally-unique id from an atomic counter. So a thread only ever references
  ids it defined — there is no cross-thread ordering hazard with batched
  flushing (a process-wide table with single definitions would be unsafe, since
  another thread could flush a reference before the defining thread flushes the
  definition). The same string may therefore get one id per thread.
- The exporter shares one name table across a run's fragments, so a reference in
  a later fragment resolves a definition emitted in an earlier one (after
  rollover a thread does not re-emit a definition).
- Fragments are named `trace[_N].appletracebin`; each begins with the
  magic+pid header. `LoggerManager` writes the header on every fragment and
  rolls over whole batches so a record is never split across files.

Keeping it opt-in preserves the text path (and the existing smoke-test
assertions) until the binary path is validated on device.
