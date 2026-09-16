#!/usr/bin/env bash
# DeepSeek off-peak guard — installed once at user level, so every VS Code
# workspace obeys the same window.
#
# Off-peak (work allowed): 04:00-06:00 and 10:00-01:00 (crosses midnight).
# Peak     (work stopped): 01:00-04:00 and 06:00-10:00. Default is no.
#
# Those are clock times on this machine's own clock, not UTC, so the rule reads
# the same wherever it is installed. AI_WINDOW_TZ=UTC (or any IANA zone) pins the
# windows to another clock, and every message prints the UTC equivalent.
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
# Verify without waiting for the clock: AI_WINDOW_TEST_NOW=HH:MM <command>
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_DIR="${AI_WINDOW_STATE_DIR:-$HOME/.deepseek-window}"
HANDOFF="$STATE_DIR/handoff"
OVERRIDE_FILE="$STATE_DIR/override"

# Window boundaries, as minutes of day on the guard's own clock: this machine's
# timezone, or AI_WINDOW_TZ=UTC / any IANA zone.
WINDOW_TZ="${AI_WINDOW_TZ:-local}"
W1_OPEN=240  # 04:00
W1_CLOSE=360 # 06:00
W2_OPEN=600  # 10:00
W2_CLOSE=60  # 01:00 the following day
PHRASE="override peak hours"
MAX_MINUTES=240
CODE_BIN_OVERRIDE="${AI_WINDOW_CODE_BIN:-}"
OWNER_ONLY="owner-only: the DeepSeek off-peak override is the owner's call, not an agent's. Ask the owner to run '$SELF override' in their own terminal (it needs an interactive TTY and a typed phrase)."

# Test-only, read on the window's clock so the boundaries do not depend on where
# the test runs. AI_WINDOW_TEST_NOW_UTC is the older spelling.
TEST_CLOCK="${AI_WINDOW_TEST_NOW:-${AI_WINDOW_TEST_NOW_UTC:-}}"
CLOCK_NOTE=""
if [[ -n "$TEST_CLOCK" ]]; then
  CLOCK_NOTE=" (clock faked with AI_WINDOW_TEST_NOW=${TEST_CLOCK}, not the real time)"
fi

# ---------------------------------------------------------------------------
# clock — every window minute below is on this clock
# ---------------------------------------------------------------------------

# date(1) in the window timezone. `local` means wherever this machine is.
zone_date() {
  if [[ "$WINDOW_TZ" == "local" ]]; then
    date "$@"
  else
    TZ="$WINDOW_TZ" date "$@"
  fi
}

ZONE="$(zone_date +%Z)"
ALLOWED_TEXT="04:00-06:00 and 10:00-01:00 ${ZONE}"
PEAK_TEXT="01:00-04:00 and 06:00-10:00 ${ZONE}"

