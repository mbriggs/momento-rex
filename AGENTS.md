# momento-rex

Write code only in a linked worktree (a lane), never in the primary checkout.

Project skills live in `.claude/skills/`, and `.agents/skills/` links there for Codex:

- `worktree`: before the first file write, and to land or remove a lane.
- `verify-momento-rex`: the diff touches `bin/momento-rex` or `lib/momento-rex/`, or you're reproducing a save, restore, install, or status bug.
- `verify-restore-model`: the diff touches `core.decide`, or `step`, `observe`, `guard`, or the token in `lib/momento-rex/watch.lua`.
