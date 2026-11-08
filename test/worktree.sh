#!/bin/bash
# Tests bin/worktree, bin/bunk's lane guard, and the Bash hook in a temporary
# repo with a bare remote and a stub gh. Lanes are narrowed to 90-95 so live
# lanes in the real repo are never touched, and git gets its identity from the
# environment because CI runners have none.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d /tmp/bunk-worktree.XXXX)" && pwd -P)"
trap 'if [ -z "${KEEP:-}" ]; then rm -rf "$T"; else echo "kept $T"; fi' EXIT

export WORKTREE_LANE_RANGE=90-95
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export HOME="$T/home"   # bin/bunk's real init.lua and state dir, for the guard tests
unset XDG_CONFIG_HOME XDG_STATE_HOME REX_CONFIG BUNK_STATE_DIR WORKTREE_LANE WORKTREE_PRIMARY
mkdir -p "$HOME"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() { : > "$T/out"; if eval "$2"; then ok "$1"; else bad "$1" "${3:-$(cat "$T/out")}"; fi; }
# rc CMD...: run CMD, keep its output in $T/out, print its exit code.
rc() { "$@" > "$T/out" 2>&1; echo $?; }
notty() { perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' "$@"; }

# Stub gh: answers `pr list` from files in $T/gh and logs create and edit.
mkdir -p "$T/stub" "$T/gh"
cat > "$T/stub/gh" <<EOF
#!/bin/bash
D="$T/gh"
EOF
cat >> "$T/stub/gh" <<'EOF'
head="" state="" title="" num=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --head) head="${args[i+1]}" ;;
    --state) state="${args[i+1]}" ;;
    --title) title="${args[i+1]}" ;;
    -f) case "${args[i+1]}" in title=*) title="${args[i+1]#title=}" ;; esac ;;
  esac
done
case "$1 $2" in
  "pr list") cat "$D/$state-$head" 2>/dev/null; exit 0 ;;
  "pr create") echo "create $head $title" >> "$D/log"; echo 7 > "$D/open-$head"; echo "https://github.com/x/y/pull/7" ;;
  "api -X") [ "$3" = PATCH ] && echo "edit ${4##*/} $title" >> "$D/log" ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/stub/gh"
export WORKTREE_GH="$T/stub/gh"

# The repo: bin/worktree, bin/bunk, lib/bunk, .gitignore, pushed to a bare remote.
git init -q --bare -b main "$T/origin.git"
P="$T/repo"
git init -q -b main "$P"
mkdir -p "$P/bin" "$P/lib"
cp "$ROOT/bin/worktree" "$ROOT/bin/bunk" "$P/bin/"
cp -R "$ROOT/lib/bunk" "$P/lib/"
cp "$ROOT/.gitignore" "$P/"
git -C "$P" add -A && git -C "$P" commit -q -m init
git -C "$P" remote add origin "$T/origin.git"
git -C "$P" push -q -u origin main
W="$P/bin/worktree"
lane() { git -C "$P" worktree add -q -b "$1" "$P/.claude/worktrees/$1" "${2:-main}"; }
L() { printf '%s/.claude/worktrees/%s' "$P" "$1"; }
lane_of() { sed -n 's/^WORKTREE_LANE=//p' "$1/worktree.env" 2>/dev/null; }
reg_has() { grep -lxF "$1" "$P/tmp/worktrees/"* 2>/dev/null | wc -l | tr -d ' '; }
other() { # other CMD...: run in a second clone that pushes to origin
  [ -d "$T/other" ] || { git clone -q "$T/origin.git" "$T/other"; }
  git -C "$T/other" "$@"
}

echo "primary"
check "setup refuses in the primary" '[ "$(rc "$W" setup)" = 1 ] && grep -q "primary" "$T/out"'
check "info reports the primary" '[ "$(rc "$W" info)" = 0 ] && grep -q "(primary)" "$T/out"'
check "guard --deny does nothing in the primary" '[ "$(rc "$W" guard --deny thing)" = 0 ]'
check "WORKTREE_LANE_RANGE can't widen" '[ "$(WORKTREE_LANE_RANGE=0-150 rc "$W" info)" = 1 ] && [ "$(WORKTREE_LANE_RANGE=95-90 rc "$W" info)" = 1 ]'

