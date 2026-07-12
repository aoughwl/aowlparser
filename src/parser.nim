## parser.nim — recursive-descent parser that emits NIF DIRECTLY via nifbuilder,
## matching classic `nifler`'s output (see the emit cheatsheet / bridge.nim).
##
## This is the SPINE, not the whole grammar. It fuses parse + emit: constructs
## are written to the `Builder` as they are recognised, with bounded lookahead
## over the flat token list (no PNode AST is materialised — that is deliberate:
## object-variant ref trees crash nimony's field magics).
##
## Expressions are handled with a token-range recursive splitter
## (`parseExprRange`): given a `[lo, hi)` token span we find the lowest-
## precedence binary operator at paren-depth 0 (rightmost, for left
## associativity) and emit `(infix op <left> <right>)`, recursing on the two
## sub-ranges. This reproduces nifler's operator nesting (and its `\n`+indent
## pretty-printing, which nifbuilder derives from nesting depth) for free.
##
## Line-info suffixes are emitted relative to each node's parent, exactly like
## bridge.nim's `relLineInfo`, so output can match native nifler byte-for-byte
## on the supported constructs. `tokens.Token` carries 1-based `line` / 0-based
## `col` for this purpose.

import tokens
import nifbuilder

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
# expression emission
# ---------------------------------------------------------------------------

proc parseExprRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32)

proc parseCallRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  ## `callee(args)` spanning `[lo, hi)`; `lo+1` is the `(`.
  let callee = ps.tok(int(lo))
  let lpIdx = int(lo) + 1
  let lp = ps.tok(lpIdx)
  let rpIdx = ps.matchClose(lpIdx)
  b.addTree "call"
  ps.emitInfo(b, lp.line, lp.col, pl, pc, false)   # call node info = '(' position
  b.addIdent callee.s
  ps.emitInfo(b, callee.line, callee.col, lp.line, lp.col, false)
  let starts = ps.splitArgs(lpIdx + 1, rpIdx)
  for ai in 0 ..< starts.len:
    let aLo = starts[ai]
    let aHi = if ai + 1 < starts.len: starts[ai+1] - 1 else: rpIdx
    if aLo < aHi:
      ps.parseExprRange(b, int32(aLo), int32(aHi), lp.line, lp.col)
  b.endTree()

proc parsePrimaryRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  let t = ps.tok(int(lo))
  case t.kind
  of tkIntLit:
    b.addIntLit t.iVal
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
  of tkFloatLit:
    b.addFloatLit(t.fVal, t.col - pc, t.line - pl, "")
  of tkStrLit:
    b.addStrLit t.s
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
  of tkRStrLit:
    b.addStrLit(t.s, "R", t.col - pc, t.line - pl, "")
  of tkTripleStrLit:
    b.addStrLit(t.s, "T", t.col - pc, t.line - pl, "")
  of tkCharLit:
    b.addCharLit char(t.iVal)
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
  of tkParLe:
    # `(...)` grouping — `(par x)` or `(tup a b)` (best-effort)
    let rpIdx = ps.matchClose(int(lo))
    let starts = ps.splitArgs(int(lo) + 1, rpIdx)
    let tag = if starts.len > 1: "tup" else: "par"
    b.addTree tag
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
    for ai in 0 ..< starts.len:
      let aLo = starts[ai]
      let aHi = if ai + 1 < starts.len: starts[ai+1] - 1 else: rpIdx
      if aLo < aHi:
        ps.parseExprRange(b, int32(aLo), int32(aHi), t.line, t.col)
    b.endTree()
  of tkOperator:
    # prefix operator: `(prefix op operand)`
    b.addTree "prefix"
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
    b.addIdent t.s
    ps.emitInfo(b, t.line, t.col, t.line, t.col, false)
    if int(lo) + 1 < int(hi):
      ps.parseExprRange(b, lo + 1, hi, t.line, t.col)
    b.endTree()
  of tkIdent, tkKeyword:
    if t.kind == tkKeyword and t.s == "nil":
      b.addTree "nil"
      ps.emitInfo(b, t.line, t.col, pl, pc, false)
      b.endTree()
    elif int(lo) + 1 < int(hi) and ps.tok(int(lo)+1).kind == tkParLe and
         ps.tok(int(lo)+1).line == t.line and
         ps.tok(int(lo)+1).col == t.col + int32(t.s.len):
      # adjacent `(` → call
      ps.parseCallRange(b, lo, hi, pl, pc)
    else:
      b.addIdent t.s
      ps.emitInfo(b, t.line, t.col, pl, pc, false)
  else:
    b.addEmpty

