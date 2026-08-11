## tgate.nim — the `js-parsed` acceptance gate.
##
## Shape assertions concentrate on the regex-vs-division decision, because that
## is the one tokenizer choice a byte-exact round-trip is completely blind to:
## scanning `a / b / c` as a regex preserves every byte while producing a token
## stream that means something entirely different.

import "../../src/jsparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = jsToAif(src)

var g = initGate("js", jsDialect(), parse)
checkSpec(g)

# --- round-trip -------------------------------------------------------------
roundTrip(g, "empty", "")
roundTrip(g, "simple", "var x = 1;\n")
roundTrip(g, "no final newline", "var x = 1;")
roundTrip(g, "function", "function f(a, b) {\n  return a + b;\n}\n")
roundTrip(g, "arrow", "const f = (a) => a * 2;\n")
roundTrip(g, "line comment", "// hi\nvar x = 1; // trailing\n")
roundTrip(g, "block comment", "/* a\n   b */ var x = 1;\n")
roundTrip(g, "strings", "var a = 'x', b = \"y\", c = 'it\\'s';\n")
roundTrip(g, "template", "var s = `a${b + c}d`;\n")
roundTrip(g, "nested template", "var s = `a${`inner${x}`}b`;\n")
roundTrip(g, "template with brace in string", "var s = `a${ f('}') }b`;\n")
roundTrip(g, "regex", "var re = /ab+c/gi;\n")
roundTrip(g, "regex with slash in class", "var re = /[/]/;\n")
roundTrip(g, "division", "var x = a / b / c;\n")
roundTrip(g, "regex after paren", "if (/x/.test(s)) {}\n")
roundTrip(g, "numbers", "var a=0x1F, b=0b11, c=1_000, d=1.5e-3, e=10n;\n")
roundTrip(g, "operators", "a ??= b; c ||= d; e >>>= f; g?.h; i ?? j;\n")
roundTrip(g, "class", "class A extends B {\n  #p = 1;\n  get x() { return 1; }\n}\n")
roundTrip(g, "async await", "async function f() { await g(); }\n")
roundTrip(g, "spread", "f(...args, [...a], {...o});\n")
roundTrip(g, "crlf", "var a = 1;\r\nvar b = 2;\r\n")
roundTrip(g, "utf8", "var s = 'caf\xc3\xa9 \xe2\x9c\x93';\n")
roundTrip(g, "dollar identifiers", "var $x = $('#id')._y;\n")
roundTrip(g, "jsx-ish angle", "var a = b < c && d > e;\n")

# --- malformed input --------------------------------------------------------
roundTrip(g, "unclosed brace", "function f() {\n  return 1;\n")
roundTrip(g, "unmatched close", "}\nvar x = 1;\n")
roundTrip(g, "mismatched close", "function f( ] {}\n")
roundTrip(g, "unterminated string", "var a = 'oops\n")
roundTrip(g, "unterminated template", "var a = `oops\n")
roundTrip(g, "unterminated block comment", "/* never closed\n")
roundTrip(g, "unterminated regex", "var re = /oops\n")
roundTrip(g, "garbage", "var a = 1 \\ ? ` ;\n")
roundTrip(g, "only whitespace", "  \n\t\n")

# --- shape: regex vs division, the byte-blind decision ---------------------
# Scanning `a / b / c` as a regex preserves every byte while meaning something
# completely different. Only a shape assertion can see the difference.
expectCount(g, "division is not a regex", "var x = a / b / c;\n", "regex", 0)
expectCount(g, "division yields ops", "var x = a / b;\n", "op", 3)  # = / ;
expectCount(g, "regex after assignment", "var re = /ab/g;\n", "regex", 1)
expectCount(g, "regex after return", "function f(){ return /x/; }\n", "regex", 1)
expectCount(g, "regex after comma", "f(a, /x/);\n", "regex", 1)
expectCount(g, "regex after open paren", "f(/x/);\n", "regex", 1)
expectCount(g, "division after close paren", "var x = f(a) / 2;\n", "regex", 0)
expectCount(g, "division after bracket", "var x = a[0] / 2;\n", "regex", 0)
expectCount(g, "division after number", "var x = 4 / 2;\n", "regex", 0)
expectCount(g, "division after this", "var x = this / 2;\n", "regex", 0)
expectCount(g, "regex after typeof", "var x = typeof /a/;\n", "regex", 1)

# Comments are not regexes and regexes are not comments.
expectCount(g, "line comment is a comment", "// a / b\n", "comment", 1)
expectCount(g, "line comment is not a regex", "// a / b\n", "regex", 0)
expectCount(g, "slash-star is a comment", "/* /x/ */\n", "comment", 1)

# Templates stay whole.
expectCount(g, "template is one token", "var s = `a${b}c`;\n", "template", 1)
expectCount(g, "nested template is one token", "var s = `a${`b${c}`}d`;\n",
  "template", 1)
expectCount(g, "brace inside template string does not split it",
  "var s = `${ f('}') }`;\n", "template", 1)

# Grouping.
expectCount(g, "three groups", "f(a[0], {b: 1});\n", "group", 3)
expectNesting(g, "nested groups", "f(g(h(x)));\n", "group", 3)
expectNesting(g, "sibling groups do not nest", "f(); g();\n", "group", 1)
expectCount(g, "brace in a string is not a group", "var s = '{';\n", "group", 0)
expectCount(g, "brace in a regex is not a group", "var r = /{/;\n", "group", 0)
expectCount(g, "unmatched close makes no group", "}\n", "group", 0)

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
