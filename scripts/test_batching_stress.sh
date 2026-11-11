#!/usr/bin/env bash
#
# Host stress test for the per-thread batched trace writer.
#
# Compiles appletrace.mm together with Tests/stress/stress_main.mm, runs a
# multithreaded workload in several configurations, merges each run with the
# `appletrace` CLI, and asserts that exactly the expected number of events
# survive with correct nesting (no loss, duplication or reordering).
#
# Configurations: text and binary formats, an aggressive 1 ms background
# drain, exit-time draining without APTFlush, SIGKILL after the background
# drain, fragment rollover, malformed configuration, an unwritable trace
# directory, and disabled tracing. Runs on macOS; independent of the simulator
# smoke tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/appletrace/appletrace/src"
WORK_DIR="$(mktemp -d)"
BIN_PATH="${WORK_DIR}/appletrace_stress"

cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

echo "[build] Compiling stress harness"
clang++ -std=gnu++11 -fobjc-arc -O2 -Wall \
  -I "${SRC_DIR}" \
  -framework Foundation \
  "${SRC_DIR}/appletrace.mm" \
  "${ROOT_DIR}/Tests/stress/stress_main.mm" \
  -o "${BIN_PATH}"

echo "[build] Building the appletrace CLI"
(cd "${ROOT_DIR}" && swift build --product appletrace >/dev/null)
CLI="$(cd "${ROOT_DIR}" && swift build --product appletrace --show-bin-path)/appletrace"

verify() {
  local label="$1" trace_json="$2" expected="$3"
  python3 - "${trace_json}" "${expected}" "${label}" <<'PY'
import collections
import json
import sys

events = json.load(open(sys.argv[1]))
expected = int(sys.argv[2])
label = sys.argv[3]
complete = [e for e in events if e.get("ph") == "X"]
counts = collections.Counter(e["name"] for e in complete)
unpaired = [e for e in events if e.get("ph") in ("B", "E")]

errors = []
for name in ("outer", "inner"):
    if counts[name] != expected:
        errors.append(f"{name}: {counts[name]} != {expected}")
dynamic = sum(v for k, v in counts.items() if k.startswith("dyn_"))
if dynamic != expected:
    errors.append(f"dyn_*: {dynamic} != {expected}")
if len([k for k in counts if k.startswith("dyn_")]) != 7:
    errors.append(f"expected 7 distinct dyn_ names, got {sorted(k for k in counts if k.startswith('dyn_'))}")
if unpaired:
    errors.append(f"{len(unpaired)} unpaired begin/end events")

# Every "inner" must sit inside an "outer" on the same thread.
by_thread = collections.defaultdict(list)
for e in complete:
    if e["name"] in ("outer", "inner"):
        by_thread[e["tid"]].append(e)
misnested = 0
for tid, items in by_thread.items():
    outers = sorted((e["ts"], e["ts"] + e["dur"]) for e in items if e["name"] == "outer")
    inners = sorted((e["ts"], e["ts"] + e["dur"]) for e in items if e["name"] == "inner")
    for (start, end), (istart, iend) in zip(outers, inners):
        if not (start <= istart and iend <= end):
            misnested += 1
if misnested:
    errors.append(f"{misnested} inner sections outside their outer section")

if errors:
    raise SystemExit(f"[{label}] FAILED: " + "; ".join(errors))
print(f"[{label}] OK: {expected} outer/inner/dyn sections each, nesting intact")
PY
}

run_mode() {
  local label="$1" mode="$2"
  shift 2  # remaining args are extra environment assignments
  local data_dir="${WORK_DIR}/${label}"
  local output_file="${WORK_DIR}/${label}.out"

  echo "[${label}] Running stress harness"
  if [[ "${mode}" == "hang" ]]; then
    env APPLETRACE_DATA_DIR="${data_dir}" "$@" "${BIN_PATH}" hang >"${output_file}" &
    local pid=$!
    for _ in $(seq 1 200); do
      grep -q READY "${output_file}" 2>/dev/null && break
      sleep 0.1
    done
    sleep 2.5  # > one background drain interval
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true
  else
    env APPLETRACE_DATA_DIR="${data_dir}" "$@" "${BIN_PATH}" ${mode} >"${output_file}"
  fi

  local expected
  expected="$(sed -n 's/^EXPECTED_STRESS_PAIRS=//p' "${output_file}")"
  if [[ -z "${expected}" ]]; then
    echo "[${label}] harness did not report an expected count" >&2
    exit 1
  fi
  "${CLI}" merge "${data_dir}" >/dev/null
  verify "${label}" "${data_dir}/trace.json" "${expected}"
}

run_mode text "" APPLETRACE_FORMAT=text
run_mode binary ""
run_mode legacy-binary-flag "" APPLETRACE_BINARY=1
run_mode fast-drain-binary "" APPLETRACE_FLUSH_INTERVAL_MS=1
run_mode fast-drain-text "" APPLETRACE_FLUSH_INTERVAL_MS=1 APPLETRACE_FORMAT=text
run_mode exit-drain no-flush
run_mode killed hang
run_mode killed-text hang APPLETRACE_FORMAT=text
run_mode rollover "" APPLETRACE_BLOCK_SIZE_MB=1
run_mode malformed-config "" APPLETRACE_BLOCK_SIZE_MB=12abc APPLETRACE_FLUSH_INTERVAL_MS=-3 \
  APPLETRACE_FORMAT=bogus APPLETRACE_ENABLED=maybe APPLETRACE_KEEP_EXISTING=perhaps

fragments="$(ls "${WORK_DIR}/rollover" | grep -c '^trace.*\.appletracebin$' || true)"
if [[ "${fragments}" -lt 2 ]]; then
  echo "[rollover] expected several fragments, got ${fragments}" >&2
  exit 1
fi
echo "[rollover] OK: ${fragments} fragments"

echo "[disabled] Running with APPLETRACE_ENABLED=0"
env APPLETRACE_DATA_DIR="${WORK_DIR}/disabled" APPLETRACE_ENABLED=0 "${BIN_PATH}" >/dev/null
if "${CLI}" merge "${WORK_DIR}/disabled" >/dev/null 2>&1; then
  python3 - "${WORK_DIR}/disabled/trace.json" <<'PY'
import json, sys
events = json.load(open(sys.argv[1]))
traced = [e for e in events if e.get("ph") not in ("M",)]
if traced:
    raise SystemExit(f"[disabled] FAILED: {len(traced)} events recorded while disabled")
print("[disabled] OK: only metadata recorded")
PY
else
  echo "[disabled] OK: no events recorded"
fi

echo "[unwritable] Running with an unwritable trace directory"
env APPLETRACE_DATA_DIR=/dev/null/appletrace "${BIN_PATH}" >/dev/null
echo "[unwritable] OK: no crash"

echo "batching stress test passed"
