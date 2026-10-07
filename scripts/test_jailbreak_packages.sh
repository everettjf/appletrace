#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JAILBREAK_DIR="${ROOT_DIR}/Jailbreak"

if [[ -z "${THEOS:-}" || ! -d "${THEOS}/makefiles" ]]; then
  echo "THEOS must point to an installed Theos checkout." >&2
  exit 1
fi

assert_slices() {
  local binary="$1"
  local slices
  slices="$(lipo -archs "${binary}")"
  [[ " ${slices} " == *" arm64 "* ]]
  [[ " ${slices} " == *" arm64e "* ]]
}

assert_stage() {
  local prefix="$1"
  local expected_program="$2"
  local stage="${JAILBREAK_DIR}/.theos/_${prefix}"
  local tweak="${stage}/Library/MobileSubstrate/DynamicLibraries/AppleTraceTweak.dylib"
  local daemon="${stage}/usr/libexec/appletraced"
  local launchd="${stage}/Library/LaunchDaemons/com.everettjf.appletraced.plist"
  local console="${stage}/usr/share/appletrace/console"
  local javascript
  local stylesheet

  [[ -f "${tweak}" && -f "${daemon}" && -f "${launchd}" ]]
  [[ -s "${console}/index.html" ]]
  javascript="$(find "${console}/assets" -type f -name '*.js' -size +0c -print -quit)"
  stylesheet="$(find "${console}/assets" -type f -name '*.css' -size +0c -print -quit)"
  [[ -n "${javascript}" && -n "${stylesheet}" ]]
  assert_slices "${tweak}"
  assert_slices "${daemon}"
  plutil -lint "${launchd}" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${launchd}")" == "${expected_program}" ]]
}

cd "${JAILBREAK_DIR}"

echo "[rootless] Building arm64 + arm64e package"
make clean package THEOS_PACKAGE_SCHEME=rootless
assert_stage "/var/jb" "/var/jb/usr/libexec/appletraced"
[[ -n "$(find packages -maxdepth 1 -type f -name '*_iphoneos-arm64.deb' -print -quit)" ]]

echo "[rootful] Building arm64 + arm64e package"
make clean package THEOS_PACKAGE_SCHEME=
assert_stage "" "/usr/libexec/appletraced"
[[ -n "$(find packages -maxdepth 1 -type f -name '*_iphoneos-arm.deb' -print -quit)" ]]

echo "jailbreak rootless/rootful package validation passed"
