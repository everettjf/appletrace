#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

clang -fobjc-arc -framework Foundation \
  -I"${ROOT_DIR}/Jailbreak/Daemon" \
  "${ROOT_DIR}/Jailbreak/Daemon/main.m" \
  "${ROOT_DIR}/Jailbreak/Daemon/AgentRegistry.m" \
  "${ROOT_DIR}/Jailbreak/Daemon/ControlServer.m" \
  -o "${WORK_DIR}/appletraced"

clang -fobjc-arc -framework Foundation \
  -I"${ROOT_DIR}/appletrace/appletrace/src" \
  -I"${ROOT_DIR}/Jailbreak/Tweak" \
  "${ROOT_DIR}/tests/jailbreak/agent_transport_harness.m" \
  "${ROOT_DIR}/Jailbreak/Tweak/AgentTransport.m" \
  -o "${WORK_DIR}/agent_harness"

python3 "${ROOT_DIR}/tests/jailbreak/test_daemon_control.py" \
  "${WORK_DIR}/appletraced" \
  "${WORK_DIR}/agent_harness" \
  "${ROOT_DIR}/Sources/AppleTraceServer/Resources/Console"