echo "setup"
lane a
check "setup provisions a lane in the narrowed range" '(cd "$(L a)" && bin/worktree setup >/dev/null) && [ "$(lane_of "$(L a)")" = 90 ] && [ "$(cat "$P/tmp/worktrees/90")" = "$(L a)" ]'
check "worktree.env is shell-sourceable" '( . "$(L a)/worktree.env" && [ "$WORKTREE_LANE" = 90 ] && [ "$WORKTREE_PRIMARY" = "$P" ] )'
check "setup again reuses the lane" '(cd "$(L a)" && bin/worktree setup >/dev/null) && [ "$(lane_of "$(L a)")" = 90 ] && [ "$(reg_has "$(L a)")" = 1 ]'
check "info in a lane names the lane and what it refuses" '(cd "$(L a)" && bin/worktree info) | grep -q "^lane      90" && (cd "$(L a)" && bin/worktree info) | grep -q "bin/bunk start"'

lane b
for i in 1 2 3 4 5; do (cd "$(L b)" && bin/worktree setup >"$T/race-$i.log" 2>&1; echo $? > "$T/race-$i.rc") & done
wait
check "five setups racing in one worktree all succeed" '[ "$(cat "$T"/race-*.rc | sort -u)" = 0 ]' "$(cat "$T"/race-*.log)"
check "the race leaves one lane and one registry entry" '[ "$(lane_of "$(L b)")" = 91 ] && [ "$(reg_has "$(L b)")" = 1 ] && [ ! -e "$P/tmp/worktrees/92" ]'

lane c; lane d
(cd "$(L c)" && bin/worktree setup >/dev/null 2>&1) & (cd "$(L d)" && bin/worktree setup >/dev/null 2>&1) & wait
check "two worktrees racing get different lanes" 'lc=$(lane_of "$(L c)"); ld=$(lane_of "$(L d)"); [ -n "$lc" ] && [ -n "$ld" ] && [ "$lc" != "$ld" ]'

lane e
perl -MFcntl=:flock -e 'open(my $f, ">>", shift) or die; flock($f, LOCK_EX) or die; sleep 60' "$P/tmp/worktrees/.lock" &
holder=$!
sleep 0.5
(cd "$(L e)" && bin/worktree setup >/dev/null 2>&1; echo $? > "$T/e.rc") &
waiter=$!
sleep 1
check "setup waits while another process holds the registry lock" '[ ! -f "$T/e.rc" ] && [ ! -f "$(L e)/worktree.env" ]'
kill -9 "$holder"; wait "$holder" 2>/dev/null
wait "$waiter"
check "a killed lock holder leaves no lock behind" '[ "$(cat "$T/e.rc")" = 0 ] && [ -n "$(lane_of "$(L e)")" ]'

echo "sweep"
printf '/gone/away\n' > "$P/tmp/worktrees/99"
printf '/gone/too\n' > "$P/tmp/worktrees/150"
printf '/gone/three\n' > "$P/tmp/worktrees/abc"
lc="$(lane_of "$(L c)")"
rm -rf "$(L c)"; git -C "$P" worktree prune
check "teardown --stale drops a lane whose directory is gone" '"$W" teardown --stale >/dev/null && [ ! -e "$P/tmp/worktrees/$lc" ]'
check "it leaves live lanes alone" '[ -f "$P/tmp/worktrees/90" ] && [ -f "$P/tmp/worktrees/91" ]'
check "it leaves lanes outside the narrowed range alone" '[ -f "$P/tmp/worktrees/99" ]'
check "it refuses indexes outside 0-99 and junk names" '[ -f "$P/tmp/worktrees/150" ] && [ -f "$P/tmp/worktrees/abc" ] && "$W" teardown --stale | grep -q "outside 0-99"'
rm -f "$P/tmp/worktrees/99" "$P/tmp/worktrees/150" "$P/tmp/worktrees/abc"

echo "guard"
check "guard --deny exits 3 in a lane" '[ "$(cd "$(L a)" && rc bin/worktree guard --deny "make deploy")" = 3 ] && grep -q "make deploy" "$T/out"'
check "guard --warn warns and goes on" '[ "$(cd "$(L a)" && rc bin/worktree guard --warn x)" = 0 ] && grep -q warning "$T/out"'
check "guard --confirm with no terminal refuses" '[ "$(cd "$(L a)" && rc notty bin/worktree guard --confirm x)" = 3 ]'
check "a lane's guard run from the primary's directory still refuses" '[ "$(cd "$P" && rc "$(L a)/bin/worktree" guard --deny x)" = 3 ]'
check "the primary's guard run from a lane's directory passes" '[ "$(cd "$(L a)" && rc "$W" guard --deny x)" = 0 ]'

