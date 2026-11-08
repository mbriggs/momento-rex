---
name: verify-restore-model
description: Model-check momento-rex's resume protocol (TLA+). Use when a diff touches core.decide, or step, observe, guard, or the token in watch.lua, or to ask if a resume can be typed twice or a chat lost.
---

# Verify the restore model

`verify/restore/Restore.tla` models one Rex pane across Rex restarts: the agent in it, its record in `panes/<block>.json`, and the momento-rex watchers that read and write that record. TLC explores every order of those steps within small bounds and checks three properties:

| Property | Plain sentence | Harm when broken |
|---|---|---|
| `OneResumePerShell` | Each restored shell gets the resume line typed at most once. | A second `claude --resume ID` lands in the running chat as a message. |
| `ResumeLandsAtPrompt` | The resume line is only typed into the pane's own shell prompt. | The line goes to vim, a nested shell, or a new Claude chat. |
| `SavedChatSurvives` | A chat momento-rex saved stays saved while its agent runs, through a restart, until its resume line runs. | After the restart the chat doesn't come back. |

CI runs the default check on every PR. Run it yourself before landing a change to `core.decide`, or to `step`, `observe`, `guard`, or the token in `lib/momento-rex/watch.lua`, so you read any failure before review. For `guard`, the token, or `step`, run `--deep` too. If you can't tell whether a change touches the model, run the check. It takes about 15 seconds.

## Run

```sh
verify/restore/check            # every change: ~15 s
verify/restore/check --deep     # also Handoff at full bounds, a few minutes
verify/restore/check --mutants  # after editing the model or check, ~40 s
```

It needs `java` 11+ and `luajit`. It uses `$TLA2TOOLS_JAR` when set, and otherwise downloads tla2tools 1.7.4 to `~/.cache/momento-rex-verify` and checks its sha256. Output goes to `$TMPDIR/momento-rex-verify-restore/`: `<cfg>.out` is raw TLC output, and `<cfg>.trace` has one line per step showing only the variables that changed.

A clean run prints this and exits 0. `--deep` adds a `pass   HandoffDeep` line.

```
conformance: the model's Decide against lib/momento-rex/core.lua
  core.decide matches the model on all 105336 inputs
pass   Restore              all properties hold (408127 states)
pass   Handoff              all properties hold (63164 states)
known  F1-typed-mid-step    still breaks ResumeLandsAtPrompt (trace: ...)
```

The `known` line is expected, because F1 is an open finding that must keep failing. Any change to `core.lua` or `watch.lua` also prints `STALE` and exits 1 until someone confirms the model still describes the code. [results.md](results.md) has a playbook for each `differs:`, `FAIL`, `GONE`, and `STALE` line.

A pass holds only within the model's scope: one pane, one agent per pane, Claude's chat lookup, and small bounds. When you report a pass, list each gap in [model.md](model.md#what-this-doesnt-cover) that names code your change touched, such as the startup wait's timeout for a change to watcher startup. If none does, say so.

To edit the model or the coverage table, read [model.md](model.md) first.
