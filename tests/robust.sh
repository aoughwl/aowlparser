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

# (4) THE READER ON THE COMMAND LINE. `jsonq` and `jsonlint` reach
# src/jsonfast.nim, which the Nim gates never touch through the CLI — and a
# command nobody runs in the gate is a command that rots. Exit CODES are the
# contract here: CI steps branch on them.
J="$WORK/q.json"
printf '{"user":{"name":"ada"},"tags":["x","y"],"ok":true,"n":1.5e3,"deep":{"a":{"b":[0,{"c":"found"}]}}}' > "$J"

expect() { # expect <label> <want-stdout> <want-rc> <args...>
  local label="$1" want="$2" wantrc="$3"; shift 3
  local got rc
  got=$(timeout -s KILL 5 "$NP" "$@" 2>/dev/null); rc=$?
  if [ "$got" != "$want" ] || [ "$rc" != "$wantrc" ]; then
    echo "FAIL: $label — got '$got' rc=$rc, want '$want' rc=$wantrc"
    fail=1
  fi
}

expect "jsonq nested key"    "ada"     0 jsonq "$J" user.name
expect "jsonq array index"   "y"       0 jsonq "$J" 'tags[1]'
expect "jsonq deep mixed"    "found"   0 jsonq "$J" 'deep.a.b[1].c'
expect "jsonq number keeps spelling" "1.5e3" 0 jsonq "$J" n
expect "jsonq bool"          "true"    0 jsonq "$J" ok
expect "jsonq container"     "[2 elements]" 0 jsonq "$J" tags
expect "jsonq missing path"  ""        1 jsonq "$J" nope.deep
expect "jsonq past the end"  ""        1 jsonq "$J" 'tags[9]'
expect "jsonq malformed path" ""       2 jsonq "$J" 'tags[x]'
expect "jsonq no path given" ""        2 jsonq "$J"
expect "jsonlint accepts"    ""        0 jsonlint "$J"

# (5) `auto` must dispatch the repo's OWN format. It did not: `auto x.nim`
# answered "no dialect for x.nim" while `p x.nim` worked, because nim-parsed is
# not a registry row. .nims and .nimble are NimScript too.
printf 'proc f(x: int): int = x + 1\n' > "$WORK/src.txt"
for ext in nim nims nimble; do
  cp "$WORK/src.txt" "$WORK/auto.$ext"
  if ! timeout -s KILL 5 "$NP" auto "$WORK/auto.$ext" /dev/null >/dev/null 2>&1; then
    echo "FAIL: auto did not dispatch .$ext"
    fail=1
  fi
done
expect "auto still refuses an unknown extension" "" 1 auto "$WORK/auto.zzz"

printf '{"a":1,}' > "$WORK/bad.json"
expect "jsonlint rejects a trailing comma" "" 1 jsonlint "$WORK/bad.json"
printf 'NaN' > "$WORK/nan.json"
expect "jsonlint rejects NaN (not JSON)"   "" 1 jsonlint "$WORK/nan.json"
printf '' > "$WORK/empty.json"
expect "jsonlint rejects an empty file"    "" 1 jsonlint "$WORK/empty.json"

if [ "$fail" -eq 0 ]; then echo "robust: no hangs/crashes"; else echo "robust: FAILURES above"; fi
exit "$fail"
