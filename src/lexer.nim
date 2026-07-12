## lexer.nim — STUB hand-lexer for nifparser.
##
## This is deliberately minimal: it tokenizes exactly the constructs the
## bootstrap corpus needs (identifiers/keywords, decimal int & float literals,
## `"..."` string literals, `'.'` char literals, operators, the punctuation
## `( ) [ ] { } , ; : .`, and line comments `#...`). It records source
## line/col and the off-side `indent` field on the Token contract in
## `tokens.nim`.
##
## A dedicated lexer agent is expected to REPLACE this file with a full Nim
## lexer (number bases & underscores, `r"..."`/`"""..."""`, escape sequences,
## char-literal escapes, unicode operators, backtick-quoted identifiers,
## explicit Indent/Dedent if desired). The parser only depends on the
## `tokens.nim` contract, so a richer lexer is a drop-in.

import tokens

type
  Lexer = object
    src: string
    n: int
    pos: int
    line: int32
    col: int32
    atLineStart: bool  ## no significant token emitted on the current line yet

proc initLexer(src: string): Lexer =
  Lexer(src: src, n: src.len, pos: 0, line: 1, col: 0, atLineStart: true)

proc cur(lx: Lexer): char =
  if lx.pos < lx.n: lx.src[lx.pos] else: '\0'

proc peek(lx: Lexer; k: int): char =
  let p = lx.pos + k
  if p < lx.n: lx.src[p] else: '\0'

proc advance(lx: var Lexer) =
  if lx.pos < lx.n:
    if lx.src[lx.pos] == '\n':
      inc lx.line
      lx.col = 0
      lx.atLineStart = true
    else:
      inc lx.col
    inc lx.pos

proc isIdentStart(c: char): bool =
  c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc isIdentCont(c: char): bool =
  isIdentStart(c) or (c >= '0' and c <= '9')

proc isDigit(c: char): bool =
  c >= '0' and c <= '9'

const OperatorChars = {'+', '-', '*', '/', '\\', '<', '>', '=', '@', '$', '~',
                       '&', '%', '|', '!', '?', '^', '.', ':'}

proc startToken(lx: Lexer; kind: TokKind): Token =
  result = initToken(kind, lx.line, lx.col)
  if lx.atLineStart:
    result.indent = lx.col

proc lexString(lx: var Lexer): Token =
  ## Minimal `"..."` string literal: supports the common backslash escapes
  ## (`\n \t \r \" \\ \'`); everything else passes through verbatim. Raw and
  ## triple-quoted strings are left for the full lexer.
  result = startToken(lx, tkStrLit)
  advance lx # opening quote
  var s = ""
  while lx.pos < lx.n and lx.cur != '"' and lx.cur != '\n':
    if lx.cur == '\\':
      advance lx
      let e = lx.cur
      case e
      of 'n': s.add '\n'
      of 't': s.add '\t'
      of 'r': s.add '\r'
      of '\\': s.add '\\'
      of '"': s.add '"'
      of '\'': s.add '\''
      else: s.add e
      advance lx
    else:
      s.add lx.cur
      advance lx
  if lx.cur == '"': advance lx
  result.s = s

proc lexChar(lx: var Lexer): Token =
  result = startToken(lx, tkCharLit)
  advance lx # opening quote
  var c = '\0'
  if lx.cur == '\\':
    advance lx
    case lx.cur
    of 'n': c = '\n'
    of 't': c = '\t'
    of 'r': c = '\r'
    of '0': c = '\0'
    of '\\': c = '\\'
    of '\'': c = '\''
    else: c = lx.cur
    advance lx
  else:
    c = lx.cur
    advance lx
  if lx.cur == '\'': advance lx
  result.iVal = int64(ord(c))

proc parseIntStr(s: string): int64 =
  result = 0
  for c in s:
    if c >= '0' and c <= '9':
      result = result * 10 + int64(ord(c) - ord('0'))

proc parseFloatStr(s: string): float =
  ## Tiny decimal float parser (no base/underscore handling) so the stub does
  ## not depend on std parsing. Sufficient for the bootstrap corpus.
  var i = 0
  let n = s.len
  var intPart = 0.0
  while i < n and s[i] >= '0' and s[i] <= '9':
    intPart = intPart * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
  var frac = 0.0
  var scale = 1.0
  if i < n and s[i] == '.':
    inc i
    while i < n and s[i] >= '0' and s[i] <= '9':
      scale = scale / 10.0
      frac = frac + float(ord(s[i]) - ord('0')) * scale
      inc i
  result = intPart + frac
  if i < n and (s[i] == 'e' or s[i] == 'E'):
    inc i
    var neg = false
    if i < n and (s[i] == '+' or s[i] == '-'):
      neg = s[i] == '-'
      inc i
    var e = 0
    while i < n and s[i] >= '0' and s[i] <= '9':
      e = e * 10 + (ord(s[i]) - ord('0'))
      inc i
    var f = 1.0
    var k = 0
    while k < e:
      f = f * 10.0
      inc k
    if neg: result = result / f
    else: result = result * f

