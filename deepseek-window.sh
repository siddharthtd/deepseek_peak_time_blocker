#!/usr/bin/env bash
# DeepSeek off-peak guard — installed once at user level, so every VS Code
# workspace on this machine obeys the same window.
#
# The rule is DeepSeek's own schedule, defined in UTC:
#
#   peak (work stopped)   Mon-Fri 01:00-04:00 and 06:00-10:00 UTC
#   off-peak (allowed)    everything else, including the whole weekend
#
# The decision is made on the UTC clock, and the machine's timezone is used to
# *show* you when each boundary lands in your own day, next to the UTC value.
#
#   deepseek-window.sh                guard: exit 0 allowed, exit 1 denied
#   deepseek-window.sh --hook         VS Code agent hook: JSON on stdout
#   deepseek-window.sh status         what the window is doing right now
#   deepseek-window.sh watch [dir]    wait for the boundaries; when off-peak
#                                     starts, restart the work peak interrupted
#   deepseek-window.sh override [--minutes N] [--reason "..."]
#                                     owner-only: interactive TTY + typed phrase
#   deepseek-window.sh override:clear
#
# State lives in ~/.deepseek-window/: `handoff` is the work parked by the last
# peak window, `override` is the owner's temporary allow.
#
# The owner is the only one who can arm the override — it needs a real terminal
# and a typed phrase, and the hook refuses an agent's attempt to run it.
#
# Verify without waiting for the clock (both values are UTC):
#   AI_WINDOW_TEST_NOW=05:30 AI_WINDOW_TEST_DAY=Mon deepseek-window.sh status
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_DIR="${AI_WINDOW_STATE_DIR:-$HOME/.deepseek-window}"
HANDOFF="$STATE_DIR/handoff"
OVERRIDE_FILE="$STATE_DIR/override"

# Peak windows: minutes of day UTC, plus the UTC days they apply to (1=Mon..5=Fri,
# 0=Sun, 6=Sat). Change these four numbers and $PEAK_DAYS to change the rule.
PEAK1_OPEN=60    # 01:00 UTC
PEAK1_CLOSE=240  # 04:00 UTC
PEAK2_OPEN=360   # 06:00 UTC
PEAK2_CLOSE=600  # 10:00 UTC
PEAK_DAYS="12345"

PHRASE="override peak hours"
MAX_MINUTES=240
CODE_BIN_OVERRIDE="${AI_WINDOW_CODE_BIN:-}"
OWNER_ONLY="owner-only: the DeepSeek off-peak override is the owner's call, not an agent's. Ask the owner to run '$SELF override' in their own terminal (it needs an interactive TTY and a typed phrase)."

# Test-only. Both are UTC, so a test says the same thing wherever it runs. They
# are parsed here, at the top level, so a bad value exits the script instead of a
# subshell.
TEST_CLOCK="${AI_WINDOW_TEST_NOW:-${AI_WINDOW_TEST_NOW_UTC:-}}"
TEST_DAY="${AI_WINDOW_TEST_DAY:-}"
TEST_MINUTE=""
TEST_DOW=""
if [[ -n "$TEST_CLOCK" ]]; then
  if [[ ! "$TEST_CLOCK" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || (( 10#${BASH_REMATCH[1]} > 23 || 10#${BASH_REMATCH[2]} > 59 )); then
    echo "AI_WINDOW_TEST_NOW must look like HH:MM in UTC" >&2
    exit 64
  fi
  TEST_MINUTE=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
fi
if [[ -n "$TEST_DAY" ]]; then
  case "$(printf '%s' "$TEST_DAY" | tr '[:upper:]' '[:lower:]')" in
    sun | su | 7) TEST_DOW=0 ;;
    mon | mo | 1) TEST_DOW=1 ;;
    tue | tu | 2) TEST_DOW=2 ;;
    wed | we | 3) TEST_DOW=3 ;;
    thu | th | 4) TEST_DOW=4 ;;
    fri | fr | 5) TEST_DOW=5 ;;
    sat | sa | 6) TEST_DOW=6 ;;
    *)
      echo "AI_WINDOW_TEST_DAY must be Mon..Sun, or 1..7 with Mon=1" >&2
      exit 64
      ;;
  esac
