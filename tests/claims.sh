#!/usr/bin/env bash
# tests/claims.sh — do the NUMBERS in README.md still agree with the gates?
#
# README.md said "all 169 corpus programs pass — 154 of them byte-for-byte"
# while the dialect table eight sections down said 172/172 and tests/corpus/
# holds 172 files. Nothing caught it, because no gate reads prose. This is that
# gate. See CLAIMS.tsv, and tools/claimcheck.py for the argument.
#
#   bash tests/claims.sh          # the rows that cost nothing
#   bash tests/claims.sh --all    # also diff.sh and the three stress.sh sweeps
#   bash tests/claims.sh --sweep  # numbers with no row in CLAIMS.tsv
#
# ⚠️ On a checkout with no bin/aowlparser, or no native nifler at the path
# diff.sh/stress.sh expect, the differential gates answer `pass=0 …
# oracle-skip=N`. That zero means "no oracle", not "everything failed", and the
# rows carry a GUARD so it is reported UNVERIFIABLE rather than as a
# disagreement. A checker that read it as a measurement would call 184/184 wrong
# and invite someone to write a number no gate ever printed.
#
# Exit 0 clean / 1 a real disagreement or an UNATTRIBUTED number / 2 could not
# be checked. It never rewrites a document.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 tools/claimcheck.py --label aowlparser "$@"
