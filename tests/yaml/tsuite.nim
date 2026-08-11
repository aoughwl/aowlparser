## tsuite.nim — the `yaml-parsed` dialect against the OFFICIAL yaml-test-suite.
##
## Every other check in this repo is self-referential: the parser and the
## renderer agree, and the shape assertions are ones I wrote after writing the
## parser. Both can be wrong together. The suite ships a canonical **event
## stream** per case (`test.event`) produced by reference implementations, which
## is third-party truth about the document — so a disagreement here is evidence
## in a way `render(parse(s)) == s` never is.
##
## WHAT IS COMPARED, and why not more. This is a concrete-syntax dialect, not a
## YAML loader: it deliberately does not resolve aliases, model flow collections
## as mappings, or fold block scalars. Comparing `+MAP`/`+SEQ` counts would
## therefore report differences that are the dialect's DESIGN, and a gate whose
## failures are mostly expected is a gate nobody reads.
##
## What does transfer exactly is the **document count**: `+DOC` per document,
## whatever the content. That covers `---`, `...`, implicit documents, a
## document after a `%YAML` directive, and bare comment-only streams — the part
## of YAML's structure this dialect really does claim to model.
##
## Error cases (a case directory containing a file named `error`) are skipped
## for the count and still round-tripped: their event stream is a prefix of a
## parse that was supposed to fail, so it has no document count to compare.
##
## Usage: tsuite <case-dir>...   (tests/run.sh passes the suite's case dirs)

import "../../src/yamlparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import "../../src/aowlparse/render.nim"
import std/[syncio, os]

proc parse(src: string): string = yamlToAif(src)

proc countDocEvents(events: string): int =
  ## `+DOC` at the start of a line. The suffix (`+DOC ---`) is not significant
  ## here: an explicit and an implicit document are both one document.
  result = 0
  var atLineStart = true
  var i = 0
  while i < events.len:
    if atLineStart and i + 3 < events.len and events[i] == '+' and
       events[i+1] == 'D' and events[i+2] == 'O' and events[i+3] == 'C':
      result = result + 1
    atLineStart = events[i] == '\n'
    i = i + 1

proc readOr(path: string; ok: var bool): string =
  ok = true
  result = ""
  try:
    result = readFile(path)
  except:
    ok = false
    result = ""

var g = initGate("yaml-suite", yamlDialect(), parse)

let cases = commandLineParams()
var compared = 0
var skippedErr = 0
var mismatches = 0

for ci in 0 ..< cases.len:
  let dir = cases[ci]
  var ok = true
  let src = readOr(dir & "/in.yaml", ok)
  if not ok: continue

  # Every case, valid or not, must round-trip byte-exactly.
  roundTrip(g, dir, src)

  var isErr = true
  discard readOr(dir & "/error", isErr)
  if isErr:
    skippedErr = skippedErr + 1
    continue

  var haveEvents = true
  let events = readOr(dir & "/test.event", haveEvents)
  if not haveEvents: continue

  let want = countDocEvents(events)
  let got = countTag(parse(src), "doc")
  compared = compared + 1
  g.checked = g.checked + 1
  if got != want:
    mismatches = mismatches + 1
    g.failures = g.failures + 1
    echo "FAIL [yaml-suite] ", dir, ": document count ", got,
         ", oracle says ", want

echo "oracle: ", compared, " case(s) compared on document count, ",
     mismatches, " mismatch(es); ", skippedErr,
     " error-case(s) round-tripped only"
quit report(g)
