---
name: verify-restore-model
description: Model-check momento-rex's resume protocol (TLA+). Use when a diff touches core.decide, or step, observe, guard, or the token in lib/momento-rex/watch.lua, or to ask if momento-rex can double-type a resume or lose a chat.
---

# Verify the restore model

`verify/restore/Restore.tla` models one Rex pane across Rex restarts: the agent in it, its record in `panes/<block>.json`, and the momento-rex watchers that read and write that record. TLC explores every order of those steps within small bounds. It checks three promises:

| Property | Plain sentence | Harm when broken |
|---|---|---|
| `OneResumePerShell` | Each restored shell gets the resume line typed at most once. | A second `claude --resume ID` lands in the running chat as a message. |
| `ResumeLandsAtPrompt` | The resume line is only typed into the pane's own shell prompt. | The line goes to vim, a nested shell, or a new Claude chat. |
| `SavedChatSurvives` | A chat momento-rex saved stays saved while its agent runs, through a restart, until its resume line runs. | After the restart the chat doesn't come back. |

The `known` ghost resets on `/clear`, so `SavedChatSurvives` allows the lag the README documents ("a chat you switch within the last few seconds...").

## Does the change touch the model?

Look up the coverage table. If a changed function is in it, run the check. If you're not sure, run it anyway: it takes about 15 seconds.

