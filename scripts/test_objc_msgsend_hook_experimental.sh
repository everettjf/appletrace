#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPLETRACE_EXPERIMENTAL_SCENARIO=1 WAIT_SECONDS="${WAIT_SECONDS:-12}" "${ROOT_DIR}/scripts/test_objc_msgsend_hook.sh"
