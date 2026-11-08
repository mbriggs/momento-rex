# Reading a check result

## `differs:` from conformance

`core.decide` no longer does what `Decide` in `Restore.tla` says. If the code change was intended, edit `Decide` by hand to match it line for line, then rerun. Nothing generates `Decide`. The model results printed after a `differs` describe the old code, so ignore them until conformance matches.

## `FAIL Restore`, `FAIL Handoff`, or `FAIL HandoffDeep`

All three read the same way. Open `$TMPDIR/momento-rex-verify-restore/<cfg>.trace` and replay each step against the code. The coverage table in [model.md](model.md#coverage) maps each model action to its function in `core.lua` or `watch.lua`. In the trace, Restart means Rex restarted, and Type with `pending=` means the watcher typed the resume line.

A step the code can't take is a modeling error: the model lets two things interleave that the code runs with no wait between them, or the user does something impossible. The model holds one agent per pane, so a path that needs a second agent next to a suspended one is out of scope too. Fix the model, rerun the check and `--mutants`, and say what you fixed.

If every step can happen, it is a real bug. Keep the properties and [fences](#fences-and-findings) as they are. When the path runs through code your change touched, your change caused it, so rework the change and rerun. Otherwise the bug predates you: report it and leave product code alone unless the user asks you to fix it.

Report a real bug as the trace told as a short story in the code's words. Ask the user to run `/statechart` on `verify/restore/Restore.tla` with the failing config, such as `verify/restore/Handoff.cfg`. It reads the violation as its shortest path in plain words, and only the user can run it.

## `GONE`

A finding's config no longer fails. If the code was fixed on purpose, retire the finding:

- Delete its `F*.cfg`.
- Remove it from `FINDINGS` in `verify/restore/check` and from the open findings below.
- Turn off its fence in `Restore.cfg` and `Handoff.cfg`, so the must-pass runs cover that path.

If nobody meant to fix it, a model change probably hides it. Find that change.

## `STALE`

`verify/restore/SYNC` records the commit and the sha256 of `core.lua` and `watch.lua` from the last time someone confirmed the coverage table in [model.md](model.md). Read the diff of the named file against that table. Once the table and `Restore.tla` describe the code at the new commit, run `verify/restore/check --sync` and commit `SYNC` with the change.

## Fences and findings

The must-pass configs set `FenceMidStep`, which rules out the one open finding so every other path still gets checked. While a watcher is between its `observe()` and its last action, the user, the agent, and the clock hold still. Other watchers, Rex restarts, Ctrl-Z, editors, and slow rc files all still move. The finding config turns the fence off and must keep failing.

- **F1, `F1-typed-mid-step`** (`ResumeLandsAtPrompt`). `still_at_prompt` asks Rex for the pane's foreground again just before typing. If the user starts `claude` or vim between that answer and Rex's `write`, the resume line goes to that program. Rex's terminal `write` takes no condition (`rex block inspect` shows only `data`), so the gap stays open until Rex adds one. If it does, pass the shell's pid with the write and retire F1.

`MayTick` is an assumption, not a fence. Once the shell's line editor reads (`ready`), a typed resume line starts the agent before `RESUME_GRACE`. While rc files run, time passes freely with the line unread. This rests on zsh and bash turning the tty's canonical mode off exactly while their line editor reads, which a probe against a throwaway Rex confirmed. Fish wasn't available to probe.

Fixed, with the model now checking the path:

- A resumed chat that was Ctrl-Z'd or ran an editor before momento-rex saw it (`pane_agent`; e2e "a resumed chat suspended before momento-rex saw it keeps its record").
- Overlapping watchers overwriting each other or dropping a resume (the startup wait plus one `guard()` per step).
- A resume typed while the restored shell's rc files still ran, and forgotten as "resume did not start" before the shell read it (`line_ready`; e2e "slow shell startup").
