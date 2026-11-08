#!/bin/bash
# Stands in for claude and codex, imitating the private files bunk reads:
#   claude: writes $CLAUDE_CONFIG_DIR/sessions/<pid>.json at start, rewrites
#           sessionId on /clear, deletes the file on exit and on SIGHUP.
#           With $CLAUDE_CONFIG_DIR/slow-session present, it waits 4 s first.
#           The transcript projects/<slug>/<id>.jsonl appears with the first
#           message or /clear. The slug is built as Claude 2.1.319 builds it
#           (see claude_slug below).
#   codex:  opens sessions/.../rollout-<ts>-<id>.jsonl after its first
#           message and holds it open; `resume <id>` opens nothing until then.
# Run as `exec -a claude bash fake-agent.sh claude ARGS` so argv0 matches.
# Claude's project folder name for a cwd: every non-alphanumeric becomes "-",
# and a name over 200 characters is cut to 200 and gets "-" plus the base-36
# absolute value of a 32-bit string hash of the cwd. From Claude 2.1.319:
#   if (e.length <= 200) return e; return `${e.slice(0,200)}-${Math.abs(h(t)).toString(36)}`
#   h(t): e = 0; for each char: e = (e << 5) - e + charCode | 0
# ASCII paths only: JS hashes UTF-16 code units, this hashes bytes.
claude_slug() {
  local s="${1//[^a-zA-Z0-9]/-}"
  if [ ${#s} -le 200 ]; then printf '%s' "$s"; return; fi
  local h=0 i c out="" digits=0123456789abcdefghijklmnopqrstuvwxyz
  for ((i = 0; i < ${#1}; i++)); do
    printf -v c '%d' "'${1:i:1}"
    h=$(( (h * 31 + c) & 0xFFFFFFFF ))
  done
  (( h >= 0x80000000 )) && h=$(( 0x100000000 - h ))
  while :; do out="${digits:h % 36:1}$out"; h=$(( h / 36 )); (( h > 0 )) || break; done
  printf '%s-%s' "${s:0:200}" "$out"
}

kind="$1"; shift
# `fake-agent.sh slug PATH` prints the slug, to check this port against Claude.
[ "$kind" = slug ] && { claude_slug "$1"; exit; }
id=""; how=new
case "$kind:${1:-}" in
  claude:--resume) id="$2"; how=resumed ;;
  codex:resume) id="$2"; how=resumed ;;
esac
newid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
[ -n "$id" ] || id="$(newid)"
printf '%s %s %s cwd=%s alias=%s\n' "$kind" "$how" "$id" "$PWD" "${FAKE_ALIAS:-}" >> "$FAKE_LOG"
if [ "$kind" = claude ]; then
  f="$CLAUDE_CONFIG_DIR/sessions/$$.json"
  mkdir -p "${f%/*}"
  wr() {
    if [ -n "${FAKE_CLAUDE_V2:-}" ]; then
      printf '{"pid":%d,"session":"%s","kind":"interactive"}\n' $$ "$id" > "$f.tmp"
    else
      printf '{"pid":%d,"sessionId":"%s","cwd":"%s","kind":"interactive"}\n' $$ "$id" "$PWD" > "$f.tmp"
    fi
    mv "$f.tmp" "$f"
  }
  transcript() {
    local d
    d="$CLAUDE_CONFIG_DIR/projects/$(claude_slug "$PWD")"
    mkdir -p "$d"
    echo '{}' >> "$d/$id.jsonl"
  }
  trap 'rm -f "$f"; exit 129' HUP
  trap 'rm -f "$f"' EXIT
  # The test creates this file to make Claude slow to write its sessions file.
  [ -f "$CLAUDE_CONFIG_DIR/slow-session" ] && sleep 4
  wr
fi

echo "FAKE $kind ready $id"
opened=""
while IFS= read -r line; do
  case "$line" in
    /exit|/quit) exit 0 ;;
    /clear) id="$(newid)"; [ "$kind" = claude ] && { wr; transcript; }; echo "FAKE cleared $id" ;;
    *)
      [ "$kind" = claude ] && transcript
      if [ "$kind" = codex ] && [ -z "$opened" ]; then
        d="$CODEX_HOME/sessions/2026/11/08"
        mkdir -p "$d"
        exec 3>>"$d/rollout-2026-11-08T00-00-00-$id.jsonl"
        opened=1
      fi
      echo "FAKE got: $line"
      ;;
  esac
done
