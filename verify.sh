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

# Check the guard on a private state directory, so an armed owner bypass, parked
# handoff, or log from the real install cannot distort the results.
TMP_STATE="$(mktemp -d)"
export AI_WINDOW_STATE_DIR="${TMP_STATE}"
unset AI_WINDOW_OVERRIDE AI_WINDOW_OVERRIDE_REASON AI_WINDOW_MAINTENANCE
unset AI_WINDOW_TEST_NOW AI_WINDOW_TEST_NOW_UTC AI_WINDOW_TEST_DAY
trap 'rm -rf "${TMP_STATE}"' EXIT

fail() { echo "  FAIL  $*"; FAILED=1; }
ok() { echo "  ok    $*"; }

echo "guard: ${GUARD}"

# Time is UTC and the rule only bites Mon-Fri, so every case names its day.
echo "rule: peak Mon-Fri 01:00-04:00 and 06:00-10:00 UTC, off-peak otherwise"
while read -r day clock want; do
  if AI_WINDOW_TEST_NOW="${clock}" AI_WINDOW_TEST_DAY="${day}" "${GUARD}" >/dev/null 2>&1; then
    got=allow
  else
    got=deny
  fi
  if [[ "${got}" == "${want}" ]]; then
    ok "${day} ${clock} UTC -> ${got}"
  else
    fail "${day} ${clock} UTC -> ${got}, expected ${want}"
  fi
done <<'CASES'
Mon 00:30 allow
Mon 01:00 deny
Mon 03:59 deny
Mon 04:00 allow
Mon 05:59 allow
Mon 06:00 deny
Mon 09:59 deny
Mon 10:00 allow
Mon 23:30 allow
Tue 01:30 deny
Fri 07:00 deny
Fri 10:00 allow
Sat 02:00 allow
Sat 07:00 allow
Sun 08:00 allow
Sun 23:00 allow
CASES

echo "hook contract"
peak="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"read_file"}' |
  AI_WINDOW_TEST_NOW=02:00 AI_WINDOW_TEST_DAY=Wed "${GUARD}" --hook)"
case "${peak}" in
  *'"permissionDecision":"deny"'*) ok "a peak-window tool call is denied" ;;
  *) fail "a peak-window tool call is not denied: ${peak}" ;;
esac
case "${peak}" in
  *'"continue":false'*) ok "a peak-window tool call stops the session" ;;
  *) fail "a peak-window tool call does not stop the session" ;;
esac
case "${peak}" in
  *"Mon-Fri 01:00-04:00 and 06:00-10:00 UTC"*) ok "the refusal states the rule" ;;
  *) fail "the refusal does not state the rule: ${peak}" ;;
esac
open="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"read_file"}' |
  AI_WINDOW_TEST_NOW=11:00 AI_WINDOW_TEST_DAY=Wed "${GUARD}" --hook)"
case "${open}" in
  '{}' | '{"hookSpecificOutput"'*) ok "off-peak tool calls are allowed" ;;
  *) fail "off-peak tool calls returned: ${open}" ;;
esac
weekend="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"read_file"}' |
  AI_WINDOW_TEST_NOW=02:00 AI_WINDOW_TEST_DAY=Sun "${GUARD}" --hook)"
case "${weekend}" in
  '{}' | '{"hookSpecificOutput"'*) ok "weekends are never peak" ;;
  *) fail "a weekend tool call was refused: ${weekend}" ;;
esac

echo "timezone"
# The rule is UTC, but the operator needs the boundary in their own day.
local_zone="$(date +%Z)"
status="$(AI_WINDOW_TEST_NOW=12:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" status)"
case "${status}" in
  *"${local_zone}"*) ok "status shows the machine zone (${local_zone})" ;;
  *) fail "status does not show the local zone (${local_zone})" ;;
esac
case "$(AI_WINDOW_TEST_NOW=02:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" status)" in
  *"PEAK"*) ok "a peak instant reads as PEAK" ;;
  *) fail "a peak instant does not read as PEAK" ;;
esac
case "${status}" in
  *"OPEN"*) ok "an off-peak instant reads as OPEN" ;;
  *) fail "an off-peak instant does not read as OPEN" ;;
esac

echo "owner-only override"
if AI_WINDOW_TEST_NOW=02:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" override --minutes 30 --reason verify </dev/null >/dev/null 2>&1; then
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
  AI_WINDOW_TEST_NOW=12:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" --hook)"
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
