---
name: verify-momento-rex
description: Drive momento-rex end to end in a throwaway Rex server and capture proof. Use to verify a change to bin/momento-rex or lib/momento-rex, to run the landing check (sandbox all) before bin/worktree land, or to reproduce a save, restore, install, or status bug.
---

# Verify momento-rex

momento-rex has no UI of its own. A user touches it in three places:

1. The `bin/momento-rex` CLI (`install`, `uninstall`, `status`, `start`, `version`).
2. Their Rex panes. A pane running `claude` or `codex` gets a record, and after a Rex server restart the restored shell has `claude --resume ID` or `codex resume ID` typed into it.
3. Files in `$MOMENTO_REX_STATE_DIR` (`panes/*.json`, `status.json`, `momento-rex.log`) and one tagged line in `init.lua`.

`bin/sandbox` in this skill runs a real Rex server, real zsh panes, and the real watcher on a private socket in `/tmp/momento-rex-verify.XXXX`, with the fake `claude` and `codex` from `test/fake-agent.sh`, and restarts that server. The fakes are the one acceptable mock here, because momento-rex only reads the agents' files and process list and never calls them.

When a socket is gone, `rex` quietly falls back to the user's own server, and restarting that kills every pane they have open. So reach the sandbox only through `$S rex` and `$S momento-rex`, which pass `-S` and never fall back. Never set `REX_SERVER` to the sandbox socket and call `rex` or `bin/momento-rex` directly.

Run everything from the repo root. It needs `rex`, `jq`, `zsh`, `uuidgen`, and `lsof` on PATH.

```sh
S=.claude/skills/verify-momento-rex/bin/sandbox
```

## The all run

```sh
$S all      # every journey on the committed tree; exit 0 and a stamp only if all pass
```

`all` is the landing check: `bin/worktree land` refuses a change to anything but Markdown without its stamp. It refuses to start with uncommitted or untracked changes, since the stamp names the committed tree. It runs `bin/journeys`, which drives every sub-feature in `features/`, each journey from its own fresh `up`, and prints one `ok` or `FAIL` line per sub-feature ID. When every check passes, it writes `verified`, holding `HEAD^{tree}`, into the run's evidence directory, `/tmp/momento-rex-verify-evidence/all.XXXX/`. Each journey's run and snaps sit inside that directory, and `journeys.txt` holds the output.

The journeys run under `env -i` with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` plus the Rex app's own `rex` directory, and a throwaway `HOME`. Your shell rc, mise, Homebrew, and `~/.config` play no part, so a pass doesn't depend on what this machine has installed. The run needs the Rex app at `~/Library/Application Support/com.superlogical.rex/` and takes about two minutes.

A `FAIL` line prints what it saw. To dig in, drive that journey by hand with the commands below. After a fix, commit and run `all` again, because a stamp counts only for the tree it names.

The all run drives `restore-watcher-only` in a lane as well. The CLI refuses `momento-rex start` there, so the run starts the replacement watcher itself with the command `start` runs, against the sandbox server.

When you change a journey's recipe or add one, change `bin/journeys` to match, so the all run keeps covering every sub-feature.

## Launch

```sh
$S up       # prints the run dir and the evidence dir
$S doctor   # read-only health check; exits 1 if anything is off
```

`up` writes fake `claude`/`codex` wrappers and a `.zshrc` that puts them on PATH, with `alias claude='FAKE_ALIAS=1 claude'` so `launches` shows `alias=1` when the user's alias was used. It writes an `init.lua` with two lines of user content, runs `momento-rex install --no-start` against it, and starts `rex server run` with that config. The watcher runs a pass every second (`MOMENTO_REX_PERIOD=1`) and garbage-collects after 6 seconds (`MOMENTO_REX_GC_AFTER=6`). `up`, `start`, and `restart` return 0 once the server answers and its watcher has written `state/status.json` with the current token.

Every other subcommand uses the checkout's latest run, which `up` records in `tmp/sandbox-run`. Recipes name paths inside the run as `$BV_RUN/...`, so set `BV_RUN=$(cat tmp/sandbox-run)` in each Bash call or script that uses them. To drive two runs from one checkout at once, set `BV_RUN` to each run dir.

In a worktree lane, the Bash hook refuses a tool call holding compound commands such as `read ... < <($S pane a)` or `sh -c "$S ..."`. Inside a script they run fine, so write the journey as a script under the lane's `tmp/` (gitignored) and run `bash tmp/NAME.sh`.

Doctor checks that the socket answers as this run's server with the pid `up` started, that exactly one watcher carries this run's `state_dir=`, and prints `momento-rex status`. Run it first whenever anything looks off. Zero watchers after a restart means init.lua didn't start one, and two means the newest-wins handoff broke.

## Drive

| Command | What it does |
|---|---|
| `read -r SA BA < <($S pane a [DIR])` | New Rex session named `a` with a zsh pane in DIR (default `$BV_RUN/work`). Prints session and block IDs. |
| `$S type $SA $BA TEXT` | Types TEXT and Enter, as a user would. |
| `$S key $SA $BA ctrl+z` | Sends a key press. |
| `$S fg $SA $BA` | Foreground program name: `claude`, `codex`, or `zsh`. |
| `$S record $BA` | The pane's saved record (JSON). Exits 1 if there is none. |
| `$S wait SECS CMD ARGS...` | Retries CMD until it exits 0, e.g. `$S wait 10 $S record $BA`. CMD runs with `$BV_RUN` exported. |
| `$S restart` | Stops the server (Rex saves sessions) and starts it again. Rex restores panes as fresh shells with the same block IDs. |
| `$S launches` | One line per fake-agent start: `claude new ID cwd=... alias=1` or `claude resumed ID ...`. Each restart adds a `--- restart HH:MM:SS` line and never clears earlier ones. |
| `$S momento-rex ARGS...` | `bin/momento-rex` with this run's config, state dir, and socket. |
| `$S rex ARGS...` | `rex` against this run's server, e.g. `$S rex capture -s $SA -b $BA --trim`. |

The fake agents read stdin lines. Any line counts as a chat message. `/clear` starts a new chat ID, and `/exit` quits. `FAKE_CLAUDE_V2=1 claude` writes a sessions file in a changed format, which simulates Claude changing its private files. `test/fake-agent.sh` shows exactly which files each fake writes. Start the fakes by typing into a pane, never directly.

Start each journey from a fresh `up` unless it says it continues from another. Use the block ID as the pane's handle, since Rex keeps it across a restart. Keep quoted folder names such as `$BV_RUN/it's dir` exactly as written.

