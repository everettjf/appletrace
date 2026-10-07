#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="${ROOT_DIR}/Web/console"
RESOURCE_DIR="${ROOT_DIR}/Sources/AppleTraceServer/Resources/Console"

cd "${WEB_DIR}"
npm run typecheck
npm test
npm run build

mkdir -p "${RESOURCE_DIR}/assets"
find "${RESOURCE_DIR}" -type f -delete
cp "${WEB_DIR}/dist/index.html" "${RESOURCE_DIR}/index.html"
cp "${WEB_DIR}"/dist/assets/* "${RESOURCE_DIR}/assets/"

echo "AppleTrace Web Console copied to ${RESOURCE_DIR}"
