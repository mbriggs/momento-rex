#!/bin/bash
# Variables read only inside check's single-quoted strings look unused.
# shellcheck disable=SC2034
# Tests what momento-rex adds to the shared bin/worktree: its lane file
# (bin/worktree.lane), bin/momento-rex's lane guard, and the repo's Claude
# hooks, and that land and the verify all run refuse an unstamped or dirty
# tree, in a temporary repo. bin/worktree itself is the create-worktree-lanes
# skill's script, and that skill's tests cover allocation, locking, the sweep,
# land, sync, merge, and teardown. Lanes are narrowed to 90-95 so live lanes in
# the real repo are never touched, and git gets its identity from the
# environment because CI runners have none.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d /tmp/momento-rex-worktree.XXXX)" && pwd -P)"
trap 'if [ -z "${KEEP:-}" ]; then rm -rf "$T"; else echo "kept $T"; fi' EXIT

export WORKTREE_LANE_RANGE=90-95
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export HOME="$T/home"   # bin/momento-rex's real init.lua and state dir, for the guard tests
unset XDG_CONFIG_HOME XDG_STATE_HOME REX_CONFIG MOMENTO_REX_STATE_DIR WORKTREE_LANE WORKTREE_PRIMARY WORKTREE_KEYS
mkdir -p "$HOME"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() { : > "$T/out"; if eval "$2"; then ok "$1"; else bad "$1" "${3:-$(cat "$T/out")}"; fi; }
# rc CMD...: run CMD, keep its output in $T/out, print its exit code.
rc() { "$@" > "$T/out" 2>&1; echo $?; }

# The repo: the lane tooling, bin/momento-rex, lib/momento-rex, .gitignore.
P="$T/repo"
git init -q -b main "$P"
mkdir -p "$P/bin" "$P/lib"
cp "$ROOT/bin/worktree" "$ROOT/bin/worktree.lane" "$ROOT/bin/momento-rex" "$P/bin/"
cp -R "$ROOT/lib/momento-rex" "$P/lib/"
cp "$ROOT/.gitignore" "$P/"
git -C "$P" add -A && git -C "$P" commit -q -m init
W="$P/bin/worktree"
lane() { git -C "$P" worktree add -q -b "$1" "$P/.claude/worktrees/$1" "${2:-main}"; }
L() { printf '%s/.claude/worktrees/%s' "$P" "$1"; }
lane_of() { sed -n 's/^WORKTREE_LANE=//p' "$1/worktree.env" 2>/dev/null; }

echo "lane file"
check "info in the primary says where the real Rex runs" '[ "$(rc "$W" info)" = 0 ] && grep -q "(primary" "$T/out" && grep -q "^real Rex" "$T/out"'
lane a
check "setup provisions a lane in the narrowed range" '(cd "$(L a)" && bin/worktree setup >/dev/null) && [ "$(lane_of "$(L a)")" = 90 ] && [ "$(cat "$P/tmp/worktrees/90")" = "$(L a)" ]'
check "the lane sets nothing beyond the lane index" '[ -z "$(grep -v -e "^#" -e "^WORKTREE_" "$(L a)/worktree.env")" ]'
check "info in a lane names the lane, its branch, and what it refuses" '[ "$(cd "$(L a)" && rc bin/worktree info)" = 0 ] && grep -q "(lane 90)" "$T/out" && grep -q "^branch    a$" "$T/out" && grep -q "bin/momento-rex start" "$T/out"'
check "setup again reuses the lane" '(cd "$(L a)" && bin/worktree setup >/dev/null) && [ "$(lane_of "$(L a)")" = 90 ]'
check "merge is off: the user merges PRs" '[ "$(rc "$W" merge a)" = 1 ] && grep -q "the user merges" "$T/out"'
lane c
(cd "$(L c)" && bin/worktree setup >/dev/null)
lc="$(lane_of "$(L c)")"
rm -rf "$(L c)"
check "teardown --stale drops a lane whose directory is gone" '"$W" teardown --stale >/dev/null && [ ! -e "$P/tmp/worktrees/$lc" ] && [ -f "$P/tmp/worktrees/90" ]'

echo "bin/momento-rex in a lane"
check "start refuses" '[ "$(cd "$(L a)" && rc bin/momento-rex start)" = 3 ] && grep -q "refuses to run in a lane" "$T/out"'
check "install without --no-start refuses, even with a temp config" '[ "$(cd "$(L a)" && REX_CONFIG="$T/x/init.lua" MOMENTO_REX_STATE_DIR="$T/x/state" rc bin/momento-rex install)" = 3 ]'
check "install --no-start against the real init.lua refuses and writes nothing" '[ "$(cd "$(L a)" && rc bin/momento-rex install --no-start)" = 3 ] && [ ! -e "$HOME/.config/rex" ]'
check "uninstall against the real init.lua refuses" '[ "$(cd "$(L a)" && rc bin/momento-rex uninstall)" = 3 ]'
check "uninstall against the real state dir refuses" '[ "$(cd "$(L a)" && REX_CONFIG="$T/x/init.lua" rc bin/momento-rex uninstall)" = 3 ]'
check "uninstall against a temp config and state runs (as e2e does)" '[ "$(cd "$(L a)" && REX_CONFIG="$T/x/init.lua" MOMENTO_REX_STATE_DIR="$T/x/state" rc bin/momento-rex uninstall)" = 0 ]'
check "a symlinked path to the real init.lua still refuses" 'mkdir -p "$HOME/.config/rex" && ln -s "$HOME/.config/rex" "$T/rexlink" && [ "$(cd "$(L a)" && REX_CONFIG="$T/rexlink/init.lua" MOMENTO_REX_STATE_DIR="$T/x/state" rc bin/momento-rex uninstall)" = 3 ]'
check "a lane's bin/momento-rex run from the primary's directory still refuses" '[ "$(cd "$P" && rc "$(L a)/bin/momento-rex" start)" = 3 ]'
check "the primary's uninstall runs" '[ "$(cd "$P" && rc bin/momento-rex uninstall)" = 0 ]'

