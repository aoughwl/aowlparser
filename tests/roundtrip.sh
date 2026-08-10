#!/usr/bin/env bash
#
# tests/roundtrip.sh — BYTE-EXACT round-trip gate for the document dialects.
#
# For every corpus file:
#
#     aowlparser css    <in>  <work>/<in>.aif
#     aowlparser render <work>/<in>.aif  > <work>/<in>.back
#     cmp <in> <work>/<in>.back
#
# The pass criterion is BYTE-IDENTICAL. There is deliberately no canonicaliser
# here (unlike tests/diff.sh, which normalises before comparing against the
# nifler oracle): the document dialects have no oracle to diff against, so
# byte-exactness IS the correctness criterion, and a normalisation step would
# hide exactly the losses this gate exists to catch.
#
# Exit status is non-zero iff any file fails.
#
# Env overrides:
#   NIFPARSER   path to aowlparser        (default bin/aowlparser)
#   EXTRA_CSS   extra CSS paths to include, space-separated. Defaults to the
#               bootstrap.css in aoughwl-css when present — 280KB of real-world
#               CSS that is deliberately NOT vendored into this repo.
#   EXTRA_HTML  extra HTML paths to include, space-separated.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

NIFPARSER="${NIFPARSER:-$ROOT/bin/aowlparser}"
WORK="$HERE/_work/roundtrip"

BOOTSTRAP="/home/savant/aoughwl-css/tests/bootstrap.css"
if [ -z "${EXTRA_CSS:-}" ] && [ -f "$BOOTSTRAP" ]; then
  EXTRA_CSS="$BOOTSTRAP"
fi
EXTRA_CSS="${EXTRA_CSS:-}"

if [ ! -x "$NIFPARSER" ]; then
  echo "ERROR: aowlparser binary not found: $NIFPARSER" >&2
  exit 2
fi

rm -rf "$WORK"; mkdir -p "$WORK"

pass=0; fail=0; total=0; bytes=0
fails=""

check_one() {
  local src="$1" label="$2" tag="$3"
  total=$((total+1))
  local base
  base="$(echo "$label" | tr '/' '_')"
  local aif="$WORK/$base.aif"
  local back="$WORK/$base.back"

  if ! "$NIFPARSER" "$tag" "$src" "$aif" >/dev/null 2>"$WORK/$base.err"; then
    printf '  %-28s FAIL (parse exited non-zero)\n' "$label"
    fail=$((fail+1)); fails="$fails $label"; return
  fi
  if [ ! -s "$aif" ]; then
    printf '  %-28s FAIL (no AIF produced)\n' "$label"
    fail=$((fail+1)); fails="$fails $label"; return
  fi
  if ! "$NIFPARSER" render "$aif" "$back" >/dev/null 2>>"$WORK/$base.err"; then
    printf '  %-28s FAIL (render exited non-zero)\n' "$label"
    fail=$((fail+1)); fails="$fails $label"; return
  fi

  if cmp -s "$src" "$back"; then
    local n; n=$(wc -c < "$src")
    bytes=$((bytes+n))
    printf '  %-28s PASS  (%s bytes exact)\n' "$label" "$n"
    pass=$((pass+1))
  else
    printf '  %-28s FAIL  (byte mismatch)\n' "$label"
    # Name the first differing offset — a bare "differs" sends you re-deriving
    # what the gate already knows.
    cmp "$src" "$back" 2>&1 | sed 's/^/      /'
    fail=$((fail+1)); fails="$fails $label"
  fi
}

echo "css-parsed:"
for f in "$HERE"/css/corpus/*.css; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f")" css
done
for f in $EXTRA_CSS; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f") (external)" css
done

echo "html-parsed:"
for f in "$HERE"/html/corpus/*.html; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f")" html
done
for f in ${EXTRA_HTML:-}; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f") (external)" html
done

echo "py-parsed:"
for f in "$HERE"/py/corpus/*.py; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f")" py
done

echo "js-parsed:"
for f in "$HERE"/js/corpus/*.js; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f")" js
done

echo "vds-parsed:"
# vds corpus is length-prefixed records, not one file per grammar -- checked by
# tests/vds/tgate.nim rather than the CLI loop here.

echo "md-parsed:"
for f in "$HERE"/md/corpus/*.md; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f")" md
done

echo "json-parsed:"
for f in "$HERE"/json/corpus/*.json; do
  [ -e "$f" ] || continue
  check_one "$f" "$(basename "$f")" json
done

echo "--------------------------------------------------------------"
echo "round-trip: $total files   PASS: $pass   FAIL: $fail   ($bytes bytes byte-exact)"
if [ -n "$fails" ]; then
  echo "failing:$fails"
fi
[ "$fail" -eq 0 ]
