# DeepSeek off-peak guard

Keeps AI work inside the DeepSeek off-peak window — for **every** VS Code
workspace on the machine, not just one repo — with a manual override only the
owner can arm.

| | UTC |
| --- | --- |
| Off-peak — work allowed | **04:00-06:00** and **10:00-01:00** (the second window crosses midnight) |
| Peak — work stopped | **01:00-04:00** and **06:00-10:00** |
| Default | **no** — outside an allowed window, nothing runs |

## Install

```sh
git clone <this-repo> ~/dev/deepseek-window
cd ~/dev/deepseek-window
./install.sh
```

Then reload VS Code (or start a new chat session) so the hooks load.

`install.sh` does four things, all user-scoped and safe to re-run:

1. installs the guard at `~/.copilot/hooks/deepseek-window.sh` and its hook file
   next to it, rendered with the absolute path;
2. merges `chat.hookFilesLocations` into your VS Code **user** settings (backup:
   `settings.json.ai-window-backup`) so the hook folder is loaded in every
   workspace;
3. installs the background watcher — a launchd agent on macOS, a systemd user
   unit on Linux;
4. runs `verify.sh` and prints the result.

| Option | Default | Effect |
| --- | --- | --- |
| `--prefix DIR` | `~/.copilot/hooks` | where the guard and hook file go |
| `--state-dir DIR` | `~/.deepseek-window` | parked work, override, watcher log |
| `--settings FILE` | detected | VS Code user `settings.json` to merge into |
| `--label NAME` | `<user>.deepseek-window` | watcher label / service name |
| `--no-watch` | — | skip the background watcher |
| `--no-settings` | — | do not touch VS Code settings |
| `--dry-run` | — | print the plan, change nothing |

Requirements: bash, VS Code 1.100+ with agent hooks (preview). `python3` is used
to merge settings; without it the installer tells you the two lines to add.
The watcher needs launchd (macOS) or systemd (Linux); without either, run
`deepseek-window.sh watch` yourself.

## What it does at each boundary

**Peak starts.** The `PreToolUse` hook refuses every agent tool call and returns
`continue: false`, so the session stops instead of retrying, with a message that
names the resume time. A prompt you submit during peak is *parked*, not lost.

**Off-peak starts.** Tool calls pass again. Parked work is handed back to a
running session once, as hook context, and the watcher wakes at the boundary,
`cd`s into the workspace that was interrupted, and reopens it in chat:

```sh
code chat --mode agent --reuse-window "<the parked request>"
```

## Manual override (owner-only)

```sh
~/.copilot/hooks/deepseek-window.sh override --minutes 30 --reason "release day"
~/.copilot/hooks/deepseek-window.sh override:clear
```

The command needs an interactive terminal (it refuses a pipe with exit 3), asks
you to type `override peak hours`, writes a 0600 file with a TTL of 1–240
minutes, and **every** gate decision while it is live says
`OVERRIDE ACTIVE (armed … by … for …)`. When it expires, work stops again and the
refusal says `OVERRIDE EXPIRED`.

The hook also denies an *agent's* terminal call that tries to arm it, so the
override stays something you do, not something an agent talks itself into. If you
want an override that no in-workspace process can even attempt, set
`AI_WINDOW_OVERRIDE=1` in the environment VS Code itself was launched with.

## Commands

```sh
~/.copilot/hooks/deepseek-window.sh status        # state, next boundary, override, parked work
~/.copilot/hooks/deepseek-window.sh watch         # the boundary watcher (install.sh sets this up)
~/.copilot/hooks/deepseek-window.sh override      # owner-only, interactive
~/.copilot/hooks/deepseek-window.sh               # guard mode: exit 0 allowed, exit 1 denied
AI_WINDOW_TEST_NOW_UTC=02:00 ~/.copilot/hooks/deepseek-window.sh status   # fake the clock
```

Useful environment variables: `AI_WINDOW_OVERRIDE` / `AI_WINDOW_OVERRIDE_REASON`,
`AI_WINDOW_CODE_BIN` (path to the VS Code CLI), `AI_WINDOW_STATE_DIR`,
`AI_WINDOW_TEST_NOW_UTC`.

## Uninstall

```sh
./uninstall.sh            # stops the watcher, removes the files and the setting
./uninstall.sh --purge    # also deletes ~/.deepseek-window (parked work, logs)
```

## Files it touches

```
~/.copilot/hooks/deepseek-window.sh     the guard (this repo's deepseek-window.sh)
~/.copilot/hooks/deepseek-window.json   the hook wiring (all four events)
~/.deepseek-window/                     handoff, handoff.dir, override, watch.log
~/Library/LaunchAgents/<label>.plist     macOS watcher   (or ~/.config/systemd/user/<label>.service)
<vscode user settings>.json             chat.hookFilesLocations gains ~/.copilot/hooks
```

## Limits, stated honestly

- **Not a security boundary.** Hooks run with your permissions. The owner-only
  rules are enforced by the client through the guard's own `PreToolUse`
  decisions; they are not cryptographic. Anyone who can edit the guard script or
  the hook file can change the policy — as the owner, that is you.
- **The model call itself is not gated.** Only tool operations and hook-observed
  prompts are. A turn already in flight will finish.
- **The restart needs the VS Code CLI** on `PATH` or at a known location; if it
  is missing the watcher prints the parked request instead and says so.
- **Parked work is consumed when used.** There is no expiry: whatever is in
  `handoff` is restarted at the next off-peak boundary. Clear it by hand with
  `rm ~/.deepseek-window/handoff` if you no longer want it.
- Agent hooks are a preview VS Code feature; the configuration format can change.

## Verify

```sh
./verify.sh          # boundaries, hook contract, owner-only rules, watcher
```

In VS Code: `View Logs` → look for `Load Hooks` to confirm the hook file was
loaded, and `Developer: Show Agent Debug Logs` to see the JSON a hook returned.
