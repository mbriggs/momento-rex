# bunk

Rex restores your sessions, panes, folders and scrollback when its server
restarts, but every pane comes back as a fresh shell. bunk brings back the
Claude Code or Codex chat that was running in each pane.

```sh
bin/bunk install     # adds one line to ~/.config/rex/init.lua and starts the watcher
bin/bunk status      # watcher health, saved chats, problems (exits 1 if something's wrong)
bin/bunk uninstall   # removes the line and stops the watcher; saved chats stay
```

## How it works

Rex starts the watcher from init.lua and stops it when the server stops:

```
init.lua ──► rex do lib/bunk/watch.lua --all      (one per server; newest wins on reload)
               every 3s and on each foreground change, for every pane:
                 agent in front  → save {agent, chat id, folder, shell identity}
                 agent exited    → forget the chat (confirmed on a second look)
                 agent suspended → keep it (Ctrl-Z)
                 new shell + saved chat → type `claude --resume ID` / `codex resume ID`
```

A pane counts as restored when its shell is a different process from the one
saved with the chat (pid plus start time). If only the watcher restarted, the
shell is the same and nothing is typed.

Chat IDs come from files the agents keep while they run:

- **Claude Code**: `~/.claude/sessions/<pid>.json` (`$CLAUDE_CONFIG_DIR`).
  Claude deletes it on exit, even when Rex kills it, so bunk copies the ID
  while Claude runs. `/clear` and `/resume` show up within one pass. A new
  chat is saved once its transcript (`projects/<folder>/<id>.jsonl`) exists,
  which is after the first message, because Claude can't resume a chat
  without one.
- **Codex**: the `sessions/.../rollout-<time>-<id>.jsonl` file Codex holds
  open (`lsof`), or `resume <id>` in its arguments for a resumed chat that
  hasn't had a message yet. A new Codex chat has nothing to save until its
  first message.

The resume command is typed into the restored shell, so your aliases apply
and it lands in your history. It's built when it's typed, from a UUID-checked
chat ID and a quoted folder. A record with anything else in it is refused and
reported.

## What it touches

- One line in init.lua, tagged `-- bunk:managed`. Install backs the file up to
  `init.lua.bunk-backup` and runs `rex config check` on the new version first.
  Uninstall removes only tagged lines.
- `~/.local/state/bunk/` (`$BUNK_STATE_DIR`): one record per pane, the
  watcher's token, `status.json`, and `bunk.log`.

Nothing in Claude's or Codex's config, no shell rc changes, no launchd.

## Limits

- bunk relies on files the agents don't document. If Claude's sessions file
  or Codex's rollout name changes, `bunk status` names the problem
  (`claude.sessions`, `codex.rollout`) rather than failing silently. If
  Claude moves its transcripts, chats stop being saved and nothing reports it.
- A chat you switch within the last few seconds before Rex stops may come
  back as the previous chat. A chat you quit in the last two seconds may come
  back; quit it again.
- A pane with a different `CLAUDE_CONFIG_DIR` from the Rex server isn't seen.
- Each Rex host runs its own watcher; install bunk on each host.
- Typed commands use POSIX `cd -- '...' &&` syntax: zsh, bash, and fish 3+.

## Tests

```sh
make test     # unit (luajit) + end-to-end
```

The end-to-end test starts a throwaway Rex server on a socket in a temp
directory, with fake `claude` and `codex` programs that imitate the files
above, and restarts that server. It never talks to your Rex. Real agents
haven't been through a restart yet; try one before relying on it.
