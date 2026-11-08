#!/bin/bash
# Stands in for claude and codex, imitating the private files bunk reads:
#   claude: writes $CLAUDE_CONFIG_DIR/sessions/<pid>.json at start, rewrites
#           sessionId on /clear, deletes the file on exit and on SIGHUP.
#           With $CLAUDE_CONFIG_DIR/slow-session present, it waits 4 s first.
#           The transcript projects/<slug>/<id>.jsonl appears with the first
#           message or /clear.
#   codex:  opens sessions/.../rollout-<ts>-<id>.jsonl after its first
#           message and holds it open; `resume <id>` opens nothing until then.
# Run as `exec -a claude bash fake-agent.sh claude ARGS` so argv0 matches.
kind="$1"; shift
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
  transcript() { local d="$CLAUDE_CONFIG_DIR/projects/${PWD//[^a-zA-Z0-9]/-}"; mkdir -p "$d"; echo '{}' >> "$d/$id.jsonl"; }
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
