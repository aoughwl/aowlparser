## css_parse.nim — fused parse+emit for the `css-parsed` AIF dialect.
##
## INCLUDE file, spliced into `cssparser.nim` after `css_lex.nim`. Do not import.
##
## Fused parse+emit, matching the discipline of the Nim front end: constructs are
## written to the `Builder` as they are recognised, with no intermediate AST
## (object-variant ref trees crash nimony's field magics).
##
## Recovery contract: this parser NEVER fails. Anything it cannot classify becomes
## an `(err …)` node holding the skipped source verbatim, so even malformed input
## round-trips byte-exactly. That is what makes the robustness gate meaningful —
## a crash-only check would pass on a parser that silently ate bad bytes.

type
  CssParser* = object
    toks*: seq[CssTok]
    diags*: seq[Diagnostic]

proc tokAt(ps: CssParser; i: int): CssTok =
  if i < ps.toks.len: ps.toks[i]
  else: CssTok(kind: ctEof, raw: "", line: 1'i32, col: 0'i32)

proc kindAt(ps: CssParser; i: int): CssTokKind =
  tokAt(ps, i).kind

proc err(ps: var CssParser; code, message: string; t: CssTok) =
  var d = Diagnostic(severity: sevError, code: code, message: message,
                     line: t.line, col: t.col, endCol: t.col, fix: "",
                     relMsg: "", relLine: 0'i32, relCol: 0'i32)
  d.endCol = t.col + int32(t.raw.len)
  ps.diags.add d

## --- leaf emission ---------------------------------------------------------

proc leaf(b: var Builder; tag, raw: string) =
  b.addTree tag
  b.addStrLit raw
  b.endTree()

proc leafAt(b: var Builder; tag: string; t: CssTok) =
  b.addTree tag
  b.addLineInfo(t.col, t.line)
  b.addStrLit t.raw
  b.endTree()

proc valueTag(k: CssTokKind): string =
  ## The dialect tag for a token appearing inside a value or prelude run.
  case k
  of ctIdent: "ident"
  of ctNum: "num"
  of ctDim: "dim"
  of ctPercent: "pct"
  of ctString, ctBadString: "str"
  of ctHash: "hash"
  of ctFunction: "fn"
  of ctUrl, ctBadUrl: "url"
  of ctComment: "comment"
  of ctWs: "ws"
  else: "op"

proc emitTrivia(ps: CssParser; b: var Builder; i: int): bool =
  ## Emit token `i` if it is trivia. Returns true when it consumed the token.
  let t = tokAt(ps, i)
  if t.kind == ctWs:
    leaf(b, "ws", t.raw); return true
  if t.kind == ctComment:
    leaf(b, "comment", t.raw); return true
  return false

## --- lookahead: is this block a rule list or a declaration list? ------------

proc blockIsRuleList(ps: CssParser; start: int): bool =
  ## Decide whether the construct beginning at `start` is a qualified rule or a
  ## declaration, by asking which comes first at nesting depth 0: a `{` (rule) or
  ## a `;` / `}` / EOF (declaration).
  ##
  ## This replaces a hardcoded table of which at-rules take rule bodies (@media,
  ## @supports, @layer …) versus declaration bodies (@font-face, @page …). A table
  ## is wrong for every at-rule invented after it was written, and wrong for CSS
  ## Nesting, where both forms appear in the same block.
  var i = start
  var depth = 0
  while true:
    let k = kindAt(ps, i)
    case k
    of ctEof: return false
    of ctLParen, ctLBracket: depth = depth + 1
    of ctRParen, ctRBracket:
      if depth > 0: depth = depth - 1
    of ctLBrace:
      if depth == 0: return true
    of ctSemi, ctRBrace:
      if depth == 0: return false
    else: discard
    i = i + 1

## --- declarations ----------------------------------------------------------

proc parseDecl(ps: var CssParser; b: var Builder; start: int): int =
  ## `prop : value [!important] [;]`. Assumes the caller checked this is a decl.
  var i = start
  let head = tokAt(ps, i)
  b.addTree "decl"
  b.addLineInfo(head.col, head.line)

  # property name (an ident, or a custom property `--x` which also lexes as ident)
  leafAt(b, "prop", head)
  i = i + 1

  # trivia, then the colon
  while emitTrivia(ps, b, i): i = i + 1
  if kindAt(ps, i) == ctColon:
    b.addTree "colon"
    b.endTree()
    i = i + 1
  else:
    err(ps, "expected-colon", "expected ':' after property name", tokAt(ps, i))

  # value run: everything up to `;` or `}` at depth 0
  b.addTree "val"
  var depth = 0
  while true:
    let k = kindAt(ps, i)
    if k == ctEof: break
    if k == ctSemi and depth == 0: break
    if k == ctRBrace and depth == 0: break
    if k == ctLParen or k == ctLBracket: depth = depth + 1
    elif k == ctRParen or k == ctRBracket:
      if depth > 0: depth = depth - 1
    elif k == ctFunction: depth = depth + 1
    let t = tokAt(ps, i)
    leaf(b, valueTag(k), t.raw)
    if k == ctBadString:
      err(ps, "unterminated-string", "string is not closed before end of line", t)
    i = i + 1
  b.endTree()   # val

  if kindAt(ps, i) == ctSemi:
    b.addTree "semi"
    b.endTree()
    i = i + 1

  b.endTree()   # decl
  result = i

## --- blocks ----------------------------------------------------------------

