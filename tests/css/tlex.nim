## tlex.nim — the lexer identity control.
##
## Asserts concatRaw(tokenizeCss(s)) == s for a spread of nasty inputs. If this
## fails, byte-exact round-trip is unreachable and nothing downstream is worth
## measuring.

include "../../src/css_lex.nim"

import std/syncio

var failures = 0
var checked = 0

proc identity(name, s: string) =
  checked = checked + 1
  let toks = tokenizeCss(s)
  let back = concatRaw(toks)
  if back != s:
    failures = failures + 1
    echo "FAIL identity: ", name
    echo "  in : ", s
    echo "  out: ", back

proc kindOfFirst(s: string): CssTokKind =
  let toks = tokenizeCss(s)
  if toks.len > 0: toks[0].kind else: ctEof

proc expectKind(name, s: string; want: CssTokKind) =
  checked = checked + 1
  let got = kindOfFirst(s)
  if got != want:
    failures = failures + 1
    echo "FAIL kind: ", name, " want ", want, " got ", got

# --- identity over the byte-exactness checklist ---------------------------
identity "empty", ""
identity "simple rule", "a{color:red}"
identity "spaced rule", "a  {\n  color : red ;\n}\n"
identity "no final newline", "a{b:c}"
identity "comment", "/* hi */a{}"
identity "unterminated comment", "a{}/* trailing"
identity "case preserved", "A{COLOR:RED}"
identity "number spellings", "a{x:.5;y:0.50;z:+1;w:1e3;v:-1.5e-3}"
identity "dimensions", "a{margin:10px -2.5em 0 50%}"
identity "single quotes", "a{content:'x'}"
identity "double quotes", "a{content:\"x\"}"
identity "escaped ident", "a{b:\\32 0}"
identity "escape in selector", ".\\33 d{a:b}"
identity "important spaced", "a{b:c ! IMPORTANT }"
identity "atrule semi", "@import url(x);"
identity "atrule block", "@media (min-width:10px){a{b:c}}"
identity "nested parens", "a{b:calc((1 + 2) * 3)}"
identity "hash colors", "a{color:#FFF;b:#aabbcc}"
identity "unterminated string", "a{content:\"oops\n}"
identity "crlf", "a{\r\n  b:c\r\n}\r\n"
identity "utf8 ident", "\xc3\xa9lem{a:b}"
identity "bad chars", "a{b:c}@#$%^&"
identity "only whitespace", "   \n\t  \n"
identity "attr selector", "a[href^='x']{b:c}"
identity "no trailing semi", "a{b:c;d:e}"

# --- token classification --------------------------------------------------
expectKind "ws", "  a", ctWs
expectKind "comment", "/*x*/", ctComment
expectKind "ident", "abc", ctIdent
expectKind "function", "calc(", ctFunction
expectKind "atkeyword", "@media", ctAtKeyword
expectKind "hash", "#fff", ctHash
expectKind "string", "'x'", ctString
expectKind "badstring", "'x\n", ctBadString
expectKind "num", "1.5", ctNum
expectKind "dim", "10px", ctDim
expectKind "percent", "50%", ctPercent
expectKind "delim slash", "/", ctDelim
expectKind "lone hash", "# ", ctDelim
expectKind "lone at", "@ ", ctDelim
expectKind "negative ident", "-webkit-x", ctIdent
expectKind "negative num", "-1", ctNum

echo "css lexer: ", checked - failures, "/", checked, " ok"
if failures > 0:
  quit 1
