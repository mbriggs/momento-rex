# Status and problems

`momento-rex status` tells the user whether the watcher is running, whether init.lua is set up, which chats are saved, and any problems. It exits 1 when something needs attention, and the problems name the cause, for example `resume.unsafe` for a refused record or `claude.sessions` when Claude's sessions file changed format.

## Sub-features

- `status-healthy` prints `watcher running`, `init.lua set up`, and the saved chats, and exits 0.
- `status-chats` lists each saved chat as block suffix, agent, ID prefix, state, and folder.
- `status-unsafe` refuses and deletes a record with an unsafe folder or ID, types nothing, and reports `resume.unsafe` with exit 1.
- `status-drift` reports `claude.sessions` when Claude's sessions file has an unknown shape.
- `status-no-rex` prints `Rex isn't running.` and the saved record names when no server answers.

## How to get to it (user POV)

- Run `bin/momento-rex status` in a terminal.

## Driving it with sandbox

Preconditions:

- A fresh run from `eval "$($S up)"`, with `$S doctor` exiting 0.

- **Healthy, empty.** Run `$S momento-rex status; echo rc=$?`. The output shows `watcher running`, `init.lua set up`, `chats none saved`, and `rc=0`.
- **With chats.** Start a claude chat in pane `a` (see `save-chats.md`), then run `$S momento-rex status`. A line under `chats` shows the block's last 8 characters, `claude`, the first 8 characters of the chat ID, `live`, and the folder.
- **Unsafe record.** This is the one journey that plants a record, because a hostile record is the input under test. Run `read -r SD BD < <($S pane d)`, then write a record whose `cwd` contains a newline and a `touch` command (copy the `jq -cn` line from the `safety` block of `test/e2e.sh`, with `$T` set to `$BV_RUN` and `$STATE` to `$BV_RUN/state`). Then run `$S restart`. The record file is gone within 10 seconds, the `touch` target doesn't exist, `$S launches` has no line with that ID, and `$S momento-rex status; echo rc=$?` shows `resume.unsafe` and `rc=1`.
- **Format drift.** Run `read -r SE BE < <($S pane e); sleep 1; $S type $SE $BE "FAKE_CLAUDE_V2=1 claude"; $S wait 20 sh -c "$S momento-rex status 2>&1 | grep -q claude.sessions"`. `status` lists the problem with exit 1.
- **Rex down.** Run `$S stop; $S momento-rex status; echo rc=$?`. The output is `Rex isn't running.` with a `saved:` line per record, and `rc=4`. Run `$S start` to continue.
- **Proof.** `$S snap status-<id>`. It saves `status.txt` with the exit code.

## Gotchas

- `status` exits 1 for any problem, including one left over from an earlier step in the same run. Use a fresh run when the exit code is the thing being proven.
- An unsafe record only has an effect after a restart, because a record is only typed into a new shell.
- With Rex down, `momento-rex status` exits 4, not 1. It prints rex's `no Rex server is running` error to stderr, then `Rex isn't running.` and one `saved:` line per record.
- Run this journey only through `$S momento-rex`. Plain `bin/momento-rex status` with `REX_SERVER` set to a stopped sandbox socket runs against the user's own Rex instead, and reports `watcher STALE` rather than `Rex isn't running.`
