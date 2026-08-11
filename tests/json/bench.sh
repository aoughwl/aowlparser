#!/usr/bin/env bash
#
# bench.sh — jsonfast against the readers people actually use.
#
# Every contender does the SAME job: take a document already in memory, build an
# in-memory representation of it, and be timed on the best of N runs. Best, not
# mean: the mean measures the machine's noise, the minimum measures the parser.
#
# What is NOT comparable is called out rather than quietly averaged in:
#   * `jq` is measured end-to-end (read + parse + serialize) because it has no
#     parse-only mode. Its number is an upper bound on its parse cost, not a
#     parse cost, and it is listed for scale.
#   * CPython and V8 build full language objects with hash maps and interned
#     strings; jsonfast builds a tape and decodes strings on demand. That IS the
#     design difference being measured, and the correctness gate
#     (tests/json/tfast.nim) proves the tape answers the same questions.
#
# Usage: bench.sh [file.json] [iterations]

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NIMONY="${NIMONY:-/home/savant/nimony/bin/nimony}"
LIB="${NIMONY_LIB:-/home/savant/nimony/src/lib}"

FILE="${1:-}"
ITER="${2:-20}"

if [ -z "$FILE" ]; then
  # Default to the largest JSON in the test corpus.
  FILE="$(ls -S "$HERE"/corpus/*.json 2>/dev/null | head -1)"
fi
if [ ! -f "$FILE" ]; then
  echo "no benchmark file (pass one as \$1)" >&2
  exit 2
fi

BYTES=$(wc -c < "$FILE")
MB=$(python3 -c "print('%.2f' % ($BYTES/1048576.0))")
echo "file: $FILE  ($MB MB, best of $ITER)"
echo

row() { printf '  %-22s %10s MB/s   %s\n' "$1" "$2" "${3:-}"; }

# --- jsonfast --------------------------------------------------------------
BIN="$(ls -t "$HERE"/nimcache/*/bench 2>/dev/null | head -1)"
if [ -z "$BIN" ] || [ "$HERE/bench.nim" -nt "$BIN" ] || [ "$ROOT/src/jsonfast.nim" -nt "$BIN" ]; then
  ( cd "$HERE" && "$NIMONY" c -d:danger --path:"$LIB" --path:"$ROOT/src" bench.nim ) >/dev/null 2>&1
  BIN="$(ls -t "$HERE"/nimcache/*/bench 2>/dev/null | head -1)"
fi
if [ -n "$BIN" ]; then
  OUT="$("$BIN" "$FILE" "$ITER")"
  row "jsonfast (tape)" "$(echo "$OUT" | awk '/throughput/{printf "%.0f", $2}')"
else
  row "jsonfast (tape)" "BUILD FAILED"
fi

# --- CPython ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  row "CPython json (C)" "$(python3 - "$FILE" "$ITER" <<'PY'
import json, sys, time
data = open(sys.argv[1], 'rb').read().decode('utf-8')
best = None
for _ in range(int(sys.argv[2])):
    t0 = time.perf_counter()
    json.loads(data)
    dt = time.perf_counter() - t0
    best = dt if best is None or dt < best else best
print("%.0f" % (len(data.encode()) / 1048576.0 / best))
PY
)"
fi

# --- V8 --------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  row "V8 JSON.parse" "$(node -e '
const fs = require("fs");
const data = fs.readFileSync(process.argv[1], "utf8");
let best = Infinity;
for (let i = 0; i < Number(process.argv[2]); i++) {
  const t0 = process.hrtime.bigint();
  JSON.parse(data);
  const dt = Number(process.hrtime.bigint() - t0) / 1e9;
  if (dt < best) best = dt;
}
console.log((Buffer.byteLength(data) / 1048576 / best).toFixed(0));
' "$FILE" "$ITER")"
fi

# --- jq --------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  T0=$(date +%s.%N)
  jq -c . "$FILE" >/dev/null 2>&1
  T1=$(date +%s.%N)
  row "jq (read+parse+print)" \
      "$(python3 -c "print('%.0f' % ($BYTES/1048576.0/($T1-$T0)))")" \
      "not parse-only — for scale"
fi

# --- aowljson --------------------------------------------------------------
AJ="${AOWLJSON:-/home/savant/aowljson/src}"
if [ -f "$AJ/aowljson.nim" ]; then
  ABIN="$(ls -t "$HERE"/nimcache/*/bench_aowljson 2>/dev/null | head -1)"
  if [ -z "$ABIN" ] || [ "$HERE/bench_aowljson.nim" -nt "$ABIN" ]; then
    ( cd "$HERE" && "$NIMONY" c -d:danger --path:"$LIB" --path:"$AJ" \
        bench_aowljson.nim ) >/dev/null 2>&1
    ABIN="$(ls -t "$HERE"/nimcache/*/bench_aowljson 2>/dev/null | head -1)"
  fi
  if [ -n "$ABIN" ]; then
    row "aowljson (ref tree)" \
        "$("$ABIN" "$FILE" "$ITER" | awk '/throughput/{printf "%.0f", $2}')"
  fi
fi

echo
echo "correctness for the number above: tests/json/tfast.nim, which holds"
echo "jsonfast to CPython on every .json on this machine and on ~494k prefixes."
