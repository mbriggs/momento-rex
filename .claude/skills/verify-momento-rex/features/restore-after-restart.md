# Restore after restart

When the Rex server restarts, every pane comes back as a fresh shell. For each pane that had a saved chat, momento-rex types the resume command into the new shell: `claude --resume ID`, or `codex resume ID` with `cd -- '<folder>' &&` in front when the shell starts somewhere else. The user's aliases apply, and panes without a chat get nothing.

## Sub-features

- `restore-claude` resumes a saved Claude chat in its restored pane.
- `restore-codex` resumes a saved Codex chat and changes into its folder, including a folder with a quote in its name.
- `restore-once` types each resume exactly once per restart.
- `restore-none` types nothing into a pane that had no agent.
- `restore-alias` runs the resume through the user's shell alias.
- `restore-codex-unmessaged` resumes a resumed Codex that had no message yet a second time, from its `resume ID` argument.
- `restore-watcher-only` types nothing when only the watcher restarted and the shell is the same.

## How to get to it (user POV)

- Restart the Rex server while a pane runs `claude` or `codex` with at least one message sent.
- Run `momento-rex start` (replacing the watcher) without restarting Rex. Nothing should be typed.

## Driving it with sandbox

Preconditions:

- A fresh run from `eval "$($S up)"`, with `$S doctor` exiting 0.

- **Claude chat.** Open a pane, start claude, and send a message. Run `read -r SA BA < <($S pane a); sleep 1; $S type $SA $BA claude; sleep 2; $S type $SA $BA hello; $S wait 10 $S record $BA; ID=$($S record $BA | jq -r .chat_id)`. The record has `"agent":"claude"` and `"state":"live"`.
- **Codex chat in a quoted folder.** Run `read -r SB BB < <($S pane b "$BV_RUN/it's dir"); sleep 1; $S type $SB $BB codex; sleep 2; $S type $SB $BB hello; $S wait 10 $S record $BB`. The record's `cwd` is the folder with the apostrophe.
- **Empty pane.** Run `read -r SD BD < <($S pane d)`. `$S fg $SD $BD` prints `zsh`.
- **Before.** Run `$S snap restore-before`.
- **Restart.** Run `$S restart`, then `$S wait 15 sh -c "$S launches | grep -q 'claude resumed $ID'"`, then `sleep 4` so that any duplicate typing would also show up.
- **Claude resumed.** `$S launches` has exactly one line after the `--- restart` marker matching `claude resumed $ID cwd=$BV_RUN/work alias=1`. `$S fg $SA $BA` prints `claude`. The screen in `$S snap restore-after` shows `claude --resume $ID` typed at the prompt.
- **Codex resumed.** One line `codex resumed <ID_B> cwd=$BV_RUN/it's dir`. The screen shows `cd -- '...it'\''s dir' && codex resume <ID_B>` or `codex resume <ID_B>` if the restored shell is already in that folder.
- **No agent, nothing typed.** `$S fg $SD $BD` is still `zsh`, and its screen shows only a prompt.
- **Codex before its first message.** Without typing into the resumed codex, run `$S restart` again. `$S launches` shows a second `codex resumed <ID_B>` after the new marker.
- **Watcher-only restart.** From the primary checkout only (a lane refuses `momento-rex start` with exit 3), run `$S momento-rex start`, wait 5 seconds, and check `$S launches`. No new lines appear.

Proved once on 2026-11-08 (the `restore-claude` steps). The evidence went to `/tmp/momento-rex-verify-evidence/<run>/before-restart` and `after-restart`, and it showed `claude --resume 2bcac816-...` typed on screen and one `claude resumed` line.

## Gotchas

- The agents are fakes from `test/fake-agent.sh`. A pass here proves momento-rex's logic against the file formats the fakes write, not that the installed Claude Code or Codex still write them. To check real agents, compare `~/.claude/sessions/<pid>.json` and a live Codex's open `rollout-*.jsonl` (via `lsof -p`) against the fakes by hand. Don't restart the user's Rex to do it.
- `restart` never clears `launches`. Count lines after the last `--- restart` marker.
- The watcher has 15 seconds (`RESUME_GRACE`) to see the resumed agent come up. Wait for the `resumed` line rather than sleeping a fixed time.
- A chat with no message has no transcript, so momento-rex never saves it. If the record is missing, check that the pane got its `hello`.
