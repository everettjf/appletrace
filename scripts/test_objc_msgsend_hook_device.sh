#!/usr/bin/env bash
#
# On-device smoke test for the objc_msgSend hook + batched trace writer.
#
# Builds TraceAllMsgDemo, installs and launches it on a connected arm64
# device via `devicectl`, runs the experimental scenario (super dispatch,
# cross-thread events, stack-passed / floating-point arguments, small
# aggregate returns), pulls the trace back, and asserts the hook produced the
# expected events. Runs in both the binary (default) and text
# (APPLETRACE_FORMAT=text) output modes, merging with the `appletrace` CLI.
#
# Unlike scripts/test_objc_msgsend_hook.sh (Simulator) this needs a real,
# unlocked, developer-enabled device and a signing identity, so it is a local
# tool rather than a CI step. Set DEVICE_UDID to pick a specific device;
# otherwise the first connected iOS device is used.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE_ID="com.everettjf.TraceAllMsgDemo"
DERIVED_DATA_DIR="${ROOT_DIR}/build/TraceAllMsgDemoDevice"
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Debug-iphoneos/TraceAllMsgDemo.app"
WAIT_SECONDS="${WAIT_SECONDS:-8}"
DEVICE_ARCH="${DEVICE_ARCH:-arm64}"
DEVICE_DEPLOYMENT_TARGET="${DEVICE_DEPLOYMENT_TARGET:-15.0}"

# Resolve a connected iOS device: prints "<devicectl-identifier> <hardware-udid> <name>".
device_line="$(python3 - "${DEVICE_UDID:-}" <<'PY'
import json
import subprocess
import sys
import tempfile

requested = sys.argv[1]
with tempfile.NamedTemporaryFile(suffix=".json") as tmp:
    subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", tmp.name],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    devices = json.load(open(tmp.name))["result"]["devices"]

for dev in devices:
    hw = dev.get("hardwareProperties", {})
    conn = dev.get("connectionProperties", {})
    if hw.get("platform") != "iOS":
        continue
    udid = hw.get("udid", "")
    if requested:
        # devicectl reconnects an idle, paired device on demand.
        if requested not in (udid, dev.get("identifier")):
            continue
    elif conn.get("tunnelState") != "connected":
        continue
    print(dev.get("identifier"), udid, dev.get("deviceProperties", {}).get("name", ""))
    break
PY
)"

if [[ -z "${device_line}" ]]; then
  echo "No connected iOS device found (is it unlocked and developer-enabled?)." >&2
  exit 1
fi

DEVICE_ID="$(awk '{print $1}' <<<"${device_line}")"
DEVICE_UDID="$(awk '{print $2}' <<<"${device_line}")"
DEVICE_NAME="$(cut -d' ' -f3- <<<"${device_line}")"

echo "[1/4] Using device: ${DEVICE_NAME} (${DEVICE_UDID})"

(cd "${ROOT_DIR}" && swift build --product appletrace >/dev/null)
CLI="$(cd "${ROOT_DIR}" && swift build --product appletrace --show-bin-path)/appletrace"

echo "[2/4] Building sample app"
xcodebuild \
  -project "${ROOT_DIR}/sample/TraceAllMsgDemo/TraceAllMsgDemo.xcodeproj" \
  -scheme TraceAllMsgDemo \
  -configuration Debug \
  -destination "platform=iOS,id=${DEVICE_UDID}" \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  ARCHS="${DEVICE_ARCH}" \
  VALID_ARCHS="arm64 arm64e" \
  IPHONEOS_DEPLOYMENT_TARGET="${DEVICE_DEPLOYMENT_TARGET}" \
  -allowProvisioningUpdates \
  build >/tmp/appletrace-device-build.log 2>&1

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Build succeeded but app bundle not found: ${APP_PATH}" >&2
  echo "See /tmp/appletrace-device-build.log" >&2
  exit 1
fi

app_archs="$(lipo -archs "${APP_PATH}/TraceAllMsgDemo")"
if [[ " ${app_archs} " != *" ${DEVICE_ARCH} "* ]]; then
  echo "Built app does not contain requested ${DEVICE_ARCH} slice: ${app_archs}" >&2
  exit 1
fi
echo "      Built architecture: ${app_archs}"

xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}" >/dev/null

run_mode() {
  local label="$1"      # text | binary
  local format_env="$2" # extra JSON env entries, e.g. "\"APPLETRACE_FORMAT\":\"text\","
  local out_dir="${DERIVED_DATA_DIR}/trace-${label}"
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"

  echo "[3/4] (${label}) Launching experimental scenario"
  xcrun devicectl device process launch \
    --device "${DEVICE_ID}" \
    --terminate-existing \
    --environment-variables "{${format_env}\"APPLETRACE_EXPERIMENTAL_SCENARIO\":\"1\"}" \
    "${APP_BUNDLE_ID}" >/dev/null

  sleep "${WAIT_SECONDS}"

  echo "[4/4] (${label}) Pulling and verifying trace"
  xcrun devicectl device copy from \
    --device "${DEVICE_ID}" \
    --domain-type appDataContainer \
    --domain-identifier "${APP_BUNDLE_ID}" \
    --source Library/appletracedata \
    --destination "${out_dir}" >/dev/null

  local progress="${out_dir}/scenario-progress.log"
  if [[ ! -f "${progress}" ]]; then
    echo "[${label}] scenario-progress.log not found" >&2
    exit 1
  fi
  for marker in "doubleSum=55.00" "range=12,34" "insets=1.00,2.00,3.00,4.00"; do
    if ! grep -q "${marker}" "${progress}"; then
      echo "[${label}] ABI marker missing: ${marker}" >&2
      cat "${progress}" >&2
      exit 1
    fi
  done

  "${CLI}" merge "${out_dir}" >/dev/null
  case "${label}" in
    text) ls "${out_dir}"/trace*.appletrace >/dev/null ;;
    binary) ls "${out_dir}"/trace*.appletracebin >/dev/null ;;
  esac
  python3 - "${out_dir}/trace.json" "${label}" <<'PY'
import json
import sys

events = json.load(open(sys.argv[1]))
label = sys.argv[2]
text = json.dumps(events)
expected = (
    "process_name",
    "appletrace-experimental-scenario",
    "[AppDelegate]levelOne",
    "[AppDelegate]levelThree",
    "[AppDelegate]sumDoubles:b:c:d:e:f:g:h:i:j:",
    "[AppDelegate]makeRangeLocation:length:",
    "[AppDelegate]makeInsetsTop:left:bottom:right:",
    "[APTSuperBase]superPing",
    "[APTSuperChild]invokeSuperPing",
    "[ThreadTest]goLoop",
)
missing = [name for name in expected if name not in text]
if missing:
    raise SystemExit(f"[{label}] trace missing events: {missing}")
print(f"[{label}] OK: {len(events)} events, all expected hooked methods present")
PY
}

run_mode text '"APPLETRACE_FORMAT":"text",'
run_mode binary ""

echo "on-device objc_msgSend smoke test passed (text + binary)"