proc lexNumber(lx: var Lexer): Token =
  ## Decimal integer or float (with optional `.` fraction and `e`/`E` exponent).
  ## Bases (0x/0o/0b), underscores, and `'`-suffixes are left for the full lexer.
  let startTok = startToken(lx, tkIntLit)
  var raw = ""
  while lx.pos < lx.n and isDigit(lx.cur):
    raw.add lx.cur
    advance lx
  var isFloat = false
  if lx.cur == '.' and isDigit(lx.peek(1)):
    isFloat = true
    raw.add '.'
    advance lx
    while lx.pos < lx.n and isDigit(lx.cur):
      raw.add lx.cur
      advance lx
  if lx.cur == 'e' or lx.cur == 'E':
    isFloat = true
    raw.add 'e'
    advance lx
    if lx.cur == '+' or lx.cur == '-':
      raw.add lx.cur
      advance lx
    while lx.pos < lx.n and isDigit(lx.cur):
      raw.add lx.cur
      advance lx
  result = startTok
  result.s = raw
  if isFloat:
    result.kind = tkFloatLit
    result.fVal = parseFloatStr(raw)
  else:
    result.kind = tkIntLit
    result.iVal = parseIntStr(raw)

proc lexOperator(lx: var Lexer): Token =
  result = startToken(lx, tkOperator)
  var s = ""
  while lx.pos < lx.n and lx.cur in OperatorChars:
    s.add lx.cur
    advance lx
  result.s = s

proc lexIdent(lx: var Lexer): Token =
  result = startToken(lx, tkIdent)
  var s = ""
  while lx.pos < lx.n and isIdentCont(lx.cur):
    s.add lx.cur
    advance lx
  result.s = s
  if isKeyword(s):
    result.kind = tkKeyword

proc tokenize*(src: string): seq[Token] =
  ## Produce the full token list terminated by a `tkEof`. Whitespace and line
  ## comments are consumed; the off-side `indent` field marks first-on-line
  ## tokens.
  var lx = initLexer(src)
  result = @[]
  while lx.pos < lx.n:
    let c = lx.cur
    if c == ' ' or c == '\t' or c == '\r':
      advance lx
    elif c == '\n':
      advance lx
    elif c == '#':
      # line comment (block comments left for the full lexer)
      while lx.pos < lx.n and lx.cur != '\n':
        advance lx
    elif c == '"':
      let t = lexString(lx)
      lx.atLineStart = false
      result.add t
    elif c == '\'':
      let t = lexChar(lx)
      lx.atLineStart = false
      result.add t
    elif isDigit(c):
      let t = lexNumber(lx)
      lx.atLineStart = false
      result.add t
    elif isIdentStart(c):
      let t = lexIdent(lx)
      lx.atLineStart = false
      result.add t
    elif c == '(':
      let t = startToken(lx, tkParLe); lx.atLineStart = false; advance lx; result.add t
    elif c == ')':
      let t = startToken(lx, tkParRi); lx.atLineStart = false; advance lx; result.add t
    elif c == '[':
      let t = startToken(lx, tkBracketLe); lx.atLineStart = false; advance lx; result.add t
    elif c == ']':
      let t = startToken(lx, tkBracketRi); lx.atLineStart = false; advance lx; result.add t
    elif c == '{':
      let t = startToken(lx, tkCurlyLe); lx.atLineStart = false; advance lx; result.add t
    elif c == '}':
      let t = startToken(lx, tkCurlyRi); lx.atLineStart = false; advance lx; result.add t
    elif c == ',':
      let t = startToken(lx, tkComma); lx.atLineStart = false; advance lx; result.add t
    elif c == ';':
      let t = startToken(lx, tkSemicolon); lx.atLineStart = false; advance lx; result.add t
    elif c == ':' and lx.peek(1) notin OperatorChars:
      let t = startToken(lx, tkColon); lx.atLineStart = false; advance lx; result.add t
    elif c == '.' and lx.peek(1) notin OperatorChars and not isDigit(lx.peek(1)):
      let t = startToken(lx, tkDot); lx.atLineStart = false; advance lx; result.add t
    elif c in OperatorChars:
      let t = lexOperator(lx)
      lx.atLineStart = false
      result.add t
    else:
      # Unknown byte: skip it (the full lexer will diagnose).
      advance lx
  var eof = initToken(tkEof, lx.line, lx.col)
  eof.indent = 0
  result.add eof
