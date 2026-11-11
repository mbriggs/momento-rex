---
name: worktree
description: Work in a momento-rex worktree lane. Use before the first file write in the primary checkout, when the user asks for a parallel session, and when the working directory is under .claude/worktrees/.
---

# Worktree lanes in momento-rex

A **lane** is a linked git worktree that `bin/worktree` provisions. Write code in a lane, not in the primary checkout. The primary stays on `main`, and the user's real Rex runs momento-rex from there.

`bin/worktree` is the shared script from the create-worktree-lanes skill; don't edit it here. What momento-rex adds lives in `bin/worktree.lane`. A lane isolates nothing beyond its checkout: momento-rex has no ports or databases, and `make test` makes its own temp dir and Rex server. What a lane must not do is reach the user's real Rex.

## Creating a lane

- In this session, call `EnterWorktree`.
- For a subagent, pass `isolation: "worktree"`.
- From a terminal, run `claude --worktree NAME`.
- Anything else: `git worktree add .claude/worktrees/NAME -b NAME`, then `bin/worktree setup` inside it.

The first Bash command in a new lane provisions it and prints `bin/worktree info`. If provisioning fails, that one command is blocked and `tmp/worktree-setup.failed` holds the log. Read it, fix the cause, and run `bin/worktree setup` again.

## Commands in a lane

- `make test`, `make unit`, `make worktree`, `make e2e`, and the verify-momento-rex sandbox run the lane's own code against throwaway servers. Run them freely. There is no dev stack to start, so teardown has nothing to stop.
- `bin/momento-rex status` reads the user's real `~/.local/state/momento-rex`. Running it is harmless.
- `bin/momento-rex start`, `bin/momento-rex install` without `--no-start`, and `install` or `uninstall` against the real `~/.config/rex/init.lua` or `~/.local/state/momento-rex` exit 3 in a lane. They would point the user's real Rex at a lane that teardown deletes, or start a second watcher that types every resume twice. Ask the user to run them from the primary. With `REX_CONFIG` and `MOMENTO_REX_STATE_DIR` pointed at a temp dir, `install --no-start` and `uninstall` run, as the e2e test does.
- `bin/worktree info` shows the lane, its branch, and what it refuses.

The env hook picks the checkout from the directory a command starts in, so `cd <lane> && cmd` run from the primary gets the primary's env. Run lane commands with the lane as the working directory.

## Commands that run in the primary

`bin/worktree sync` and `bin/worktree teardown NAME` run in the primary. A session isolated to a worktree can't run git against the primary. In a session that entered the lane with `EnterWorktree`, call `ExitWorktree` with `keep`, run the command from the primary, then re-enter with `EnterWorktree` and the lane's path. A subagent returns the command to its parent to run. A session started with `claude --worktree` asks the user to run it from the primary.

## Landing

Lanes land through GitHub PRs into `main`, one commit per lane, which the user squash-merges. "Land it" means open or update the PR. It never asks for a merge, and `bin/worktree merge` is off in this repo.

1. Run `git fetch origin main && git rebase origin/main` in the lane, so you verify the code that lands. `land` refuses a lane that is behind, and says when `origin/main` changed the lane tooling. If it says that, or the rebase brought in changes to `bin/worktree`, `bin/worktree.lane`, `.claude/hooks/`, or this skill, reread this skill before going on.
2. The landing check. Commit everything, then run `.claude/skills/verify-momento-rex/bin/sandbox all` in the lane. It drives every verify-momento-rex journey on the committed tree and, when all pass, writes the stamp that `land` looks for. `land` refuses any change beyond Markdown without a stamp for the tree it pushes, so run `all` again after every commit, including after a rebase. Don't pass `--no-verify` unless the user says to. When a journey fails for a cause outside your change, tell the user and stop. If the diff touches what verify-restore-model covers, run its check too and put the result in the message.
3. Write the commit message and the PR description to files outside the checkout, such as `/tmp/NAME-msg` and `/tmp/NAME-body`. Write the description with the prose skill, for the reviewer as the reader, and use the show-me skill for the views that make the change clear.
4. Run `bin/worktree land --message MSG --body BODY` from the lane. It squashes the lane to one commit with that message, pushes it, and opens the PR or updates the open PR's title and description.
5. Own the PR until it merges. Watch CI in the background (`gh pr checks BRANCH --watch`). Fix failures and review comments in the lane, commit, and land again from step 1.
6. After the user merges, run `bin/worktree sync` from the primary. It fast-forwards `main`, then runs `bin/momento-rex start`, because the user's real Rex runs the watcher from the primary's files and a running watcher keeps the code it started with. The new watcher takes over at the old one's next pass. If Rex isn't running, `start` says so, and Rex starts the watcher when it comes up. If sync prints `NOT INSTALLED`, tell the user verbatim and ask them to run the command it names from the primary.

To keep working in the lane after a squash merge, run `git rebase --onto origin/main <merged PR head>`. A plain rebase replays the commits that were squashed.

## Cleanup

Ask the user before you remove a lane. In a session that entered the lane with `EnterWorktree`, call `ExitWorktree` with `keep`, never `remove`, because `remove` refuses any worktree with commits since it was created, landed or not. Then run `bin/worktree teardown NAME` from the primary (a path works for worktrees outside `.claude/worktrees/`). It refuses uncommitted or untracked files and a HEAD that is neither on `main` nor a merged PR's head, and removes the worktree, its branch, and its lane. `--discard` skips those checks once the user says the work can go.

Teardown never syncs. When it says `main` is behind `origin/main`, run `bin/worktree sync`. Teardown run from inside the lane leaves the directory behind, and the next command provisions it again.
