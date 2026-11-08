# The model and the code

## Coverage

Each row maps code to the part of `Restore.tla` that models it, and says how the two stay in step. `verify/restore/SYNC` records when someone last confirmed this table, and the check prints `STALE` once `core.lua` or `watch.lua` changes after that.

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

## Changing the model

Each action names the function it models. One model step must be one stretch of code with no `rex.exec`, `rex.block.call`, or file read in the middle. If your change adds such a wait, split the step. New state the code keeps (a new field in the record, a new cache that changes a decision) becomes a model variable. A new record field also goes into `RecStr`, `DecideTable.tla`, and `conform.lua`.

After any model edit, run `check --mutants`. Each mutant breaks the code and the model the same way, and the check shows that TLC then breaks the property the code protects, and that conformance catches the code edit when it's in `core.decide`. Where two guards protect one property, the mutant removes both: `no-prompt-checks` drops `at_prompt` and the recheck, and `no-liveness-checks` drops `agent_alive` and `pane_agent`. The others are `keep-old-inc`, `no-ready-gate`, `no-pane-agent`, `no-wait`, and `guard-each-action`. If you add a property or a guard, add a mutant for it.

Bounds are in each `.cfg`. Keep the default `check` under about 30 seconds, and push bigger bounds into `--deep`.

## What this doesn't cover

- The lag the README documents for a chat switched in the last few seconds before Rex stops. The `known` ghost resets on `/clear`, so `SavedChatSurvives` allows it.
- One pane, and one agent per pane. Records of different panes don't interact in the code, except through GC, which isn't modeled. GC deletes records of panes missing for two complete passes, after `GC_AFTER` (30 s) of uptime. If Rex restores panes slower than that, records go, and nothing here would notice.
- Claude only. Codex's lookup (`codex_chat_from_lsof` and `codex_chat_from_args`) is not modeled. `Observed` treats both agents as "chat known once its file exists".
- The startup wait's timeout. If the previous watcher is still running after 15 s, the new one kills it. A watcher killed between writing `resuming` and typing leaves that resume untyped. The model only has the predecessor exit on its own.
- `write_atomic` is one atomic step. Two watchers writing one record would share `path .. ".tmp"`, but with the startup wait they no longer run at once, except after the timeout above.
- Watchers with different state dirs don't share a token or pid file. That's two separate momento-rex watchers, outside the model.
- A shell with no line editor (`sh`, `bash --noediting`) keeps the tty canonical, so momento-rex never types into it and reports `resume.waiting` after 60 s. A resume command that itself takes over about 17 s to start the agent, such as a `cd` into a stalled network mount, still gets forgotten. The model's `MayTick` assumes neither happens.
- Unsafe records (`resume.unsafe`): `resume_line`'s validation is tested in `test/unit.lua`. The model only feeds valid records.
- How Rex shuts down. The model's `Restart` kills the agent, the shell, and every watcher in one step. If Rex left the watcher running for over `EXIT_CONFIRM` after killing the agents while their shells survive, saved chats would be deleted at shutdown.
- Bounds. `Restore`: 2 restarts, 3 agents, 3 chats, 5 ticks, 3 watcher lifetimes. `Handoff`: 1 restart, 2 agents, 2 chats, 4 ticks, 3 watchers (`--deep`: 2, 3, 3, 5, 4). The clock ticks freely between steps, so the model only uses grace > confirm, not the real 15 s and 2 s. The conformance table checks those real values.
