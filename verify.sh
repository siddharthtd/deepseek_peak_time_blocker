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

echo "extend (hold the door shut a little longer)"
# One call can never add ten minutes or more, and the value has to be a number.
for bad in 0 10 99 abc; do
  if AI_WINDOW_TEST_NOW=02:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" extend --minutes "${bad}" >/dev/null 2>&1; then
    fail "--minutes ${bad} was accepted"
  else
    ok "--minutes ${bad} is refused"
  fi
done
# Outside a block there is nothing to extend, and nothing is written.
if AI_WINDOW_TEST_NOW=04:30 AI_WINDOW_TEST_DAY=Mon "${GUARD}" extend --minutes 5 >/dev/null 2>&1; then
  if [[ -e "${TMP_STATE}/extend" ]]; then
    fail "extend wrote state while nothing was blocked"
  else
    ok "outside a block, extend changes nothing"
  fi
else
  fail "extend failed outside a block"
fi
# No interactive terminal and no typed phrase: that is what the mode is for.
if AI_WINDOW_TEST_NOW=03:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" extend --minutes 5 </dev/null >/dev/null 2>&1; then
  ok "extend needs no TTY and no confirmation phrase"
else
  fail "extend asked for a terminal or a phrase"
fi
# The extension binds every gate, not just the one that armed it.
case "$(AI_WINDOW_TEST_NOW=04:03 AI_WINDOW_TEST_DAY=Mon "${GUARD}" status)" in
  *"PEAK (extended)"*) ok "status says the block is extended (04:05)" ;;
  *) fail "status does not show the extension" ;;
esac
if AI_WINDOW_TEST_NOW=04:03 AI_WINDOW_TEST_DAY=Mon "${GUARD}" >/dev/null 2>&1; then
  fail "work was allowed 3 minutes past the scheduled end"
else
  ok "work stays stopped three minutes past the scheduled end"
fi
# A second call adds to the first instead of replacing it: 04:05 + 9m = 04:14.
AI_WINDOW_TEST_NOW=04:03 AI_WINDOW_TEST_DAY=Mon "${GUARD}" extend --minutes 9 >/dev/null 2>&1
if AI_WINDOW_TEST_NOW=04:13 AI_WINDOW_TEST_DAY=Mon "${GUARD}" >/dev/null 2>&1; then
  fail "a second extend call did not add to the first (expected the block to end 04:14)"
else
  ok "a second call adds to the first (5m + 9m ends the block at 04:14)"
fi
ext_hook="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"read_file"}' |
  AI_WINDOW_TEST_NOW=04:13 AI_WINDOW_TEST_DAY=Mon "${GUARD}" --hook)"
case "${ext_hook}" in
  *'"permissionDecision":"deny"'*) ok "the hook denies a tool call inside an extension" ;;
  *) fail "a tool call inside an extension was not denied: ${ext_hook}" ;;
esac
if AI_WINDOW_TEST_NOW=04:15 AI_WINDOW_TEST_DAY=Mon "${GUARD}" >/dev/null 2>&1; then
  ok "work resumes once the extension has run out"
else
  fail "work was still stopped after the extension ran out"
fi
if [[ -e "${TMP_STATE}/extend" ]]; then
  fail "an extension that ran out is still on disk"
else
  ok "an extension that ran out was dropped"
fi
# State that points at a window which is not the one firing is not an extension,
# however plausible it looks. The faked Monday 11:00 below is computed the same
# way the guard computes its test clock, so the two agree on "now".
real="$(date -u +%s)"
faked=$(( real - real % 86400 + ((1 - (real / 86400 + 4) % 7 + 7) % 7) * 86400 + 11 * 3600 ))
printf 'peak_end_epoch=%s\nextra_minutes=5\nuntil_epoch=%s\n' \
  "$(( faked + 172800 ))" "$(( faked + 172800 + 300 ))" > "${TMP_STATE}/extend"
if AI_WINDOW_TEST_NOW=11:00 AI_WINDOW_TEST_DAY=Mon "${GUARD}" >/dev/null 2>&1; then
  ok "an extension two days out is ignored"
else
  fail "a far-off extension file stopped work"
fi
if [[ -e "${TMP_STATE}/extend" ]]; then
  fail "ignored extension state was left on disk"
else
  ok "ignored extension state is cleaned up"
fi
# And nothing about it leaks into the normal schedule.
if AI_WINDOW_TEST_NOW=04:03 AI_WINDOW_TEST_DAY=Mon "${GUARD}" >/dev/null 2>&1; then
  ok "removing the extension restores the plain schedule"
else
  fail "work was still stopped after the extension was cleared"
fi

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