echo "hook"
HOOK="$ROOT/.claude/hooks/worktree-bash.sh"
hook() { printf '{"cwd":"%s","tool_name":"Bash"}' "$1" | CLAUDE_PROJECT_DIR="$P" "$HOOK"; }
lane g
check "the hook does nothing in the primary" '[ "$(rc hook "$P")" = 0 ] && [ ! -s "$T/out" ]'
check "the hook provisions a new lane and reports its info" '[ "$(rc hook "$(L g)")" = 0 ] && [ -f "$(L g)/worktree.env" ] && grep -q additionalContext "$T/out" && grep -q "Provisioned" "$T/out" && grep -q "bin/momento-rex start" "$T/out"'
lane h
chmod 555 "$P/tmp/worktrees"
check "a failed setup blocks one command and leaves the marker" '[ "$(rc hook "$(L h)")" = 2 ] && [ -f "$(L h)/tmp/worktree-setup.failed" ] && [ ! -f "$(L h)/worktree.env" ]'
check "the next command runs" '[ "$(rc hook "$(L h)")" = 0 ]'
chmod 755 "$P/tmp/worktrees"
check "a fixed setup clears the marker" '(cd "$(L h)" && bin/worktree setup >/dev/null) && [ ! -e "$(L h)/tmp/worktree-setup.failed" ]'

# Another repo's linked worktree that ships a bin/worktree: the hook must not run it.
X="$T/foreign"
git init -q -b main "$X" && mkdir -p "$X/bin"
printf '#!/bin/sh\ntouch %s/foreign-ran\n' "$T" > "$X/bin/worktree" && chmod +x "$X/bin/worktree"
git -C "$X" add -A && git -C "$X" commit -q -m init && git -C "$X" worktree add -q -b fw "$T/foreign-wt"
check "the hook ignores another repo's worktree" '[ "$(rc hook "$T/foreign-wt")" = 0 ] && [ ! -e "$T/foreign-ran" ]'

echo "env hook"
ENVHOOK="$ROOT/.claude/hooks/worktree-env.sh"
EF="$T/claude-env"
: > "$EF"; echo '{}' | CLAUDE_ENV_FILE="$EF" CLAUDE_PROJECT_DIR="$P" "$ENVHOOK"
envrun() { (cd "$1" && env -i HOME="$HOME" PATH="$PATH" sh -c '. "$1"; printf "%s|%s" "${WORKTREE_LANE:-}" "${WORKTREE_PRIMARY:-}"' sh "$EF"); }
check "the env line loads a lane's values" '[ "$(envrun "$(L g)")" = "$(lane_of "$(L g)")|$P" ]'
check "the env line loads nothing in the primary" '[ "$(envrun "$P")" = "|" ]'
printf 'WORKTREE_LANE=91\ntouch %s/env-ran\n' "$T" > "$T/foreign-wt/worktree.env"
check "the env line ignores another repo's worktree" '[ "$(envrun "$T/foreign-wt")" = "|" ] && [ ! -e "$T/env-ran" ]'
printf 'WORKTREE_LANE=91\ntouch %s/env-ran\n' "$T" > "$(L h)/worktree.env"
check "the env line reads worktree.env without running it" '[ "$(envrun "$(L h)")" = "91|" ] && [ ! -e "$T/env-ran" ]'

echo "landing check"
git init -q --bare "$T/origin.git"
git -C "$P" remote add origin "$T/origin.git"
mkdir -p "$P/.claude/skills/verify-momento-rex"
cp -R "$ROOT/.claude/skills/verify-momento-rex/bin" "$P/.claude/skills/verify-momento-rex/"
git -C "$P" add -A && git -C "$P" commit -q -m harness && git -C "$P" push -q origin main
lane v
(cd "$(L v)" && bin/worktree setup >/dev/null)
echo x > "$(L v)/change.txt"
check "sandbox all refuses uncommitted changes and stamps nothing" '[ "$(cd "$(L v)" && BV_EVIDENCE_ROOT="$T/stamps" rc .claude/skills/verify-momento-rex/bin/sandbox all)" = 1 ] && grep -q "uncommitted changes" "$T/out" && [ ! -e "$T/stamps" ]'
git -C "$(L v)" add change.txt && git -C "$(L v)" commit -q -m change
mkdir -p "$T/stamps/all.old" && git -C "$P" rev-parse 'main^{tree}' > "$T/stamps/all.old/verified"
check "land refuses a change that no all run stamped" '[ "$(cd "$(L v)" && WORKTREE_STAMPS="$T/stamps/all.*/verified" rc bin/worktree land)" = 1 ] && grep -q "no passing .*sandbox all run stamped" "$T/out" && [ -z "$(git -C "$T/origin.git" branch --list v)" ]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
