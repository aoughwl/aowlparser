## tgate.nim — the `yaml-parsed` acceptance gate.
##
## Shape assertions concentrate on BLOCK SCALARS, which are YAML's version of
## Markdown's fenced code and HTML's raw text: after `script: |` the indented
## lines are literal text that routinely looks like `- items`, `key: values` and
## `# comments`. Reading them as structure is byte-exact and completely wrong,
## so only a shape check can see it. Multi-line flow collections and `#` inside
## a quoted scalar are the same trap, smaller.

import "../../src/yamlparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = yamlToAif(src)

var g = initGate("yaml", yamlDialect(), parse)
checkSpec(g)

# --- round-trip ------------------------------------------------------------
roundTrip(g, "empty", "")
roundTrip(g, "one entry", "key: value\n")
roundTrip(g, "no final newline", "key: value")
roundTrip(g, "crlf", "a: 1\r\nb: 2\r\n")
roundTrip(g, "nested mapping", "a:\n  b: 1\n  c: 2\n")
roundTrip(g, "deep nesting", "a:\n  b:\n    c:\n      d: 1\n")
roundTrip(g, "sequence", "- one\n- two\n")
roundTrip(g, "sequence of mappings", "- name: a\n  id: 1\n- name: b\n  id: 2\n")
roundTrip(g, "mapping of sequences", "list:\n  - a\n  - b\n")
roundTrip(g, "empty item", "-\n- x\n")
roundTrip(g, "comment line", "# a comment\nkey: 1\n")
roundTrip(g, "trailing comment", "key: 1  # why\n")
roundTrip(g, "comment inside a quoted scalar", "key: \"a # b\"\n")
roundTrip(g, "hash without space is not a comment", "key: a#b\n")
roundTrip(g, "blank lines", "a: 1\n\n\nb: 2\n")
roundTrip(g, "trailing spaces on a blank line", "a: 1\n   \nb: 2\n")
roundTrip(g, "document start", "---\na: 1\n")
roundTrip(g, "two documents", "---\na: 1\n---\nb: 2\n")
roundTrip(g, "document end", "---\na: 1\n...\n")
roundTrip(g, "directive-ish line", "%YAML 1.2\n---\na: 1\n")
roundTrip(g, "block scalar literal", "s: |\n  line one\n  line two\n")
roundTrip(g, "block scalar folded", "s: >\n  wrapped\n  text\n")
roundTrip(g, "block scalar chomped", "s: |-\n  x\n")
roundTrip(g, "block scalar indented indicator", "s: |2\n   x\n")
roundTrip(g, "block scalar with blank line inside", "s: |\n  a\n\n  b\nt: 1\n")
roundTrip(g, "flow mapping", "a: {x: 1, y: 2}\n")
roundTrip(g, "flow sequence", "a: [1, 2, 3]\n")
roundTrip(g, "multi-line flow", "a: [\n  1,\n  2,\n]\nb: 2\n")
roundTrip(g, "compact nesting", "- key: value\n")
roundTrip(g, "nested sequence marker", "- - a\n")
roundTrip(g, "quoted key", "\"a b\": 1\n")
roundTrip(g, "url value keeps one key", "url: http://example.com/x\n")
roundTrip(g, "anchor and alias", "a: &anc 1\nb: *anc\n")
roundTrip(g, "explicit tag", "a: !!str 1\n")
roundTrip(g, "utf8", "caf\xc3\xa9: \xe2\x9c\x93\n")
roundTrip(g, "tab-indented line", "a:\n\tb: 1\n")
roundTrip(g, "empty value", "a:\n")
roundTrip(g, "colon at end of a quoted key", "\"a:\": 1\n")

# --- malformed / partial ---------------------------------------------------
roundTrip(g, "unterminated quote", "a: \"oops\n")
roundTrip(g, "unclosed flow", "a: [1, 2\n")
roundTrip(g, "unclosed block scalar", "s: |\n  only\n")
roundTrip(g, "lone dash", "-")
roundTrip(g, "lone colon", ":")
roundTrip(g, "only comments", "# a\n# b\n")
roundTrip(g, "only blank lines", "\n\n\n")
roundTrip(g, "dedent past every level", "a:\n    b: 1\n  c: 2\nd: 3\n")

# --- shape: a block scalar's content is NOT yaml ---------------------------
expectCount(g, "block scalar content is not an item",
  "s: |\n  - not an item\n", "item", 0)
expectCount(g, "block scalar content is not an entry",
  "s: |\n  key: not an entry\n", "entry", 1)
expectCount(g, "block scalar content is not a comment",
  "s: |\n  # not a comment\n", "comment", 0)
expectCount(g, "the block scalar is one scalar node",
  "s: |\n  a\n  b\n", "scalar", 1)
expectCount(g, "a real entry after the scalar is found",
  "s: |\n  key: fake\nreal: 1\n", "entry", 2)
