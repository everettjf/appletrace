#!/usr/bin/env bash
#
# Host regression test for the objc_msgSend hook on an arm64 Mac.
#
# Builds Tests/hook/hook_main.m with the AppleTrace core and hook, plus a
# plugin dylib that the program dlopen()s *after* installing the hook, then
# asserts that sends from both images were traced and nested correctly.
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "skipping: the objc_msgSend hook needs an arm64 host" >&2
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/appletrace/appletrace/src"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "[build] hook host harness + plugin"
clang -fobjc-arc -O1 -c -I "${SRC_DIR}" "${SRC_DIR}/objc/hook_objc_msgSend.m" -o "${WORK_DIR}/hook.o"
clang++ -std=gnu++17 -fobjc-arc -O1 -c -I "${SRC_DIR}" "${SRC_DIR}/appletrace.mm" -o "${WORK_DIR}/core.o"
clang -fobjc-arc -O0 -c -I "${SRC_DIR}" "${ROOT_DIR}/Tests/hook/hook_main.m" -o "${WORK_DIR}/main.o"
clang++ "${WORK_DIR}/main.o" "${WORK_DIR}/core.o" "${WORK_DIR}/hook.o" -framework Foundation -o "${WORK_DIR}/hook_main"
clang -fobjc-arc -O0 -dynamiclib "${ROOT_DIR}/Tests/hook/hook_plugin.m" -framework Foundation -o "${WORK_DIR}/plugin.dylib"

(cd "${ROOT_DIR}" && swift build --product appletrace >/dev/null)
CLI="$(cd "${ROOT_DIR}" && swift build --product appletrace --show-bin-path)/appletrace"

echo "[run] hook host harness"
APPLETRACE_DATA_DIR="${WORK_DIR}/trace" "${WORK_DIR}/hook_main" "${WORK_DIR}/plugin.dylib"
"${CLI}" merge "${WORK_DIR}/trace" -o "${WORK_DIR}/trace.json" >/dev/null

python3 - "${WORK_DIR}/trace.json" <<'PY'
import json, sys
events = json.load(open(sys.argv[1]))
names = {e["name"] for e in events if e.get("ph") == "X"}
expected = [
    "[APTHostProbe]sumA:b:c:d:e:f:g:h:i:",
    "[APTHostProbe]ping",
    "[APTLatePlugin]answer",   # sent from an image loaded after the hook
]
missing = [n for n in expected if n not in names]
if missing:
    raise SystemExit(f"missing hooked events: {missing}")
unpaired = [e for e in events if e.get("ph") in ("B", "E")]
if unpaired:
    raise SystemExit(f"{len(unpaired)} unpaired hooked events")
print(f"OK: {len(names)} distinct hooked methods, late-loaded plugin traced, all paired")
PY
