## tgate.nim — the `md-parsed` acceptance gate.
##
## Shape assertions concentrate on FENCED CODE, which is Markdown's version of
## HTML's raw-text problem: a ``` block can contain `# heading` and `- list`, and
## treating those as structure gives a nonsense tree that a byte comparison
## cannot distinguish from a correct one.

import "../../src/mdparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = mdToAif(src)

var g = initGate("md", mdDialect(), parse)
checkSpec(g)

# --- round-trip ------------------------------------------------------------
roundTrip(g, "empty", "")
roundTrip(g, "one paragraph", "hello world\n")
roundTrip(g, "no final newline", "hello")
roundTrip(g, "heading", "# Title\n")
roundTrip(g, "all heading levels", "# a\n## b\n### c\n#### d\n##### e\n###### f\n")
roundTrip(g, "heading then para", "# Title\n\nsome text\n")
roundTrip(g, "setext-ish underline stays text", "Title\n=====\n")
roundTrip(g, "bullet list", "- one\n- two\n")
roundTrip(g, "star list", "* one\n* two\n")
roundTrip(g, "ordered list", "1. one\n2. two\n")
roundTrip(g, "paren ordered list", "1) one\n2) two\n")
roundTrip(g, "list with continuation", "- one\n  more\n- two\n")
roundTrip(g, "block quote", "> quoted\n> more\n")
roundTrip(g, "fenced code", "```\ncode\n```\n")
roundTrip(g, "fenced with info", "```nim\nlet x = 1\n```\n")
roundTrip(g, "tilde fence", "~~~\ncode\n~~~\n")
roundTrip(g, "fence containing markdown", "```\n# not a heading\n- not a list\n```\n")
roundTrip(g, "fence containing a shorter fence", "````\n```\ninner\n```\n````\n")
roundTrip(g, "indented fence", "  ```\n  code\n  ```\n")
roundTrip(g, "blank lines preserved", "a\n\n\n\nb\n")
roundTrip(g, "trailing spaces on blank line", "a\n   \nb\n")
roundTrip(g, "hard break trailing spaces", "line  \nnext\n")
roundTrip(g, "crlf", "# Title\r\n\r\ntext\r\n")
roundTrip(g, "tabs", "\tindented\n")
roundTrip(g, "utf8", "# caf\xc3\xa9 \xe2\x9c\x93\n")
roundTrip(g, "table", "| a | b |\n|---|---|\n| 1 | 2 |\n")
roundTrip(g, "html block passthrough", "<div>\n  raw\n</div>\n")
roundTrip(g, "link and emphasis stay text", "see [a](b) and *em* and `code`\n")
roundTrip(g, "hash without space is text", "#nothashtag\n")

# --- malformed -------------------------------------------------------------
roundTrip(g, "unclosed fence", "```\ncode never closed\n")
roundTrip(g, "unclosed fence with info", "```nim\nlet x = 1\n")
roundTrip(g, "seven hashes is text", "####### too many\n")
roundTrip(g, "lone fence marker", "```")
roundTrip(g, "only blank lines", "\n\n\n")
roundTrip(g, "bare dash", "-\n")

# --- shape: fenced code is NOT markdown ------------------------------------
expectCount(g, "fence content is not a heading",
  "```\n# not a heading\n```\n", "heading", 0)
expectCount(g, "fence content is not a list",
  "```\n- not a list\n```\n", "list", 0)
expectCount(g, "fence content is not a quote",
  "```\n> not a quote\n```\n", "quote", 0)
expectCount(g, "the fence itself is one fence",
  "```\n# x\n- y\n```\n", "fence", 1)
expectCount(g, "a real heading outside the fence is found",
  "# real\n```\n# fake\n```\n", "heading", 1)
expectCount(g, "longer fence swallows a shorter one",
  "````\n```\ninner\n```\n````\n", "fence", 1)

# --- shape: block structure ------------------------------------------------
expectCount(g, "three headings", "# a\n## b\n### c\n", "heading", 3)
expectCount(g, "one list, two items", "- a\n- b\n", "list", 1)
expectCount(g, "two items", "- a\n- b\n", "item", 2)
expectCount(g, "blank line separates paragraphs", "a\n\nb\n", "para", 2)
expectCount(g, "adjacent lines are one paragraph", "a\nb\n", "para", 1)
expectCount(g, "quote is one quote", "> a\n> b\n", "quote", 1)
expectCount(g, "heading is not a paragraph", "# a\n", "para", 0)
expectCount(g, "hash without a space is a paragraph", "#nope\n", "heading", 0)
expectCount(g, "seven hashes is not a heading", "####### x\n", "heading", 0)
expectCount(g, "info string captured", "```nim\nx\n```\n", "info", 1)
expectCount(g, "bare fence has no info", "```\nx\n```\n", "info", 0)

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