echo "bin/bunk in a lane"
check "start refuses" '[ "$(cd "$(L a)" && rc bin/bunk start)" = 3 ]'
check "install without --no-start refuses, even with a temp config" '[ "$(cd "$(L a)" && REX_CONFIG="$T/x/init.lua" BUNK_STATE_DIR="$T/x/state" rc bin/bunk install)" = 3 ]'
check "install --no-start against the real init.lua refuses and writes nothing" '[ "$(cd "$(L a)" && rc bin/bunk install --no-start)" = 3 ] && [ ! -e "$HOME/.config/rex" ]'
check "uninstall against the real init.lua refuses" '[ "$(cd "$(L a)" && rc bin/bunk uninstall)" = 3 ]'
check "uninstall against the real state dir refuses" '[ "$(cd "$(L a)" && REX_CONFIG="$T/x/init.lua" rc bin/bunk uninstall)" = 3 ]'
check "uninstall against a temp config and state runs (as e2e does)" '[ "$(cd "$(L a)" && REX_CONFIG="$T/x/init.lua" BUNK_STATE_DIR="$T/x/state" rc bin/bunk uninstall)" = 0 ]'
check "a symlinked path to the real init.lua still refuses" 'mkdir -p "$HOME/.config/rex" && ln -s "$HOME/.config/rex" "$T/rexlink" && [ "$(cd "$(L a)" && REX_CONFIG="$T/rexlink/init.lua" BUNK_STATE_DIR="$T/x/state" rc bin/bunk uninstall)" = 3 ]'
check "the primary's uninstall runs" '[ "$(cd "$P" && rc bin/bunk uninstall)" = 0 ]'

echo "land"
A="$(L a)"
check "land refuses in the primary" '[ "$(rc "$W" land)" = 1 ]'
check "land refuses a branch with nothing to land" '[ "$(cd "$A" && rc bin/worktree land)" = 1 ] && grep -q "nothing to land" "$T/out"'
echo one > "$A/one.txt"; git -C "$A" add one.txt; git -C "$A" commit -q -m "Add one"
echo more >> "$A/one.txt"
check "land refuses tracked changes" '[ "$(cd "$A" && rc bin/worktree land)" = 1 ] && grep -q "tracked changes" "$T/out"'
git -C "$A" checkout -q one.txt
echo stray > "$A/stray.txt"
check "land pushes and opens a PR, ignoring untracked files" '[ "$(cd "$A" && rc bin/worktree land)" = 0 ] && grep -qx "create a Add one" "$T/gh/log" && [ "$(git -C "$T/origin.git" rev-parse a)" = "$(git -C "$A" rev-parse HEAD)" ]'
rm -f "$A/stray.txt"
echo two > "$A/two.txt"; git -C "$A" add two.txt; git -C "$A" commit -q -m "Add two"
check "land refuses several commits and lists them" '[ "$(cd "$A" && rc bin/worktree land)" = 1 ] && grep -q "Add two" "$T/out" && grep -q "Add one" "$T/out"'
printf 'Add one and two\n\nBoth files.\n' > "$T/msg"
check "land --message squashes to one commit and updates the open PR" '[ "$(cd "$A" && rc bin/worktree land --message "$T/msg")" = 0 ] && grep -qx "edit 7 Add one and two" "$T/gh/log" && [ "$(git -C "$T/origin.git" rev-list --count main..a)" = 1 ] && [ "$(git -C "$T/origin.git" log -1 --format=%s a)" = "Add one and two" ]'
git -C "$(L b)" checkout -q --detach
check "land refuses a detached HEAD" '[ "$(cd "$(L b)" && rc bin/worktree land)" = 1 ] && grep -q detached "$T/out"'
git -C "$(L b)" checkout -q b
other commit -q --allow-empty -m "Upstream change"; other push -q origin main
echo b > "$(L b)/b.txt"; git -C "$(L b)" add b.txt; git -C "$(L b)" commit -q -m "Add b"
check "land refuses a branch that lacks commits from origin/main" '[ "$(cd "$(L b)" && rc bin/worktree land)" = 1 ] && grep -q "lacks commits from origin/main" "$T/out"'

echo "sync"
check "sync refuses in a lane" '[ "$(cd "$A" && rc bin/worktree sync)" = 1 ]'
check "sync fast-forwards the primary's main" '[ "$(rc "$W" sync)" = 0 ] && [ "$(git -C "$P" rev-parse main)" = "$(git -C "$T/origin.git" rev-parse main)" ]'
git -C "$P" commit -q --allow-empty -m "Local only"
check "sync refuses local commits that origin/main lacks" '[ "$(rc "$W" sync)" = 1 ] && grep -q "need a PR" "$T/out"'
git -C "$P" reset -q --hard origin/main
echo stray > "$P/stray.txt"
check "sync ignores untracked files" '[ "$(rc "$W" sync)" = 0 ]'
rm -f "$P/stray.txt"