proc parseRule(ps: var CssParser; b: var Builder; start: int): int
proc parseAtRule(ps: var CssParser; b: var Builder; start: int): int

proc parseBlock(ps: var CssParser; b: var Builder; start: int): int =
  ## Parses from the `{` through the matching `}`. The braces are implied by the
  ## `block` node and re-added by the renderer.
  var i = start
  b.addTree "block"
  # Braces are EXPLICIT nodes, not implied by the `block` tag. An unclosed block
  # has no `(rbrace)` child, so the renderer emits no closing brace and malformed
  # input still round-trips byte-exactly.
  if kindAt(ps, i) == ctLBrace:
    b.addTree "lbrace"
    b.endTree()
    i = i + 1
  while true:
    let k = kindAt(ps, i)
    if k == ctEof:
      err(ps, "unclosed-block", "'{' is never closed", tokAt(ps, i))
      break
    if k == ctRBrace:
      b.addTree "rbrace"
      b.endTree()
      i = i + 1
      break
    if emitTrivia(ps, b, i):
      i = i + 1
      continue
    if k == ctAtKeyword:
      i = parseAtRule(ps, b, i)
      continue
    if k == ctSemi:
      # a stray `;` between declarations is legal and must survive
      b.addTree "semi"
      b.endTree()
      i = i + 1
      continue
    let before = i
    if blockIsRuleList(ps, i):
      i = parseRule(ps, b, i)
    elif k == ctIdent:
      i = parseDecl(ps, b, i)
    else:
      # not a property name and not a rule — skip one token into an err node so
      # the bytes survive and progress is guaranteed
      let t = tokAt(ps, i)
      err(ps, "unexpected-token", "expected a declaration or a rule", t)
      b.addTree "err"
      leaf(b, "code", "unexpected-token")
      leaf(b, "raw", t.raw)
      b.endTree()
      i = i + 1
    if i <= before: i = before + 1
  b.endTree()   # block
  result = i

proc parseRule(ps: var CssParser; b: var Builder; start: int): int =
  var i = start
  let head = tokAt(ps, i)
  b.addTree "rule"
  b.addLineInfo(head.col, head.line)

  # selector run: everything up to the `{` at depth 0
  b.addTree "sel"
  var depth = 0
  while true:
    let k = kindAt(ps, i)
    if k == ctEof: break
    if k == ctLBrace and depth == 0: break
    if k == ctRBrace and depth == 0: break
    if k == ctLParen or k == ctLBracket or k == ctFunction: depth = depth + 1
    elif k == ctRParen or k == ctRBracket:
      if depth > 0: depth = depth - 1
    leaf(b, valueTag(k), tokAt(ps, i).raw)
    i = i + 1
  b.endTree()   # sel

  if kindAt(ps, i) == ctLBrace:
    i = parseBlock(ps, b, i)
  else:
    # No block node at all — emitting an empty one would render as `{}` bytes
    # that were never in the source.
    err(ps, "expected-block", "expected '{' after selector", tokAt(ps, i))
  b.endTree()   # rule
  result = i

proc parseAtRule(ps: var CssParser; b: var Builder; start: int): int =
  var i = start
  let head = tokAt(ps, i)
  b.addTree "atrule"
  b.addLineInfo(head.col, head.line)
  # name keeps the raw lexeme INCLUDING the '@', so case and escapes survive
  leafAt(b, "name", head)
  i = i + 1

  b.addTree "prelude"
  var depth = 0
  while true:
    let k = kindAt(ps, i)
    if k == ctEof: break
    if k == ctSemi and depth == 0: break
    if k == ctLBrace and depth == 0: break
    if k == ctRBrace and depth == 0: break
    if k == ctLParen or k == ctLBracket or k == ctFunction: depth = depth + 1
    elif k == ctRParen or k == ctRBracket:
      if depth > 0: depth = depth - 1
    leaf(b, valueTag(k), tokAt(ps, i).raw)
    i = i + 1
  b.endTree()   # prelude

  if kindAt(ps, i) == ctSemi:
    b.addTree "semi"
    b.endTree()
    i = i + 1
  elif kindAt(ps, i) == ctLBrace:
    i = parseBlock(ps, b, i)
  else:
    err(ps, "unterminated-atrule", "at-rule ends without ';' or a block",
        tokAt(ps, i))
  b.endTree()   # atrule
  result = i

## --- entry point -----------------------------------------------------------

proc parseStylesheet*(ps: var CssParser; b: var Builder) =
  b.addRaw "(.aif27)\n"
  b.addRaw "(.vendor "
  b.addStrLit "aowlparser"
  b.addRaw ")\n"
  b.addRaw "(.dialect "
  b.addStrLit "css-parsed"
  b.addRaw ")\n"
  b.addTree "stylesheet"
  var i = 0
  while true:
    let k = kindAt(ps, i)
    if k == ctEof: break
    if emitTrivia(ps, b, i):
      i = i + 1
      continue
    let before = i
    if k == ctAtKeyword:
      i = parseAtRule(ps, b, i)
    elif k == ctRBrace:
      # a `}` with no open block: keep the byte, record the problem
      let t = tokAt(ps, i)
      err(ps, "unmatched-close", "'}' with no matching '{'", t)
      b.addTree "err"
      leaf(b, "code", "unmatched-close")
      leaf(b, "raw", t.raw)
      b.endTree()
      i = i + 1
    else:
      i = parseRule(ps, b, i)
    if i <= before: i = before + 1
  b.endTree()   # stylesheet