fi
CLOCK_NOTE=""
if [[ -n "$TEST_CLOCK" || -n "$TEST_DAY" ]]; then
  CLOCK_NOTE=" (test clock: AI_WINDOW_TEST_NOW=${TEST_CLOCK:-real} AI_WINDOW_TEST_DAY=${TEST_DAY:-real})"
fi

# ---------------------------------------------------------------------------
# days and clock, all in UTC
# ---------------------------------------------------------------------------

dow_name() {
  case "$1" in
    0) echo Sun ;;
    1) echo Mon ;;
    2) echo Tue ;;
    3) echo Wed ;;
    4) echo Thu ;;
    5) echo Fri ;;
    6) echo Sat ;;
  esac
}

epoch_dow() { echo "$(( ($1 / 86400 + 4) % 7 ))"; } # epoch 0 was a Thursday
epoch_minute() { echo "$(( ($1 % 86400) / 60 ))"; }

# Now, as a UTC epoch. The test clock shifts the day and the minute of day, so
# countdowns, weekdays, and boundaries stay internally consistent.
now_epoch() {
  local real midnight dow shift=0 minute
  real="$(date -u +%s)"
  if [[ -z "$TEST_CLOCK" && -z "$TEST_DAY" ]]; then
    printf '%s' "$real"
    return 0
  fi
  midnight=$(( real - real % 86400 ))
  dow=$(( (real / 86400 + 4) % 7 ))
  if [[ -n "$TEST_DAY" ]]; then
    shift=$(( (TEST_DOW - dow + 7) % 7 ))
  fi
  minute=$(( (real % 86400) / 60 ))
  if [[ -n "$TEST_CLOCK" ]]; then
    minute="$TEST_MINUTE"
  fi
  printf '%s' "$(( midnight + shift * 86400 + minute * 60 ))"
}

is_peak() { # epoch
  local dow minute
  dow="$(epoch_dow "$1")"
  case "$PEAK_DAYS" in *"$dow"*) ;; *) return 1 ;; esac
  minute="$(epoch_minute "$1")"
  (( minute >= PEAK1_OPEN && minute < PEAK1_CLOSE )) ||
    (( minute >= PEAK2_OPEN && minute < PEAK2_CLOSE ))
}

# The next instant the state flips: a peak start while we are off-peak, or the
# end of the window we are in. Weekends fall out of this for free.
next_change() { # epoch -> epoch
  local e="$1" base day k cand cur nxt
  base=$(( e - e % 86400 ))
  if is_peak "$e"; then cur=1; else cur=0; fi
  for day in 0 1 2 3 4 5 6 7; do
    for k in "$PEAK1_OPEN" "$PEAK1_CLOSE" "$PEAK2_OPEN" "$PEAK2_CLOSE"; do
      cand=$(( base + day * 86400 + k * 60 ))
      if (( cand > e )); then
        if is_peak "$cand"; then nxt=1; else nxt=0; fi
        if (( nxt != cur )); then
          printf '%s' "$cand"
          return 0
        fi
      fi
    done
  done
  printf '%s' "$(( e + 86400 ))" # unreachable with these windows
}

human() { # seconds
  local s="$1" d h m
  if (( s < 0 )); then s=0; fi
  d=$(( s / 86400 ))
  h=$(( (s % 86400) / 3600 ))
  m=$(( (s % 3600) / 60 ))
  if (( d > 0 )); then
    echo "${d}d ${h}h"
  elif (( h > 0 )); then
    echo "${h}h ${m}m"
  else
    echo "${m}m"
  fi
}

# ---------------------------------------------------------------------------
# showing the boundary in the operator's own day (display only; never the rule)
# ---------------------------------------------------------------------------

BSD_DATE=0
if date -r 0 +%s >/dev/null 2>&1; then BSD_DATE=1; fi

utc_hm() { # epoch -> HH:MM UTC
  if (( BSD_DATE )); then date -u -r "$1" '+%H:%M'; else date -u -d "@$1" '+%H:%M'; fi
}

utc_full() { # epoch -> "Mon 18:00" UTC
  if (( BSD_DATE )); then date -u -r "$1" '+%a %H:%M'; else date -u -d "@$1" '+%a %H:%M'; fi
}

local_hm() { # epoch -> HH:MM local
  if (( BSD_DATE )); then date -r "$1" '+%H:%M'; else date -d "@$1" '+%H:%M'; fi
}

