---
name: verify-momento-rex
description: Drive momento-rex (the Rex watcher that brings Claude Code and Codex chats back after a Rex server restart) end to end in a throwaway Rex server with fake agents, and capture proof. Use to verify a change to bin/momento-rex or lib/momento-rex, reproduce a save/restore bug, or check install, uninstall, and status behavior the way a user sees it.
---

# Verify momento-rex

momento-rex has no UI of its own. A user touches it in three places:

1. The `bin/momento-rex` CLI (`install`, `uninstall`, `status`, `start`, `version`).
2. Their Rex panes. A pane where `claude` or `codex` is running gets a record, and after a Rex server restart the restored shell has `claude --resume ID` or `codex resume ID` typed into it.
3. Files in `$MOMENTO_REX_STATE_DIR` (`panes/*.json`, `status.json`, `momento-rex.log`) and one tagged line in `init.lua`.

Verification therefore means running a real Rex server, real zsh panes, and the real watcher, then restarting that server. The helper `bin/sandbox` in this skill does that on a private socket in `/tmp/momento-rex-verify.XXXX`, with the fake `claude` and `codex` from `test/fake-agent.sh`.

Never drive the user's own Rex server to verify momento-rex. Restarting it kills every pane they have open. Every `sandbox` command talks to the run's own socket, and `up` aborts if that socket answers as a different server. Don't call `bin/momento-rex` or `rex` directly with `REX_SERVER` set to the sandbox socket. When that socket is gone (the sandbox is stopped, or already torn down), rex quietly falls back to the user's own server. `$S momento-rex` avoids this by giving momento-rex a `rex` shim (`$BV_RUN/rexshim/rex`) that passes `-S`, which never falls back, and `$S rex` passes `-S` too. Runs are isolated by directory, so several can exist side by side.

All commands below run from the repo root. Requirements: `rex`, `jq`, `zsh`, `uuidgen`, `lsof` on PATH. `luajit` is only needed for `make unit`.

```sh
S=.claude/skills/verify-momento-rex/bin/sandbox
```

## Launch

```sh
eval "$($S up)"        # exports BV_RUN=/tmp/momento-rex-verify.XXXX, prints the evidence dir
```

