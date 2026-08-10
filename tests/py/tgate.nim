## tgate.nim — the `py-parsed` acceptance gate.
##
## Uses the shared harness in src/aowlparse/gate.nim, so this file contains only
## what is Python-specific: the cases and the shape assertions.
##
## Shape assertions are here from the START, not added after a falsification
## probe came back green. The HTML dialect learned that the hard way: byte-exact
## round-trip cannot see a wrong tree, so a dialect whose only gate is round-trip
## has no way to detect that its structure is nonsense.

import "../../src/pyparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = pyToAif(src)

var g = initGate("py", pyDialect(), parse)
checkSpec(g)

# --- round-trip: the byte-exactness checklist ------------------------------
roundTrip(g, "empty", "")
roundTrip(g, "one statement", "x = 1\n")
roundTrip(g, "no final newline", "x = 1")
roundTrip(g, "simple def", "def f():\n    return 1\n")
roundTrip(g, "nested blocks", "def f():\n    if x:\n        return 1\n    return 2\n")
roundTrip(g, "tabs for indent", "def f():\n\treturn 1\n")
roundTrip(g, "mixed blank lines", "def f():\n\n    return 1\n\n\nx = 2\n")
roundTrip(g, "comments", "# top\nx = 1  # trailing\n# end\n")
roundTrip(g, "comment only file", "# just a comment\n")
roundTrip(g, "crlf", "x = 1\r\ny = 2\r\n")
roundTrip(g, "implicit line join", "x = [\n  1,\n  2,\n]\n")
roundTrip(g, "implicit join in call", "f(\n  a,\n  b\n)\n")
roundTrip(g, "explicit line join", "x = 1 + \\\n    2\n")
roundTrip(g, "triple quoted", "x = \"\"\"a\nb\nc\"\"\"\n")
roundTrip(g, "docstring", "def f():\n    '''doc\n    more\n    '''\n    pass\n")
roundTrip(g, "f-string", "x = f\"{a} and {b!r:>10}\"\n")
roundTrip(g, "raw string with quote", "x = r\"\\\"\"\n")
roundTrip(g, "byte string", "x = rb'\\x00'\n")
roundTrip(g, "string prefix case", "x = RB'a'\nY = F'b'\n")
roundTrip(g, "numbers", "a = 0x1F\nb = 0o17\nc = 0b1010\nd = 1_000\ne = 1.5e-3\nf = 3j\ng = .5\n")
roundTrip(g, "walrus and arrow", "def f(x) -> int:\n    if (n := x) > 1:\n        return n\n")
roundTrip(g, "decorators", "@dec\n@dec2(arg)\ndef f():\n    pass\n")
roundTrip(g, "class", "class A(B):\n    def m(self):\n        pass\n")
roundTrip(g, "async", "async def f():\n    await g()\n")
roundTrip(g, "match statement", "match x:\n    case 1:\n        pass\n    case _:\n        pass\n")
roundTrip(g, "lambda and slicing", "f = lambda a, b=1, *c, **d: a[1:2, ::3]\n")
roundTrip(g, "semicolons", "x = 1; y = 2\n")
roundTrip(g, "deep dedent", "if a:\n    if b:\n        if c:\n            x = 1\ny = 2\n")
roundTrip(g, "trailing whitespace", "x = 1   \n   \ny = 2\n")
roundTrip(g, "utf8 identifiers", "caf\xc3\xa9 = '\xe2\x9c\x93'\n")
roundTrip(g, "ellipsis", "def f(): ...\n")

# --- malformed input must round-trip too -----------------------------------
roundTrip(g, "unterminated string", "x = 'oops\n")
roundTrip(g, "unterminated triple", "x = '''oops\n")
roundTrip(g, "unclosed bracket", "x = [1, 2\n")
roundTrip(g, "unexpected indent", "x = 1\n    y = 2\n")
roundTrip(g, "dedent to nowhere", "def f():\n        x = 1\n  y = 2\n")
roundTrip(g, "stray backslash", "x = \\\n")
roundTrip(g, "garbage bytes", "x = 1 $ ? `\n")
roundTrip(g, "only whitespace", "   \n\t\n")

# --- shape: the assertions byte-comparison is blind to ---------------------
# Blank lines must NOT close a block. If they did, every file with an empty line
# inside a function would produce a flat tree while staying byte-exact.
expectCount(g, "blank line does not close a block",
  "def f():\n    a = 1\n\n    b = 2\n", "block", 1)
expectCount(g, "blank line keeps both statements in the block",
  "def f():\n    a = 1\n\n    b = 2\n", "stmt", 3)
expectCount(g, "comment line does not close a block",
  "def f():\n    a = 1\n# c\n    b = 2\n", "block", 1)

# Implicit line joining: a bracketed newline is not a statement terminator, so
# this is ONE statement, not four.
expectCount(g, "implicit join is one statement",
  "x = [\n  1,\n  2,\n]\n", "stmt", 1)
expectCount(g, "explicit join is one statement",
  "x = 1 + \\\n    2\n", "stmt", 1)
expectCount(g, "multi-line string is one statement",
  "x = \"\"\"a\nb\nc\"\"\"\n", "stmt", 1)
expectCount(g, "two plain lines are two statements", "a = 1\nb = 2\n", "stmt", 2)

# Nesting follows indentation.
expectNesting(g, "three nested suites",
  "if a:\n    if b:\n        if c:\n            x = 1\n", "block", 3)
expectNesting(g, "siblings do not nest",
  "if a:\n    x = 1\nif b:\n    y = 2\n", "block", 1)
expectCount(g, "dedent closes the inner suite",
  "if a:\n    if b:\n        x = 1\ny = 2\n", "block", 2)

# Tokenization: a '#' inside a string is not a comment; a keyword-looking
# attribute is not a keyword-only construct.
expectCount(g, "hash inside a string is not a comment",
  "x = '# not a comment'\n", "comment", 0)
expectCount(g, "real comment is one comment", "x = 1  # yes\n", "comment", 1)
expectCount(g, "def is a keyword", "def f():\n    pass\n", "kw", 2)
expectCount(g, "string with newline stays one token",
  "x = \"\"\"a\nb\"\"\"\n", "str", 1)

# --- files named on the command line ---------------------------------------
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
    echo "FAIL could not read ", path

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
