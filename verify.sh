#!/usr/bin/env bash
# Verify an installed DeepSeek off-peak guard. Exit 0 when everything holds,
# 1 when something does not. Nothing is changed.
#
#   ./verify.sh [path/to/deepseek-window.sh]
set -uo pipefail

GUARD="${1:-${HOME}/.copilot/hooks/deepseek-window.sh}"
REAL_STATE_DIR="${HOME}/.deepseek-window"
FAILED=0

if [[ ! -x "${GUARD}" ]]; then
  echo "guard not found or not executable: ${GUARD}" >&2
  exit 1
fi

# Check the guard on a private state directory, so a workload override, parked
# handoff, or log from the real install cannot distort the results.
TMP_STATE="$(mktemp -d)"
export AI_WINDOW_STATE_DIR="${TMP_STATE}"
unset AI_WINDOW_OVERRIDE AI_WINDOW_OVERRIDE_REASON AI_WINDOW_MAINTENANCE
unset AI_WINDOW_TZ 2>/dev/null || true
trap 'rm -rf "${TMP_STATE}"' EXIT

fail() { echo "  FAIL  $*"; FAILED=1; }
ok() { echo "  ok    $*"; }

echo "guard: ${GUARD}"

echo "peak/off-peak boundaries (UTC)"
while read -r clock want; do
  if AI_WINDOW_TEST_NOW="${clock}" "${GUARD}" >/dev/null 2>&1; then got=allow; else got=deny; fi
  if [[ "${got}" == "${want}" ]]; then
    ok "${clock} -> ${got}"
  else
    fail "${clock} -> ${got}, expected ${want}"
  fi
done <<'CASES'
00:30 allow
01:00 deny
03:59 deny
04:00 allow
05:59 allow
06:00 deny
09:59 deny
10:00 allow
23:30 allow
CASES

echo "hook contract"
peak="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"read_file"}' |
  AI_WINDOW_TEST_NOW=02:00 "${GUARD}" --hook)"
case "${peak}" in
  *'"permissionDecision":"deny"'*) ok "peak-hours PreToolUse is denied" ;;
  *) fail "peak-hours PreToolUse is not denied: ${peak}" ;;
esac
case "${peak}" in
  *'"continue":false'*) ok "peak-hours PreToolUse stops the session" ;;
  *) fail "peak-hours PreToolUse does not stop the session" ;;
esac
open="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"read_file"}' |
  AI_WINDOW_TEST_NOW=11:00 "${GUARD}" --hook)"
case "${open}" in
  '{}' | '{"hookSpecificOutput"'*)
    ok "off-peak PreToolUse is allowed" ;;
  *) fail "off-peak PreToolUse returned: ${open}" ;;
esac

echo "timezone"
# The windows are on this machine's clock; the guard must say so, and say the
# UTC equivalent too, or an owner in another zone has to do date math.
local_zone="$(date +%Z)"
if [[ "${local_zone}" == "UTC" || "${local_zone}" == "GMT" ]]; then
  ok "machine clock is UTC (${local_zone})"
else
  status="$(AI_WINDOW_TEST_NOW=12:00 "${GUARD}" status)"
  case "${status}" in
    *"${local_zone}"*) ok "status names the machine zone (${local_zone})" ;;
    *) fail "status does not name the local zone (${local_zone})" ;;
  esac
  case "${status}" in
    *"UTC"*) ok "status also shows the UTC clock" ;;
    *) fail "status shows no UTC equivalent" ;;
  esac
  # 20:00 local is outside 01:00-04:00 and 06:00-10:00 local, so work is allowed.
  if AI_WINDOW_TEST_NOW=20:00 "${GUARD}" >/dev/null 2>&1; then
    ok "20:00 ${local_zone} is off-peak"
  else
    fail "20:00 ${local_zone} is treated as peak"
  fi
fi

echo "owner-only override"
# Pinned to peak hours, otherwise the guard just says the window is already open.
if AI_WINDOW_TEST_NOW=02:00 "${GUARD}" override --minutes 30 --reason verify </dev/null >/dev/null 2>&1; then
  fail "the override armed itself without a human typing the phrase"
else
  code=$?
  case "${code}" in
    3) ok "refuses a non-interactive shell (exit 3)" ;;
    4) ok "refused: the confirmation phrase was not typed (exit 4)" ;;
    *) fail "unexpected exit ${code} when arming the override" ;;
  esac
fi
armed="$(printf '%s' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"run_in_terminal\",\"tool_input\":{\"command\":\"${GUARD} over""ride --minutes 60\"}}" |
  AI_WINDOW_TEST_NOW=12:00 "${GUARD}" --hook)"
case "${armed}" in
  *'"permissionDecision":"deny"'*) ok "the hook refuses an agent arming the override" ;;
  *) fail "an agent could arm the override: ${armed}" ;;
esac

echo "background watcher"
if pgrep -f "${GUARD} watch" >/dev/null 2>&1; then
  ok "watcher is running"
elif [[ -s "${REAL_STATE_DIR}/watch.log" ]]; then
  ok "watcher has run (log: ${REAL_STATE_DIR}/watch.log)"
else
  fail "no watcher process and no log; parked work will not restart by itself"
fi

echo
if (( FAILED )); then
  echo "verify: FAILED"
  exit 1
fi
echo "verify: all checks passed"