`up` creates the run directory, writes fake `claude`/`codex` wrappers and a `.zshrc` that puts them on PATH (plus `alias claude='FAKE_ALIAS=1 claude'`, so you can see that the user's alias was used), writes an `init.lua` holding two lines of user content, and runs `momento-rex install --no-start` against it. It then starts `rex server run` with that config. The server's `init.lua` launches the watcher with `MOMENTO_REX_PERIOD=1` (one pass per second instead of three) and `MOMENTO_REX_GC_AFTER=6`.

The run is ready when `up` returns 0. It waits for the server to answer on its socket and for the watcher that server started to write `state/status.json` with the current token. `start` and `restart` wait the same way. Any failure exits non-zero with the reason.

Every other subcommand reads the run from `$BV_RUN`. In a new shell, run `export BV_RUN=/tmp/momento-rex-verify.XXXX` again. Shell variables don't carry between separate Bash tool calls, so put the export at the top of each call.

A session isolated to a worktree lane refuses `eval`. There, write the journey as a script under the lane's `tmp/` (gitignored) and run it with `bash tmp/NAME.sh`. Inside the script, set the run with `BV_RUN="$($S up | sed -n 's/^export BV_RUN=//p')"; export BV_RUN`.

In a lane, `bin/momento-rex start` and `install` without `--no-start` exit 3 even against the sandbox, because momento-rex can't tell the sandbox from your real Rex. Every journey except `restore-watcher-only` avoids them. Drive that one from the primary checkout.

## Doctor

```sh
$S doctor; echo rc=$?
```

Doctor is read-only. It checks that the socket answers as this run's server, that the answering pid is the one `up` started, that exactly one watcher process carries this run's `state_dir=`, and it prints the momento-rex version and `momento-rex status`. It exits 1 if any check fails. A healthy run looks like:

```
server     up, pid 83391, unix:///private/tmp/momento-rex-verify.JgBA/s.sock
watcher    1 process for this run
momento-rex       momento-rex 0.1.0 from /Users/.../momento-rex
--- momento-rex status
watcher   running, v0.1.0, last pass 0s ago
init.lua  set up (...)
chats     none saved
```

Run doctor first whenever anything looks off. Zero watchers after a restart means init.lua didn't start one. Two means the newest-wins handoff broke.

## Drive

| Command | What it does |
|---|---|
| `read -r SA BA < <($S pane a [DIR])` | New Rex session named `a` with a zsh pane in DIR (default `$BV_RUN/work`). Prints session and block IDs. |
| `$S type $SA $BA TEXT` | Types TEXT and Enter, as a user would. |
| `$S key $SA $BA ctrl+z` | Sends a key press. |
| `$S fg $SA $BA` | Foreground program name: `claude`, `codex`, or `zsh`. |
| `$S record $BA` | The pane's saved record (JSON). Exits 1 if there is none. |
| `$S wait SECS CMD ARGS...` | Retries CMD until it exits 0. Use it instead of fixed sleeps, e.g. `$S wait 10 $S record $BA`. CMD runs with `$BV_RUN` exported, so `$S` works inside `sh -c`. |
| `$S restart` | Stops the server (Rex saves sessions), starts it again from the same state dir. Rex restores panes as fresh shells with the same block IDs. |
| `$S launches` | One line per fake-agent start: `claude new ID cwd=... alias=1` or `claude resumed ID ...`. Restarts add a `--- restart HH:MM:SS` line. |
| `$S momento-rex ARGS...` | `bin/momento-rex` with this run's config, state dir, and socket. |
| `$S rex ARGS...` | `rex` against this run's server, e.g. `$S rex capture -s $SA -b $BA --trim`. |

The fake agents read stdin lines. Any line counts as a chat message. `/clear` starts a new chat ID, and `/exit` quits. `FAKE_CLAUDE_V2=1 claude` writes a sessions file in a changed format, which simulates Claude changing its private files. See `test/fake-agent.sh` for exactly which files each fake writes.

The feature map in `features/` has a recipe for each user-facing behavior. Read `features/README.md` before driving.

## Evidence

```sh
$S snap LABEL     # prints the directory it wrote
```

`snap` writes `/tmp/momento-rex-verify-evidence/<run id>/LABEL/` with: `screen-<block>.txt` (each pane's screen and scrollback), `records/` (copies of `panes/*.json`), `status.txt` (`momento-rex status` output plus its exit code), `momento-rex.log`, `launches.txt`, `init.lua`, and `sessions.json`. `up` also saves `install.txt` there. Snap before and after each action you are proving, with labels like `before-restart` and `after-restart`.

Proof standards:

- Go through the user's path. Type `claude` into a pane and restart the server. Don't write records by hand, and don't call `lib/momento-rex/*.lua` functions to simulate a pass. The one exception is the safety journey, which plants a record because a hostile record is exactly what it tests.
- A restore is proven by three things together. The pane's screen shows the typed `claude --resume ID` (or `cd -- '...' && codex resume ID`). `launches` shows `resumed ID` with the expected `cwd=`, and shows it exactly once. And `fg` is the agent.
- Prove side effects as well as output. That means the record file appearing or disappearing, the `init.lua` diff, and the `momento-rex status` exit code.
- The agents are fakes. This is the one place a mock is acceptable, because momento-rex only reads the agents' files and process list and never calls them. A pass here does not prove that real Claude or Codex still write those files the same way. See Gotchas in `features/restore-after-restart.md`.

## Cleanup

```sh
$S down
```

`down` stops this run's server by its socket and recorded pid, kills watcher processes whose command line contains this run's unique `state_dir=` path, and deletes `$BV_RUN`. It never kills by process name. Evidence in `/tmp/momento-rex-verify-evidence/<run id>/` survives. Delete that by hand once you have reported it. Run `down` after every failed attempt too, so stray servers don't pile up. Each run's socket lives in its own directory, so a stray server never collides with a new run.

If `$BV_RUN` was lost, find leftovers with `ls -d /tmp/momento-rex-verify.*`, then `BV_RUN=/tmp/momento-rex-verify.XXXX $S down` for each.

## Other checks

`make test` runs the unit tests and `test/e2e.sh`, which uses the same setup as this skill and asserts 29 behaviors. Run it as a regression check, but it is not a substitute for driving the specific behavior you changed and capturing evidence.