local_full() { # epoch -> "Mon 18:00" local
  if (( BSD_DATE )); then date -r "$1" '+%a %H:%M'; else date -d "@$1" '+%a %H:%M'; fi
}

zone_name() { date +%Z; }

# "04:00 UTC (21:00 PDT)"
at_both() { # epoch
  printf '%s UTC (%s %s)' "$(utc_hm "$1")" "$(local_hm "$1")" "$(zone_name)"
}

state_line() { # epoch
  local e="$1" change secs dow
  change="$(next_change "$e")"
  secs=$(( change - e ))
  if is_peak "$e"; then
    printf 'PEAK — work stopped until %s, in %s' "$(at_both "$change")" "$(human "$secs")"
    return 0
  fi
  dow="$(epoch_dow "$e")"
  if [[ "$dow" == 0 || "$dow" == 6 ]]; then
    printf 'OPEN (weekend) — next peak %s UTC (%s %s), in %s' \
      "$(utc_full "$change")" "$(local_full "$change")" "$(zone_name)" "$(human "$secs")"
  else
    printf 'OPEN — work allowed until %s, in %s' "$(at_both "$change")" "$(human "$secs")"
  fi
}

peak_message() { # the whole sentence a blocked agent and its owner see
  local e change secs
  e="$(now_epoch)"
  change="$(next_change "$e")"
  secs=$(( change - e ))
  printf 'Peak hours: work is stopped. The rule is Mon-Fri 01:00-04:00 and 06:00-10:00 UTC; now it is %s. Work resumes at %s, in %s. Owner override: %s override (interactive, owner-only)%s.' \
    "$(at_both "$e")" "$(at_both "$change")" "$(human "$secs")" "$SELF" "$CLOCK_NOTE"
}

# ---------------------------------------------------------------------------
# state: parked work, owner override
# ---------------------------------------------------------------------------

kv() { # file, key
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1
}

handoff_save() { # text, workspace dir
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$HANDOFF"
  printf '%s\n' "${2:-$PWD}" > "$STATE_DIR/handoff.dir"
}

# Print the parked work and consume it, so a session is nudged only once.
handoff_take() {
  local text
  [[ -s "$HANDOFF" ]] || return 0
  text="$(cat "$HANDOFF")"
  mv -f "$HANDOFF" "$STATE_DIR/handoff.done" 2>/dev/null || true
  printf '%s' "$text"
}

override_active() {
  local expires
  case "${AI_WINDOW_OVERRIDE:-0}" in
    1 | yes | true | on) return 0 ;;
  esac
  [[ -f "$OVERRIDE_FILE" ]] || return 1
  expires="$(kv "$OVERRIDE_FILE" expires_epoch)"
  [[ -n "$expires" ]] || return 1
  (( $(date -u +%s) < expires ))
}

override_note() {
  local expires reason by at left
  case "${AI_WINDOW_OVERRIDE:-0}" in
    1 | yes | true | on)
      echo "OVERRIDE ACTIVE (env AI_WINDOW_OVERRIDE): ${AI_WINDOW_OVERRIDE_REASON:-no reason given}"
      return 0
      ;;
  esac
  [[ -f "$OVERRIDE_FILE" ]] || return 0
  expires="$(kv "$OVERRIDE_FILE" expires_epoch)"
  [[ -n "$expires" ]] || return 0
  reason="$(kv "$OVERRIDE_FILE" reason)"
  by="$(kv "$OVERRIDE_FILE" armed_by)"
  at="$(kv "$OVERRIDE_FILE" armed_at)"
  left=$(( (expires - $(date -u +%s)) / 60 ))
  if (( left >= 0 )); then
    echo "OVERRIDE ACTIVE (armed $at by $by, ~${left}m left): ${reason}"
  else
    echo "OVERRIDE EXPIRED (armed $at by $by): ${reason}"
  fi
}

# ---------------------------------------------------------------------------
# what the VS Code hooks get
# ---------------------------------------------------------------------------

