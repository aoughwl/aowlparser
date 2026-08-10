## troundtrip.nim — the CSS byte-exact round-trip gate.
##
##   renderCss(cssToAif(s)) == s
##
## for every inline case below plus every file named on the command line. Prints
## the first differing byte offset on failure, and exits non-zero.

import "../../src/cssparser.nim"
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
  let aif = cssToAif(src)
  let back = renderCss(aif)
  if back != src:
    failures = failures + 1
    let d = firstDiff(src, back)
    echo "FAIL ", name, "  (first difference at byte ", d, ")"
    echo "  want: ", excerpt(src, d, 30)
    echo "  got : ", excerpt(back, d, 30)

check "empty", ""
check "simple", "a{color:red}"
check "spaced", "a  {\n  color : red ;\n}\n"
check "no final newline", "a{b:c}"
check "comment", "/* hi */a{}"
check "unterminated comment", "a{}/* trailing"
check "case preserved", "A{COLOR:RED}"
check "number spellings", "a{x:.5;y:0.50;z:+1;w:1e3;v:-1.5e-3}"
check "dimensions", "a{margin:10px -2.5em 0 50%}"
check "single quotes", "a{content:'x'}"
check "escaped ident", "a{b:\\32 0}"
check "escape in selector", ".\\33 d{a:b}"
check "important spaced", "a{b:c ! IMPORTANT }"
check "atrule semi", "@import url(x);"
check "atrule block", "@media (min-width:10px){a{b:c}}"
check "nested calc", "a{b:calc((1 + 2) * 3)}"
check "hash colors", "a{color:#FFF;b:#aabbcc}"
check "crlf", "a{\r\n  b:c\r\n}\r\n"
check "utf8 ident", "\xc3\xa9lem{a:b}"
check "only whitespace", "   \n\t  \n"
check "no trailing semi", "a{b:c;d:e}"
check "attr selector", "a[href^='x']{b:c}"
check "font-face", "@font-face{font-family:'X';src:url(y.woff)}"
check "keyframes", "@keyframes s{from{opacity:0}to{opacity:1}}"
check "nesting", "a{color:red;&:hover{color:blue}}"
check "stray semis", "a{;;b:c;;}"
check "custom property", "a{--my-var: {weird} ;b:var(--my-var)}"

# --- malformed input must round-trip too -----------------------------------
check "unclosed block", "a{b:c"
check "unmatched close", "}a{b:c}"
check "missing colon", "a{bogus}"
check "bare garbage", "@#$%^&"
check "unterminated string", "a{content:\"oops"
check "atrule no terminator", "@media screen"
check "empty rule no brace", "a"

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
# Every prefix of a real stylesheet is malformed CSS of some shape: a severed
# comment, a half-written selector, an unclosed block, a value cut mid-token.
# All of them must still round-trip, because the recovery contract says `err`
# nodes keep the bytes. This is the cheapest way to reach the error paths that
# hand-written cases never think of.
proc fuzzTruncations(label, src: string; step: int) =
  var n = 0
  var bad = 0
  while n <= src.len:
    var prefix = ""
    var i = 0
    while i < n:
      prefix.add src[i]
      i = i + 1
    if renderCss(cssToAif(prefix)) != prefix:
      bad = bad + 1
      if bad <= 3:
        echo "FAIL truncation ", label, " at length ", n
    n = n + step
  checked = checked + 1
  if bad > 0:
    failures = failures + 1
    echo "FAIL ", label, ": ", bad, " truncations did not round-trip"

for ci in 0 ..< cli.len:
  let path = cli[ci]
  var src = ""
  var ok = true
  try:
    src = readFile(path)
  except:
    ok = false
  if ok:
    fuzzTruncations("truncations of " & path, src, 997)

echo "css round-trip: ", checked - failures, "/", checked, " byte-exact"
if failures > 0:
  quit 1
