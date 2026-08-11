## toracle.nim — `py-parsed` against CPython's own tokenizer.
##
## Every other check on this dialect is self-referential: the parser and the
## renderer agree, and the shape assertions were written by whoever wrote the
## parser. Both can be wrong together, and a byte-exact round-trip is blind to
## it — a token's bytes survive whichever node they land in. CPython's
## `tokenize` module is truth from outside: `tests/py/oracle.py` writes a
## manifest of expected counts, and this compares ours against it.
##
## WHAT IS COMPARED
##   name     NAME tokens          — our `name` + `kw`, since the dialect splits
##                                   keywords out and CPython does not
##   num      NUMBER               str  STRING          comment  COMMENT
##   op       OP
##   stmt     NEWLINE              — one per LOGICAL line, so a bracketed or
##                                   backslash-continued statement counts once
##   block    INDENT               — one per indented suite
##
## Usage: toracle <manifest>   (tests/run.sh builds the manifest first)

import "../../src/pyparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import "../../src/aowlparse/render.nim"
import std/[syncio, os]

proc parse(src: string): string = pyToAif(src)

proc splitOn(s: string; sep: char): seq[string] =
  ## nimony's stdlib has no `splitLines`, and a manifest is line-oriented.
  result = @[]
  var cur = ""
  for c in s.items:
    if c == sep:
      result.add cur
      cur = ""
    elif c != '\r':
      cur.add c
  result.add cur

proc splitTabs(s: string): seq[string] =
  result = @[]
  var cur = ""
  for c in s.items:
    if c == '\t':
      result.add cur
      cur = ""
    else:
      cur.add c
  result.add cur

proc fieldValue(field: string; name: var string; value: var int): bool =
  ## `stmt=12` → ("stmt", 12). False when the field is not a `k=v` pair.
  name = ""
  value = 0
  var i = 0
  while i < field.len and field[i] != '=':
    name.add field[i]
    i = i + 1
  if i >= field.len or name.len == 0: return false
  i = i + 1
  var any = false
  while i < field.len:
    let c = field[i]
    if c < '0' or c > '9': return false
    value = value * 10 + (int(c) - int('0'))
    any = true
    i = i + 1
  return any

var g = initGate("py-oracle", pyDialect(), parse)

let args = commandLineParams()
if args.len < 1:
  echo "FAIL no manifest given"
  quit 1

var manifest = ""
var ok = true
try:
  manifest = readFile(args[0])
except:
  ok = false
if not ok:
  echo "FAIL cannot read manifest: ", args[0]
  quit 1

var files = 0
var skipped = 0
var mismatches = 0

let manifestLines = splitOn(manifest, '\n')
for line in manifestLines.items:
  if line.len == 0: continue
  let fields = splitTabs(line)
  if fields.len < 2: continue
  if fields[0] == "SKIP":
    # CPython could not tokenize it either. Printed, never silent: a dropped
    # file reads exactly like a passing one.
    skipped = skipped + 1
    echo "  skip: ", fields[1], " (CPython: ", fields[2], ")"
    continue
  let path = fields[0]
  var src = ""
  var readOk = true
  try:
    src = readFile(path)
  except:
    readOk = false
  if not readOk:
    echo "FAIL [py-oracle] cannot read ", path
    g.failures = g.failures + 1
    g.checked = g.checked + 1
    continue
  files = files + 1
  let aif = parse(src)
  for fi in 1 ..< fields.len:
    var name = ""
    var want = 0
    if not fieldValue(fields[fi], name, want): continue
    var got = countTag(aif, name)
    if name == "name":
      # CPython does not separate keywords from other names; this dialect does.
      got = got + countTag(aif, "kw")
    g.checked = g.checked + 1
    if got != want:
      mismatches = mismatches + 1
      g.failures = g.failures + 1
      echo "FAIL [py-oracle] ", path, ": ", name, " count ", got,
           ", CPython says ", want

echo "oracle: ", files, " file(s) compared against CPython's tokenizer, ",
     mismatches, " mismatch(es); ", skipped, " not tokenizable by CPython"
quit report(g)
