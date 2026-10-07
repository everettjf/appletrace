#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR_NAME="${SIMULATOR_NAME:-}"
WAIT_SECONDS="${WAIT_SECONDS:-10}"
SIMULATOR_DEPLOYMENT_TARGET="${SIMULATOR_DEPLOYMENT_TARGET:-15.0}"
EXPERIMENTAL_SCENARIO="${APPLETRACE_EXPERIMENTAL_SCENARIO:-0}"
APP_BUNDLE_ID="com.everettjf.TraceAllMsgDemo"
DERIVED_DATA_DIR="${ROOT_DIR}/build/TraceAllMsgDemoDerived"
APP_BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/Debug-iphonesimulator"
APP_PATH="${APP_BUILD_DIR}/TraceAllMsgDemo.app"
CRASH_DIR="${HOME}/Library/Logs/DiagnosticReports"

readarray_output="$(python3 - "${SIMULATOR_NAME}" <<'PY'
import json
import subprocess
import sys

requested_name = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
candidates = []
for runtime, devices in data["devices"].items():
    for device in devices:
        name = device.get("name", "")
        if not name.startswith("iPhone"):
            continue
        if requested_name and name != requested_name:
            continue
        candidates.append((device.get("state") == "Booted", runtime, name, device["udid"]))

if not candidates:
    sys.exit(1)

candidates.sort(key=lambda item: (not item[0], item[1], item[2]))
selected = candidates[0]
print(selected[2])
print(selected[3])
PY
)"

if [[ -z "${readarray_output}" ]]; then
  echo "No available iPhone simulator found." >&2
  exit 1
fi

SIMULATOR_NAME="$(printf '%s\n' "${readarray_output}" | sed -n '1p')"
DEVICE_ID="$(printf '%s\n' "${readarray_output}" | sed -n '2p')"

echo "[1/7] Booting simulator: ${SIMULATOR_NAME}"
xcrun simctl boot "${DEVICE_ID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${DEVICE_ID}" -b

echo "[2/7] Building sample app"
xcodebuild \
  -project "${ROOT_DIR}/sample/TraceAllMsgDemo/TraceAllMsgDemo.xcodeproj" \
  -scheme TraceAllMsgDemo \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  build CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET="${SIMULATOR_DEPLOYMENT_TARGET}" >/tmp/appletrace-smoke-build.log

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Build succeeded but app bundle not found: ${APP_PATH}" >&2
  exit 1
fi

echo "[2/7] Building late-loaded hook probe"
SIMULATOR_SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang \
  -dynamiclib \
  -fobjc-arc \
  -arch arm64 \
  -mios-simulator-version-min="${SIMULATOR_DEPLOYMENT_TARGET}" \
  -isysroot "${SIMULATOR_SDK_PATH}" \
  -framework Foundation \
  "${ROOT_DIR}/sample/TraceAllMsgDemo/LateLoadedProbe.m" \
  -o "${APP_PATH}/TraceLateLoad.dylib"

MARKER_FILE="$(mktemp)"
touch "${MARKER_FILE}"

echo "[3/7] Reinstalling app"
xcrun simctl uninstall "${DEVICE_ID}" "${APP_BUNDLE_ID}" >/dev/null 2>&1 || true
xcrun simctl install "${DEVICE_ID}" "${APP_PATH}"
DATA_CONTAINER="$(xcrun simctl get_app_container "${DEVICE_ID}" "${APP_BUNDLE_ID}" data)"

if [[ "${EXPERIMENTAL_SCENARIO}" == "1" ]]; then
  mkdir -p "${DATA_CONTAINER}/Library"
  : > "${DATA_CONTAINER}/Library/appletrace_experimental.flag"
fi

echo "[4/7] Launching app"
if [[ "${EXPERIMENTAL_SCENARIO}" == "1" ]]; then
  SIMCTL_CHILD_APPLETRACE_EXPERIMENTAL_SCENARIO=1 xcrun simctl launch "${DEVICE_ID}" "${APP_BUNDLE_ID}" --args -AppleTraceExperimentalScenario
else
  xcrun simctl launch "${DEVICE_ID}" "${APP_BUNDLE_ID}"
fi

echo "[5/7] Waiting up to ${WAIT_SECONDS}s for hook install and trace flush"
python3 - "${DATA_CONTAINER}/Library/appletracedata" "${WAIT_SECONDS}" "${EXPERIMENTAL_SCENARIO}" <<'PY'
import pathlib
import sys
import time

trace_directory = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + float(sys.argv[2])
experimental = sys.argv[3] == "1"
while time.monotonic() < deadline:
    trace_data = b""
    for path in trace_directory.glob("*.appletrace"):
        trace_data += path.read_bytes().replace(b"\x00", b"")
    if experimental:
        progress = trace_directory / "scenario-progress.log"
        progress_text = progress.read_text(errors="ignore") if progress.exists() else ""
        if "runTraceScenario:block2-after-flush" in progress_text and b"[APTLateLoadedProbe]run" in trace_data:
            raise SystemExit(0)
    elif b"appletrace-smoke-scenario" in trace_data:
        raise SystemExit(0)
    time.sleep(0.2)
