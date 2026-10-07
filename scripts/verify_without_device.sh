#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$(mktemp -d /tmp/appletrace-arm64e-derived.XXXXXX)"

cleanup() {
  rm -rf "${DERIVED_DATA_DIR}"
}
trap cleanup EXIT

cd "${ROOT_DIR}"

echo "[1/10] Swift package tests"
swift test

echo "[2/10] Python exporter tests"
python3 -m unittest discover -s Tests -p 'test_*.py'

echo "[3/10] Text and binary writer stress test"
./scripts/test_batching_stress.sh

echo "[4/10] Embedded Web Console"
./scripts/build_web_console.sh

echo "[5/10] Jailbreak Agent/daemon protocol"
./scripts/test_jailbreak_ipc.sh

echo "[6/10] Jailbreak multi-Agent control server"
./scripts/test_jailbreak_control.sh

echo "[7/10] Standard simulator hook scenario"
./scripts/test_objc_msgsend_hook.sh

echo "[8/10] Experimental simulator ABI and late-image scenario"
./scripts/test_objc_msgsend_hook_experimental.sh

echo "[9/10] iOS arm64e compile and slice inspection"
xcodebuild \
  -project sample/TraceAllMsgDemo/TraceAllMsgDemo.xcodeproj \
  -scheme TraceAllMsgDemo \
  -configuration Debug \
  -sdk iphoneos \
  -destination generic/platform=iOS \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  ARCHS=arm64e \
  "VALID_ARCHS=arm64 arm64e" \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_BINARY="${DERIVED_DATA_DIR}/Build/Products/Debug-iphoneos/TraceAllMsgDemo.app/TraceAllMsgDemo"
FRAMEWORK_BINARY="${DERIVED_DATA_DIR}/Build/Products/Debug-iphoneos/TraceAllMsgDemo.app/Frameworks/appletrace.framework/appletrace"
[[ "$(lipo -archs "${APP_BINARY}")" == "arm64e" ]]
[[ "$(lipo -archs "${FRAMEWORK_BINARY}")" == "arm64e" ]]

echo "[10/10] AppleTraceServer iOS cross-build"
swift build --triple arm64-apple-ios15.0 --target AppleTraceServer

if [[ "${RUN_THEOS_PACKAGE_TESTS:-0}" == "1" ]]; then
  if [[ -z "${THEOS:-}" || ! -d "${THEOS}" ]]; then
    echo "RUN_THEOS_PACKAGE_TESTS=1 requires THEOS to name an installed Theos checkout." >&2
    exit 1
  fi
  echo "[extra] Rootless and rootful Theos packages"
  ./scripts/test_jailbreak_packages.sh
fi

echo "All checks available without a physical device passed."