expectCount(g, "a folded scalar swallows too",
  "s: >\n  - no\n", "item", 0)

# --- shape: flow collections ------------------------------------------------
# A flow collection is parsed, not swallowed: `{a: 1}` is an entry exactly as
# `a: 1` is, which is what lets a consumer ask "what are the mapping entries?"
# without caring which syntax was used.
expectCount(g, "a flow sequence is one flow node", "a: [1, 2]\n", "flow", 1)
expectCount(g, "its elements are items", "a: [1, 2]\n", "item", 2)
expectCount(g, "a flow mapping's pairs are entries", "a: {x: 1, y: 2}\n",
  "entry", 3)
expectCount(g, "a multi-line flow is still one flow", "a: [\n  1,\n  2,\n]\n",
  "flow", 1)
expectCount(g, "a dash inside a flow is a scalar, not a block marker",
  "a: [\n  - x,\n]\n", "marker", 0)
expectCount(g, "one element even so", "a: [\n  - x,\n]\n", "item", 1)
expectCount(g, "nested flow nests", "a: [[1], [2]]\n", "flow", 3)
expectNesting(g, "nesting depth is two", "a: [[1]]\n", "flow", 2)
expectCount(g, "a colon inside a flow scalar does not make an entry",
  "a: [\"x: y\"]\n", "entry", 1)
expectCount(g, "a bracket in a plain scalar is not a flow",
  "note: see [1] below\n", "flow", 0)
expectCount(g, "an unclosed flow is still one flow", "a: [1, 2\n", "flow", 1)
expectCount(g, "a flow value under a key is that key's entry",
  "a: {x: 1}\nb: 2\n", "entry", 3)

# --- shape: quoting and comments ------------------------------------------
expectCount(g, "a hash inside quotes is not a comment",
  "key: \"a # b\"\n", "comment", 0)
expectCount(g, "a real trailing comment is one comment",
  "key: 1 # why\n", "comment", 1)
expectCount(g, "a colon inside a quoted key does not split it",
  "\"a:b\": 1\n", "entry", 1)

# --- shape: block structure ------------------------------------------------
expectCount(g, "two entries", "a: 1\nb: 2\n", "entry", 2)
expectCount(g, "three items", "- a\n- b\n- c\n", "item", 3)
expectCount(g, "nesting opens one block", "a:\n  b: 1\n", "block", 1)
expectCount(g, "siblings share one block", "a:\n  b: 1\n  c: 2\n", "block", 1)
expectNesting(g, "three levels nest three deep",
  "a:\n  b:\n    c: 1\n", "block", 2)
expectCount(g, "compact nesting is an item holding an entry",
  "- key: value\n", "entry", 1)
expectCount(g, "two documents", "---\na: 1\n---\nb: 2\n", "doc", 2)
expectCount(g, "an implicit document is still a document", "a: 1\n", "doc", 1)

# Document counting, pinned against the yaml-test-suite's event streams (see
# tests/yaml/tsuite.nim). Every one of these was WRONG when this dialect first
# passed its own round-trip and shape gates — a directive read as content, and a
# `...` opening the document it was supposed to be ending.
expectCount(g, "a directive is not a document", "%YAML 1.2\n--- text\n", "doc", 1)
expectCount(g, "a directive is a directive", "%YAML 1.2\n--- text\n", "directive", 1)
expectCount(g, "a lone document end is zero documents", "...\n", "doc", 0)
expectCount(g, "comment then document end is zero documents",
  "# c\n...\n", "doc", 0)
expectCount(g, "directive, doc, end, directive, doc",
  "%TAG !m! !my-\n--- a\n...\n%TAG !m! !my-\n--- b\n", "doc", 2)
expectCount(g, "two directives", "%TAG !m! !my-\n--- a\n...\n%TAG !m! !my-\n--- b\n",
  "directive", 2)
roundTrip(g, "directive with comment", "%FOO bar # ignored\n---\n\"x\"\n")
roundTrip(g, "lone document end", "...\n")
roundTrip(g, "percent inside a document is content", "---\na: 100%\n")

# A TAB separates a key from its value just as a space does. YAML bans tabs for
# INDENTATION, a different rule, and conflating the two made these no mapping at
# all — found by the suite oracle (6BCT, DC7X), invisible to the round-trip.
expectCount(g, "tab after the colon still makes an entry", "a:\tb\n", "entry", 1)
expectCount(g, "tab after a dash still makes an item", "-\tb\n", "item", 1)
expectCount(g, "tab-separated entry inside an item", "- foo:\tbar\n", "entry", 1)
roundTrip(g, "tab after the colon", "a:\tb\nseq:\t\n - a\t\nc: d\t#X\n")
expectCount(g, "-1 is a value, not a marker", "a: -1\n", "item", 0)
expectCount(g, "a url is one entry", "url: http://x/y\n", "entry", 1)

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
