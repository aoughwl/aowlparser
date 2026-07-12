## parsecore.nim — shared spine for the recursive-descent parser.
##
## This file is `include`d FIRST by parser.nim. It defines the `Parser` type,
## token-cursor helpers, line-info emission, operator classification, and the
## range-scanning utilities that every grammar area builds on.
##
## PARALLEL-WORK CONTRACT: the grammar is split across sibling include files —
##   parse_expr.nim   (expressions / operators / constructors)
##   parse_stmt.nim   (statements, control flow, var/let/const sections)
##   parse_type.nim   (type defs, routine/proc defs, params, pragmas)
## Each is owned by ONE agent and spliced (via `include`) AFTER this file, in the
## order expr → type → stmt. Cross-file calls resolve through the forward
## declarations at the bottom of this file. If your area needs to be called from
## another area's file, ADD a forward decl to the block marked FORWARD DECLS
## below (append-only; that is the ONLY shared edit point). Do not edit another
## area's file.

type
  Parser* = object
    toks: seq[Token]
    file: string

proc initParser*(toks: seq[Token]; file: string): Parser =
  Parser(toks: toks, file: file)

# ---------------------------------------------------------------------------
# token helpers
# ---------------------------------------------------------------------------

proc tok(ps: Parser; i: int): Token =
  if i >= 0 and i < ps.toks.len: ps.toks[i]
  else: ps.toks[ps.toks.len-1]  # EOF sentinel

proc isOpenBracket(k: TokKind): bool =
  k == tkParLe or k == tkBracketLe or k == tkCurlyLe

proc isCloseBracket(k: TokKind): bool =
  k == tkParRi or k == tkBracketRi or k == tkCurlyRi

# ---------------------------------------------------------------------------
# line-info emission (mirrors bridge.nim relLineInfo / absLineInfo)
# ---------------------------------------------------------------------------

proc emitInfo(ps: Parser; b: var Builder; nl, nc, pl, pc: int32; root: bool) =
  if root:
    b.attachLineInfo(nc, nl, ps.file)
  else:
    b.attachLineInfo(nc - pc, nl - pl, "")

# ---------------------------------------------------------------------------
# operator classification
# ---------------------------------------------------------------------------

const BinaryKeywords = ["div", "mod", "shl", "shr", "and", "or", "xor",
                        "in", "notin", "is", "isnot", "of", "as", "from"]

proc isBinaryOp(t: Token): bool =
  if t.kind == tkKeyword:
    for k in BinaryKeywords:
      if k == t.s: return true
    return false
  elif t.kind == tkOperator:
    return t.s != "=" and t.s != "."
  else:
    return false

proc precedenceOf(t: Token): int =
  if t.kind == tkKeyword:
    case t.s
    of "div", "mod", "shl", "shr": return 9
    of "and": return 4
    of "or", "xor": return 3
    else: return 5
  if t.s == "..": return 6
  let c = if t.s.len > 0: t.s[0] else: ' '
  case c
  of '$', '^': return 10
  of '*', '/', '%', '\\': return 9
  of '+', '-', '~', '|': return 8
  of '&': return 7
  of '=', '<', '>', '!': return 5
  of '@', ':', '?': return 2
  else: return 6

proc startsExpr(t: Token): bool =
  case t.kind
  of tkIdent, tkKeyword, tkIntLit, tkFloatLit, tkStrLit, tkRStrLit,
     tkTripleStrLit, tkCharLit, tkParLe, tkBracketLe, tkCurlyLe:
    true
  else:
    false

# ---------------------------------------------------------------------------
# range scanning
# ---------------------------------------------------------------------------

proc lineEnd(ps: Parser; startIdx: int): int =
  ## First token index at or after `startIdx` that begins a new logical line at
  ## paren-depth 0 (or EOF). Continuations inside brackets keep the same line.
  let startLine = ps.tok(startIdx).line
  var i = startIdx
  var depth = 0
  while ps.tok(i).kind != tkEof:
    let t = ps.tok(i)
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    if depth == 0 and t.line != startLine:
      break
    inc i
  result = i

proc matchClose(ps: Parser; openIdx: int): int =
  ## Index of the bracket that closes the one at `openIdx`.
  var depth = 0
  var i = openIdx
  while ps.tok(i).kind != tkEof:
    let k = ps.tok(i).kind
    if isOpenBracket(k): inc depth
    elif isCloseBracket(k):
      dec depth
      if depth == 0: return i
    inc i
  result = i

proc findSplit(ps: Parser; lo, hi: int): int =
  ## Rightmost lowest-precedence binary operator at depth 0 in `[lo, hi)`, or -1.
  var depth = 0
  var bestPrec = 1000
  result = -1
  var i = lo
  while i < hi:
    let t = ps.tok(i)
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    elif depth == 0 and i > lo and isBinaryOp(t):
      let p = precedenceOf(t)
      if p <= bestPrec:
        bestPrec = p
        result = i
    inc i

proc findAssign(ps: Parser; lo, hi: int): int =
  ## Depth-0 bare `=` (assignment) in `[lo, hi)`, or -1.
  var depth = 0
  result = -1
  var i = lo
  while i < hi:
    let t = ps.tok(i)
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    elif depth == 0 and t.kind == tkOperator and t.s == "=":
      return i
    inc i

proc splitArgs(ps: Parser; lo, hi: int): seq[int] =
  ## Comma boundaries (depth 0) within `[lo, hi)`; returns the start index of
  ## each argument. Empty when the range is empty.
  result = @[]
  if lo >= hi: return
  result.add lo
  var depth = 0
  var i = lo
  while i < hi:
    let t = ps.tok(i)
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    elif depth == 0 and t.kind == tkComma:
      if i + 1 < hi: result.add(i + 1)
    inc i

# ---------------------------------------------------------------------------
# FORWARD DECLS — cross-file call surface (append-only shared edit point)
# ---------------------------------------------------------------------------
# parse_expr.nim implements:
proc parseExprRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32)
# parse_stmt.nim implements:
proc parseStmt(ps: var Parser; b: var Builder; startIdx: int; pl, pc: int32): int
# parse_type.nim implements:
proc parseType(ps: var Parser; b: var Builder; idx: int; pl, pc: int32): int
proc parseTypeSection(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int
