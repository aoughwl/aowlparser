## tstructure.nim — the gate the round-trip gate CANNOT be.
##
## WHY THIS FILE EXISTS
## --------------------
## Byte-exact round-trip proves the renderer inverts the parser. It proves
## NOTHING about whether the tree is right, because every token's bytes survive
## no matter which node they end up in.
##
## Measured, not assumed: disabling raw-text mode entirely — so `<script>`
## content is tokenized as markup and a `<div>` inside a JavaScript string
## becomes an element — left tests/html/troundtrip.nim at 44/44 PASS. The tree
## was badly wrong and the round-trip gate could not see it.
##
## So this file asserts SHAPE: what nodes exist, how many, and how they nest.
## Every assertion here is one a byte-comparison is structurally blind to.

import "../../src/htmlparser.nim"
import "../../src/aifread.nim"
import std/syncio

var failures = 0
var checked = 0

proc countTag(aif, tag: string): int =
  ## Count `(tag` occurrences at any depth, via the shared reader — not a
  ## substring scan, which would also match the tag name inside a string literal.
  result = 0
  var r = AifReader(src: aif, pos: 0)
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    if n.kind == akParLe and n.tag == tag:
      result = result + 1

proc expectCount(name, src, tag: string; want: int) =
  checked = checked + 1
  let got = countTag(htmlToAif(src), tag)
  if got != want:
    failures = failures + 1
    echo "FAIL ", name, ": expected ", want, " (", tag, ") node(s), got ", got

proc maxDepthOf(aif, tag: string): int =
  ## Deepest nesting of `tag` within itself.
  result = 0
  var cur = 0
  var r = AifReader(src: aif, pos: 0)
  var stack: seq[bool] = @[]
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    if n.kind == akParLe:
      let isIt = n.tag == tag
      stack.add isIt
      if isIt:
        cur = cur + 1
        if cur > result: result = cur
    elif n.kind == akParRi:
      if stack.len > 0:
        let wasIt = stack.pop()
        if wasIt: cur = cur - 1

proc expectDepth(name, src, tag: string; want: int) =
  checked = checked + 1
  let got = maxDepthOf(htmlToAif(src), tag)
  if got != want:
    failures = failures + 1
    echo "FAIL ", name, ": expected (", tag, ") nesting depth ", want,
         ", got ", got

# --- raw-text elements: the property the round-trip gate is blind to -------
# Markup-looking content inside script/style/textarea/title must produce NO
# elements. If raw-text mode regresses, these go red while round-trip stays green.
expectCount "script content is not markup",
  "<script>var x = \"<div>\"; if (a<b) {}</script>", "elem", 1
expectCount "script content is one text node",
  "<script>var x = \"<div><span>\";</script>", "text", 1
expectCount "style content is not markup",
  "<style>a{content:\"<p>\"}</style>", "elem", 1
expectCount "textarea content is not markup",
  "<textarea><p>not markup</p></textarea>", "elem", 1
expectCount "title content is not markup",
  "<title>a<b</title>", "elem", 1
expectCount "script does not swallow the rest of the document",
  "<script>x</script><p>after</p>", "elem", 2
expectCount "self-closed script does not swallow the document",
  "<script/><p>after</p>", "elem", 2

# --- element identification -------------------------------------------------
expectCount "two siblings", "<p>a</p><p>b</p>", "elem", 2
expectCount "void element is an element", "<br>", "elem", 1
expectCount "text nodes counted", "<p>a</p>", "text", 1
expectCount "comment is not an element", "<!-- <div> -->", "elem", 0
expectCount "doctype is not an element", "<!DOCTYPE html>", "elem", 0
expectCount "bare lt is text not element", "a < b", "elem", 0
expectCount "cdata is not an element", "<![CDATA[<div>]]>", "elem", 0

# --- nesting ----------------------------------------------------------------
expectDepth "flat siblings do not nest", "<p>a</p><p>b</p>", "elem", 1
expectDepth "three deep", "<div><div><div>x</div></div></div>", "elem", 3
expectDepth "void does not nest children", "<div><br><br></div>", "elem", 2
expectDepth "mismatched close still closes", "<div><span>x</div>", "elem", 2
expectCount "stray end tag is recorded", "</div>", "etag", 1
expectCount "omitted end tags: two list items", "<ul><li>a<li>b</ul>", "elem", 3

# --- attributes -------------------------------------------------------------
expectCount "three attributes", "<a x=\"1\" y='2' z=3>t</a>", "attr", 3
expectCount "valueless attribute", "<input disabled>", "attr", 1
expectCount "valueless attribute has no value node", "<input disabled>", "aval", 0
expectCount "quoted value is one node", "<a href=\"a b c\">t</a>", "aval", 1
expectCount "value with '>' inside quotes stays one attr",
  "<a title=\"a > b\">t</a>", "attr", 1
expectCount "value with '>' inside quotes yields one element",
  "<a title=\"a > b\">t</a>", "elem", 1

echo "html structure: ", checked - failures, "/", checked, " ok"
if failures > 0:
  quit 1