PY

echo "[6/7] Checking for crashes"
crash_files="$(find "${CRASH_DIR}" -maxdepth 1 -name 'TraceAllMsgDemo-*.ips' -newer "${MARKER_FILE}" | sort)"
if [[ -n "${crash_files}" ]]; then
  echo "Crash detected:"
  printf '%s\n' "${crash_files}"
  exit 1
fi

echo "[7/7] Checking trace output"
TRACE_DIR="${DATA_CONTAINER}/Library/appletracedata"
PROGRESS_LOG="${TRACE_DIR}/scenario-progress.log"

print_experimental_progress() {
  if [[ "${EXPERIMENTAL_SCENARIO}" != "1" || ! -f "${PROGRESS_LOG}" ]]; then
    return
  fi

  echo "Experimental progress log:"
  cat "${PROGRESS_LOG}"

  if [[ "$(wc -l < "${PROGRESS_LOG}" | tr -d ' ')" == "1" ]] && [[ "$(head -n 1 "${PROGRESS_LOG}" | tr -d '\r')" == "runTraceScenario:entry" ]]; then
    echo "Diagnostic: objc_msgSend direct hook entered runTraceScenario, but the first nested Objective-C message send did not complete."
  fi
}

assert_experimental_progress() {
  if [[ "${EXPERIMENTAL_SCENARIO}" != "1" || ! -f "${PROGRESS_LOG}" ]]; then
    return 0
  fi

  if ! grep -q '^runTraceScenario:doubleSum=55.00$' "${PROGRESS_LOG}"; then
    echo "Experimental progress log:"
    cat "${PROGRESS_LOG}"
    echo "Diagnostic: floating-point objc_msgSend arguments or return value were not preserved." >&2
    return 1
  fi

  if ! grep -q '^runTraceScenario:range=12,34$' "${PROGRESS_LOG}"; then
    echo "Experimental progress log:"
    cat "${PROGRESS_LOG}"
    echo "Diagnostic: pair-register Objective-C struct return was not preserved." >&2
    return 1
  fi

  if ! grep -q '^runTraceScenario:insets=1.00,2.00,3.00,4.00$' "${PROGRESS_LOG}"; then
    echo "Experimental progress log:"
    cat "${PROGRESS_LOG}"
    echo "Diagnostic: floating-point aggregate Objective-C return was not preserved." >&2
    return 1
  fi
}

if [[ ! -d "${TRACE_DIR}" ]]; then
  echo "Trace directory not found: ${TRACE_DIR}" >&2
  exit 1
fi

trace_files="$(find "${TRACE_DIR}" -maxdepth 1 -type f -name '*.appletrace' | sort)"
if [[ -z "${trace_files}" ]]; then
  print_experimental_progress
  echo "No trace fragments found in ${TRACE_DIR}" >&2
  exit 1
fi

echo "Trace fragments:"
printf '%s\n' "${trace_files}"
if ! APPLETRACE_EXPERIMENTAL_SCENARIO="${EXPERIMENTAL_SCENARIO}" python3 - "${TRACE_DIR}" <<'PY'
import pathlib
import os
import sys

trace_directory = pathlib.Path(sys.argv[1])
trace_paths = sorted(trace_directory.glob("*.appletrace"))
data = b"\n".join(path.read_bytes().replace(b"\x00", b"") for path in trace_paths if path.stat().st_size)
if not data:
    raise SystemExit("trace fragments are empty")
text = data.decode("utf-8", errors="ignore")
if '"name":"process_name"' not in text:
    raise SystemExit("trace missing process_name metadata")
if 'appletrace-smoke-scenario' not in text:
    raise SystemExit("trace missing smoke scenario events")
if '"cat":"appletrace","ph":"B"' not in text:
    raise SystemExit("trace missing hooked begin events")
if os.environ.get("APPLETRACE_EXPERIMENTAL_SCENARIO") == "1":
    if 'appletrace-experimental-scenario' not in text:
        raise SystemExit("trace missing experimental scenario sentinel")
    expected = (
        "[AppDelegate]levelOne",
        "[AppDelegate]levelTwo",
        "[AppDelegate]levelThree",
        "[AppDelegate]manyArgs:a2:a3:a4:a5:a6:a7:a8:a9:a10:",
        "[AppDelegate]sumDoubles:b:c:d:e:f:g:h:i:j:",
        "[AppDelegate]makeRangeLocation:length:",
        "[AppDelegate]makeInsetsTop:left:bottom:right:",
        "[APTSuperBase]superPing",
        "[APTSuperChild]invokeSuperPing",
        "[ThreadTest]goLoop",
        "[AppDelegate]filterAllowedProbe",
        "[APTLateLoadedProbe]run",
    )
    if not all(name in text for name in expected):
        raise SystemExit("trace missing experimental sample method events")
    if "[AppDelegate]filterDeniedProbe" in text:
        raise SystemExit("runtime class filter did not suppress denied probe")
for line in text.splitlines()[:10]:
    print(line)
PY
then
  print_experimental_progress
  exit 1
fi
if ! assert_experimental_progress; then
  exit 1
fi
