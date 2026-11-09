#!/usr/bin/env bash
#
# Builds the AppleTraceLoader tweak packages for jailbroken devices:
#
#   build/jailbreak/appletrace-loader_<version>_iphoneos-arm64.deb   rootless (/var/jb)
#   build/jailbreak/appletrace-loader_<version>_iphoneos-arm64e.deb  roothide
#
# Both contain the same universal (arm64 + arm64e) binaries:
#   Library/MobileSubstrate/DynamicLibraries/AppleTraceLoader.{dylib,plist}
#   Library/Frameworks/appletrace.framework/appletrace   (core + objc_msgSend hook)
#
# Needs Xcode, ldid (brew install ldid) and xz. No Theos required.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(sed -n 's/^let toolVersion = "\(.*\)"/\1/p' "${ROOT_DIR}/Sources/AppleTraceCLI/main.swift")}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/jailbreak}"
WORK_DIR="$(mktemp -d)"
SRC_DIR="${ROOT_DIR}/appletrace/appletrace/src"
MIN_IOS="${MIN_IOS:-15.0}"

cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

command -v ldid >/dev/null || { echo "ldid not found (brew install ldid)" >&2; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"

compile() {
  local arch="$1" output="$2"; shift 2
  "${CLANG}" -isysroot "${SDK}" -target "${arch}-apple-ios${MIN_IOS}" -fobjc-arc -O2 -Wall -c "$@" -o "${output}"
}

link() {
  local arch="$1" output="$2"; shift 2
  "${CLANG}" -isysroot "${SDK}" -target "${arch}-apple-ios${MIN_IOS}" -dynamiclib "$@" -o "${output}"
}

lipo_and_sign() {
  local name="$1"
  lipo -create "${WORK_DIR}/${name}.arm64" "${WORK_DIR}/${name}.arm64e" -output "${WORK_DIR}/${name}"
  ldid -S "${WORK_DIR}/${name}"
}

for arch in arm64 arm64e; do
  echo "[build] appletrace.framework (${arch})"
  compile "${arch}" "${WORK_DIR}/core.${arch}.o" -I "${SRC_DIR}" -std=gnu++17 -x objective-c++ "${SRC_DIR}/appletrace.mm"
  compile "${arch}" "${WORK_DIR}/hook.${arch}.o" -I "${SRC_DIR}" -x objective-c "${SRC_DIR}/objc/hook_objc_msgSend.m"
  link "${arch}" "${WORK_DIR}/appletrace.${arch}" "${WORK_DIR}/core.${arch}.o" "${WORK_DIR}/hook.${arch}.o" \
    -install_name /Library/Frameworks/appletrace.framework/appletrace -framework Foundation -lc++

  echo "[build] AppleTraceLoader.dylib (${arch})"
  compile "${arch}" "${WORK_DIR}/loader.${arch}.o" "${ROOT_DIR}/loader/AppleTraceLoader.m"
  link "${arch}" "${WORK_DIR}/AppleTraceLoader.${arch}" "${WORK_DIR}/loader.${arch}.o" \
    -install_name /Library/MobileSubstrate/DynamicLibraries/AppleTraceLoader.dylib -framework Foundation
done
lipo_and_sign appletrace
lipo_and_sign AppleTraceLoader

write_ar() {
  # Minimal System V ar writer (dpkg needs ar format; macOS ar adds BSD quirks).
  python3 - "$@" <<'PY'
import os, sys
out, *members = sys.argv[1:]
with open(out, "wb") as archive:
    archive.write(b"!<arch>\n")
    for path in members:
        data = open(path, "rb").read()
        name = (os.path.basename(path) + "/").encode()
        header = b"%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 0, 0, 0, b"100644", len(data))
        archive.write(header)
        archive.write(data)
        if len(data) % 2:
            archive.write(b"\n")
PY
}

package() {
  local flavor="$1" arch="$2" prefix="$3"
  local stage="${WORK_DIR}/stage-${flavor}"
  local root="${stage}/data${prefix}"
  mkdir -p "${root}/Library/MobileSubstrate/DynamicLibraries" \
           "${root}/Library/Frameworks/appletrace.framework/Headers" \
           "${root}/var/mobile/Library/AppleTrace" \
           "${stage}/control"

  cp "${WORK_DIR}/AppleTraceLoader" "${root}/Library/MobileSubstrate/DynamicLibraries/AppleTraceLoader.dylib"
  cp "${ROOT_DIR}/loader/AppleTraceLoader.plist" "${root}/Library/MobileSubstrate/DynamicLibraries/AppleTraceLoader.plist"
  cp "${WORK_DIR}/appletrace" "${root}/Library/Frameworks/appletrace.framework/appletrace"
  cp "${SRC_DIR}/appletrace.h" "${root}/Library/Frameworks/appletrace.framework/Headers/appletrace.h"
  sed "s/@VERSION@/${VERSION}/" "${ROOT_DIR}/loader/Info.plist" > "${root}/Library/Frameworks/appletrace.framework/Info.plist"
  chmod 755 "${root}/var/mobile/Library/AppleTrace"

  sed -e "s/@VERSION@/${VERSION}/" -e "s/@ARCH@/${arch}/" \
    "${ROOT_DIR}/loader/control" > "${stage}/control/control"
  local size
  size="$(du -sk "${stage}/data" | cut -f1)"
  echo "Installed-Size: ${size}" >> "${stage}/control/control"

  printf '2.0\n' > "${stage}/debian-binary"
  (cd "${stage}/control" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname wheel \
     -czf "${stage}/control.tar.gz" .)
  (cd "${stage}/data" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname wheel \
     -cf - . | xz -9 > "${stage}/data.tar.xz")

  mkdir -p "${OUT_DIR}"
  local deb="${OUT_DIR}/appletrace-loader_${VERSION}_${arch}.deb"
  rm -f "${deb}"
  write_ar "${deb}" "${stage}/debian-binary" "${stage}/control.tar.gz" "${stage}/data.tar.xz"
  echo "[package] ${flavor}: ${deb}"
}

package rootless iphoneos-arm64 /var/jb
package roothide iphoneos-arm64e ""

echo "done: $(ls "${OUT_DIR}"/*.deb | tr '\n' ' ')"
