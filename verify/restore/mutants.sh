#!/bin/bash
# Each mutant breaks one line of momento-rex the way a careless change might, in
# temp copies, never in the repo. For each one this shows:
#   1. conformance catches the code change (the model no longer matches),
#   2. after the same change in the model, conformance matches again,
#   3. the model checker then breaks the property that line protects.
# Run through `verify/restore/check --mutants`.
set -u
JAR="$1" OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
fail=0

# Some properties have two guards (core.decide and watch.lua); a mutant that
# removes only one of them breaks nothing, so those mutants remove both.
# name | perl edit to lib/momento-rex/core.lua ("-" = watch.lua only, not table-checked) | perl edit to Restore.tla | cfg | property
MUTANTS=(
  'no-prompt-checks|s/^    if not o\.at_prompt then return \{\} end\n//m|s{IF ~o\.atPrompt THEN <<>>}{IF FALSE THEN <<>>}; s{IF AtPrompt /\\ shell = wObs\[w\]\.inc}{IF TRUE}|Restore|ResumeLandsAtPrompt'
  'keep-old-inc|s/r2\.inc, r2\.state, r2\.resumed_at = o\.inc, "resuming", now/r2.state, r2.resumed_at = "resuming", now/|s/\[r EXCEPT !\.inc = o\.inc, !\.state/[r EXCEPT !.state/|Restore|OneResumePerShell'
  'no-pane-agent|-|s{IF rec\.state # "none" /\\ wObs\[w\]\.kind # "agent" /\\ ag # "none"}{IF FALSE}|Restore|SavedChatSurvives'
  'no-liveness-checks|s/^  if o\.agent_alive then return \{\} end[^\n]*\n//m|s/  ELSE IF alive THEN <<>>\n//; s{IF rec\.state # "none" /\\ wObs\[w\]\.kind # "agent" /\\ ag # "none"}{IF FALSE}|Restore|SavedChatSurvives'
  'no-wait|-|s{/\\ \\A v \\in Watchers : v < w => ~wAlive\[v\]}{/\\ TRUE}|Handoff|OneResumePerShell'
  'guard-each-action|-|s{/\\ UNCHANGED <<token, wAlive, wPc, wObs, wGuarded, counts, lost>>}{/\\ wGuarded'"'"' = [wGuarded EXCEPT ![w] = FALSE]\n  /\\ UNCHANGED <<token, wAlive, wPc, wObs, counts, lost>>}|Handoff|SavedChatSurvives'
)

for m in "${MUTANTS[@]}"; do
  IFS='|' read -r name code model cfg want <<< "$m"
  d="$OUT/mutant-$name"
  mkdir -p "$d/lib/momento-rex"
  cp "$ROOT/lib/momento-rex/"*.lua "$d/lib/momento-rex/"
  cp "$HERE"/*.tla "$HERE"/*.cfg "$d/"
  line="mutant $name:"
  if [ "$code" != - ]; then
    perl -0pi -e "$code" "$d/lib/momento-rex/core.lua"
    if cmp -s "$d/lib/momento-rex/core.lua" "$ROOT/lib/momento-rex/core.lua"; then echo "$line code edit didn't apply"; fail=1; continue; fi
    if luajit "$HERE/conform.lua" "$d" < "$OUT/table.out" > "$d/conform-before.txt"; then
      echo "$line conformance MISSED the code change"; fail=1; continue
    fi
    line="$line conformance caught it;"
  fi
  perl -0pi -e "$model" "$d/Restore.tla"
  if cmp -s "$d/Restore.tla" "$HERE/Restore.tla"; then echo "$line model edit didn't apply"; fail=1; continue; fi
  if [ "$code" != - ]; then
    (cd "$d" && java -cp "$JAR" tlc2.TLC -metadir "$d/meta-t" -config DecideTable.cfg DecideTable.tla) > "$d/table.out" 2>&1
    if ! luajit "$HERE/conform.lua" "$d" < "$d/table.out" > "$d/conform-after.txt"; then
      echo "$line the mirrored model edit doesn't match the code edit"; fail=1; continue
    fi
  fi
  (cd "$d" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -metadir "$d/meta" -config "$cfg.cfg" Restore.tla) > "$d/tlc.out" 2>&1
  got="$(sed -n 's/^Error: Invariant \([A-Za-z]*\) is violated.*/\1/p' "$d/tlc.out" | head -1)"
  if [ "$got" = "$want" ]; then
    echo "$line $cfg breaks $want"
  else
    echo "$line expected $cfg to break $want, got ${got:-no violation}"; fail=1
  fi
done
exit $fail
