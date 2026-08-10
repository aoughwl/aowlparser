## jsonparser.nim — JSON ↔ AIF, the `json-parsed` dialect.
##
## The economy check for aowlparse. This whole dialect — declaration, tokenizer,
## parser, renderer, and gate — is one short file, because everything except the
## JSON-specific grammar already exists in the core. That is the point of the
## library: a new format should cost only what is genuinely new about it.
##
## Byte-exact like the others, which for JSON means the things a
## parse-to-a-value-tree round trip always destroys: key order, indentation,
## number spelling (`1.0`, `1e2`, `-0`), and duplicate keys.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

proc jsonDialect*(): Dialect =
  Dialect(name: "json-parsed", nodes: @[
    struct "doc",
    struct "object",
    struct "array",
    struct "member",     ## one `key: value` pair
    struct "err",
    punct("lbrace", "{"),
    punct("rbrace", "}"),
    punct("lbracket", "["),
    punct("rbracket", "]"),
    punct("colon", ":"),
    punct("comma", ","),
    text "ws",
    text "str",
    text "num",
    text "lit",          ## true / false / null
    text "raw",
    opaque "code",
  ])

type
  JsonTokKind = enum
    jnEof, jnWs, jnStr, jnNum, jnLit, jnLBrace, jnRBrace, jnLBracket,
    jnRBracket, jnColon, jnComma, jnJunk

  JsonTok = object
    kind: JsonTokKind
    raw: string
    line, col: int32

proc scanJsonString(s: var Scanner) =
  advance(s)                              # opening quote
  while not atEnd(s):
    let c = cur(s)
    if c == '\\':
      advance(s)
      if not atEnd(s): advance(s)
      continue
    if c == '"':
      advance(s)
      return
    advance(s)

proc scanJsonNumber(s: var Scanner) =
  if cur(s) == '-' or cur(s) == '+': advance(s)
  while not atEnd(s) and isDigitCh(cur(s)): advance(s)
  if not atEnd(s) and cur(s) == '.':
    advance(s)
    while not atEnd(s) and isDigitCh(cur(s)): advance(s)
  if not atEnd(s) and (cur(s) == 'e' or cur(s) == 'E'):
    advance(s)
    if not atEnd(s) and (cur(s) == '+' or cur(s) == '-'): advance(s)
    while not atEnd(s) and isDigitCh(cur(s)): advance(s)

proc tokenizeJson(src: string): seq[JsonTok] =
  result = @[]
  var s = initScanner(src)
  while true:
    if atEnd(s):
      result.add JsonTok(kind: jnEof, raw: "", line: s.line, col: s.col)
      break
    let startPos = s.pos
    let startLine = s.line
    let startCol = s.col
    let c = cur(s)
    var k = jnJunk
    if isSpaceCh(c):
      while not atEnd(s) and isSpaceCh(cur(s)): advance(s)
      k = jnWs
    elif c == '"':
      scanJsonString(s); k = jnStr
    elif isDigitCh(c) or c == '-' or c == '+':
      scanJsonNumber(s); k = jnNum
    elif isIdentStartCh(c):
      while not atEnd(s) and isIdentCh(cur(s)): advance(s)
      k = jnLit                           # true/false/null, or a bare word
    elif c == '{':
      advance(s); k = jnLBrace
    elif c == '}':
      advance(s); k = jnRBrace
    elif c == '[':
      advance(s); k = jnLBracket
    elif c == ']':
      advance(s); k = jnRBracket
    elif c == ':':
      advance(s); k = jnColon
    elif c == ',':
      advance(s); k = jnComma
    else:
      advance(s); k = jnJunk
    result.add JsonTok(kind: k, raw: sliceFrom(s, startPos),
                       line: startLine, col: startCol)

type
  JsonParser = object
    toks: seq[JsonTok]
    diags: seq[Diagnostic]

proc jtAt(ps: JsonParser; i: int): JsonTok =
  if i < ps.toks.len: ps.toks[i]
  else: JsonTok(kind: jnEof, raw: "", line: 1'i32, col: 0'i32)

proc jkAt(ps: JsonParser; i: int): JsonTokKind = jtAt(ps, i).kind

proc jErr(ps: var JsonParser; code, message: string; t: JsonTok) =
  var d = Diagnostic(severity: sevError, code: code, message: message,
                     line: t.line, col: t.col, endCol: t.col, fix: "",
                     relMsg: "", relLine: 0'i32, relCol: 0'i32)
  d.endCol = t.col + int32(t.raw.len)
  ps.diags.add d

