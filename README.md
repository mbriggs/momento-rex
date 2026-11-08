# momento-rex

When the [Rex](https://www.superlogical.com/updates/public-testing-beginning)
server restarts, Rex brings back your sessions, panes, folders,
and scrollback, but each pane starts a new shell. If a pane was running a
Claude Code or Codex chat, that chat is gone. momento-rex gets it back. It
saves the chat ID of each agent running in a pane, and after the restart it
types the resume command into the new shell:

```text
~/src/app % cd -- '/Users/you/src/app/api' && claude --resume 561bd957-38e5-4e23-bef1-72c0f0ec1000
```

The command goes in as typed input, so your aliases apply and it lands in
your shell history.

Rex is in public testing and changes quickly, so momento-rex will likely go
away once Rex does this itself, or enables a more elegant way to do it.

## Requirements

- Rex, with `rex` on your `PATH`.
- macOS. Linux is untested, but testing on Linux is coming soon.
- zsh, bash, or fish 3 or later in your panes.
- Claude Code, Codex, or both.

## Install

Clone the repo somewhere it can stay, then run install from the clone:

```sh
git clone https://github.com/mbriggs/momento-rex.git ~/.local/share/momento-rex
~/.local/share/momento-rex/bin/momento-rex install
```

Install adds one line to `~/.config/rex/init.lua`, and that line starts a
watcher each time the Rex server starts. Unless you pass `--no-start`, install
also starts a watcher right away if Rex is running. The line points at the clone, so if you move or
delete the clone, run install again from its new location.

To check that it works, run `momento-rex status`:

```text
watcher   running, v0.1.0, last pass 0s ago
init.lua  set up (~/.config/rex/init.lua)
chats
  55e33ae2  claude  148c02b7  live  ~/src/momento-rex
```

Each chat line shows the end of the pane ID, the agent, the start of the chat
ID, the record's state, and the folder. When something is wrong, status lists
it under `problems` with the command that fixes it, and exits 1.

To update, run `git pull` in the clone, then `momento-rex start` so the
watcher runs the new code.

## Commands

- `momento-rex install` adds the init.lua line and starts the watcher. With
  `--no-start`, it adds the line only.
- `momento-rex start` starts a new watcher now, which replaces the running
  one.
- `momento-rex status` shows the watcher, the saved chats, and any problems.
- `momento-rex uninstall` removes the line and stops the watcher. Your saved
  chats stay on disk.
- `momento-rex version` prints the version.

## What it changes

- One line in init.lua, tagged `-- momento-rex:managed`. Before it changes
  the file, install runs `rex config check` on the new version and backs up
  the old one to `init.lua.momento-rex-backup`. Uninstall removes only the
  tagged line.
- `~/.local/state/momento-rex/`, or `$MOMENTO_REX_STATE_DIR`. It holds one
  record per pane, `status.json`, and `momento-rex.log`.

momento-rex changes nothing in Claude's or Codex's config and nothing in your
shell rc files, and it adds no launchd job.

## Limits

Claude Code chats have been through real Rex restarts. Codex chats have
been through restarts only in this repo's automated test, with a fake
`codex`. Testing Codex through real restarts is coming soon.

A few things you do can come back wrong:

- If you switch chats in the last few seconds before Rex stops, the pane
  may come back with the previous chat.
- If you quit a chat in the last two seconds before Rex stops, it may come
  back after the restart. Quit it again.
- momento-rex checks that the shell is at its prompt just before it types.
  If you start a command in the moment between the check and the typing,
  the resume line goes to your command.
- If Rex stops before a new chat's first message, the chat doesn't come
  back, because neither agent can resume a chat that has no messages.

Some setups momento-rex can't see or can't type into:

- A pane with a different `CLAUDE_CONFIG_DIR` from the Rex server.
- A shell with no line editor, such as `sh` or `bash --noediting`.
  momento-rex waits for the line editor before it types, so the resume never
  goes in, and status shows `resume.waiting`. A shell that has a line editor
  but a slow rc file gets the resume late, not never.
- A resume command that takes more than about 17 seconds to start the agent.
  momento-rex deletes the chat's record, and saves the chat again once it
  sees the agent running.
- Other machines. Each Rex host runs its own watcher, so install momento-rex
  on each host.

momento-rex reads files that Claude and Codex don't document. If Claude's
sessions file or Codex's rollout file changes name or shape, status reports
`claude.sessions` or `codex.rollout`. If Claude moves its transcripts,
momento-rex stops saving new Claude chats, and status shows nothing wrong.

## How it works

The init.lua line runs `lib/momento-rex/watch.lua` under `rex do`. The
watcher stops when the server stops. If a config reload starts a second
watcher, the new one waits for the old one to exit and then takes over.

Every 3 seconds, the watcher looks at every pane. When an agent is in front,
it saves the agent, the chat ID, the folder, and the identity of the pane's
shell (its pid and start time). When the agent exits, it deletes the record,
after a second pass confirms the exit. A suspended agent (Ctrl-Z) keeps its
record.

After a restart, each pane has a new shell. When a pane's shell is not the
shell saved in its record, the watcher types the resume command. If
only the watcher restarted, the shells are the same and it types nothing.

The watcher builds the command when it types it, from a chat ID that must be
a UUID and a quoted folder. It refuses a record that holds anything else and
reports it in status.

The chat IDs come from files the agents keep while they run:

- Claude Code writes `~/.claude/sessions/<pid>.json`, or the same path under
  `$CLAUDE_CONFIG_DIR`. Claude deletes the file when it exits, even when Rex
  kills it, so momento-rex copies the ID while Claude runs. A `/clear` or
  `/resume` shows up within one pass. momento-rex saves a new chat once its
  transcript, `projects/<folder>/<id>.jsonl`, exists.
- Codex holds its `sessions/.../rollout-<time>-<id>.jsonl` file open, and
  momento-rex finds it with `lsof`. A resumed Codex chat that has no new
  message yet has no file open, so momento-rex reads `resume <id>` from the
  process's arguments.

## Development

```sh
make test     # lint, unit tests (luajit), and the end-to-end test
make lint     # shellcheck and luacheck
```

`mise.toml` pins shellcheck. luacheck 1.2 fails to load under Lua 5.5, so
install it for LuaJIT:

```sh
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" install --local luacheck
```

`make lint` finds luacheck on your `PATH` or in `~/.luarocks/bin`.

The end-to-end test starts a throwaway Rex server on a socket in a temp
directory, with fake `claude` and `codex` programs that write the files
described above, and then restarts that server. It never talks to your Rex.

`verify/restore/check` model-checks the save-and-resume protocol with TLA+,
and needs java and luajit.
`.claude/skills/verify-restore-model/SKILL.md` explains what it covers and
how to read its output.
