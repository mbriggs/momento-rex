---
name: worktree
description: Work in a bunk worktree lane. Use before the first file write in the primary checkout, when the user asks for a parallel session, and when the working directory is under .claude/worktrees/.
---

# Worktree lanes in bunk

A **lane** is a linked git worktree that `bin/worktree` provisions. Write code in a lane, not in the primary checkout. The primary stays on `main`, and the user's real Rex runs bunk from there.

bunk has no ports, databases, or build outputs to isolate. `make test` makes its own temp dir and private Rex server each run, so any number of lanes can run it at once. A lane's only job is to keep its work off `main` and off the user's real Rex.

## Creating a lane

- In this session, call `EnterWorktree`.
- For a subagent, pass `isolation: "worktree"`.
- From a terminal, run `claude --worktree NAME`.
- Anything else: `git worktree add .claude/worktrees/NAME -b NAME`, then `bin/worktree setup` inside it.

The first Bash command in a new lane provisions it and prints `bin/worktree info`. If provisioning fails, that one command is blocked and `tmp/worktree-setup.failed` holds the log. Read it, fix the cause, and run `bin/worktree setup` again.

## Commands in a lane

- `make test`, `make unit`, `make worktree`, `make e2e`, and the verify-bunk sandbox run the lane's own code against throwaway servers. Run them freely.
- `bin/bunk status` reads the user's real `~/.local/state/bunk`. Running it is harmless.
- `bin/bunk start`, `bin/bunk install` without `--no-start`, and `install` or `uninstall` against the real `~/.config/rex/init.lua` or `~/.local/state/bunk` exit 3 in a lane. They would point the user's real Rex at a lane that teardown deletes, or start a second watcher that types every resume twice. Ask the user to run them from the primary. With `REX_CONFIG` and `BUNK_STATE_DIR` pointed at a temp dir, `install --no-start` and `uninstall` run, as the e2e test does.

The env hook picks the checkout from the directory a command starts in, so `cd <lane> && cmd` run from the primary gets the primary's env. Start lane commands with the lane as the working directory.

## Commands that run in the primary

A session isolated to a worktree can't run git against the primary. Call `ExitWorktree` with `keep`, run the command from the primary, then re-enter with `EnterWorktree` and the lane's path.

## Landing

Lanes land through GitHub PRs into `main`, one commit per lane, which the user squash-merges.

1. If the diff touches `bin/bunk` or `lib/bunk/`, `make test` alone doesn't prove it. Run [verify-bunk](../verify-bunk/SKILL.md) on every journey in its `features/` map that the change can affect, and put each journey's result and evidence path in the commit body. A lane refuses `bunk start`, so for `restore-watcher-only` ask the user to drive it from the primary, or list it in the body as not driven.
2. Commit in the lane, rebased on `origin/main`.
3. Run `bin/worktree land` from the lane. It pushes and opens the PR, or updates the open PR's title and body from the commit. With several commits it refuses; write the message to a file and run `bin/worktree land --message FILE` to squash them.
4. Own the PR until it merges: watch CI, answer review comments, and re-land fixes with `--message`.
5. After the merge, run `bin/worktree sync` from the primary to fast-forward `main`.

To keep working in the lane after a squash merge, run `git rebase --onto origin/main <merged PR head>`. A plain rebase replays the commits that were squashed.

## Cleanup

Ask the user before you remove a lane. Call `ExitWorktree` with `keep`, never `remove`, because `remove` refuses any worktree with commits since it was created, landed or not. Then run `bin/worktree teardown NAME` from the primary (a path works for worktrees outside `.claude/worktrees/`). It syncs `main`, refuses uncommitted or untracked files and a HEAD that is neither on `main` nor a merged PR's head, and removes the worktree, its branch, and its lane. `--discard` skips those checks once the user says the work can go. Teardown run from inside the lane leaves the directory behind, and the next command provisions it again.