minute_now() {
  if [[ -n "$TEST_CLOCK" ]]; then
    if [[ ! "$TEST_CLOCK" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
      echo "AI_WINDOW_TEST_NOW must look like HH:MM" >&2
      exit 64
    fi
    echo "$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))"
  else
    local hm
    hm="$(zone_date +%H:%M)"
    echo "$(( 10#${hm%%:*} * 60 + 10#${hm##*:} ))"
  fi
}

is_open() {
  local m="$1"
  (( m >= W1_OPEN && m < W1_CLOSE )) || (( m >= W2_OPEN || m < W2_CLOSE ))
}

next_change() {
  local m="$1"
  if (( m >= W2_OPEN || m < W2_CLOSE )); then
    echo "$W2_CLOSE"
  elif (( m < W1_OPEN )); then
    echo "$W1_OPEN"
  elif (( m < W1_CLOSE )); then
    echo "$W1_CLOSE"
  else
    echo "$W2_OPEN"
  fi
}

seconds_left() { # minute, second
  local m="$1" s="$2" boundary
  boundary="$(next_change "$m")"
  echo "$(( ((boundary - m + 1440) % 1440) * 60 - s ))"
}

hhmm() { printf '%02d:%02d' "$(( $1 / 60 % 24 ))" "$(( $1 % 60 ))"; }

human() {
  if (( $1 >= 3600 )); then
    echo "$(( $1 / 3600 ))h $(( ($1 % 3600) / 60 ))m"
  else
    echo "$(( $1 / 60 ))m"
  fi
}

# The windows are in $ZONE, so messages also need the UTC clock. Plain
# arithmetic on minutes of day, which sidesteps the GNU/BSD date-arithmetic trap.
zone_offset_minutes() { # minutes east of UTC
  local raw sign=1
  raw="$(zone_date +%z)"
  if [[ "${raw:0:1}" == "-" ]]; then sign=-1; fi
  echo "$(( (10#${raw:1:2} * 60 + 10#${raw:3:2}) * sign ))"
}

utc_minute_of() { # minute of day in $ZONE -> minute of day UTC
  echo "$(( ($1 - $(zone_offset_minutes) + 1440) % 1440 ))"
}

utc_window_text() { # the allowed windows, on the UTC clock
  printf '%s-%s and %s-%s UTC' \
    "$(hhmm "$(utc_minute_of "$W1_OPEN")")" "$(hhmm "$(utc_minute_of "$W1_CLOSE")")" \
    "$(hhmm "$(utc_minute_of "$W2_OPEN")")" "$(hhmm "$(utc_minute_of "$W2_CLOSE")")"
}

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# The VS Code CLI used to reopen chat when off-peak starts: PATH first, then the
# usual app-bundle and package locations on macOS and Linux.
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

# ---------------------------------------------------------------------------
# state
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
# messages
# ---------------------------------------------------------------------------

json_escape() {
  printf '%s' "$1" \
    | tr -d '\000' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' \
    | awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

peak_message() {
  local m boundary secs
  m="$(minute_now)"
  boundary="$(next_change "$m")"
  secs="$(seconds_left "$m" "$(zone_date +%S)")"
  printf 'Peak hours: the DeepSeek off-peak window is closed (%s are peak; work is allowed %s). Work stops now and resumes at %s %s (%s UTC), in %s. Owner override: %s override%s.' \
    "$PEAK_TEXT" "$ALLOWED_TEXT" "$(hhmm "$boundary")" "$ZONE" "$(hhmm "$(utc_minute_of "$boundary")")" "$(human "$secs")" "$SELF" "$CLOCK_NOTE"
}

hook_out() {
  printf '%s\n' "$1"
  exit 0
}

# ---------------------------------------------------------------------------
# hook mode
# ---------------------------------------------------------------------------

hook_mode() {
  local payload="" event tool prompt cwd m handoff text note

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

  m="$(minute_now)"

  if is_open "$m"; then
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
# watch mode: announce the boundaries and restart parked work at off-peak
# ---------------------------------------------------------------------------

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
  local dir="${1:-$PWD}" m secs state prev=""
  cd "$dir" 2>/dev/null || true
  echo "deepseek-window: watching $PWD — peak ${PEAK_TEXT}, work allowed ${ALLOWED_TEXT}."
  while :; do
    m="$(minute_now)"
    if is_open "$m"; then state=open; else state=closed; fi
    if [[ "$state" != "$prev" ]]; then
      if [[ "$state" == "open" ]]; then
        echo "OFF-PEAK — work resumes now ($(now_iso)). Next peak: $(hhmm "$(next_change "$m")") $ZONE."
        restart_handoff
      else
        echo "PEAK HOURS — work stops now ($(now_iso)). Work resumes $(hhmm "$(next_change "$m")") $ZONE."
      fi
      prev="$state"
    fi
    secs="$(seconds_left "$m" "$(zone_date +%S)")"
    if (( secs > 30 )); then secs=30; fi
    if (( secs < 1 )); then secs=1; fi
    sleep "$secs"
  done
}

# ---------------------------------------------------------------------------
# override: owner-only
# ---------------------------------------------------------------------------

override_arm() {
  local minutes=30 reason="" answer m target
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
  m="$(minute_now)"
  if is_open "$m"; then
    echo "override: the window is already open ($(hhmm "$m") $ZONE); nothing to override."
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
  target=$(( (m + minutes) % 1440 ))
  mkdir -p "$STATE_DIR"
  umask 077
  {
    printf 'armed_at=%s\n' "$(now_iso)"
    printf 'armed_by=%s\n' "${USER:-$(id -un)}@$(tty 2>/dev/null || echo '?')"
    printf 'minutes=%s\n' "$minutes"
    printf 'expires_epoch=%s\n' "$(( $(date -u +%s) + minutes * 60 ))"
    printf 'reason=%s\n' "${reason:-not given}"
  } > "$OVERRIDE_FILE"
  echo "override armed until $(hhmm "$target") $ZONE ($(hhmm "$(utc_minute_of "$target")") UTC), for ${minutes}m. Every decision says so until then, and it expires by itself."
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

status_mode() {
  local m boundary secs state note
  m="$(minute_now)"
  boundary="$(next_change "$m")"
  secs="$(seconds_left "$m" "$(zone_date +%S)")"
  if is_open "$m"; then
    state="OPEN — work allowed until $(hhmm "$boundary") $ZONE ($(hhmm "$(utc_minute_of "$boundary")") UTC), in $(human "$secs")"
  else
    state="CLOSED (peak hours) — work resumes $(hhmm "$boundary") $ZONE ($(hhmm "$(utc_minute_of "$boundary")") UTC), in $(human "$secs")"
  fi
  echo "DeepSeek off-peak guard $SELF"
  echo "now:        $(now_iso) ($(hhmm "$m") $ZONE)$CLOCK_NOTE"
  if [[ "$WINDOW_TZ" == "local" ]]; then
    echo "zone:       $ZONE, this machine's clock (AI_WINDOW_TZ pins another)"
  else
    echo "zone:       $ZONE (AI_WINDOW_TZ=$WINDOW_TZ)"
  fi
  echo "allowed:    $ALLOWED_TEXT"
  echo "peak:       $PEAK_TEXT"
  echo "utc:        allowed $(utc_window_text)"
  echo "state:      $state"
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
    m="$(minute_now)"
    if is_open "$m"; then exit 0; fi
    if override_active; then
      echo "$(override_note)" >&2
      exit 0
    fi
    echo "$(peak_message)" >&2
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
    sed -n '2,22p' "$SELF" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "deepseek-window: unknown mode '$1' (try: status, watch, override, --hook)" >&2
    exit 64
    ;;
esac
