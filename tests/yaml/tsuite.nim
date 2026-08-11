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

type
  EvCtx = object
    isMap: bool
    expectKey: bool

proc lineTagOf(events: string; start: int): string =
  ## The event name at `start`: up to the first space or newline.
  result = ""
  var i = start
  while i < events.len and events[i] != ' ' and events[i] != '\n' and
        events[i] != '\r':
    result.add events[i]
    i = i + 1

proc countMapKeys(events: string): int =
  ## How many mapping KEYS the oracle sees. Inside a `+MAP` the events alternate
  ## key, value, key, value…; a nested collection consumes whichever slot it
  ## lands in. This is the structural claim `yaml-parsed` actually makes — "these
  ## are the mapping entries" — measured by someone else's parser.
  result = 0
  var stack: seq[EvCtx] = @[]
  var i = 0
  while i < events.len:
    let tag = lineTagOf(events, i)
    if tag == "+MAP" or tag == "+SEQ":
      let top = stack.len - 1
      if top >= 0 and stack[top].isMap:
        if stack[top].expectKey: result = result + 1
        stack[top].expectKey = not stack[top].expectKey
      stack.add EvCtx(isMap: tag == "+MAP", expectKey: tag == "+MAP")
    elif tag == "-MAP" or tag == "-SEQ":
      if stack.len > 0: discard stack.pop()
    elif tag == "=VAL" or tag == "=ALI":
      let top = stack.len - 1
      if top >= 0 and stack[top].isMap:
        if stack[top].expectKey: result = result + 1
        stack[top].expectKey = not stack[top].expectKey
    # advance to the next line
    while i < events.len and events[i] != '\n': i = i + 1
    if i < events.len: i = i + 1

proc hasAny(src, chars: string): bool =
  for c in src.items:
    for w in chars.items:
      if c == w: return true
  return false

proc opensBlockScalar(line: string): bool =
  ## Whether a line ENDS with a `|` / `>` indicator (`|`, `>-`, `|+2`), which is
  ## what makes the following lines literal text. A `>` or `|` anywhere else in
  ## a line — inside a plain or quoted scalar — does nothing of the sort, and
  ## excluding those cases as well threw away a third of the comparable corpus.
  var e = line.len
  while e > 0 and (line[e-1] == ' ' or line[e-1] == '\t' or line[e-1] == '\n' or
                   line[e-1] == '\r'): e = e - 1
  if e == 0: return false
  var i = e
  while i > 0:
    let c = line[i-1]
    if c == '+' or c == '-' or (c >= '0' and c <= '9'):
      i = i - 1
      continue
    return (c == '|' or c == '>') and
           (i - 1 == 0 or line[i-2] == ' ' or line[i-2] == ':')
  return false

proc keyCountComparable(src: string): bool =
  ## Whether a case's KEY count is a fair comparison. `yaml-parsed` is a
  ## concrete-syntax dialect: it does not model a flow mapping as a mapping, an
  ## explicit `? ` key as a key, or a block scalar's content as anything at all.
  ## Comparing those would report the DESIGN as a defect, so they are excluded
  ## by name — and the exclusions are counted and printed, never silent.
  ##
  ## Anchors and aliases are NOT excluded: `*alias : scalar` is an entry to this
  ## dialect and a key to the oracle, which is the agreement being checked.
  var i = 0
  while i + 1 < src.len:
    if src[i] == '?' and src[i+1] == ' ': return false
    # A COLLECTION used as a key — `{a: 1}: v`, `[x]:adjacent` — is a complex
    # key, and this dialect does not model one: the collection is the key's
    # text. Named here, and in yamlparser.nim's SCOPE, rather than quietly
    # counted as agreement.
    if (src[i] == '}' or src[i] == ']') and src[i+1] == ':': return false
    # An anchor or alias NAME may itself contain a colon (`&a:` / `*a:`), so
    # `&a: key: value` has one key and this dialect, which does not tokenize
    # anchor names, sees two. A named gap, not a silent one.
    if src[i] == '&' or src[i] == '*':
      var j = i + 1
      while j < src.len and src[j] != ' ' and src[j] != '\t' and
            src[j] != '\n' and src[j] != '\r':
        if src[j] == ':': return false
        j = j + 1
    i = i + 1
  # a block scalar anywhere in the case makes its body uncomparable
  var line = ""
  var k = 0
  while k <= src.len:
    if k == src.len or src[k] == '\n':
      if opensBlockScalar(line): return false
      line = ""
    else:
      line.add src[k]
    k = k + 1
  return true

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
var keyCompared = 0
var keyMismatches = 0
var keySkipped = 0

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

  let aif = parse(src)
  let want = countDocEvents(events)
  let got = countTag(aif, "doc")
  compared = compared + 1
  g.checked = g.checked + 1
  if got != want:
    mismatches = mismatches + 1
    g.failures = g.failures + 1
    echo "FAIL [yaml-suite] ", dir, ": document count ", got,
         ", oracle says ", want

  if keyCountComparable(src):
    let wantKeys = countMapKeys(events)
    let gotKeys = countTag(aif, "entry")
    keyCompared = keyCompared + 1
    g.checked = g.checked + 1
    if gotKeys != wantKeys:
      keyMismatches = keyMismatches + 1
      g.failures = g.failures + 1
      echo "FAIL [yaml-suite] ", dir, ": mapping-key count ", gotKeys,
           ", oracle says ", wantKeys
  else:
    keySkipped = keySkipped + 1

echo "oracle: ", compared, " case(s) compared on document count, ",
     mismatches, " mismatch(es); ", keyCompared,
     " compared on mapping-key count, ", keyMismatches, " mismatch(es) (",
     keySkipped, " not comparable: flow, explicit keys, block scalars); ",
     skippedErr, " error-case(s) round-tripped only"
quit report(g)
