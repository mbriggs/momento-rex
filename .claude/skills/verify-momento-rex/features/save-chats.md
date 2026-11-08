# Saving chats

While Rex runs, the watcher keeps one record per pane that has Claude Code or Codex in front. It writes `$MOMENTO_REX_STATE_DIR/panes/<block>.json` with the agent, chat ID, folder, and shell identity. It forgets the chat when the agent exits and keeps it when the agent is suspended.

## Sub-features

- `save-claude-first-message` saves a Claude chat only once its first message exists.
- `save-claude-clear` replaces the chat ID after `/clear`.
- `save-codex-first-message` saves a Codex chat only after its first message.
- `save-suspend` keeps the record while the agent is stopped with Ctrl-Z.
- `save-exit` deletes the record after the agent exits.
- `save-gc` deletes the record of a pane that was closed.

## How to get to it (user POV)

- Run `claude` or `codex` in any Rex pane and send a message.
- Type `/clear`, press Ctrl-Z, type `fg`, or type `/exit` in that pane.
- Close the pane's session.

## Driving it with sandbox

Preconditions:

- A fresh run from `eval "$($S up)"`, with `$S doctor` exiting 0.

- **Nothing before the first message.** Run `read -r SA BA < <($S pane a); sleep 1; $S type $SA $BA claude; sleep 3; $S record $BA; echo rc=$?`. The command prints `rc=1`.
- **Saved after it.** Run `$S type $SA $BA hello; $S wait 10 $S record $BA; $S record $BA`. The JSON has `agent` `claude`, a UUID `chat_id`, `cwd` `$BV_RUN/work`, and `state` `live`.
- **/clear.** Note the chat ID, then run `$S type $SA $BA /clear` and `$S wait 10 sh -c "$S record $BA | jq -e '.chat_id != \"$OLD\"'"`. The record holds the new ID, and it matches the `FAKE cleared <id>` line on screen.
- **Codex.** Run the same two steps with `codex` in a second pane. The record appears only after `hello`.
- **Ctrl-Z keeps it.** Run `$S key $SA $BA ctrl+z; sleep 4; $S record $BA`. The record is still there. `$S fg $SA $BA` prints `zsh`.
- **Exit forgets it.** Run `$S type $SA $BA fg; sleep 1; $S type $SA $BA /exit; $S wait 10 sh -c "! $S record $BA"`. The record file is gone.
- **Closed pane collected.** Start a chat in pane `c`, then run `$S rex kill $SC`. The record is gone within 15 seconds.
- **Proof.** Run `$S snap save-<id>` after each step.

## Gotchas

- Exit is confirmed on a second look, so a record can survive up to two passes (about 2 seconds in the sandbox, 6 by default) after `/exit`.
- Garbage collection waits `MOMENTO_REX_GC_AFTER` seconds. The sandbox sets it to 6, and the default is 30.
- The record file name is the block ID with `:` replaced by `_`.
