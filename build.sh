#!/usr/bin/env bash
# Build aowlparser — the pure-nimony parse front end (Nim source -> .p.aif).
#
# aowlparser is written in the language it parses, so it is built by nimony
# rather than by classic Nim; that is why there was no build.sh here for a
# while, and why `aowlup setup` reported "no build recipe" and skipped it.
#
# It needs two search paths:
#   src/                 its own modules (tokens, lexer, parser, the dialects)
#   $NIMONY/src/lib      nifbuilder and friends, nimony's shared compiler library
set -e

NIMONY="${NIMONY_ROOT:-$HOME/nimony}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

NIMONY_BIN="$NIMONY/bin/nimony"
[ -x "$NIMONY_BIN" ] || NIMONY_BIN="$NIMONY/bin/nimony.exe"
[ -x "$NIMONY_BIN" ] || {
  echo "aowlparser: nimony not found under $NIMONY (build it with: nim c -r src/hastur build all)" >&2
  exit 1
}

# On Windows the msys2 ucrt64 toolchain must precede Git-for-Windows' /mingw64
# on PATH, or gcc's cc1 loads its support DLLs from the wrong mingw and dies
# without printing anything at all.
case "$(uname -s)" in
  MINGW*|MSYS*)
    [ -d /c/msys64/ucrt64/bin ] && PATH="/c/msys64/ucrt64/bin:$PATH"
    EXE=".exe"
    ;;
  *) EXE="" ;;
esac
export PATH

mkdir -p "$ROOT/bin"

"$NIMONY_BIN" c \
  -o:"$ROOT/bin/aowlparser$EXE" \
  -p:"$ROOT/src" \
  -p:"$NIMONY/src/lib" \
  "$ROOT/src/aowlparser.nim"

echo "built $ROOT/bin/aowlparser$EXE"