proc parseExprRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  let split = ps.findSplit(int(lo), int(hi))
  if split < 0:
    ps.parsePrimaryRange(b, lo, hi, pl, pc)
  else:
    let op = ps.tok(split)
    b.addTree "infix"
    ps.emitInfo(b, op.line, op.col, pl, pc, false)   # infix node info = operator pos
    b.addIdent op.s
    ps.emitInfo(b, op.line, op.col, op.line, op.col, false)
    ps.parseExprRange(b, lo, int32(split), op.line, op.col)          # left
    ps.parseExprRange(b, int32(split) + 1, hi, op.line, op.col)      # right
    b.endTree()

# ---------------------------------------------------------------------------
# statement emission
# ---------------------------------------------------------------------------

proc parseStmt(ps: var Parser; b: var Builder; startIdx: int; pl, pc: int32): int

proc parseCommand(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  let callee = ps.tok(int(lo))
  b.addTree "cmd"
  ps.emitInfo(b, callee.line, callee.col, pl, pc, false)   # cmd node info = callee pos
  b.addIdent callee.s
  ps.emitInfo(b, callee.line, callee.col, callee.line, callee.col, false)
  let starts = ps.splitArgs(int(lo) + 1, int(hi))
  for ai in 0 ..< starts.len:
    let aLo = starts[ai]
    let aHi = if ai + 1 < starts.len: starts[ai+1] - 1 else: int(hi)
    if aLo < aHi:
      ps.parseExprRange(b, int32(aLo), int32(aHi), callee.line, callee.col)
  b.endTree()

proc parseExprStmt(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  let eqi = ps.findAssign(int(lo), int(hi))
  if eqi >= 0:
    let op = ps.tok(eqi)
    b.addTree "asgn"
    ps.emitInfo(b, op.line, op.col, pl, pc, false)
    ps.parseExprRange(b, lo, int32(eqi), op.line, op.col)
    ps.parseExprRange(b, int32(eqi) + 1, hi, op.line, op.col)
    b.endTree()
    return
  # command: leading ident, no depth-0 binary operator, not an adjacent call,
  # and a following argument token.
  let head = ps.tok(int(lo))
  let isCmd =
    (head.kind == tkIdent) and (int(lo) + 1 < int(hi)) and
    (ps.findSplit(int(lo), int(hi)) < 0) and
    not (ps.tok(int(lo)+1).kind == tkParLe and
         ps.tok(int(lo)+1).col == head.col + int32(head.s.len)) and
    startsExpr(ps.tok(int(lo)+1))
  if isCmd:
    ps.parseCommand(b, lo, hi, pl, pc)
  else:
    ps.parseExprRange(b, lo, hi, pl, pc)

proc parseReturnLike(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32;
                     tag: string): int =
  let kw = ps.tok(kwIdx)
  let hi = ps.lineEnd(kwIdx)
  b.addTree tag
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  if kwIdx + 1 < hi and startsExpr(ps.tok(kwIdx+1)):
    ps.parseExprRange(b, int32(kwIdx) + 1, int32(hi), kw.line, kw.col)
  else:
    b.addEmpty
  b.endTree()
  result = hi

proc parseImportLike(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32;
                     tag: string): int =
  let kw = ps.tok(kwIdx)
  let hi = ps.lineEnd(kwIdx)
  b.addTree tag
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  let starts = ps.splitArgs(kwIdx + 1, hi)
  for ai in 0 ..< starts.len:
    let aLo = starts[ai]
    let aHi = if ai + 1 < starts.len: starts[ai+1] - 1 else: hi
    if aLo < aHi:
      ps.parseExprRange(b, int32(aLo), int32(aHi), kw.line, kw.col)
  b.endTree()
  result = hi

proc parseType(ps: var Parser; b: var Builder; idx: int; pl, pc: int32): int =
  ## Minimal type: a single primary (ident). Returns index after it.
  let t = ps.tok(idx)
  b.addIdent t.s
  ps.emitInfo(b, t.line, t.col, pl, pc, false)
  result = idx + 1

proc parseParams(ps: var Parser; b: var Builder; lpIdx: int; pl, pc: int32): int =
  ## Emit `(params ...)` then the return type as a sibling. `lpIdx` is `(`.
  ## `pl,pc` = the enclosing routine node position. Returns index after the
  ## return type (or after `)` if none).
  let lp = ps.tok(lpIdx)
  let rpIdx = ps.matchClose(lpIdx)
  b.addTree "params"
  ps.emitInfo(b, lp.line, lp.col, pl, pc, false)   # params node info = '(' pos
  var i = lpIdx + 1
  while i < rpIdx:
    # collect a group of names up to ':'
    var names: seq[Token] = @[]
    if ps.tok(i).kind == tkIdent or ps.tok(i).kind == tkKeyword:
      names.add ps.tok(i)
      inc i
    while i < rpIdx and ps.tok(i).kind == tkComma:
      inc i
      if i < rpIdx and (ps.tok(i).kind == tkIdent or ps.tok(i).kind == tkKeyword):
        names.add ps.tok(i)
        inc i
    var typeIdx = -1
    if i < rpIdx and ps.tok(i).kind == tkColon:
      inc i
      typeIdx = i
      inc i  # single-token type (skeleton)
    for nm in names:
      b.addTree "param"
      ps.emitInfo(b, nm.line, nm.col, lp.line, lp.col, false)  # param node = name pos
      b.addIdent nm.s
      ps.emitInfo(b, nm.line, nm.col, nm.line, nm.col, false)
      b.addEmpty  # export marker
      b.addEmpty  # pragma
      if typeIdx >= 0:
        discard ps.parseType(b, typeIdx, nm.line, nm.col)  # type (parent = name)
      else:
        b.addEmpty
      b.addEmpty  # value
      b.endTree()
    # separator between groups
    if i < rpIdx and (ps.tok(i).kind == tkComma or ps.tok(i).kind == tkSemicolon):
      inc i
  b.endTree()  # close params
  # return type sibling
  var j = rpIdx + 1
  if ps.tok(j).kind == tkColon:
    inc j
    j = ps.parseType(b, j, lp.line, lp.col)   # ret type parent = params node ('(' pos)
  else:
    b.addEmpty
  result = j

proc parseRoutine(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32;
                  tag: string): int =
  let kw = ps.tok(kwIdx)
  b.addTree tag
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)   # routine node info = keyword pos
  var i = kwIdx + 1
  # name
  let name = ps.tok(i)
  b.addIdent name.s
  ps.emitInfo(b, name.line, name.col, kw.line, kw.col, false)
  inc i
  # export marker `*`
  if ps.tok(i).kind == tkOperator and ps.tok(i).s == "*":
    inc i
    b.addRaw " x"
  else:
    b.addEmpty
  b.addEmpty  # pattern
  b.addEmpty  # generics
  # params + return type
  if ps.tok(i).kind == tkParLe:
    i = ps.parseParams(b, i, kw.line, kw.col)
  else:
    b.addEmpty  # params slot
    b.addEmpty  # return type slot
  b.addEmpty  # pragmas
  b.addEmpty  # reserved / misc
  # body after `=`
  if ps.tok(i).kind == tkOperator and ps.tok(i).s == "=":
    inc i
    # body = indented block; body stmts node info = first body stmt position
    let refIndent = kw.col
    if ps.tok(i).kind == tkEof or ps.tok(i).indent <= refIndent:
      b.addEmpty
    else:
      let first = ps.tok(i)
      b.addTree "stmts"
      ps.emitInfo(b, first.line, first.col, kw.line, kw.col, false)  # body parent = routine node
      while ps.tok(i).kind != tkEof and ps.tok(i).indent > refIndent:
        i = ps.parseStmt(b, i, first.line, first.col)
      b.endTree()
  else:
    b.addEmpty
  b.endTree()
  result = i

proc parseStmt(ps: var Parser; b: var Builder; startIdx: int; pl, pc: int32): int =
  ## Emit one statement starting at token `startIdx`. Returns the index of the
  ## first token AFTER the statement.
  let t = ps.tok(startIdx)
  if t.kind == tkKeyword:
    case t.s
    of "proc": return ps.parseRoutine(b, startIdx, pl, pc, "proc")
    of "func": return ps.parseRoutine(b, startIdx, pl, pc, "func")
    of "method": return ps.parseRoutine(b, startIdx, pl, pc, "method")
    of "converter": return ps.parseRoutine(b, startIdx, pl, pc, "converter")
    of "iterator": return ps.parseRoutine(b, startIdx, pl, pc, "iterator")
    of "macro": return ps.parseRoutine(b, startIdx, pl, pc, "macro")
    of "template": return ps.parseRoutine(b, startIdx, pl, pc, "template")
    of "return": return ps.parseReturnLike(b, startIdx, pl, pc, "ret")
    of "discard": return ps.parseReturnLike(b, startIdx, pl, pc, "discard")
    of "raise": return ps.parseReturnLike(b, startIdx, pl, pc, "raise")
    of "yield": return ps.parseReturnLike(b, startIdx, pl, pc, "yld")
    of "import": return ps.parseImportLike(b, startIdx, pl, pc, "import")
    of "include": return ps.parseImportLike(b, startIdx, pl, pc, "include")
    of "export": return ps.parseImportLike(b, startIdx, pl, pc, "export")
    else: discard
  # expression / command / assignment statement (single logical line)
  let hi = ps.lineEnd(startIdx)
  ps.parseExprStmt(b, int32(startIdx), int32(hi), pl, pc)
  result = hi

proc parseModule*(ps: var Parser; b: var Builder) =
  b.addHeader "Nifler", "nim-parsed"
  b.addTree "stmts"
  ps.emitInfo(b, 1, 0, 0, 0, true)   # module stmts: absolute (col 0, line 1, file)
  var i = 0
  while ps.tok(i).kind != tkEof:
    i = ps.parseStmt(b, i, 1, 0)
  b.endTree()
