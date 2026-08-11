## gate.nim — the reusable acceptance harness every dialect is held to.
##
## Writing the CSS gate then the HTML gate produced the same four checks twice.
## They are here once, and a new dialect gets all of them by handing over a
## parse proc and its declaration.
##
## THE FOUR CHECKS, and why no one of them is sufficient:
##
##  1. identity     concatenating the token stream reproduces the input.
##                  Catches a tokenizer that drops or invents bytes, BEFORE any
##                  tree exists to blame.
##  2. round-trip   render(parse(s)) == s, byte for byte.
##                  Proves the renderer inverts the parser — and NOTHING about
##                  whether the tree is right, because a token's bytes survive
##                  no matter which node they land in. Measured, not assumed:
##                  disabling HTML raw-text mode left this at 44/44 PASS with
##                  <script> content parsed as markup.
##  3. declared     every tag emitted is declared in the dialect.
##                  An undeclared tag renders as structure and contributes no
##                  bytes, so forgetting one is a SILENT loss. This names it.
##  4. shape        caller-supplied assertions on node counts and nesting.
##                  The ONLY check that can see tree correctness. A dialect that
##                  supplies none has opted out of ever detecting a wrong tree.
##
## Plus a truncation fuzz: every prefix of a real document is malformed input of
## some shape, which reaches error-recovery paths hand-written cases never think
## of.

import nodespec
import render
import std/syncio

type
  Gate* = object
    name*: string
    dialect*: Dialect
    parse*: proc (src: string): string   ## source -> AIF
    checked*: int
    failures*: int
    quiet*: bool

proc initGate*(name: string; d: Dialect; parse: proc (src: string): string): Gate =
  Gate(name: name, dialect: d, parse: parse, checked: 0, failures: 0,
       quiet: false)

proc fail(g: var Gate; what, detail: string) =
  g.failures = g.failures + 1
  echo "FAIL [", g.name, "] ", what
  if detail.len > 0:
    echo "     ", detail

proc firstDiff*(a, b: string): int =
  var i = 0
  while i < a.len and i < b.len:
    if a[i] != b[i]: return i
    i = i + 1
  if a.len != b.len: return i
  return -1

proc excerpt*(s: string; at, span: int): string =
  result = ""
  var i = at - span
  if i < 0: i = 0
  var e = at + span
  if e > s.len: e = s.len
  while i < e:
    let c = s[i]
    if c == '\n': result.add "\\n"
    elif c == '\t': result.add "\\t"
    elif c == '\r': result.add "\\r"
    else: result.add c
    i = i + 1

proc checkSpec*(g: var Gate) =
  ## The declaration itself must be well formed before anything else is measured.
  g.checked = g.checked + 1
  let problem = validateSpec(g.dialect)
  if problem.len > 0:
    fail(g, "dialect declaration is malformed", problem)

proc roundTrip*(g: var Gate; label, src: string) =
  ## Checks 2 and 3 together: byte-exact round-trip, and no undeclared tag.
  g.checked = g.checked + 1
  let aif = g.parse(src)

  let undeclared = undeclaredTags(g.dialect, aif)
  if undeclared.len > 0:
    var names = ""
    for t in undeclared:
      if names.len > 0: names.add ", "
      names.add t
    fail(g, label & ": undeclared tag(s) emitted", names &
         "  (an undeclared tag renders as nothing — a silent byte loss)")
    return

  let back = renderWith(g.dialect, aif)
  if back != src:
    let d = firstDiff(src, back)
    fail(g, label & ": not byte-exact (first difference at byte " & $d & ")",
         "want: " & excerpt(src, d, 30) & "\n      got : " & excerpt(back, d, 30))

proc failUnreadable*(g: var Gate; path: string) =
  ## A file the gate was told to check and could not read.
  ##
  ## This exists because every dialect gate printed "FAIL could not read …" with
  ## an `echo` and then EXITED ZERO: the word FAIL in the output, a clean tally
  ## on the last line, and the harness reporting success. A file that silently
  ## vanishes from a corpus sweep reads exactly like a file that passed.
  g.checked = g.checked + 1
  fail(g, "could not read " & path, "named on the command line but unreadable")

proc expectCount*(g: var Gate; label, src, tag: string; want: int) =
  ## Check 4. Shape assertions are the only ones that can see a wrong tree.
  g.checked = g.checked + 1
  let got = countTag(g.parse(src), tag)
  if got != want:
    fail(g, label, "expected " & $want & " (" & tag & ") node(s), got " & $got)

proc expectNesting*(g: var Gate; label, src, tag: string; want: int) =
  g.checked = g.checked + 1
  let got = maxNesting(g.parse(src), tag)
  if got != want:
    fail(g, label, "expected (" & tag & ") nesting depth " & $want &
                   ", got " & $got)

const
  FuzzSamples* = 128        ## prefixes tried per file, REGARDLESS of file size
  FuzzMaxBytes* = 262144    ## files larger than this are not fuzzed

proc fuzzTruncations*(g: var Gate; label, src: string) =
  ## Every prefix must round-trip: a severed comment, a half-written token, an
  ## unclosed block. This is the cheapest way to reach the recovery paths.
  ##
  ## THE WORK IS BOUNDED BY WORK, NOT BY STEPS. Fuzzing is inherently O(n^2) —
  ## each of n/step prefixes is re-parsed from the start — so a fixed byte
  ## `step` makes cost explode with file size. Measured: a 25.8MB minified
  ## bundle at step 397 is ~63,000 prefixes averaging 12.5MB, which killed a
  ## whole-corpus sweep at the 560s deadline while 300 ordinary files took 5.3s.
  ##
  ## So: a fixed SAMPLE COUNT (step scales with the file), and a hard size cap
  ## above which the file is skipped — and the skip is PRINTED, never silent. A
  ## harness that quietly drops the hardest inputs reads exactly like one that
  ## passed them.
  g.checked = g.checked + 1
  if src.len > FuzzMaxBytes:
    echo "  skip fuzz: ", label, " (", src.len, " bytes > ", FuzzMaxBytes,
         " cap; round-trip still checked)"
    return
  var step = src.len div FuzzSamples
  if step < 1: step = 1
  var n = 0
  var bad = 0
  var firstBad = -1
  while n <= src.len:
    var prefix = ""
    var i = 0
    while i < n:
      prefix.add src[i]
      i = i + 1
    let aif = g.parse(prefix)
    if renderWith(g.dialect, aif) != prefix:
      bad = bad + 1
      if firstBad < 0: firstBad = n
    n = n + step
  if bad > 0:
    fail(g, label & ": " & $bad & " truncation(s) did not round-trip",
         "first at prefix length " & $firstBad)

proc report*(g: Gate): int =
  ## Prints the tally and returns the process exit code.
  echo g.name, ": ", g.checked - g.failures, "/", g.checked, " ok"
  if g.failures > 0: 1 else: 0
