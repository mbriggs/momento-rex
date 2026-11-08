# Install and uninstall

`bunk install` adds one line tagged `-- bunk:managed` to the user's Rex `init.lua`. It backs the file up first and checks the new version with `rex config check`, and from then on Rex starts the watcher. `bunk uninstall` removes only tagged lines and stops the watcher. Saved chats stay.

## Sub-features

- `install-line` adds exactly one tagged line and keeps the user's content above it.
- `install-backup` writes `init.lua.bunk-backup` before changing the file.
- `install-idempotent` leaves the file unchanged on a second install and says so.
- `install-check` refuses to write an init.lua that fails `rex config check`, leaving the file unchanged.
- `install-watcher` gets one watcher started by Rex from init.lua, and still one after `rex config reload`.
- `uninstall-clean` restores init.lua byte for byte and stops the watcher within a few seconds.

## How to get to it (user POV)

- `bin/bunk install` (or `install --no-start`), `bin/bunk uninstall`.
- Starting or reloading Rex with the line in place.

## Driving it with sandbox

Preconditions:

- A fresh run from `eval "$($S up)"`. `up` already ran `install --no-start`, and its output is in the evidence dir as `install.txt`.

- **One line, user content kept.** Run `grep -c 'bunk:managed' "$BV_RUN/init.lua"; head -2 "$BV_RUN/init.lua" | cmp - "$BV_RUN/init.orig" && echo kept`. The output is `1` and `kept`.
- **Second install.** Run `$S bunk install --no-start; echo rc=$?`. It prints `init.lua is already set up: ...` and `rc=0`, and the grep count stays 1.
- **Watcher started by Rex.** Run `$S doctor`. It reports `watcher 1 process for this run`.
- **Reload keeps one.** Run `$S rex config reload; sleep 2; $S doctor`. It still reports 1 process.
- **Rejected config.** Run `printf 'this is not lua(\n' >> "$BV_RUN/init.lua"; cp "$BV_RUN/init.lua" "$BV_RUN/broken"; sed -i '' '/bunk:managed/d' "$BV_RUN/init.lua"; $S bunk install --no-start; echo rc=$?`. The output names `rex config check` with `rc=1`, and `cmp "$BV_RUN/init.lua" <(grep -v bunk:managed "$BV_RUN/broken")` shows the file unchanged. Use a fresh run afterwards.
- **Uninstall.** Run `$S bunk uninstall; cmp "$BV_RUN/init.lua" "$BV_RUN/init.orig" && echo restored; $S wait 10 sh -c '[ "$(pgrep -f "state_dir=$BV_RUN/state" | wc -l)" -eq 0 ]' && echo stopped`. The output is `restored` and `stopped`, and `$S bunk status; echo rc=$?` reports `NOT set up` with `rc=1`.
- **Proof.** Run `$S snap install-<id>` after each step. It copies `init.lua`.

## Gotchas

- `sandbox up` installs with `--no-start` because the watcher comes from the server's init.lua. Running `$S bunk install` without `--no-start` also starts a watcher, and doctor will then report 2 until the older one notices the new token.
- Uninstall stops the watcher by writing `uninstalled` to `watcher.token`. The watcher exits on its next pass, not immediately.
- The sandbox's tagged line names `$BV_RUN/rexshim/rex` as its rex fallback path, not the real `rex`, because `$S bunk` sets `REX_BIN_DIR` to the shim. A real install writes `command -v rex`.
- The backup is overwritten on every change, so it holds only the previous version.
