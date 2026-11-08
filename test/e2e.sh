#!/bin/bash
# End-to-end test against a throwaway Rex server with fake agents.
# Never touches the user's Rex: every call goes to unix://$T/s.sock, and the
# test aborts if the server it reaches isn't that one.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(cd "$(mktemp -d /tmp/bunk-e2e.XXXX)" && pwd -P)"
SOCK="unix://$T/s.sock"
STATE="$T/state"
SERVER_PID=""

R() { rex -S "$SOCK" --autostart=false "$@"; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
# wait_for SECONDS COMMAND ARGS...: retry COMMAND until it succeeds.
wait_for() { local n=$(($1 * 5)); shift; while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n - 1)); done; return 1; }

cleanup() {
  [ -n "$SERVER_PID" ] && { R server stop >/dev/null 2>&1; sleep 1; kill "$SERVER_PID" 2>/dev/null; }
  pkill -f "state_dir=$STATE" 2>/dev/null
  if [ -z "${KEEP:-}" ]; then rm -rf "$T"; else echo "kept $T"; fi
}
trap cleanup EXIT

mkdir -p "$T/bin" "$T/zdot" "$T/claude" "$T/codex" "$T/work" "$T/it's dir"
for a in claude codex; do
  printf '#!/bin/bash\nexec -a %s /bin/bash %q %s "$@"\n' "$a" "$ROOT/test/fake-agent.sh" "$a" > "$T/bin/$a"
  chmod +x "$T/bin/$a"
done
cat > "$T/zdot/.zshrc" <<EOF
PROMPT='%~ %% '
path=("$T/bin" \$path)
alias claude='FAKE_ALIAS=1 claude'
EOF

# The test's init.lua is the one `bunk install` writes, on top of user content.
printf -- '-- my config\nlocal x = 1\n' > "$T/init.lua"
cp "$T/init.lua" "$T/init.orig"
B() { env -u REX_SESSION -u REX_BLOCK REX_CONFIG="$T/init.lua" BUNK_STATE_DIR="$STATE" REX_SERVER="$SOCK" "$ROOT/bin/bunk" "$@"; }

start_server() {
  local unset_args
  unset_args="$(env | grep -E '^(REX_|CLAUDE|CODEX_|BUNK_)[A-Za-z0-9_]*=' | cut -d= -f1 | sed 's/^/-u /' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  ( env $unset_args REX_SERVER="$SOCK" ZDOTDIR="$T/zdot" CLAUDE_CONFIG_DIR="$T/claude" CODEX_HOME="$T/codex" \
      FAKE_LOG="$T/launches" BUNK_PERIOD=1 BUNK_GC_AFTER=6 \
      rex server run --listen "$SOCK" --state-dir "$T/rex" --config "$T/init.lua" \
      >> "$T/server.log" 2>&1 < /dev/null & )
  wait_for 10 up || { echo "test server didn't start"; cat "$T/server.log"; exit 1; }
  SERVER_PID="$(R whoami --json | jq -r '.pid // .server.pid // empty')"
  # Guard: the server we reach must be ours.
  R whoami --json | grep -qF "$T/s.sock" || { echo "ABORT: not talking to the test server"; exit 1; }
}
stop_server() {
  R server stop >/dev/null 2>&1
  wait_for 10 server_gone || kill "$SERVER_PID"
  SERVER_PID=""
}
watchers() { pgrep -f "state_dir=$STATE" | wc -l | tr -d ' '; }
pane() { local s; s="$(R new "$1" -c "$2" --json | jq -r .session_id)"; printf '%s %s\n' "$s" "$(R block ls -s "$s" --json | jq -r '.blocks[0].block_id')"; }
type_in() { R send -s "$1" -b "$2" "$3"$'\r' >/dev/null; }
rec() { printf '%s/panes/%s.json' "$STATE" "${1//:/_}"; }
recf() { jq -r ".$2 // empty" "$(rec "$1")" 2>/dev/null; }
fg() { R block call -s "$1" -b "$2" process 2>/dev/null | jq -r '.foreground.argv0 // empty' | sed 's|.*/||; s/^-//'; }
launches() { grep -cF -- "$1" "$T/launches" 2>/dev/null || true; }
launched() { [ "$(launches "$1")" = "${2:-1}" ]; }
watchers_are() { [ "$(watchers)" = "$1" ]; }
has_chat() { [ -n "$(recf "$1" chat_id)" ]; }
chat_is() { [ "$(recf "$1" chat_id)" = "$2" ] && [ "$(recf "$1" state)" = "${3:-live}" ]; }
chat_changed() { has_chat "$1" && [ "$(recf "$1" chat_id)" != "$2" ]; }
no_rec() { [ ! -f "$(rec "$1")" ]; }
status_has() { B status 2>&1 | grep -q "$1"; }
started() { watchers_are 1 && [ -f "$STATE/status.json" ]; }
up() { R ls >/dev/null 2>&1; }
server_gone() { ! kill -0 "$SERVER_PID" 2>/dev/null; }

