#!/usr/bin/env bash
#
# tests/run.sh — THE gate. Builds every test binary and runs every check.
#
# There are three kinds of check here and they measure different things (see
# src/aowlparse/gate.nim for the long version):
#
#   differential   the Nim dialect against the native `nifler` oracle
#   round-trip     render(parse(s)) == s, byte for byte — proves the renderer
#                  inverts the parser, and NOTHING about tree correctness
#   shape          node counts and nesting — the only check that sees a wrong
#                  tree, because a token's bytes survive whichever node they
#                  land in
#
# Usage:
#   tests/run.sh            build what is missing, run everything
#   tests/run.sh --rebuild  force a rebuild of every test binary first
#   tests/run.sh --quick    skip the Nim differential (the slow one)
#
# Exit status is non-zero if ANY check fails.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NIMONY="${NIMONY:-/home/savant/nimony/bin/nimony}"
LIB="${NIMONY_LIB:-/home/savant/nimony/src/lib}"

REBUILD=0
QUICK=0
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1 ;;
    --quick) QUICK=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

fails=0
run_count=0

# Locate the executable a nimony compile produced for <src>.
#
# This picks the newest match under the source's own nimcache, which is a real
# hazard worth naming: if a stale binary of the same name sorts first, you
# silently measure the wrong thing. It bit this repo once already — a reverted
# falsification probe left a stale vds binary that reported 1286/1290 against
# fixed source. So a binary older than its source is ALWAYS rebuilt.
find_bin() {
  local dir="$1" name="$2"
  ls -t "$dir"/nimcache/*/"$name" 2>/dev/null | head -1
}

build() {
  local src="$1"
  local dir; dir="$(dirname "$src")"
  ( cd "$dir" && "$NIMONY" c --path:"$LIB" --path:"$ROOT/src" "$(basename "$src")" ) \
    >/dev/null 2>&1
}

check() {
  local label="$1" src="$2"; shift 2
  local dir; dir="$(dirname "$src")"
  local name; name="$(basename "$src" .nim)"
  local bin; bin="$(find_bin "$dir" "$name")"

  if [ "$REBUILD" = "1" ] || [ -z "$bin" ] || [ "$src" -nt "$bin" ]; then
    build "$src"
    bin="$(find_bin "$dir" "$name")"
  fi
  if [ -z "$bin" ]; then
    printf '  %-22s BUILD FAILED\n' "$label"
    fails=$((fails+1)); return
  fi

  run_count=$((run_count+1))
  local out rc
  out=$( cd "$dir" && timeout 600 "$bin" "$@" 2>&1 ); rc=$?
  local last; last=$(echo "$out" | tail -1)
  if [ "$rc" -eq 0 ]; then
    printf '  %-22s %s\n' "$label" "$last"
  else
    printf '  %-22s FAIL (exit %s)\n' "$label" "$rc"
    echo "$out" | grep -E '^(FAIL|  )' | head -12 | sed 's/^/      /'
    fails=$((fails+1))
  fi
}

echo "=== dialect gates ==="
check "css round-trip"   "$HERE/css/troundtrip.nim"
check "html round-trip"  "$HERE/html/troundtrip.nim"
check "html shape"       "$HERE/html/tstructure.nim"
check "css lexer"        "$HERE/css/tlex.nim"
check "py"               "$HERE/py/tgate.nim"
check "js"               "$HERE/js/tgate.nim"
check "json"             "$HERE/json/tgate.nim"
check "vds"              "$HERE/vds/tgate.nim" corpus/mdn.vdscorpus
check "completeness"     "$HERE/tcompleteness.nim"

echo "=== CLI round-trip (all dialects, real corpora) ==="
if out=$("$HERE/roundtrip.sh" 2>&1); then
  echo "$out" | tail -1 | sed 's/^/  /'
else
  echo "$out" | tail -20 | sed 's/^/  /'
  fails=$((fails+1))
fi

echo "=== robustness (never hang, never crash) ==="
if out=$("$HERE/robust.sh" 2>&1); then
  echo "$out" | tail -1 | sed 's/^/  /'
else
  echo "$out" | tail -8 | sed 's/^/  /'
  fails=$((fails+1))
fi

if [ "$QUICK" = "0" ]; then
  echo "=== nim differential (vs the nifler oracle) ==="
  if out=$("$HERE/diff.sh" 2>&1); then
    echo "$out" | tail -1 | sed 's/^/  /'
  else
    echo "$out" | tail -12 | sed 's/^/  /'
    fails=$((fails+1))
  fi
else
  echo "=== nim differential SKIPPED (--quick) ==="
fi

echo "--------------------------------------------------------------"
if [ "$fails" -eq 0 ]; then
  echo "ALL GREEN ($run_count dialect gates + CLI + robustness)"
else
  echo "$fails CHECK(S) FAILED"
fi
[ "$fails" -eq 0 ]
