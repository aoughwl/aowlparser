## tcompleteness.nim — the verdicts aowlrepl asked for.
##
## The 22 verdicts aowlrepl pinned in its own tests/cases/reader.analyze are the
## contract this must satisfy, so the same cases are asserted here — at the
## library level, where they belong.

import "../src/completeness.nim"
import std/syncio

var checked = 0
var failures = 0

proc expect(src: string; want: Completeness) =
  checked = checked + 1
  let r = completeness(src)
  if r.verdict != want:
    failures = failures + 1
    echo "FAIL ", want, " expected for: ", src
    echo "     got ", r.verdict, " (", r.reason, ": ", r.detail, ")"

# --- complete ---------------------------------------------------------------
expect "", ckComplete
expect "x + 1", ckComplete
expect "echo \"hi\"", ckComplete
expect "let x = 1", ckComplete
expect "proc f() = discard", ckComplete
expect "foo(a, b)", ckComplete
expect "a[0]", ckComplete
expect "{1, 2}", ckComplete
expect "x = nil", ckComplete
expect "# just a comment", ckComplete

# --- incomplete: the cases `check` returns [] for ---------------------------
# These are exactly the inputs the message named: check reports nothing because
# an empty-bodied construct is valid for nifler, and a REPL must keep reading.
expect "type", ckIncomplete
expect "if x > 1:", ckIncomplete
expect "proc twice(x: int): int =", ckIncomplete
expect "while true:", ckIncomplete
expect "for i in 0..3:", ckIncomplete
expect "try:", ckIncomplete

# --- incomplete: dangling tokens and open brackets -------------------------
expect "1 +", ckIncomplete
expect "foo(", ckIncomplete
expect "a[", ckIncomplete
expect "{", ckIncomplete
expect "foo(a,", ckIncomplete
expect "x.", ckIncomplete
expect "let x =", ckIncomplete
expect "foo(a,\n  b", ckIncomplete
expect "\"unterminated", ckIncomplete
expect "#[ open block comment", ckIncomplete

# --- invalid: cannot be repaired by typing more ----------------------------
expect "foo)", ckInvalid
expect "]", ckInvalid
expect "foo(a]", ckInvalid
expect "(a}", ckInvalid

echo "completeness: ", checked - failures, "/", checked, " ok"
if failures > 0: quit 1