echo "install"
B install --no-start >/dev/null
check "install adds one tagged line and keeps user content" \
  '[ "$(grep -c "bunk:managed" "$T/init.lua")" = 1 ] && head -2 "$T/init.lua" | cmp -s - "$T/init.orig"'
B install --no-start >/dev/null
check "install twice changes nothing" '[ "$(grep -c "bunk:managed" "$T/init.lua")" = 1 ]'

echo "watcher"
start_server
check "init.lua starts one watcher" 'wait_for 10 started'
R config reload >/dev/null 2>&1
check "after a config reload, one watcher is left" 'sleep 1; wait_for 10 watchers_are 1' "$(pgrep -fl "state_dir=$STATE")"

echo "saving"
read -r SA BA < <(pane a "$T/work")
CWD_B="$T/it's dir"
read -r SB BB < <(pane b "$CWD_B")
read -r SC BC < <(pane c "$T/work")
read -r SD BD < <(pane d "$T/work")
sleep 1
type_in "$SA" "$BA" claude
sleep 3
check "claude: nothing saved before the first message" 'no_rec $BA'
type_in "$SA" "$BA" hello
check "claude: record saved with its chat id" 'wait_for 10 has_chat $BA'
ID_A="$(recf "$BA" chat_id)"
check "claude: alias used" '[ "$(launches "alias=1")" -ge 1 ]'
type_in "$SA" "$BA" /clear
check "claude: /clear updates the record" 'wait_for 10 chat_changed $BA $ID_A'
ID_A="$(recf "$BA" chat_id)"

type_in "$SB" "$BB" codex
sleep 3
check "codex: nothing saved before the first message" '[ ! -f "$(rec "$BB")" ]'
type_in "$SB" "$BB" hello
check "codex: record saved after the first message" 'wait_for 10 has_chat $BB'
ID_B="$(recf "$BB" chat_id)"

type_in "$SC" "$BC" claude
sleep 1
type_in "$SC" "$BC" hello
wait_for 10 has_chat "$BC"
R send-key -s "$SC" -b "$BC" ctrl+z >/dev/null
sleep 4
check "Ctrl-Z keeps the record" '[ -f "$(rec "$BC")" ]'
type_in "$SC" "$BC" fg
sleep 1
type_in "$SC" "$BC" /exit
check "a clean exit forgets the chat" 'wait_for 10 no_rec $BC'

echo "restart"
stop_server
check "records survive the server stopping" '[ -f "$(rec "$BA")" ] && [ -f "$(rec "$BB")" ]'
check "the watcher exits with the server" 'wait_for 10 watchers_are 0'
: > "$T/launches"
start_server
check "claude resumes in the restored pane" 'wait_for 15 launched "claude resumed $ID_A"' "$(cat "$T/launches"; tail -5 "$STATE/bunk.log")"
check "codex resumes, cd'd into its folder" 'wait_for 15 launched "codex resumed $ID_B cwd=$CWD_B"' "$(cat "$T/launches")"
check "the resumed claude keeps the user's alias" '[ "$(launches "claude resumed $ID_A cwd=$T/work alias=1")" = 1 ]'
sleep 4
check "each chat resumes exactly once" '[ "$(wc -l < "$T/launches" | tr -d " ")" = 2 ]' "$(cat "$T/launches")"
check "a pane that had no agent gets nothing" '[ "$(fg "$SD" "$BD")" = zsh ]'
check "the resumed codex (no message yet) keeps its record" 'wait_for 10 chat_is $BB $ID_B live'

stop_server
: > "$T/launches"
start_server
check "a resumed codex with no message resumes again (from argv)" 'wait_for 15 launched "codex resumed $ID_B"' "$(cat "$T/launches")"

echo "safety"
bad_id="11111111-2222-3333-4444-555555555555"
jq -cn --arg b "$BD" --arg s "$SD" --arg id "$bad_id" --arg cwd "/tmp/x
touch $T/pwned" '{v:1,agent:"claude",chat_id:$id,cwd:$cwd,inc:"1@old",agent_pid:1,agent_start:"x",session_id:$s,block_id:$b,state:"live"}' > "$(rec "$BD")"
check "a record with a newline in its folder is refused" 'wait_for 10 no_rec $BD'
sleep 1
check "nothing was typed or run" '[ ! -e "$T/pwned" ] && [ "$(launches "$bad_id")" = 0 ]'
check "status reports it and exits 1" 'out="$(B status 2>&1)"; [ $? = 1 ] && printf "%s" "$out" | grep -q resume.unsafe' "$(B status 2>&1)"

echo "format drift"
read -r SE BE < <(pane e "$T/work")
sleep 1
type_in "$SE" "$BE" "FAKE_CLAUDE_V2=1 claude"
check "a changed Claude sessions file shows up in status" 'wait_for 20 status_has claude.sessions' "$(B status 2>&1)"

echo "cleanup"
R kill "$SA" >/dev/null 2>&1
check "a closed pane's record is collected" 'wait_for 15 no_rec $BA'

echo "uninstall"
B uninstall >/dev/null
check "uninstall restores init.lua exactly" 'cmp -s "$T/init.lua" "$T/init.orig"'
check "uninstall stops the watcher" 'wait_for 10 watchers_are 0'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
