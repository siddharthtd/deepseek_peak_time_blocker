# Enhancements

Requests for the guard, in the order they were made. `README.md` is the
reference; each item here is implemented and covered by `verify.sh`.

## 1. `extend` — done

> There should be an extend option as well, which will extend the firing of the
> block by --minutes N. Value at a time should be less than 10, Shouldn't require
> writing or typing anything extra (confirmation text)

Landed as a new mode next to `override`:

```sh
~/.copilot/hooks/deepseek-window.sh extend --minutes 5     # 1..9, default 5
```

- **Less than ten a call.** `--minutes` is capped at 9, so one call can never add
  ten minutes or more. Repeated calls accumulate — the state file keeps the total
  past the scheduled end, and a later call pushes that total further out rather
  than replacing it.
- **Nothing to type and nothing to confirm.** No interactive terminal is
  required and no phrase is asked for: the command is the whole interaction. The
  asymmetry with `override` is deliberate — that mode lets work *through*, so it
  stays owner-only and phrase-gated; `extend` only ever stops work for longer,
  and while a block is firing an agent cannot run anything at all.
- **A block has to be firing.** Off-peak there is nothing to extend, so `extend`
  says so and changes nothing.
- **It binds every gate, not just the caller.** The extension is part of the
  window decision, so guard mode, the `PreToolUse` hook, `status` and the watcher
  all honour it, and the watcher announces the extended tail instead of declaring
  off-peak at the scheduled boundary.
- **Machine-wide, like the rest of the rule.** The guard lives at
  `~/.copilot/hooks/deepseek-window.sh`, so every workspace sees the same state.
- **Verified.** The `extend` section of `verify.sh` checks the `--minutes` bounds
  (0, 10, 99, `abc`), the no-op off-peak, that no TTY or phrase is needed, that
  work stays stopped three minutes past the scheduled end and resumes when the
  extension runs out, that a second call adds to the first, that the hook denies
  inside an extension, and that a spent extension is dropped.

