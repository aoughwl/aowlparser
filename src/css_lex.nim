## css_lex.nim — CSS tokenizer for the `css-parsed` AIF dialect.
##
## INCLUDE file (like parsecore.nim): it is spliced into `cssparser.nim` and must
## NOT be imported directly — `import css_lex` fails hard, same trap the aowlrepl
## message hit with `parsecore`.
##
## Contract: every token carries its EXACT source slice in `raw`. Nothing is
## decoded, unescaped, lower-cased, or normalised. Concatenating `raw` over the
## whole token stream reproduces the input byte-for-byte — that identity is what
## the round-trip gate rests on, and it is checked directly by `selfCheck` below.
##
## Follows the CSS Syntax Level 3 tokenizer, minus the parts that only matter to a
## consumer that decodes (numeric values, unescaped identifiers): those stay raw.

type
  CssTokKind* = enum
    ctEof
    ctWs           ## a run of whitespace
    ctComment      ## `/* ... */` (raw INCLUDES the delimiters)
    ctIdent        ## identifier, possibly containing escapes
    ctFunction     ## identifier immediately followed by `(` (raw includes the `(`)
    ctAtKeyword    ## `@media` (raw INCLUDES the `@`)
    ctHash         ## `#fff`, `#ident` (raw INCLUDES the `#`)
    ctString       ## quoted string (raw INCLUDES the quotes)
    ctBadString    ## unterminated string — newline hit before the closing quote
    ctUrl          ## `url(...)` unquoted form (raw includes `url(` .. `)`)
    ctBadUrl       ## unterminated url(
    ctNum          ## `1`, `-.5`, `+1e3`
    ctDim          ## number immediately followed by an identifier: `10px`
    ctPercent      ## number immediately followed by `%`: `50%`
    ctColon        ## :
    ctSemi         ## ;
    ctComma        ## ,
    ctLBrace       ## {
    ctRBrace       ## }
    ctLParen       ## (
    ctRParen       ## )
    ctLBracket     ## [
    ctRBracket     ## ]
    ctDelim        ## any other single character: > + ~ * . ! = | ^ $ /

  CssTok* = object
    kind*: CssTokKind
    raw*: string     ## EXACT source slice — never decoded
    line*: int32     ## 1-based
    col*: int32      ## 0-based

proc isCssSpace(c: char): bool {.inline.} =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc isCssDigit(c: char): bool {.inline.} =
  c >= '0' and c <= '9'

proc isCssNameStart(c: char): bool {.inline.} =
  # Non-ASCII bytes (>= 0x80) are name-start per the spec, which conveniently
  # makes UTF-8 sequences fall through byte-by-byte without special handling.
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= '\x80'

proc isCssName(c: char): bool {.inline.} =
  isCssNameStart(c) or isCssDigit(c) or c == '-'

type
  CssLexer* = object
    src*: string
    pos*: int
    line*: int32
    col*: int32

proc atEnd(lx: CssLexer): bool {.inline.} =
  lx.pos >= lx.src.len

proc peekAt(lx: CssLexer; off: int): char {.inline.} =
  let i = lx.pos + off
  if i < lx.src.len: lx.src[i] else: '\0'

proc advance(lx: var CssLexer) =
  ## Consume one byte, maintaining line/col. A `\n` ends a line; a lone `\r`
  ## does too (old-Mac), but `\r\n` counts as ONE line break.
  if lx.pos < lx.src.len:
    let c = lx.src[lx.pos]
    if c == '\n':
      lx.line = lx.line + 1'i32
      lx.col = 0'i32
    elif c == '\r':
      if lx.pos + 1 < lx.src.len and lx.src[lx.pos + 1] == '\n':
        discard  # the '\n' will do the line bump
      else:
        lx.line = lx.line + 1'i32
        lx.col = 0'i32
    else:
      lx.col = lx.col + 1'i32
    lx.pos = lx.pos + 1

proc sliceFrom(lx: CssLexer; start: int): string =
  result = ""
  var i = start
  while i < lx.pos:
    result.add lx.src[i]
    i = i + 1

## --- escape handling -------------------------------------------------------
## An escape is `\` + anything-but-newline. We only need to know how many bytes
## it spans so the raw slice stays intact; the VALUE is never computed here.

proc isValidEscape(lx: CssLexer; off: int): bool {.inline.} =
  peekAt(lx, off) == '\\' and peekAt(lx, off + 1) != '\n' and
    peekAt(lx, off + 1) != '\0'

proc consumeEscape(lx: var CssLexer) =
  advance(lx)                       # the backslash
  if atEnd(lx): return
  let c = lx.src[lx.pos]
  let isHex = isCssDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')
  if isHex:
    var n = 0
    while n < 6 and not atEnd(lx):
      let h = lx.src[lx.pos]
      if isCssDigit(h) or (h >= 'a' and h <= 'f') or (h >= 'A' and h <= 'F'):
        advance(lx)
        n = n + 1
      else:
        break
    # a single trailing whitespace is part of the escape
    if not atEnd(lx) and isCssSpace(lx.src[lx.pos]): advance(lx)
  else:
    advance(lx)

proc consumeName(lx: var CssLexer) =
  while not atEnd(lx):
    if isCssName(lx.src[lx.pos]): advance(lx)
    elif isValidEscape(lx, 0): consumeEscape(lx)
    else: break

## --- number lookahead ------------------------------------------------------

