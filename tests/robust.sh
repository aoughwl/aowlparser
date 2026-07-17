#!/usr/bin/env bash
# robust.sh — aowlparser must NEVER hang or crash, on any input, however broken.
#
# A recovering front end (editor/LSP/CI) is fed half-typed and malformed code all
# day. nifler may abort with an error; we must still terminate and emit something.
# These cases all previously HUNG via the same bug class: a `-1` "not found"
# sentinel used as an index (`colon + 1` -> token 0), which restarted the parse at
# the START OF FILE and recursed forever.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NP="${NIFPARSER:-$ROOT/bin/aowlparser}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0

run() { # run <label> <source>
  printf '%s\n' "$2" > "$WORK/t.nim"
  timeout -s KILL 5 "$NP" p "$WORK/t.nim" /dev/null >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 137 ]; then echo "FAIL: HANG on $1: $2"; fail=1; fi
}

# (1) degenerate bare control-flow keywords in every hostile position.
for kw in if when case try for while block proc func iterator template macro \
          let var const type import discard return yield raise defer static do of; do
  for pat in "(%s)" "let x = (%s)" "discard (%s)" "%s" "proc f = (%s)" \
             "if (%s): x" "f((%s))" "[%s]" "{%s}" "(%s;)" "(%s: )" "(%s:)" \
             "x = (%s)" "(%s in )" "f(%s, a)"; do
    # shellcheck disable=SC2059
    run "degenerate" "$(printf "$pat" "$kw")"
  done
done

# (2) the historical real-world hangs, kept as explicit cases.
run "cmd anon-proc body with a comma then an if" \
'y.addCallback proc(f: T) =
  echo a, n
  if c:
    bar()'
run "proc foo = (if)" 'proc foo = (if)'
run "(for: ) — colon but no in" '(for: )'

# (3) TRUNCATION: every line-prefix of a real file must terminate (this is what
# an editor feeds a parser on every keystroke).
for src in "$ROOT/tests/corpus"/*.nim; do
  n=$(wc -l < "$src")
  for ((i = 1; i <= n; i++)); do
    head -n "$i" "$src" > "$WORK/t.nim"
    timeout -s KILL 5 "$NP" p "$WORK/t.nim" /dev/null >/dev/null 2>&1
    [ $? -eq 137 ] && { echo "FAIL: HANG on truncation: $src head -$i"; fail=1; break; }
  done
done

if [ "$fail" -eq 0 ]; then echo "robust: no hangs/crashes"; else echo "robust: FAILURES above"; fi
exit "$fail"