json_escape() {
  printf '%s' "$1" \
    | tr -d '\000' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' \
    | awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

hook_out() {
  printf '%s\n' "$1"
  exit 0
}

hook_mode() {
  local payload="" event tool prompt cwd e handoff text note

  [[ -t 0 ]] || payload="$(cat || true)"
  json_field() {
    printf '%s' "$payload" \
      | tr -d '\n' \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      | head -n 1
  }
  event="$(json_field hook_event_name)"
  tool="$(json_field tool_name)"
  prompt="$(json_field prompt)"
  cwd="$(json_field cwd)"
  [[ -n "$event" ]] || event="PreToolUse"

  # Owner-only: an agent may not arm the override, and the client enforces it.
  case "$tool" in
    run_in_terminal | send_to_terminal)
      if printf '%s' "$payload" | grep -Eq 'deepseek-window\.sh.*override|AI_WINDOW_OVERRIDE='; then
        hook_out "$(printf '{"hookSpecificOutput":{"hookEventName":"%s","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
          "$event" "$(json_escape "$OWNER_ONLY")")"
      fi
      ;;
  esac

  e="$(now_epoch)"

  if ! is_peak "$e"; then
    # Work may proceed. Hand back anything the last peak window parked, once.
    handoff=""
    case "$event" in
      SessionStart | PreToolUse) handoff="$(handoff_take)" ;;
    esac
    if [[ -n "$handoff" ]]; then
      hook_out "$(printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
        "$event" "$(json_escape "The DeepSeek off-peak window is open again. Work parked by the last peak window: $handoff — resume it now, or say in one line that it is already done.")")"
    fi
    hook_out '{}'
  fi

  note="$(override_note)"
  if [[ -n "$note" && "$note" == OVERRIDE\ ACTIVE* ]]; then
    if [[ "$event" == "SessionStart" ]]; then
      hook_out "$(printf '{"systemMessage":"%s"}' "$(json_escape "$note")")"
    fi
    hook_out '{}'
  fi

  text="$(peak_message)"
  case "$event" in
    UserPromptSubmit)
      handoff_save "${prompt:-a prompt submitted during peak hours}" "$cwd"
      hook_out "$(printf '{"continue":false,"stopReason":"%s","systemMessage":"%s"}' \
        "$(json_escape "$text")" "$(json_escape "$text")")"
      ;;
    SessionStart)
      hook_out "$(printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s Do not call tools until the window opens: they are refused."}}' \
        "$(json_escape "$text")" "$(json_escape "$text")")"
      ;;
    Stop)
      [[ -s "$HANDOFF" ]] || handoff_save "the task that peak hours stopped" "$cwd"
      hook_out "$(printf '{"systemMessage":"%s"}' "$(json_escape "$text")")"
      ;;
    *)
      [[ -s "$HANDOFF" ]] || handoff_save "the task interrupted by peak hours (last tool: ${tool:-unknown})" "$cwd"
      hook_out "$(printf '{"continue":false,"stopReason":"%s","systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
        "$(json_escape "$text")" "$(json_escape "$text")" "$(json_escape "$text")")"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# watch: announce the boundaries, restart parked work at off-peak
# ---------------------------------------------------------------------------

