#!/usr/bin/env bash
#
# Builds the release artifacts into build/release/:
#   appletrace-<version>-macos.zip                 universal `appletrace` CLI
#   appletrace.xcframework.zip                     iOS device (arm64, arm64e) + Simulator (arm64, x86_64)
#   appletrace-loader_<version>_iphoneos-arm64.deb   jailbreak loader, rootless
#   appletrace-loader_<version>_iphoneos-arm64e.deb  jailbreak loader, roothide
#   SHA256SUMS
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^let toolVersion = "\(.*\)"/\1/p' "${ROOT_DIR}/Sources/AppleTraceCLI/main.swift")"
OUT_DIR="${ROOT_DIR}/build/release"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

echo "[cli] universal appletrace ${VERSION}"
(cd "${ROOT_DIR}" && swift build -c release --product appletrace --arch arm64 --arch x86_64 >/dev/null)
CLI_BIN="$(cd "${ROOT_DIR}" && swift build -c release --product appletrace --arch arm64 --arch x86_64 --show-bin-path)/appletrace"
mkdir -p "${WORK_DIR}/cli"
cp "${CLI_BIN}" "${WORK_DIR}/cli/appletrace"
codesign --force --sign - "${WORK_DIR}/cli/appletrace"
lipo -info "${WORK_DIR}/cli/appletrace"
"${WORK_DIR}/cli/appletrace" version
(cd "${WORK_DIR}/cli" && zip -q "${OUT_DIR}/appletrace-${VERSION}-macos.zip" appletrace)

echo "[xcframework] appletrace.framework"
archive() {
  local destination="$1" path="$2" archs="$3"
  xcodebuild archive \
    -project "${ROOT_DIR}/appletrace/appletrace.xcodeproj" \
    -scheme appletrace \
    -configuration Release \
    -destination "${destination}" \
    -archivePath "${path}" \
    ARCHS="${archs}" VALID_ARCHS="${archs}" ONLY_ACTIVE_ARCH=NO \
    SKIP_INSTALL=NO CODE_SIGNING_ALLOWED=NO >/dev/null
}
archive "generic/platform=iOS" "${WORK_DIR}/ios.xcarchive" "arm64 arm64e"
archive "generic/platform=iOS Simulator" "${WORK_DIR}/sim.xcarchive" "arm64 x86_64"
xcodebuild -create-xcframework \
  -framework "${WORK_DIR}/ios.xcarchive/Products/Library/Frameworks/appletrace.framework" \
  -framework "${WORK_DIR}/sim.xcarchive/Products/Library/Frameworks/appletrace.framework" \
  -output "${WORK_DIR}/appletrace.xcframework" >/dev/null
for slice in "${WORK_DIR}"/appletrace.xcframework/*/appletrace.framework/appletrace; do
  echo "  $(lipo -info "${slice}")"
done
(cd "${WORK_DIR}" && zip -qry "${OUT_DIR}/appletrace.xcframework.zip" appletrace.xcframework)

echo "[debs] jailbreak loader"
OUT_DIR="${OUT_DIR}" VERSION="${VERSION}" "${ROOT_DIR}/scripts/build_jailbreak_packages.sh" >/dev/null

(cd "${OUT_DIR}" && shasum -a 256 * > SHA256SUMS)
echo "done:"
ls -la "${OUT_DIR}"