proc jTag(k: JsonTokKind): string =
  case k
  of jnWs: "ws"
  of jnStr: "str"
  of jnNum: "num"
  of jnLit: "lit"
  of jnLBrace: "lbrace"
  of jnRBrace: "rbrace"
  of jnLBracket: "lbracket"
  of jnRBracket: "rbracket"
  of jnColon: "colon"
  of jnComma: "comma"
  else: "raw"

proc emitTok(b: var Builder; t: JsonTok) =
  let tag = jTag(t.kind)
  # Punctuation nodes carry no child; text nodes carry the raw lexeme. The
  # declaration is the authority on which is which.
  case t.kind
  of jnLBrace, jnRBrace, jnLBracket, jnRBracket, jnColon, jnComma:
    mark(b, tag)
  else:
    leaf(b, tag, t.raw)

proc parseValue(ps: var JsonParser; b: var Builder; start, depth: int): int

proc parseObject(ps: var JsonParser; b: var Builder; start, depth: int): int =
  var i = start
  let head = jtAt(ps, i)
  b.addTree "object"
  b.addLineInfo(head.col, head.line)
  emitTok(b, head)                        # '{'
  i = i + 1
  while true:
    let k = jkAt(ps, i)
    if k == jnEof:
      jErr(ps, "unclosed-object", "'{' is never closed", jtAt(ps, i)); break
    if k == jnRBrace:
      emitTok(b, jtAt(ps, i)); i = i + 1; break
    if k == jnWs or k == jnComma:
      emitTok(b, jtAt(ps, i)); i = i + 1; continue
    # a member: key, colon, value
    b.addTree "member"
    emitTok(b, jtAt(ps, i))
    i = i + 1
    while jkAt(ps, i) == jnWs:
      emitTok(b, jtAt(ps, i)); i = i + 1
    if jkAt(ps, i) == jnColon:
      emitTok(b, jtAt(ps, i)); i = i + 1
    else:
      jErr(ps, "expected-colon", "expected ':' after object key", jtAt(ps, i))
    let before = i
    i = parseValue(ps, b, i, depth + 1)
    if i <= before: i = before + 1
    b.endTree()                           # member
  b.endTree()                             # object
  result = i

proc parseArray(ps: var JsonParser; b: var Builder; start, depth: int): int =
  var i = start
  let head = jtAt(ps, i)
  b.addTree "array"
  b.addLineInfo(head.col, head.line)
  emitTok(b, head)                        # '['
  i = i + 1
  while true:
    let k = jkAt(ps, i)
    if k == jnEof:
      jErr(ps, "unclosed-array", "'[' is never closed", jtAt(ps, i)); break
    if k == jnRBracket:
      emitTok(b, jtAt(ps, i)); i = i + 1; break
    if k == jnWs or k == jnComma:
      emitTok(b, jtAt(ps, i)); i = i + 1; continue
    let before = i
    i = parseValue(ps, b, i, depth + 1)
    if i <= before: i = before + 1
  b.endTree()                             # array
  result = i

proc parseValue(ps: var JsonParser; b: var Builder; start, depth: int): int =
  var i = start
  while jkAt(ps, i) == jnWs:
    emitTok(b, jtAt(ps, i)); i = i + 1
  let k = jkAt(ps, i)
  # Bound the recursion so deeply nested input cannot blow the stack; past the
  # limit tokens are kept flat, so bytes still survive.
  if k == jnLBrace and depth < 300:
    i = parseObject(ps, b, i, depth)
  elif k == jnLBracket and depth < 300:
    i = parseArray(ps, b, i, depth)
  elif k == jnEof:
    discard
  else:
    emitTok(b, jtAt(ps, i)); i = i + 1
  result = i

proc jsonToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = JsonParser(toks: tokenizeJson(src), diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  addAifHeader(b, "json-parsed")
  b.addTree "doc"
  var i = 0
  while jkAt(ps, i) != jnEof:
    let before = i
    i = parseValue(ps, b, i, 0)
    if i <= before: i = before + 1
  b.endTree()
  for d in ps.diags: diags.add d
  result = extract(b)

proc jsonToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = jsonToAif(src, ignored)

proc renderJson*(aif: string): string =
  renderWith(jsonDialect(), aif)

proc jsonRoundTrips*(src: string): bool =
  renderJson(jsonToAif(src)) == src