find_code() {
  local candidate
  if [[ -n "$CODE_BIN_OVERRIDE" ]]; then
    printf '%s' "$CODE_BIN_OVERRIDE"
    return 0
  fi
  if command -v code >/dev/null 2>&1; then
    command -v code
    return 0
  fi
  for candidate in \
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" \
    "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    "$HOME/.local/bin/code" \
    /usr/bin/code \
    /usr/share/code/bin/code \
    /snap/bin/code; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

restart_handoff() {
  local text dir code
  text="$(handoff_take)"
  if [[ -z "$text" ]]; then
    echo "  nothing was parked by peak hours."
    return 0
  fi
  dir="$(cat "$STATE_DIR/handoff.dir" 2>/dev/null || true)"
  if [[ -n "$dir" && -d "$dir" ]]; then
    cd "$dir" && echo "  workspace: $dir"
  fi
  code="$(find_code)"
  if [[ -z "$code" || ! -x "$code" ]]; then
    echo "  VS Code CLI not found (set AI_WINDOW_CODE_BIN); parked work: $text"
    return 0
  fi
  echo "  restarting: $text"
  "$code" chat --mode agent --reuse-window \
    "The DeepSeek off-peak window is open again. Resume the work that peak hours interrupted: $text If it is already finished, reply in one line and stop." \
    || echo "  (chat restart failed; the parked work is in $STATE_DIR/handoff.done)"
}

watch_mode() {
  local dir="${1:-$PWD}" e secs state prev="" change
  cd "$dir" 2>/dev/null || true
  echo "deepseek-window: watching $PWD — peak Mon-Fri 01:00-04:00 and 06:00-10:00 UTC, off-peak otherwise."
  while :; do
    e="$(now_epoch)"
    if is_peak "$e"; then state=peak; else state=open; fi
    if [[ "$state" != "$prev" ]]; then
      change="$(next_change "$e")"
      if [[ "$state" == "open" ]]; then
        echo "OFF-PEAK — work resumes now ($(at_both "$e")). Next peak: $(at_both "$change")."
        restart_handoff
      else
        echo "PEAK HOURS — work stops now ($(at_both "$e")). Work resumes $(at_both "$change")."
      fi
      prev="$state"
    fi
    change="$(next_change "$e")"
    secs=$(( change - e ))
    if (( secs > 30 )); then secs=30; fi
    if (( secs < 1 )); then secs=1; fi
    sleep "$secs"
  done
}

# ---------------------------------------------------------------------------
# override: owner-only
# ---------------------------------------------------------------------------

override_arm() {
  local minutes=30 reason="" answer e target
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --minutes) minutes="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) echo "override: unknown argument '$1'" >&2; exit 64 ;;
    esac
  done
  if [[ ! "$minutes" =~ ^[0-9]+$ ]] || (( minutes < 1 || minutes > MAX_MINUTES )); then
    echo "override: --minutes must be 1..$MAX_MINUTES" >&2
    exit 64
  fi
  e="$(now_epoch)"
  if ! is_peak "$e"; then
    echo "override: work is already allowed ($(at_both "$e")); nothing to override."
    exit 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "refused: the override is owner-only and needs an interactive terminal (stdin is not a TTY)." >&2
    exit 3
  fi
  printf 'This lets agents work during peak hours for %s minutes.\nType "%s" to confirm: ' "$minutes" "$PHRASE"
  IFS= read -r answer || true
  if [[ "$answer" != "$PHRASE" ]]; then
    echo "refused: the phrase did not match." >&2
    exit 4
  fi
  target=$(( e + minutes * 60 ))
  mkdir -p "$STATE_DIR"
  umask 077
  {
    printf 'armed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'armed_by=%s\n' "${USER:-$(id -un)}@$(tty 2>/dev/null || echo '?')"
    printf 'minutes=%s\n' "$minutes"
    printf 'expires_epoch=%s\n' "$target"
    printf 'reason=%s\n' "${reason:-not given}"
  } > "$OVERRIDE_FILE"
  echo "override armed until $(at_both "$target"), for ${minutes}m. Every decision says so until then, and it expires by itself."
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

status_mode() {
  local e change note
  e="$(now_epoch)"
  echo "DeepSeek off-peak guard $SELF"
  echo "now:        $(at_both "$e") $(dow_name "$(epoch_dow "$e")")$CLOCK_NOTE"
  echo "rule:       peak Mon-Fri 01:00-04:00 and 06:00-10:00 UTC; everything else off-peak"
  echo "state:      $(state_line "$e")"
  note="$(override_note)"
  echo "override:   ${note:-none}"
  if [[ -s "$HANDOFF" ]]; then
    echo "parked:     $(cat "$HANDOFF")"
  elif [[ -f "$STATE_DIR/handoff.done" ]]; then
    echo "parked:     none (last handoff was used)"
  else
    echo "parked:     none"
  fi
}

case "${1:-guard}" in
  guard | "")
    e="$(now_epoch)"
    if ! is_peak "$e"; then exit 0; fi
    if override_active; then
      override_note >&2
      exit 0
    fi
    peak_message >&2
    exit 1
    ;;
  --hook | hook)
    hook_mode
    ;;
  status)
    status_mode
    ;;
  watch)
    shift
    watch_mode "$@"
    ;;
  override)
    shift
    override_arm "$@"
    ;;
  override:clear)
    rm -f "$OVERRIDE_FILE"
    echo "override cleared; peak hours stop work again."
    ;;
  help | -h | --help)
    sed -n '2,27p' "$SELF" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "deepseek-window: unknown mode '$1' (try: status, watch, override, --hook)" >&2
    exit 64
    ;;
esac