| Code | Model | How it stays in step |
|---|---|---|
| `core.decide` (`lib/momento-rex/core.lua`) | `Decide` | `conform.lua` runs the real function on 105,336 inputs and compares. Mechanical. |
| `core.resume_line` | the `type` action | conformance checks that the typed bytes equal `resume_line(rec, cwd)`. Its validation is in `test/unit.lua`, not here. |
| `core.EXIT_CONFIRM`, `core.RESUME_GRACE` | constants | the conformance table runs at the real values, 2 and 15 |
| `step` in `lib/momento-rex/watch.lua`: `observe`, then `load`, `pane_agent` (when there's a record and no agent in front), `lstart(rec.agent_pid)` (never cached), then one `guard()` before the first action, then `exit_seen` cleared unless marked | `Observe`, `Load`, `Guard`, `Do`, `Finish` | by reading. Each model step is one stretch of code with no wait in it. |
| `still_at_prompt` before each `type`; if it fails, the loaded record is saved back | `Recheck`, `Type` | by reading |
| `observe` and `find_chat`: `at_prompt` means `#ancestors <= 1`, and a Claude chat counts only with `sessions/<pid>.json` and a transcript. `pane_agent` finds an agent among the pane shell's children (`core.pane_shell`, `core.child_agent`). | `Observed`, `BackgroundObs` | by reading; the two core helpers have unit tests |
| `line_ready` in `step` (only for a record whose shell is new and at its prompt): Rex's `input_mode`, not canonical; nil when Rex can't say, which `decide` treats as ready | `ready`, `ShellReady`, `MayTick` | by reading; conformance covers how `decide` uses it |
| watcher startup: read `watcher.pid`, write our pid and `watcher.token`, wait for the named watcher to exit (kill it after 15 s), then stop if the token isn't ours | `StartWatcher`, `Wait` | by reading |
| `guard()` at the top of `full_pass` | `StopIdle` | by reading |
| `bin/momento-rex start_watcher`, `install` (always starts another watcher), config reload | `StartWatcher` with `Handoff = TRUE` | by reading |
| Rex runs one script's handlers one at a time, and nothing runs during `rex.sleep` (`rex do --help`) | watcher steps of one watcher never interleave | an assumption about Rex |

`verify/restore/SYNC` records the commit and the sha256 of `core.lua` and `watch.lua` from the last time someone confirmed the table. The check prints `STALE` when either file has changed since then.

## Run

```sh
verify/restore/check            # every change: ~15 s
verify/restore/check --mutants  # after editing the model or check: proves each property can still fail, ~40 s
verify/restore/check --deep     # before landing a change to guard/token/step: Handoff at full bounds, a few minutes
```

It needs `java` 11+ and `luajit`. It uses `$TLA2TOOLS_JAR` when that's set. Otherwise it downloads tla2tools 1.7.4 to `~/.cache/momento-rex-verify` and checks the jar's sha256. Output goes to `$TMPDIR/momento-rex-verify-restore/`: `<cfg>.out` is raw TLC output, and `<cfg>.trace` has one line per step showing only the variables that changed.

A clean run prints:

```
conformance: the model's Decide against lib/momento-rex/core.lua
  core.decide matches the model on all 105336 inputs
pass   Restore              all properties hold (408127 states)
pass   Handoff              all properties hold (63164 states)
known  F1-typed-mid-step    still breaks ResumeLandsAtPrompt (trace: ...)
```

Exit 0 means all of that. `known` lines are expected: it is the open finding below.

## Read a result

Ask the user to run `/statechart` on `verify/restore/Restore.tla` with the failing config. It reads each violation as its shortest path in plain words, and it draws a chart when the check passes. You can't invoke it yourself. Meanwhile, read `<cfg>.trace`. Name each step in the code's words (Restart means Rex restarted, Type with `pending=` means the watcher typed the resume line), and tell the user the path as a short story.

**`differs:` from conformance.** `core.decide` no longer does what `Decide` says. If the change was intended, edit `Decide` in `Restore.tla` to match it line for line, then rerun. The model results printed after a `differs` describe the old code, so ignore them until conformance matches.

**`FAIL Restore` or `FAIL Handoff`.** A property broke. Before calling it a bug, replay the trace against the code. Can each step happen in that order in `watch.lua`, with the user and Rex doing what the trace says? If a step can't happen (the model lets two things interleave that the code runs without a wait between them, or it lets the user do something impossible), that is a modeling error: fix the model and say what you fixed. One known gap is that the model holds one agent per pane, so a path that needs a second agent started next to a suspended one is out of scope. If every step can happen, it is a real bug. Report it with the trace in the code's words. Don't weaken the property or add a fence to make it pass, and don't change product code unless the user asks.

**`GONE`.** A finding no longer reproduces. If the code was fixed on purpose, retire the finding: delete its `F*.cfg`, remove it from `FINDINGS` in `check` and from the findings section here, and turn off its fence in `Restore.cfg` and `Handoff.cfg` so the must-pass runs cover that path from now on. If nobody meant to fix it, the model probably changed in a way that hides it, so find out why.

**`STALE`.** Read the diff of the named file against the coverage table. If the model still describes the code, or once you've updated it to, run `verify/restore/check --sync` and commit `SYNC` with the change. Only sync after you've confirmed that the table and `Restore.tla` describe the code at the new commit.

## Fences and findings

The must-pass configs set `FenceMidStep`, which rules out the one open finding so every other path still gets checked: the user, the agent, and the clock hold still while a watcher is between its `observe()` and its last action. Other watchers, Rex restarts, Ctrl-Z, editors, and slow rc files all still move.

The finding config turns the fence off and must keep failing:

- **F1, `F1-typed-mid-step`** (`ResumeLandsAtPrompt`). `still_at_prompt` asks Rex for the pane's foreground again just before typing. If the user starts `claude` or vim in the time between that answer and Rex's `write`, the resume line goes to that program. Rex's terminal `write` takes no condition (`rex block inspect` shows only `data`), so this one call's gap stays open until Rex adds one. If it does, pass the shell's pid with the write and retire F1.

`MayTick` is an assumption, not a fence: once the shell's line editor reads (`ready`), a typed resume line starts the agent before `RESUME_GRACE`. While rc files run, time passes freely with the line unread. The assumption rests on zsh and bash turning the tty's canonical mode off exactly while their line editor reads, which a probe against a throwaway Rex confirmed. Fish wasn't available to probe.

Fixed, with the model now checking the path:

- A resumed chat that was Ctrl-Z'd or ran an editor before momento-rex saw it (`pane_agent`; e2e "a resumed chat suspended before momento-rex saw it keeps its record").
- Overlapping watchers overwriting each other or dropping a resume (the startup wait plus one `guard()` per step).
- A resume typed while the restored shell's rc files still ran, and forgotten as "resume did not start" before the shell read it (`line_ready`; e2e "slow shell startup").

## Change the model

Keep it true to the code. Each action names the function it models. One model step must be one stretch of code with no `rex.exec`, `rex.block.call`, or file read in the middle. If your change adds such a wait, split the step. New state the code keeps (a new field in the record, a new cache that changes a decision) becomes a model variable, and a new record field also goes into `RecStr`, `DecideTable.tla`, and `conform.lua`.

After any model edit, run `check --mutants`. Each mutant breaks the code and the model the same way, and the check must show that TLC then breaks the property that the code protects (and that conformance catches the code edit, when it's in `core.decide`). Where two guards protect one property, the mutant removes both: `no-prompt-checks` drops `at_prompt` and the recheck, and `no-liveness-checks` drops `agent_alive` and `pane_agent`. The others are `keep-old-inc`, `no-ready-gate`, `no-pane-agent`, `no-wait`, and `guard-each-action`. If you add a property or a guard, add a mutant for it.

Bounds are in each `.cfg`. Keep the default `check` under about 30 seconds. Push bigger bounds into `--deep`.

## What this doesn't cover

- One pane, and one agent per pane. Records of different panes don't interact in the code, except through GC, which isn't modeled. GC deletes records of panes missing for two complete passes, after `GC_AFTER` (30 s) of uptime. If Rex restores panes slower than that, records go, and nothing here would notice.
- Claude only. Codex's lookup (`codex_chat_from_lsof` and `codex_chat_from_args`) is not modeled. `Observed` treats both agents as "chat known once its file exists".
- The startup wait's timeout. If the previous watcher is still running after 15 s, the new one kills it. A watcher killed between writing `resuming` and typing leaves that resume untyped. The model only has the predecessor exit on its own.
- `write_atomic` is one atomic step. Two watchers writing one record would share `path .. ".tmp"`, but with the startup wait they no longer run at once, except after the timeout above.
- Watchers with different state dirs don't share a token or pid file. That's two separate momento-rex watchers, outside the model.
- A shell with no line editor (`sh`, `bash --noediting`) keeps the tty canonical, so momento-rex never types into it and reports `resume.waiting` after 60 s. A resume command that itself takes over about 17 s to start the agent, such as a `cd` into a stalled network mount, still gets forgotten. The model's `MayTick` assumes neither happens.
- Unsafe records (`resume.unsafe`): `resume_line`'s validation is tested in `test/unit.lua`. The model only feeds valid records.
- How Rex shuts down. The model's `Restart` kills the agent, the shell, and every watcher in one step. If Rex left the watcher running for over `EXIT_CONFIRM` after killing the agents while their shells survive, saved chats would be deleted at shutdown.
- Bounds. `Restore`: 2 restarts, 3 agents, 3 chats, 5 ticks, 3 watcher lifetimes. `Handoff`: 1 restart, 2 agents, 2 chats, 4 ticks, 3 watchers (`--deep`: 2, 3, 3, 5, 4). The clock ticks freely between steps, so the model only uses grace > confirm, not the real 15 s and 2 s. The conformance table checks those real values.
