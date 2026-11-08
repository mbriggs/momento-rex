#!/bin/sh
# PreToolUse(Bash): provision a linked worktree's lane before its first command.
# The primary checkout and provisioned worktrees cost one git call and exit 0.
# A failure blocks this one command, then leaves a marker so later commands run
# and the agent can fix the cause instead of re-running a slow setup each time.
# JSON goes through the system perl's JSON::PP, which bin/worktree's lock
# already needs; python3 here comes from mise and may not be on the hook's PATH.

input=$(cat)
cwd=$(printf '%s' "$input" | /usr/bin/perl -MJSON::PP -0777 -ne 'my $j = eval { decode_json($_) } || {}; print $j->{cwd} // ""' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$top/.git" ] || exit 0                 # only linked worktrees have a .git file
[ -x "$top/bin/worktree" ] || exit 0         # a branch from before the lane tooling
[ -f "$top/worktree.env" ] && exit 0         # already provisioned
[ -f "$top/tmp/worktree-setup.failed" ] && exit 0

mkdir -p "$top/tmp"
log="$top/tmp/worktree-setup.log"
if (cd "$top" && bin/worktree setup) >"$log" 2>&1; then
  (cd "$top" && bin/worktree info) | /usr/bin/perl -MJSON::PP -0777 -ne '
print JSON::PP->new->canonical->encode({hookSpecificOutput => {hookEventName => "PreToolUse", additionalContext =>
  "Provisioned this git worktree as its own lane. Use these, not the primary checkout:\n"
  . $_
  . "When the work here is done, ask the user whether to remove the worktree."}}), "\n"'
  exit 0
fi

cp "$log" "$top/tmp/worktree-setup.failed"
{
  echo "bin/worktree setup failed in $top. Read tmp/worktree-setup.failed, fix the cause, then run bin/worktree setup."
  tail -n 20 "$log"
} >&2
exit 2
