## tgate.nim — the `vds-parsed` acceptance gate.
##
## Round-trip over MDN's own 1,224 published grammar strings, plus shape
## assertions on the thing byte-exactness cannot see: whether the COMBINATOR
## PRECEDENCE tree is right. `a | b && c` parsed as `(a | b) && c` preserves
## every byte and means the opposite of the truth.

import "../../src/vdsparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = vdsToAif(src)

var g = initGate("vds", vdsDialect(), parse)
checkSpec(g)

# --- round-trip: the VDS surface ------------------------------------------
roundTrip(g, "empty", "")
roundTrip(g, "single keyword", "auto")
roundTrip(g, "single type", "<length>")
roundTrip(g, "property reference", "<'margin-top'>")
roundTrip(g, "alternation", "false | true")
roundTrip(g, "range in type", "<length [0,\xe2\x88\x9e]>")
roundTrip(g, "multiplier braces", "<'margin-top'>{1,4}")
roundTrip(g, "open range", "<length>{1,}")
roundTrip(g, "hash multiplier", "<length>#")
roundTrip(g, "hash with range", "<length>#{1,4}")
roundTrip(g, "optional", "<color>?")
roundTrip(g, "star and plus", "<a>* <b>+")
roundTrip(g, "bang", "<a>!")
roundTrip(g, "group", "[ <a> | <b> ]")
roundTrip(g, "double bar", "<a> || <b>")
roundTrip(g, "double amp", "<a> && <b>")
roundTrip(g, "function", "abs( <calc-sum> )")
roundTrip(g, "nested function", "clamp( <a>, minmax( <b>, <c> ), <d> )")
roundTrip(g, "slash literal", "<length-percentage>{1,4} [ / <length-percentage>{1,4} ]?")
roundTrip(g, "quoted literal plus", "[ '+' | '-' ] <a>")
roundTrip(g, "string literal", "@charset \"<charset>\";")
roundTrip(g, "at rule with block", "@media <query> {\n  <rule-list>\n}")
roundTrip(g, "selector-ish", ".class")
roundTrip(g, "pseudo", "::before")
roundTrip(g, "mixed precedence", "<a> | <b> && <c> || <d> <e>")
roundTrip(g, "deep nesting", "[ [ [ <a> ] ] ]")
roundTrip(g, "comma literal", "rgb( <r> , <g> , <b> )")
roundTrip(g, "extra whitespace", "  <a>   |   <b>  ")

# --- malformed must round-trip too ----------------------------------------
roundTrip(g, "unclosed group", "[ <a> | <b>")
roundTrip(g, "unclosed angle", "<length")
roundTrip(g, "stray close", "<a> ]")
roundTrip(g, "trailing bar", "<a> |")
roundTrip(g, "leading bar", "| <a>")
roundTrip(g, "orphan multiplier", "? <a>")
roundTrip(g, "unclosed function", "abs( <a>")
roundTrip(g, "garbage", "%%% $$$")

# --- shape: combinator PRECEDENCE, invisible to a byte comparison ----------
# `|` is loosest, so it must be the OUTERMOST node. Parsing this as
# `(a | b) && c` keeps every byte and inverts the meaning.
expectCount(g, "alt is outermost over amp", "<a> | <b> && <c>", "alt", 1)
expectCount(g, "amp nests inside alt", "<a> | <b> && <c>", "all", 1)
expectNesting(g, "alt does not nest itself", "<a> | <b> | <c>", "alt", 1)
expectCount(g, "three-way alt is ONE node", "<a> | <b> | <c>", "alt", 1)
expectCount(g, "bar-bar is any not alt", "<a> || <b>", "any", 1)
expectCount(g, "bar-bar is not alt", "<a> || <b>", "alt", 0)
expectCount(g, "single bar is alt not any", "<a> | <b>", "any", 0)
expectCount(g, "juxtaposition is tightest", "<a> | <b> <c>", "juxta", 1)

# No singleton wrappers: `auto` must not become four nested combinators.
expectCount(g, "lone keyword has no alt", "auto", "alt", 0)
expectCount(g, "lone keyword has no juxta", "auto", "juxta", 0)
expectCount(g, "lone keyword has no comp", "auto", "comp", 0)
expectCount(g, "lone keyword is one kw", "auto", "kw", 1)

# Grouping and multipliers.
expectCount(g, "group is a group", "[ <a> | <b> ]", "group", 1)
expectCount(g, "group contains the alt", "[ <a> | <b> ]", "alt", 1)
expectNesting(g, "nested groups nest", "[ [ [ <a> ] ] ]", "group", 3)
expectCount(g, "multiplier makes a comp", "<a>?", "comp", 1)
expectCount(g, "range makes a comp", "<a>{1,4}", "comp", 1)
expectCount(g, "range is one token", "<a>{1,4}", "range", 1)
expectCount(g, "function is a fn", "abs( <a> )", "fn", 1)
expectCount(g, "nested fn", "clamp( <a>, min( <b> ), <c> )", "fn", 2)

# The `+`/`*` positional ambiguity: multiplier after a component, literal before.
expectCount(g, "plus after component is a multiplier", "<a>+", "mult", 1)
expectCount(g, "quoted plus is a literal not a multiplier", "'+'", "mult", 0)
expectCount(g, "quoted plus is a string", "'+'", "str", 1)

# The `{` ambiguity: range multiplier vs literal brace block.
expectCount(g, "brace range is not a block", "<a>{1,4}", "block", 0)
expectCount(g, "literal brace is a block", "@media <q> { <rule-list> }", "block", 1)
expectCount(g, "literal brace block has no range", "@media <q> { <r> }", "range", 0)

# Property references are distinct from type references.
expectCount(g, "propref is not a type", "<'margin-top'>", "type", 0)
expectCount(g, "propref is a propref", "<'margin-top'>", "propref", 1)
expectCount(g, "type with a range is one type", "<length [0,\xe2\x88\x9e]>", "type", 1)

# --- the MDN corpus --------------------------------------------------------
# Length-prefixed records ("<n>\n<n bytes>\n"), because 19 of MDN's grammars
# contain newlines and a line-per-entry format would silently split them.
proc runCorpus(path: string) =
  var blob = ""
  try:
    blob = readFile(path)
  except:
    echo "note: no MDN corpus at ", path, " (skipped)"
    return
  var i = 0
  var n = 0
  while i < blob.len:
    var lenStr = ""
    while i < blob.len and blob[i] != '\n':
      lenStr.add blob[i]
      i = i + 1
    i = i + 1                       # the newline
    if lenStr.len == 0: break
    var count = 0
    var ok = true
    for c in lenStr.items:
      if c >= '0' and c <= '9': count = count * 10 + (int(c) - int('0'))
      else: ok = false
    if not ok: break
    var s = ""
    var k = 0
    while k < count and i < blob.len:
      s.add blob[i]
      i = i + 1
      k = k + 1
    i = i + 1                       # the trailing newline
    n = n + 1
    roundTrip(g, "mdn#" & $n, s)
  echo "MDN corpus: ", n, " grammar strings checked"

let cli = commandLineParams()
if cli.len > 0:
  for ci in 0 ..< cli.len:
    runCorpus(cli[ci])
else:
  runCorpus("corpus/mdn.vdscorpus")

quit report(g)
