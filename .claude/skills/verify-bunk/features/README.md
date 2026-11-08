# bunk verification map

This directory is the maintained source for verifying bunk's user-facing behavior. Read this index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- Set `S=.claude/skills/verify-bunk/bin/sandbox` and run commands from the repo root.
- `eval "$($S up)"` has created a fresh run, and `$S doctor` exits 0.
- The run's `init.lua` holds the two user lines plus one `-- bunk:managed` line, and no chats are saved.
- Never drive a Rex server that this run did not start.

## Driving conventions

- Start each recipe from a fresh `up` unless it says it continues from another.
- Use the pane's block ID as the handle. Rex keeps block IDs across a restart.
- Wait with `$S wait SECS ...` on an observable condition, not a fixed sleep. The watcher runs a pass every second in the sandbox.
- Type agent commands into panes with `$S type`. Don't start the fakes directly.
- Commands are literal. Keep quoted folder names, including `$BV_RUN/it's dir`, unchanged.

## Proof and skip reporting

- Snap the state before and after the action being proven with `$S snap LABEL`.
- Restore proof needs the typed command on screen, one matching `resumed` line in `$S launches`, and the agent in the foreground.
- CLI proof needs the command, its output, and its exit code.
- File proof needs a second read of the file after the action, such as a record, `init.lua`, or `bunk.log`.
- Record the feature ID with every artifact label, e.g. `snap restore-claude-after`.
- If a precondition can't be met, report the attempted command and what was missing. Don't report a journey as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior, followed by four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with sandbox` (starting with `Preconditions:`), and `Gotchas`. Keep implementation details out unless a verifier needs them to read the evidence.

## Features

- [Install and uninstall](./install-uninstall.md) covers the init.lua line, its backup, idempotence, the watcher starting with Rex, and a clean uninstall.
- [Saving chats](./save-chats.md) covers when a pane's chat gets a record, `/clear`, Ctrl-Z, and exit.
- [Restore after restart](./restore-after-restart.md) covers resuming Claude and Codex in restored panes, exactly once, in the right folder.
- [Status and problems](./status.md) covers `bunk status` output, its exit code, and the problems it reports.
