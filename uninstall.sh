#!/usr/bin/env bash
# Remove the DeepSeek off-peak guard installed by install.sh.
#
#   ./uninstall.sh [options]
#
#   --prefix DIR      where the guard was installed (default: ~/.copilot/hooks)
#   --state-dir DIR   runtime state                (default: ~/.deepseek-window)
#   --settings FILE   VS Code user settings.json   (default: detected)
#   --label NAME      watcher label                (default: <user>.deepseek-window)
#   --purge           also delete the runtime state (parked work, logs, override)
#   --dry-run         print the plan, change nothing
#   -h, --help        this text
set -euo pipefail

OS="$(uname -s)"
PREFIX="${HOME}/.copilot/hooks"
STATE_DIR="${HOME}/.deepseek-window"
SETTINGS=""
LABEL="$(id -un).deepseek-window"
PURGE=0
DRY_RUN=0

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:?--state-dir needs a directory}"; shift 2 ;;
    --settings) SETTINGS="${2:?--settings needs a file}"; shift 2 ;;
    --label) LABEL="${2:?--label needs a name}"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "uninstall.sh: unknown option '$1' (try --help)" >&2; exit 64 ;;
  esac
done

GUARD="${PREFIX}/deepseek-window.sh"
HOOKS_JSON="${PREFIX}/deepseek-window.json"

say() { printf '%s\n' "$*"; }
run() {
  if (( DRY_RUN )); then say "  [dry-run] $*"; else "$@"; fi
}

say "DeepSeek off-peak guard — removing the install in ${PREFIX}"

say ""
say "1. background watcher"
if [[ "${OS}" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
  PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
  run launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  if [[ -f "${PLIST}" ]]; then run rm -f "${PLIST}"; fi
  say "  launchd agent ${LABEL} stopped and removed"
elif command -v systemctl >/dev/null 2>&1; then
  UNIT="${HOME}/.config/systemd/user/${LABEL}.service"
  run systemctl --user disable --now "${LABEL}.service" 2>/dev/null || true
  if [[ -f "${UNIT}" ]]; then run rm -f "${UNIT}"; fi
  command -v systemctl >/dev/null 2>&1 && run systemctl --user daemon-reload
  say "  systemd user unit ${LABEL}.service stopped and removed"
else
  say "  nothing to do (no launchd or systemd)"
fi
# A watcher started by hand is not ours to kill silently beyond this note.
if pgrep -f "${GUARD} watch" >/dev/null 2>&1; then
  say "  note: '${GUARD} watch' is still running in another terminal"
fi

say ""
say "2. installed files"
if [[ -f "${GUARD}" ]] && grep -q 'DeepSeek off-peak guard' "${GUARD}"; then
  run rm -f "${GUARD}"
  say "  removed ${GUARD}"
else
  say "  ${GUARD} is not ours (or already gone); left alone"
fi
if [[ -f "${HOOKS_JSON}" ]] && grep -q 'deepseek-window.sh' "${HOOKS_JSON}"; then
  run rm -f "${HOOKS_JSON}"
  say "  removed ${HOOKS_JSON}"
else
  say "  ${HOOKS_JSON} is not ours (or already gone); left alone"
fi

say ""
say "3. VS Code user settings"
if command -v python3 >/dev/null 2>&1; then
  case "$OS" in
    Darwin) [[ -n "${SETTINGS}" ]] || SETTINGS="${HOME}/Library/Application Support/Code/User/settings.json" ;;
    *) [[ -n "${SETTINGS}" ]] || SETTINGS="${HOME}/.config/Code/User/settings.json" ;;
  esac
  if (( DRY_RUN )); then
    say "  [dry-run] drop ${PREFIX} from chat.hookFilesLocations in ${SETTINGS}"
  elif [[ -f "${SETTINGS}" ]]; then
    python3 - "${SETTINGS}" "${PREFIX}" <<'PY'
import json, sys

path, prefix = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
locations = data.get("chat.hookFilesLocations")
if isinstance(locations, dict) and prefix in locations:
    del locations[prefix]
    data["chat.hookFilesLocations"] = locations
    with open(path, "w") as fh:
        json.dump(data, fh, indent=4)
        fh.write("\n")
    print("  dropped " + prefix + " from chat.hookFilesLocations")
else:
    print("  nothing to drop")
PY
  else
    say "  ${SETTINGS} not found; nothing to drop"
  fi
else
  say "  python3 not found; remove '${PREFIX}' from chat.hookFilesLocations by hand"
fi

say ""
say "4. runtime state"
if (( PURGE )); then
  run rm -rf "${STATE_DIR}"
  say "  removed ${STATE_DIR}"
else
  say "  kept ${STATE_DIR} (parked work, override, logs). Use --purge to delete it."
fi

say ""
say "Done. Start a new VS Code chat session so the hooks unload."