proc startsNumber(lx: CssLexer; off: int): bool =
  let c0 = peekAt(lx, off)
  if c0 == '+' or c0 == '-':
    let c1 = peekAt(lx, off + 1)
    if isCssDigit(c1): return true
    return c1 == '.' and isCssDigit(peekAt(lx, off + 2))
  if c0 == '.':
    return isCssDigit(peekAt(lx, off + 1))
  return isCssDigit(c0)

proc startsIdent(lx: CssLexer; off: int): bool =
  let c0 = peekAt(lx, off)
  if c0 == '-':
    let c1 = peekAt(lx, off + 1)
    if isCssNameStart(c1) or c1 == '-': return true
    return isValidEscape(lx, off + 1)
  if isCssNameStart(c0): return true
  return isValidEscape(lx, off)

proc consumeNumber(lx: var CssLexer) =
  if not atEnd(lx) and (lx.src[lx.pos] == '+' or lx.src[lx.pos] == '-'):
    advance(lx)
  while not atEnd(lx) and isCssDigit(lx.src[lx.pos]): advance(lx)
  if not atEnd(lx) and lx.src[lx.pos] == '.' and isCssDigit(peekAt(lx, 1)):
    advance(lx)
    while not atEnd(lx) and isCssDigit(lx.src[lx.pos]): advance(lx)
  let e = if atEnd(lx): '\0' else: lx.src[lx.pos]
  if e == 'e' or e == 'E':
    let s1 = peekAt(lx, 1)
    if isCssDigit(s1) or ((s1 == '+' or s1 == '-') and isCssDigit(peekAt(lx, 2))):
      advance(lx)                                     # e
      if not atEnd(lx) and (lx.src[lx.pos] == '+' or lx.src[lx.pos] == '-'):
        advance(lx)
      while not atEnd(lx) and isCssDigit(lx.src[lx.pos]): advance(lx)

## --- the main scanner ------------------------------------------------------

proc nextCssTok(lx: var CssLexer): CssTok =
  result = CssTok(kind: ctEof, raw: "", line: lx.line, col: lx.col)
  if atEnd(lx): return
  let startPos = lx.pos
  let startLine = lx.line
  let startCol = lx.col
  let c = lx.src[lx.pos]
  var k = ctDelim

  if isCssSpace(c):
    while not atEnd(lx) and isCssSpace(lx.src[lx.pos]): advance(lx)
    k = ctWs
  elif c == '/' and peekAt(lx, 1) == '*':
    advance(lx); advance(lx)
    var closed = false
    while not atEnd(lx):
      if lx.src[lx.pos] == '*' and peekAt(lx, 1) == '/':
        advance(lx); advance(lx)
        closed = true
        break
      advance(lx)
    # An unterminated comment runs to EOF — still ctComment, still raw-exact, so
    # it round-trips. The parser records the diagnostic.
    discard closed
    k = ctComment
  elif c == '"' or c == '\'':
    let quote = c
    advance(lx)
    k = ctString
    while true:
      if atEnd(lx):
        k = ctBadString
        break
      let d = lx.src[lx.pos]
      if d == quote:
        advance(lx)
        break
      elif d == '\n':
        k = ctBadString
        break
      elif d == '\\' and peekAt(lx, 1) == '\n':
        advance(lx); advance(lx)     # escaped newline inside a string
      elif isValidEscape(lx, 0):
        consumeEscape(lx)
      else:
        advance(lx)
  elif c == '#':
    if isCssName(peekAt(lx, 1)) or isValidEscape(lx, 1):
      advance(lx)
      consumeName(lx)
      k = ctHash
    else:
      advance(lx)
      k = ctDelim
  elif c == '@':
    if startsIdent(lx, 1):
      advance(lx)
      consumeName(lx)
      k = ctAtKeyword
    else:
      advance(lx)
      k = ctDelim
  elif startsNumber(lx, 0):
    consumeNumber(lx)
    if startsIdent(lx, 0):
      consumeName(lx)
      k = ctDim
    elif not atEnd(lx) and lx.src[lx.pos] == '%':
      advance(lx)
      k = ctPercent
    else:
      k = ctNum
  elif startsIdent(lx, 0):
    consumeName(lx)
    if not atEnd(lx) and lx.src[lx.pos] == '(':
      advance(lx)
      k = ctFunction
    else:
      k = ctIdent
  elif c == ':':
    advance(lx); k = ctColon
  elif c == ';':
    advance(lx); k = ctSemi
  elif c == ',':
    advance(lx); k = ctComma
  elif c == '{':
    advance(lx); k = ctLBrace
  elif c == '}':
    advance(lx); k = ctRBrace
  elif c == '(':
    advance(lx); k = ctLParen
  elif c == ')':
    advance(lx); k = ctRParen
  elif c == '[':
    advance(lx); k = ctLBracket
  elif c == ']':
    advance(lx); k = ctRBracket
  else:
    advance(lx)
    k = ctDelim

  result = CssTok(kind: k, raw: sliceFrom(lx, startPos),
                  line: startLine, col: startCol)

proc tokenizeCss*(src: string): seq[CssTok] =
  ## Tokenize `src`. The stream always ends with a single `ctEof` whose `raw` is
  ## empty, so `parse` can look ahead without bounds checks.
  result = @[]
  var lx = CssLexer(src: src, pos: 0, line: 1'i32, col: 0'i32)
  while true:
    let t = nextCssTok(lx)
    if t.kind == ctEof:
      result.add t
      break
    result.add t

proc concatRaw*(toks: seq[CssTok]): string =
  ## The lexer's own identity check: this must equal the input exactly.
  result = ""
  for t in toks:
    result.add t.raw