## Journeys

Each file in `features/` is the recipe for one area, with sub-feature IDs, the steps, and the gotchas. Drive every sub-feature your change can affect.

- [Install and uninstall](features/install-uninstall.md): the init.lua line, its backup, idempotence, the watcher starting with Rex, and a clean uninstall.
- [Saving chats](features/save-chats.md): when a pane's chat gets a record, `/clear`, Ctrl-Z, and exit.
- [Restore after restart](features/restore-after-restart.md): resuming Claude and Codex in restored panes, exactly once, in the right folder.
- [Status and problems](features/status.md): `momento-rex status` output, its exit code, and the problems it reports.

## Evidence

```sh
$S snap LABEL     # prints the directory it wrote
```

`snap` writes `/tmp/momento-rex-verify-evidence/<run id>/LABEL/` with `screen-<block>.txt` (each pane's screen and scrollback), `records/` (copies of `panes/*.json`), `status.txt` (`momento-rex status` output and exit code), `momento-rex.log`, `launches.txt`, `init.lua`, and `sessions.json`. `up` also saves `install.txt` there. Snap before and after each action you prove, with the journey in the label, like `restore-before`.

What counts as proof:

- **The user's path.** Type `claude` into a pane and restart the server. Don't write records by hand or call `lib/momento-rex/*.lua` functions to simulate a pass. The unsafe-record journey in `status.md` is the one exception.
- **A restore** needs three things together: the typed `claude --resume ID` (or `cd -- '...' && codex resume ID`) on the pane's screen, exactly one `resumed ID` line with the expected `cwd=` after the last restart marker in `launches`, and `fg` printing the agent.
- **A CLI behavior** needs the command, its output, and its exit code.
- **A file side effect** needs a second read of the file after the action: the record appearing or disappearing, the `init.lua` diff, the log line.

If a journey's precondition can't be met, report the command you tried and what was missing, and list that journey as not driven.

## Cleanup

```sh
$S down
```

`down` stops this run's server by its socket and recorded pid, kills watchers whose command line has this run's `state_dir=`, and deletes the run dir. The evidence survives. Quote the proving lines in your report, then delete it. Run `down` after a failed attempt too. Find runs whose pointer was lost with `ls -d /tmp/momento-rex-verify.*`, and stop each with `BV_RUN=/tmp/momento-rex-verify.XXXX $S down`.

## Adding a journey

A feature file starts with an H1 title and one paragraph describing the user-visible behavior. Four H2 sections follow in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with sandbox` (starting with `Preconditions:`), and `Gotchas`. Leave implementation details out unless a verifier needs them to read the evidence. Add the file to the list under Journeys, and add a check per sub-feature ID to `bin/journeys`.
