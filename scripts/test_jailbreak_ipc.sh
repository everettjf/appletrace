#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/appletrace-ipc.XXXXXX)"
SOCKET_PATH="${WORK_DIR}/appletraced.sock"
DAEMON_LOG="${WORK_DIR}/daemon.log"
DAEMON_PID=""

cleanup() {
  if [[ -n "${DAEMON_PID}" ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
    kill "${DAEMON_PID}" 2>/dev/null || true
    wait "${DAEMON_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

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

APPLETRACE_DAEMON_SOCKET="${SOCKET_PATH}" APPLETRACE_CONTROL_PORT=31338 \
  APPLETRACE_CONTROL_TOKEN=test-token APPLETRACE_CONSOLE_PATH="${ROOT_DIR}/Sources/AppleTraceServer/Resources/Console" \
  APPLETRACE_TEST_COMMANDS=start,filters,flush,stop \
  "${WORK_DIR}/appletraced" >"${DAEMON_LOG}" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 100); do
  [[ -S "${SOCKET_PATH}" ]] && break
  sleep 0.02
done
[[ -S "${SOCKET_PATH}" ]]

APPLETRACE_DAEMON_SOCKET="${SOCKET_PATH}" "${WORK_DIR}/agent_harness"

for _ in $(seq 1 100); do
  grep -q 'AppleTrace agent connected' "${DAEMON_LOG}" && break
  sleep 0.02
done
grep -q 'AppleTrace agent connected' "${DAEMON_LOG}"
grep -q 'bundleIdentifier' "${DAEMON_LOG}"
status_count="$(grep -c 'AppleTrace agent status' "${DAEMON_LOG}")"
[[ "${status_count}" -ge 4 ]]
echo "jailbreak agent/daemon IPC smoke test passed"
