#!/usr/bin/env bash
#
# Checks `appletrace summary` / `appletrace diff` end to end, including the
# exit statuses a CI job relies on: 0 = no regression, 2 = regression (or a
# missing span with --fail-on-missing), 1 = error.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

(cd "${ROOT_DIR}" && swift build --product appletrace >/dev/null)
CLI="$(cd "${ROOT_DIR}" && swift build --product appletrace --show-bin-path)/appletrace"

# write_trace <dir> <launch µs> <feed µs> [extra span]
write_trace() {
  local dir="$1" launch="$2" feed="$3" extra="${4:-}"
  mkdir -p "${dir}"
  {
    echo '{"name":"App.launch","cat":"appletrace","ph":"B","pid":1,"tid":0,"ts":0}'
    echo '{"name":"App.loadFeed","cat":"appletrace","ph":"B","pid":1,"tid":0,"ts":100}'
    echo "{\"name\":\"App.loadFeed\",\"cat\":\"appletrace\",\"ph\":\"E\",\"pid\":1,\"tid\":0,\"ts\":$((100 + feed))}"
    echo "{\"name\":\"App.launch\",\"cat\":\"appletrace\",\"ph\":\"E\",\"pid\":1,\"tid\":0,\"ts\":${launch}}"
    echo '{"name":"[UIView]layoutSubviews","cat":"appletrace","ph":"B","pid":1,"tid":0,"ts":200000}'
    echo '{"name":"[UIView]layoutSubviews","cat":"appletrace","ph":"E","pid":1,"tid":0,"ts":290000}'
    if [[ -n "${extra}" ]]; then
      echo "{\"name\":\"${extra}\",\"cat\":\"appletrace\",\"ph\":\"B\",\"pid\":1,\"tid\":0,\"ts\":300000}"
      echo "{\"name\":\"${extra}\",\"cat\":\"appletrace\",\"ph\":\"E\",\"pid\":1,\"tid\":0,\"ts\":305000}"
    fi
  } > "${dir}/trace.appletrace"
}

# expect <status> <description> <command...>
expect() {
  local want="$1" what="$2"
  shift 2
  set +e
  "$@" > "${WORK_DIR}/out.txt" 2>&1
  local got=$?
  set -e
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${what}: exit ${got}, expected ${want}" >&2
    cat "${WORK_DIR}/out.txt" >&2
    exit 1
  fi
  echo "ok: ${what} (exit ${got})"
}

write_trace "${WORK_DIR}/base" 100000 50000 App.extra
write_trace "${WORK_DIR}/same" 100500 50200 App.extra
write_trace "${WORK_DIR}/slow" 150000 90000
write_trace "${WORK_DIR}/run2" 110000 60000 App.extra

expect 0 "summary table" "${CLI}" summary "${WORK_DIR}/base"
grep -q "App.launch" "${WORK_DIR}/out.txt"
expect 0 "summary of two runs saved as a baseline" "${CLI}" summary "${WORK_DIR}/base" "${WORK_DIR}/run2" -o "${WORK_DIR}/baseline.json"
grep -q '"runs" : 2' "${WORK_DIR}/baseline.json"
grep -q '"format" : "appletrace-summary"' "${WORK_DIR}/baseline.json"
expect 0 "summary --json" "${CLI}" summary "${WORK_DIR}/base" --json --only App.
grep -q '"App.loadFeed"' "${WORK_DIR}/out.txt"
if grep -q "layoutSubviews" "${WORK_DIR}/out.txt"; then
  echo "FAIL: --only App. kept a [UIView] span" >&2
  exit 1
fi

expect 0 "diff within noise" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/same"
expect 2 "diff detects a regression" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow"
grep -q "regressed  App.loadFeed" "${WORK_DIR}/out.txt"
expect 0 "diff ignores spans outside --only" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --only "[UIView]"
expect 0 "diff with a generous threshold" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --threshold 100%
expect 0 "a removed span alone passes" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --only App.extra
expect 2 "--fail-on-missing fails on a removed span" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --only App.extra --fail-on-missing
expect 2 "diff against a saved summary" "${CLI}" diff "${WORK_DIR}/baseline.json" "${WORK_DIR}/slow" --metric p50
expect 2 "diff --json" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --json
grep -q '"failed":true' "${WORK_DIR}/out.txt"

"${CLI}" merge "${WORK_DIR}/slow" -o "${WORK_DIR}/slow.json" >/dev/null
expect 2 "diff reads merged trace JSON" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow.json"

expect 1 "missing input is an error" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/nope"
expect 1 "bad --metric is an error" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --metric fastest
expect 1 "bad --min-delta is an error" "${CLI}" diff "${WORK_DIR}/base" "${WORK_DIR}/slow" --min-delta soon

echo "PASS: summary / diff CI gates"
