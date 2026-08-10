## troundtrip.nim — the HTML byte-exact round-trip gate.
##
##   renderHtml(htmlToAif(s)) == s
##
## for the inline cases below plus every file named on the command line, plus a
## truncation fuzz over those files.

import "../../src/htmlparser.nim"
import std/[syncio, os]

var failures = 0
var checked = 0

proc firstDiff(a, b: string): int =
  var i = 0
  while i < a.len and i < b.len:
    if a[i] != b[i]: return i
    i = i + 1
  if a.len != b.len: return i
  return -1

proc excerpt(s: string; at, span: int): string =
  result = ""
  var i = at - span
  if i < 0: i = 0
  var e = at + span
  if e > s.len: e = s.len
  while i < e:
    let c = s[i]
    if c == '\n': result.add "\\n"
    elif c == '\t': result.add "\\t"
    else: result.add c
    i = i + 1

proc check(name, src: string) =
  checked = checked + 1
  let back = renderHtml(htmlToAif(src))
  if back != src:
    failures = failures + 1
    let d = firstDiff(src, back)
    echo "FAIL ", name, "  (first difference at byte ", d, ")"
    echo "  want: ", excerpt(src, d, 30)
    echo "  got : ", excerpt(back, d, 30)

check "empty", ""
check "text only", "hello world"
check "simple", "<p>hi</p>"
check "nested", "<div><p>a</p><p>b</p></div>"
check "doctype", "<!DOCTYPE html>\n<html><body>x</body></html>\n"
check "comment", "<!-- a comment --><p>x</p>"
check "attr double quotes", "<a href=\"x\">y</a>"
check "attr single quotes", "<a href='x'>y</a>"
check "attr unquoted", "<a href=x>y</a>"
check "attr valueless", "<input disabled>"
check "attr spaced eq", "<a href = \"x\" >y</a>"
check "tag case", "<DIV ID=x>y</DIV>"
check "void br", "<br>"
check "void self-closed", "<br/>"
check "void spaced self-close", "<br />"
check "entities", "<p>a &amp; b &#38; c &nope; d</p>"
check "bare ampersand", "<p>a & b</p>"
check "script with markup inside", "<script>var x = \"<div>\"; if (a<b) {}</script>"
check "style with braces", "<style>a{color:red}</style>"
check "textarea raw", "<textarea><p>not markup</p></textarea>"
check "title raw", "<title>a<b</title>"
check "omitted end tags", "<ul><li>a<li>b</ul>"
check "utf8 text", "<p>caf\xc3\xa9 \xe2\x9c\x93</p>"
check "crlf", "<p>a</p>\r\n<p>b</p>\r\n"
check "whitespace preserved", "<div>\n  <p> a </p>\n</div>\n"
check "cdata", "<![CDATA[ raw <stuff> ]]>"
check "processing instruction", "<?xml version=\"1.0\"?><a/>"
check "namespaced attr", "<svg xmlns:xlink=\"u\"><use xlink:href=\"#a\"/></svg>"
check "data attrs", "<div data-x=\"1\" data-y='2' data-z=3></div>"
check "nested same tag", "<div><div><div>x</div></div></div>"

# --- malformed input must round-trip too -----------------------------------
check "unclosed tag at eof", "<div"
check "unclosed element", "<div><p>x"
check "stray end tag", "</div>"
check "mismatched close", "<div><span>x</div>"
check "bare lt", "a < b"
check "lt then eof", "<"
check "empty tag name", "<>"
check "attr no value", "<a href=>x</a>"
check "unterminated comment", "<!-- never closed"
check "unterminated string attr", "<a href=\"x>y"
check "unterminated script", "<script>var a = 1;"
check "garbage", "<<<>>>"

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
    check path, src
  else:
    failures = failures + 1
    checked = checked + 1
    echo "FAIL ", path, "  (could not be read)"

# --- truncation fuzz -------------------------------------------------------
proc fuzzTruncations(label, src: string; step: int) =
  var n = 0
  var bad = 0
  while n <= src.len:
    var prefix = ""
    var i = 0
    while i < n:
      prefix.add src[i]
      i = i + 1
    if renderHtml(htmlToAif(prefix)) != prefix:
      bad = bad + 1
      if bad <= 3:
        echo "FAIL truncation ", label, " at length ", n
    n = n + step
  checked = checked + 1
  if bad > 0:
    failures = failures + 1
    echo "FAIL ", label, ": ", bad, " truncations did not round-trip"

# Fuzzing is O(n^2) in file size, so it runs over the first few files only —
# enough to reach the error paths, bounded so a wide corpus sweep stays fast.
# The bound is stated out loud rather than left as a silent truncation.
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
    fuzzTruncations("truncations of " & path, src, 397)

echo "html round-trip: ", checked - failures, "/", checked, " byte-exact"
if failures > 0:
  quit 1
