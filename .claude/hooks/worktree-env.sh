#!/bin/sh
# SessionStart and CwdChanged: make every Bash command load the lane values of
# the checkout it runs in. Claude Code captures the shell environment once per
# session, and EnterWorktree and ExitWorktree don't fire CwdChanged, so this
# writes one line that resolves the checkout per command instead of baking in a
# lane. Subagent shells source the same file.
#
# Only a linked worktree of this project ($CLAUDE_PROJECT_DIR's repo) counts.
# The line never sources worktree.env, so a checkout elsewhere, or a branch
# that commits its own worktree.env, can't run code here. It reads the lane
# number and takes the primary's path from this project.
#
# The captured PATH can also hold paths inside the primary, like its bin/ or
# node_modules/.bin (from mise, direnv, or a shell rc), which would run the
# primary's scripts from inside a worktree. The line rewrites each such entry
# to the same path inside the worktree.

cat >/dev/null
[ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] || exit 0
grep -q 'worktree-lane-env' "$CLAUDE_ENV_FILE" 2>/dev/null && exit 0
common=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
primary=$(cd "$common/.." && pwd -P) || exit 0
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
  printf 'wl_common=%s wl_primary=%s; ' "$(shq "$common")" "$(shq "$primary")"
  cat <<'LINE'
wl_top=$(git rev-parse --show-toplevel 2>/dev/null); if [ -n "$wl_top" ] && [ -f "$wl_top/.git" ] && [ -f "$wl_top/worktree.env" ] && git --git-dir="$wl_common" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wl_top"; then WORKTREE_LANE=$(sed -n 's/^WORKTREE_LANE=\([0-9][0-9]*\)$/\1/p' "$wl_top/worktree.env"); WORKTREE_PRIMARY=$wl_primary; export WORKTREE_LANE WORKTREE_PRIMARY; PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v from="$wl_primary" -v to="$wl_top" '{ inlane = $0 == to || index($0, to "/") == 1; inprimary = $0 == from || index($0, from "/") == 1; print (inprimary && !inlane ? to substr($0, length(from) + 1) : $0) }' | sed 's/:$//'); export PATH; fi; unset wl_top wl_primary wl_common # worktree-lane-env
LINE
} >>"$CLAUDE_ENV_FILE"
exit 0
