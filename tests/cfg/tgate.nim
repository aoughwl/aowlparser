## tgate.nim — the `cfg-parsed` acceptance gate.
##
## The hazard this dialect carries is not embedded content but AMBIGUITY: the
## same file holds `--path:"x"` (a switch), `path = "x"` (an assignment) and
## `[Package]` (a section header), and choosing wrong still round-trips
## byte-for-byte, because every byte survives whichever node it lands in. So the
## shape assertions here are about WHICH node a line became, which is the only
## thing a byte comparison cannot see.

import "../../src/cfgparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = cfgToAif(src)

var g = initGate("cfg", cfgDialect(), parse)
checkSpec(g)

# --- round-trip -------------------------------------------------------------
roundTrip(g, "empty", "")
roundTrip(g, "one switch", "--path:\"$lib\"\n")
roundTrip(g, "switch with a space", "--outdir: \"bin\"\n")
roundTrip(g, "short switch", "-d:release\n")
roundTrip(g, "short switch no value", "-d\n")
roundTrip(g, "assignment", "path = \"lib\"\n")
roundTrip(g, "assignment no spaces", "path=\"lib\"\n")
roundTrip(g, "bracketed key", "warning[SmallLshouldNotBeUsed] = off\n")
roundTrip(g, "section", "[Package]\nname = \"x\"\n")
roundTrip(g, "two sections", "[a]\nk = 1\n[b]\nk = 2\n")
roundTrip(g, "hash comment", "# a comment\n")
roundTrip(g, "semicolon comment", "; a comment\n")
roundTrip(g, "trailing comment", "path = \"lib\"  # why\n")
roundTrip(g, "hash inside a quoted value", "--passC:\"-DX=#1\"\n")
roundTrip(g, "conditional", "@if windows:\n  -d:win\n@end\n")
roundTrip(g, "blank lines", "a = 1\n\n\nb = 2\n")
roundTrip(g, "indented entry", "  path = \"x\"\n")
roundTrip(g, "no final newline", "path = \"x\"")
roundTrip(g, "crlf", "a = 1\r\nb = 2\r\n")
roundTrip(g, "value with a colon", "path = \"a:b\"\n")
roundTrip(g, "bare word line", "refc\n")
roundTrip(g, "utf8", "name = \"caf\xc3\xa9\"\n")
roundTrip(g, "tabs", "\tpath\t=\t\"x\"\n")
roundTrip(g, "unclosed bracket is not a header", "[oops\n")
roundTrip(g, "empty section name", "[]\n")
roundTrip(g, "only a dash", "-\n")
roundTrip(g, "dash space", "- item\n")

# --- shape: which node did the line become? ---------------------------------
expectCount(g, "a switch is a switch", "--path:\"x\"\n", "switch", 1)
expectCount(g, "a switch is not an entry", "--path:\"x\"\n", "entry", 0)
expectCount(g, "an assignment is an entry", "path = \"x\"\n", "entry", 1)
expectCount(g, "an assignment is not a switch", "path = \"x\"\n", "switch", 0)
expectCount(g, "a short switch is a switch", "-d:release\n", "switch", 1)
expectCount(g, "a header opens a section", "[a]\n", "section", 1)
expectCount(g, "a header is not an entry", "[a]\n", "entry", 0)
expectCount(g, "entries nest under their section", "[a]\nk = 1\nj = 2\n",
  "entry", 2)
expectCount(g, "two headers, two sections", "[a]\nk = 1\n[b]\nk = 2\n",
  "section", 2)
expectCount(g, "sections do not nest", "[a]\n[b]\n", "section", 2)
expectNesting(g, "and really do not nest", "[a]\nk=1\n[b]\nk=2\n", "section", 1)
expectCount(g, "a conditional is a cond", "@if windows:\n", "cond", 1)
expectCount(g, "@end too", "@end\n", "cond", 1)
expectCount(g, "a comment line is no node", "# hi\n", "entry", 0)
expectCount(g, "a hash inside quotes does not end the value",
  "--passC:\"-DX=#1\"\n", "comment", 0)
expectCount(g, "a real trailing comment is one comment",
  "path = \"x\" # why\n", "comment", 1)
expectCount(g, "an unclosed bracket is not a section", "[oops\n", "section", 0)
expectCount(g, "a bare word is a line", "refc\n", "line", 1)
expectCount(g, "a bare word is not an entry", "refc\n", "entry", 0)
expectCount(g, "the colon of a switch is one op", "-d:release\n", "op", 1)
expectCount(g, "a value colon does not add an op", "path = \"a:b\"\n", "op", 1)

# --- files named on the command line ----------------------------------------
let cli = commandLineParams()
for ci in 0 ..< cli.len:
  let path = cli[ci]
  var src = ""
  var ok = true
  try:
    src = readFile(path)
  except:
    ok = false
  if ok:
    roundTrip(g, path, src)
  else:
    failUnreadable(g, path)

var fuzzBudget = 3
if cli.len > fuzzBudget:
  echo "note: truncation fuzz limited to the first ", fuzzBudget, " of ",
       cli.len, " files"
for ci in 0 ..< cli.len:
  if ci >= fuzzBudget: break
  let path = cli[ci]
  var src = ""
  var ok = true
  try:
    src = readFile(path)
  except:
    ok = false
  if ok:
    fuzzTruncations(g, "truncations of " & path, src)

quit report(g)
