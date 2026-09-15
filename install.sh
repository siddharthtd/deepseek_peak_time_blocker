#!/usr/bin/env bash
# Install the DeepSeek off-peak guard for the current user, so every VS Code
# workspace on this machine obeys the same window.
#
#   ./install.sh [options]
#
#   --prefix DIR      where the guard is installed   (default: ~/.copilot/hooks)
#   --state-dir DIR   runtime state                  (default: ~/.deepseek-window)
#   --settings FILE   VS Code user settings.json     (default: detected)
#   --label NAME      watcher label/service name     (default: <user>.deepseek-window)
#   --workdir DIR     directory the watcher starts in (default: $HOME)
#   --no-watch        do not install the background watcher
#   --no-settings     do not touch the VS Code user settings
#   --dry-run         print the plan, change nothing
#   -h, --help        this text
#
# Safe to re-run: it refreshes the files, reloads the watcher, and merges the
# settings instead of replacing them.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

PREFIX="${HOME}/.copilot/hooks"
STATE_DIR="${HOME}/.deepseek-window"
WORKDIR="${HOME}"
LABEL="$(id -un).deepseek-window"
SETTINGS=""
DO_WATCH=1
DO_SETTINGS=1
DRY_RUN=0

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:?--state-dir needs a directory}"; shift 2 ;;
    --settings) SETTINGS="${2:?--settings needs a file}"; shift 2 ;;
    --label) LABEL="${2:?--label needs a name}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a directory}"; shift 2 ;;
    --no-watch) DO_WATCH=0; shift ;;
    --no-settings) DO_SETTINGS=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (try --help)" >&2; exit 64 ;;
  esac
done

GUARD="${PREFIX}/deepseek-window.sh"
HOOKS_JSON="${PREFIX}/deepseek-window.json"
LOG="${STATE_DIR}/watch.log"

say() { printf '%s\n' "$*"; }
run() {
  if (( DRY_RUN )); then
    say "  [dry-run] $*"
  else
    "$@"
  fi
}

default_settings_path() {
  case "$OS" in
    Darwin) echo "${HOME}/Library/Application Support/Code/User/settings.json" ;;
    *) echo "${HOME}/.config/Code/User/settings.json" ;;
  esac
}

substitute() { # template file
  sed -e "s|@GUARD@|${GUARD}|g" \
    -e "s|@LABEL@|${LABEL}|g" \
    -e "s|@LOG@|${LOG}|g" \
    -e "s|@WORKDIR@|${WORKDIR}|g" "$1"
}

say "DeepSeek off-peak guard — installing for user $(id -un) on ${OS}"
say "  guard:      ${GUARD}"
say "  hook file:  ${HOOKS_JSON}"
say "  state:      ${STATE_DIR}"
say "  watcher:    $([[ "${DO_WATCH}" == 1 ]] && echo "yes (${LABEL})" || echo 'no')"
say ""

# ---------------------------------------------------------------------------
# 1. the guard and its hook wiring
# ---------------------------------------------------------------------------

say "1. guard + hook wiring"
run mkdir -p "${PREFIX}"
if (( DRY_RUN )); then
  say "  [dry-run] copy ${REPO_DIR}/deepseek-window.sh -> ${GUARD}"
  say "  [dry-run] render ${REPO_DIR}/hooks/deepseek-window.json.in -> ${HOOKS_JSON}"
else
  install -m 0755 "${REPO_DIR}/deepseek-window.sh" "${GUARD}"
  substitute "${REPO_DIR}/hooks/deepseek-window.json.in" > "${HOOKS_JSON}"
  say "  installed ${GUARD}"
  say "  installed ${HOOKS_JSON}"
fi

# ---------------------------------------------------------------------------
# 2. VS Code user settings: make sure the user hook folder is loaded
# ---------------------------------------------------------------------------

say ""
say "2. VS Code user settings"
if [[ "${DO_SETTINGS}" == 0 ]]; then
  say "  skipped (--no-settings). Add this yourself if hooks do not load:"
  say "    \"chat.hookFilesLocations\": { \"~/.copilot/hooks\": true }"
