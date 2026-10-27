#!/usr/bin/env bash
# Build aowlparser with the Nimony compiler -> bin/aowlparser.
#
# `aowlup setup` runs this on a fresh machine; before it existed setup cloned
# this repo, found no recipe, and every new install silently fell back to
# nimony's nifler for the parser slot.
#
# Runs FROM src/ with a bare filename: nimony resolves nimcache from the cwd,
# and a --base: elsewhere builds nothing and exits 0. Success is judged by the
# binary being NEWER than this run's start, not by its existing — a failed
# rebuild leaves the previous binary in place.
#
# Overrides: NIMONY=/path/to/nimony  OPT=release|danger|none (default release)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
OPT="${OPT:-release}"
LOCK="${NIMONY_BUILD_LOCK:-$HOME/.nimony-build.lock}"
OUT="$ROOT/bin/aowlparser"

# On Windows the msys2 ucrt64 toolchain must precede Git-for-Windows' /mingw64
# on PATH, or gcc's cc1 loads its support DLLs from the wrong mingw and dies
# without printing anything at all.
case "$(uname -s)" in
  MINGW*|MSYS*)
    [ -d /c/msys64/ucrt64/bin ] && PATH="/c/msys64/ucrt64/bin:$PATH"
    OUT="$OUT.exe"
    ;;
esac
export PATH

[ -x "$NIMONY" ] || { echo "no nimony at $NIMONY (set NIMONY=)" >&2; echo "BUILD-FAIL"; echo "BUILD-DONE"; exit 1; }
mkdir -p "$ROOT/bin"
flags=()
[ "$OPT" != "none" ] && flags+=("-d:$OPT")
stamp="$(mktemp)"

build() {
  cd "$ROOT/src" && "$NIMONY" c "${flags[@]}" -o:"$OUT" aowlparser.nim 2>&1
}
run_locked() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock 9
  fi
  build
}

log="$(run_locked)"; rc=$?
if [ $rc -ne 0 ] || grep -qE '(^|[^a-zA-Z])Error:' <<<"$log" || [ ! "$OUT" -nt "$stamp" ]; then
  echo "$log" | grep -E 'Error:' | head -20
  [ "$OUT" -nt "$stamp" ] || echo "bin/aowlparser was not (re)written by this run"
  rm -f "$stamp"
  echo "BUILD-FAIL"; echo "BUILD-DONE"
  exit 1
fi
rm -f "$stamp"
echo "built $OUT"
echo "BUILD-OK"
echo "BUILD-DONE"