echo "teardown"
check "teardown NAME refuses from inside a lane" '[ "$(cd "$A" && rc bin/worktree teardown a)" = 1 ] && grep -q "primary" "$T/out"'
echo stray > "$A/stray.txt"
check "teardown refuses untracked files" '[ "$(rc "$W" teardown a)" = 1 ] && grep -q untracked "$T/out" && [ -d "$A" ]'
rm -f "$A/stray.txt"
check "teardown refuses a HEAD that is neither on main nor a merged PR head" '[ "$(rc "$W" teardown a)" = 1 ] && grep -q "neither on main" "$T/out" && [ -d "$A" ]'
# Squash-merge PR a on the remote.
other fetch -q origin; other merge -q --squash origin/a >/dev/null 2>&1; other commit -q -m "Add one and two (#7)"; other push -q origin main
git -C "$A" rev-parse HEAD > "$T/gh/merged-a"
echo late > "$A/late.txt"; git -C "$A" add late.txt; git -C "$A" commit -q -m "After the merge"
check "a commit made after the merge still blocks teardown" '[ "$(rc "$W" teardown a)" = 1 ] && [ -d "$A" ]'
git -C "$A" reset -q --hard HEAD~1
la="$(lane_of "$A")"
check "teardown removes a squash-merged lane, its branch, and its lane" '[ "$(rc "$W" teardown a)" = 0 ] && [ ! -e "$A" ] && ! git -C "$P" rev-parse -q --verify refs/heads/a >/dev/null && [ ! -e "$P/tmp/worktrees/$la" ]'
check "teardown synced main first" '[ "$(git -C "$P" rev-parse main)" = "$(git -C "$T/origin.git" rev-parse main)" ]'

lane f
(cd "$(L f)" && bin/worktree setup >/dev/null)
check "teardown removes a lane whose HEAD is on main (git branch -d)" '[ "$(rc "$W" teardown f)" = 0 ] && [ ! -e "$(L f)" ] && ! git -C "$P" rev-parse -q --verify refs/heads/f >/dev/null'

check "teardown refuses unlanded work without --discard" '[ "$(rc "$W" teardown b)" = 1 ] && [ -d "$(L b)" ]'
echo stray > "$(L b)/stray.txt"
lb="$(lane_of "$(L b)")"
check "teardown --discard removes unlanded work and untracked files" '[ "$(rc "$W" teardown b --discard)" = 0 ] && [ ! -e "$(L b)" ] && ! git -C "$P" rev-parse -q --verify refs/heads/b >/dev/null && [ ! -e "$P/tmp/worktrees/$lb" ]'

git -C "$P" worktree add -q -b cur "$T/cursor-wt" main
(cd "$T/cursor-wt" && bin/worktree setup >/dev/null)
check "teardown takes a path for a worktree outside .claude/worktrees" '[ "$(rc "$W" teardown "$T/cursor-wt")" = 0 ] && [ ! -e "$T/cursor-wt" ]'

echo "hook"
HOOK="$ROOT/.claude/hooks/worktree-bash.sh"
hook() { printf '{"cwd":"%s","tool_name":"Bash"}' "$1" | "$HOOK"; }
lane g
check "the hook does nothing in the primary" '[ "$(rc hook "$P")" = 0 ] && [ ! -s "$T/out" ]'
check "the hook provisions a new lane and reports it" '[ "$(rc hook "$(L g)")" = 0 ] && [ -f "$(L g)/worktree.env" ] && grep -q additionalContext "$T/out" && grep -q "Provisioned" "$T/out"'
lane h
chmod 555 "$P/tmp/worktrees"
check "a failed setup blocks one command and leaves the marker" '[ "$(rc hook "$(L h)")" = 2 ] && [ -f "$(L h)/tmp/worktree-setup.failed" ] && [ ! -f "$(L h)/worktree.env" ]'
check "the next command runs" '[ "$(rc hook "$(L h)")" = 0 ]'
chmod 755 "$P/tmp/worktrees"
check "a fixed setup clears the marker" '(cd "$(L h)" && bin/worktree setup >/dev/null) && [ ! -e "$(L h)/tmp/worktree-setup.failed" ]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