elif ! command -v python3 >/dev/null 2>&1; then
  say "  python3 not found; add this by hand to your VS Code user settings:"
  say "    \"chat.hookFilesLocations\": { \"~/.copilot/hooks\": true }"
else
  [[ -n "${SETTINGS}" ]] || SETTINGS="$(default_settings_path)"
  say "  file: ${SETTINGS}"
  if (( DRY_RUN )); then
    say "  [dry-run] merge chat.hookFilesLocations and keep every other key"
  else
    mkdir -p "$(dirname "${SETTINGS}")"
    if [[ -f "${SETTINGS}" && ! -f "${SETTINGS}.ai-window-backup" ]]; then
      cp "${SETTINGS}" "${SETTINGS}.ai-window-backup"
      say "  backup: ${SETTINGS}.ai-window-backup"
    fi
    python3 - "${SETTINGS}" "${PREFIX}" <<'PY'
import json, os, sys

path, prefix = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as fh:
        data = json.load(fh)

locations = data.get("chat.hookFilesLocations")
if not isinstance(locations, dict):
    locations = {
        ".github/hooks": True,
        ".claude/settings.json": True,
        ".claude/settings.local.json": True,
        "~/.claude/settings.json": True,
    }
# Both spellings, so the install works whether VS Code expands ~ or not.
locations["~/.copilot/hooks"] = True
locations[prefix] = True
data["chat.hookFilesLocations"] = locations

with open(path, "w") as fh:
    json.dump(data, fh, indent=4)
    fh.write("\n")
print("  chat.hookFilesLocations now includes " + prefix)
PY
  fi
fi

# ---------------------------------------------------------------------------
# 3. background watcher: announce the boundaries, restart parked work
# ---------------------------------------------------------------------------

say ""
say "3. background watcher"
if [[ "${DO_WATCH}" == 0 ]]; then
  say "  skipped (--no-watch). Run '${GUARD} watch' yourself if you want it."
elif [[ "${OS}" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
  PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
  if (( DRY_RUN )); then
    say "  [dry-run] write ${PLIST} and load it with launchctl"
  else
    mkdir -p "${STATE_DIR}" "${HOME}/Library/LaunchAgents"
    substitute "${REPO_DIR}/watchers/launchd.plist.in" > "${PLIST}"
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${PLIST}" 2>/dev/null ||
      launchctl load -w "${PLIST}"
    say "  launchd agent ${LABEL} loaded (log: ${LOG})"
  fi
elif command -v systemctl >/dev/null 2>&1; then
  UNIT="${HOME}/.config/systemd/user/${LABEL}.service"
  if (( DRY_RUN )); then
    say "  [dry-run] write ${UNIT} and enable it with systemctl --user"
  else
    mkdir -p "${STATE_DIR}" "$(dirname "${UNIT}")"
    substitute "${REPO_DIR}/watchers/systemd.service.in" > "${UNIT}"
    systemctl --user daemon-reload
    systemctl --user enable --now "${LABEL}.service"
    say "  systemd user unit ${LABEL}.service enabled (log: ${LOG})"
    say "  note: run 'loginctl enable-linger $(id -un)' to keep it alive when logged out"
  fi
else
  say "  no launchd or systemd found; run '${GUARD} watch' yourself if you want it."
fi

# ---------------------------------------------------------------------------
# 4. prove it works
# ---------------------------------------------------------------------------

say ""
say "4. checks"
if (( DRY_RUN )); then
  say "  [dry-run] run ${REPO_DIR}/verify.sh ${GUARD}"
else
  bash -n "${GUARD}" && say "  bash syntax ok"
  python3 -m json.tool "${HOOKS_JSON}" >/dev/null && say "  hook JSON ok"
  "${REPO_DIR}/verify.sh" "${GUARD}" || say "  verify reported a problem (see above)"
fi

say ""
say "Done."
say "  Reload VS Code (or start a new chat session) so the hooks load."
say "  Check the state any time:  ${GUARD} status"
say "  Owner-only lift of peak hours:  ${GUARD} override --minutes 30 --reason \"...\""
say "  Remove it again:  ${REPO_DIR}/uninstall.sh"
