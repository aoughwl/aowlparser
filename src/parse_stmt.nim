## parse_stmt.nim — STATEMENTS, CONTROL FLOW, var/let/const SECTIONS
## (owned by the statements agent).
##
## Spliced LAST (after parse_expr.nim and parse_type.nim), so it can call
## `parseExprRange`, `parseType`, `parseRoutine` directly. `parseStmt` is the
## dispatch entry (forward-declared in parsecore.nim) — routine bodies and the
## module loop re-enter through it.
##
## Currently: expr/command/assignment statements, return-like (ret/discard/raise/
## yld), import-like. EXTEND HERE: `if`/`elif`/`else`, `case`+`(of (ranges …) …)`,
## `while`, `for`+`(unpackflat (let …))` / `(unpacktup …)`, `try`/`except`/`fin`,
## `when`, `block`/`break`/`continue`, `defer`; and var/let/const SECTIONS which
## emit NO wrapper — each ident-def is its own sibling with type & value
## DUPLICATED across a multi-name group (`(var name . pragma type value)`), plus
## var-tuple `(unpackdecl value (unpacktup (let …)…))`. See nifler-nif-spec.md §4.
## Indentation-delimited blocks: use `ps.tok(i).indent > refIndent` like
## parseRoutine's body loop.

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

# ---------------------------------------------------------------------------
# control-flow helpers
# ---------------------------------------------------------------------------

proc findColon(ps: Parser; lo, hi: int): int =
  ## Depth-0 `:` in `[lo, hi)` (body introducer), or -1.
  var depth = 0
  var i = lo
  while i < hi:
    let t = ps.tok(i)
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    elif depth == 0 and t.kind == tkColon:
      return i
    inc i
  result = -1

proc emitBody(ps: var Parser; b: var Builder; colonIdx: int; refIndent: int32;
              pl, pc: int32): int =
  ## Emit a `(stmts …)` body after a `:`. Handles both the one-line form
  ## (`if c: stmt`) and the indented block (mirrors parseRoutine's body loop).
  ## `pl,pc` = the controlling branch node position (parent of the stmts node).
  let bodyStart = colonIdx + 1
  let first = ps.tok(bodyStart)
  b.addTree "stmts"
  ps.emitInfo(b, first.line, first.col, pl, pc, false)   # stmts info = first body stmt
  var i = bodyStart
  if first.kind == tkEof:
    discard
  elif first.indent < 0:
    # one-liner: statements on the same logical line
    let hi = ps.lineEnd(bodyStart)
    while i < hi and ps.tok(i).kind != tkEof:
      i = ps.parseStmt(b, i, first.line, first.col)
  else:
    # indented block
    while ps.tok(i).kind != tkEof and ps.tok(i).indent > refIndent:
      i = ps.parseStmt(b, i, first.line, first.col)
  b.endTree()
  result = i

proc parseIfLike(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32;
                 tag: string): int =
  ## `if`/`elif`/`else` → `(if (elif cond body) (else body))`; also `when`.
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  b.addTree tag
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)   # if node = keyword pos
  var i = kwIdx
  while true:
    let branch = ps.tok(i)
    let isElif = branch.kind == tkKeyword and (branch.s == tag or branch.s == "elif")
    if isElif:
      let hi = ps.lineEnd(i)
      let colon = ps.findColon(i, hi)
      let condTok = ps.tok(i + 1)
      b.addTree "elif"
      ps.emitInfo(b, condTok.line, condTok.col, kw.line, kw.col, false)  # elif = cond pos
      ps.parseExprRange(b, int32(i + 1), int32(colon), condTok.line, condTok.col)
      i = ps.emitBody(b, colon, refIndent, condTok.line, condTok.col)
      b.endTree()
    elif branch.kind == tkKeyword and branch.s == "else":
      let hi = ps.lineEnd(i)
      let colon = ps.findColon(i, hi)
      b.addTree "else"
      ps.emitInfo(b, branch.line, branch.col, kw.line, kw.col, false)   # else = keyword pos
      i = ps.emitBody(b, colon, refIndent, branch.line, branch.col)
      b.endTree()
      break
    else:
      break
    let nxt = ps.tok(i)
    if nxt.kind == tkKeyword and (nxt.s == "elif" or nxt.s == "else") and
       nxt.indent == refIndent:
      continue
    else:
      break
  b.endTree()
  result = i

proc parseWhile(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int =
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  let hi = ps.lineEnd(kwIdx)
  let colon = ps.findColon(kwIdx, hi)
  b.addTree "while"
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  ps.parseExprRange(b, int32(kwIdx + 1), int32(colon), kw.line, kw.col)  # cond parent = while
  result = ps.emitBody(b, colon, refIndent, kw.line, kw.col)
  b.endTree()

proc parseCase(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int =
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  let selHi = ps.lineEnd(kwIdx)
  b.addTree "case"
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  let selColon = ps.findColon(kwIdx, selHi)
  let selEnd = if selColon >= 0: selColon else: selHi
  ps.parseExprRange(b, int32(kwIdx + 1), int32(selEnd), kw.line, kw.col)  # selector parent = case
  var i = selHi
  while ps.tok(i).kind == tkKeyword and ps.tok(i).indent == refIndent and
        (ps.tok(i).s == "of" or ps.tok(i).s == "else"):
    let br = ps.tok(i)
    let bhi = ps.lineEnd(i)
    let bcolon = ps.findColon(i, bhi)
    if br.s == "of":
      b.addTree "of"
      ps.emitInfo(b, br.line, br.col, kw.line, kw.col, false)
      b.addTree "ranges"   # ranges carries NO line-info
      let starts = ps.splitArgs(i + 1, bcolon)
      for ai in 0 ..< starts.len:
        let aLo = starts[ai]
        let aHi = if ai + 1 < starts.len: starts[ai+1] - 1 else: bcolon
        if aLo < aHi:
          ps.parseExprRange(b, int32(aLo), int32(aHi), br.line, br.col)  # value parent = of
      b.endTree()  # ranges
      i = ps.emitBody(b, bcolon, refIndent, br.line, br.col)
      b.endTree()  # of
    else:
      b.addTree "else"
      ps.emitInfo(b, br.line, br.col, kw.line, kw.col, false)
      i = ps.emitBody(b, bcolon, refIndent, br.line, br.col)
      b.endTree()
  b.endTree()  # case
  result = i

proc parseFor(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int =
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  let hi = ps.lineEnd(kwIdx)
  let colon = ps.findColon(kwIdx, hi)
  # locate the depth-0 `in` keyword separating loop vars from the iterator
  var inIdx = -1
  block findIn:
    var depth = 0
    var j = kwIdx + 1
    while j < colon:
      let t = ps.tok(j)
      if isOpenBracket(t.kind): inc depth
      elif isCloseBracket(t.kind):
        if depth > 0: dec depth
      elif depth == 0 and t.kind == tkKeyword and t.s == "in":
        inIdx = j
        break findIn
      inc j
  let firstVar = ps.tok(kwIdx + 1)          # for node info = first loop var position
  b.addTree "for"
  ps.emitInfo(b, firstVar.line, firstVar.col, pl, pc, false)
  # iterator FIRST (parent = for node)
  ps.parseExprRange(b, int32(inIdx + 1), int32(colon), firstVar.line, firstVar.col)
  if firstVar.kind == tkParLe:
    # tuple unpacking: `(a, b)` → (unpacktup (let a . . . .) …)  (addEmpty 4)
    let rp = ps.matchClose(kwIdx + 1)
    b.addTree "unpacktup"
    let starts = ps.splitArgs(kwIdx + 2, rp)
    for ai in 0 ..< starts.len:
      let v = ps.tok(starts[ai])
      b.addTree "let"
      b.addIdent v.s
      ps.emitInfo(b, v.line, v.col, firstVar.line, firstVar.col, false)  # name rel for node
      b.addEmpty 4   # export, pragma, type, value
      b.endTree()
    b.endTree()
  else:
    # flat: one `(let name . . . .)` per loop var
    b.addTree "unpackflat"
    let starts = ps.splitArgs(kwIdx + 1, inIdx)
    for ai in 0 ..< starts.len:
      let v = ps.tok(starts[ai])
      b.addTree "let"
      b.addIdent v.s
      ps.emitInfo(b, v.line, v.col, firstVar.line, firstVar.col, false)
      b.addEmpty      # export marker
      b.addEmpty      # pragma
      b.addEmpty 2    # type, value
      b.endTree()
    b.endTree()
  # body LAST (parent = for node)
  result = ps.emitBody(b, colon, refIndent, firstVar.line, firstVar.col)
  b.endTree()

proc parseTry(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int =
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  b.addTree "try"
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  let hi = ps.lineEnd(kwIdx)
  let colon = ps.findColon(kwIdx, hi)
  var i = ps.emitBody(b, colon, refIndent, kw.line, kw.col)   # try body, parent = try node
  while ps.tok(i).kind == tkKeyword and ps.tok(i).indent == refIndent and
        (ps.tok(i).s == "except" or ps.tok(i).s == "finally"):
    let br = ps.tok(i)
    let bhi = ps.lineEnd(i)
    let bcolon = ps.findColon(i, bhi)
    if br.s == "except":
      b.addTree "except"
      ps.emitInfo(b, br.line, br.col, kw.line, kw.col, false)
      if i + 1 < bcolon:
        ps.parseExprRange(b, int32(i + 1), int32(bcolon), br.line, br.col)  # exc type
      else:
        b.addEmpty   # bare `except:` → `.`
      i = ps.emitBody(b, bcolon, refIndent, br.line, br.col)
      b.endTree()
    else:
      b.addTree "fin"
      ps.emitInfo(b, br.line, br.col, kw.line, kw.col, false)
      i = ps.emitBody(b, bcolon, refIndent, br.line, br.col)
      b.endTree()
  b.endTree()  # try
  result = i

proc parseBlock(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int =
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  b.addTree "block"
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  let hi = ps.lineEnd(kwIdx)
  let colon = ps.findColon(kwIdx, hi)
  if kwIdx + 1 < colon and ps.tok(kwIdx + 1).kind == tkIdent:
    let lbl = ps.tok(kwIdx + 1)
    b.addIdent lbl.s
    ps.emitInfo(b, lbl.line, lbl.col, kw.line, kw.col, false)   # label rel block node
  else:
    b.addEmpty
  result = ps.emitBody(b, colon, refIndent, kw.line, kw.col)
  b.endTree()

proc parseBreakLike(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32;
                    tag: string): int =
  ## `break`/`continue` → `(break <label-or-.>)`.
  let kw = ps.tok(kwIdx)
  let hi = ps.lineEnd(kwIdx)
  b.addTree tag
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  if kwIdx + 1 < hi and ps.tok(kwIdx + 1).kind == tkIdent:
    let lbl = ps.tok(kwIdx + 1)
    b.addIdent lbl.s
    ps.emitInfo(b, lbl.line, lbl.col, kw.line, kw.col, false)
  else:
    b.addEmpty
  b.endTree()
  result = hi

proc parseDefer(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32): int =
  let kw = ps.tok(kwIdx)
  let refIndent = kw.col
  b.addTree "defer"
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)
  let hi = ps.lineEnd(kwIdx)
  let colon = ps.findColon(kwIdx, hi)
  result = ps.emitBody(b, colon, refIndent, kw.line, kw.col)
  b.endTree()

# ---------------------------------------------------------------------------
# var / let / const sections (NO wrapper node — each def is a sibling)
# ---------------------------------------------------------------------------

proc parseSectionDef(ps: var Parser; b: var Builder; lo, hi: int; tag: string;
                     pl, pc: int32) =
  ## One ident-def logical range `[lo, hi)` → one or more sibling section nodes.
  if ps.tok(lo).kind == tkParLe:
    # tuple decl: `var (a, b) = value` → (unpackdecl value (unpacktup (var a …) …))
    let lp = ps.tok(lo)
    let rp = ps.matchClose(lo)
    let assign = ps.findAssign(rp + 1, hi)
    b.addTree "unpackdecl"
    ps.emitInfo(b, lp.line, lp.col, pl, pc, false)          # unpackdecl = '(' pos
    if assign >= 0 and assign + 1 < hi:
      ps.parseExprRange(b, int32(assign + 1), int32(hi), lp.line, lp.col)  # value
    else:
      b.addEmpty
    b.addTree "unpacktup"   # no line-info
    let starts = ps.splitArgs(lo + 1, rp)
    for ai in 0 ..< starts.len:
      let v = ps.tok(starts[ai])
      b.addTree tag         # section tag (var/let/const)
      b.addIdent v.s
      ps.emitInfo(b, v.line, v.col, lp.line, lp.col, false)  # name rel '(' node
      b.addEmpty            # export
      b.addEmpty            # pragma
      b.addEmpty 2          # type, value
      b.endTree()
    b.endTree()  # unpacktup
    b.endTree()  # unpackdecl
    return
  # `name1, name2, … [: type] [= value]`
  let colon = ps.findColon(lo, hi)
  let assign = ps.findAssign(lo, hi)
  let nameEnd = if colon >= 0: colon
                elif assign >= 0: assign
                else: hi
  let typeLo = if colon >= 0: colon + 1 else: -1
  let typeHi = if colon >= 0: (if assign >= 0: assign else: hi) else: -1
  let valLo = if assign >= 0: assign + 1 else: -1
  let nameStarts = ps.splitArgs(lo, nameEnd)
  for ni in 0 ..< nameStarts.len:
    let nTok = ps.tok(nameStarts[ni])
    b.addTree tag
    ps.emitInfo(b, nTok.line, nTok.col, pl, pc, false)       # section node = name pos
    b.addIdent nTok.s
    ps.emitInfo(b, nTok.line, nTok.col, nTok.line, nTok.col, false)  # name rel itself → none
    # export marker `*`
    if nameStarts[ni] + 1 < nameEnd and ps.tok(nameStarts[ni] + 1).kind == tkOperator and
       ps.tok(nameStarts[ni] + 1).s == "*":
      b.addRaw " x"
    else:
      b.addEmpty
    b.addEmpty   # pragma (minimal — split pragmas TODO)
    if typeLo >= 0 and typeLo < typeHi:
      ps.parseExprRange(b, int32(typeLo), int32(typeHi), nTok.line, nTok.col)  # type
    else:
      b.addEmpty
    if valLo >= 0 and valLo < hi:
      ps.parseExprRange(b, int32(valLo), int32(hi), nTok.line, nTok.col)       # value
    else:
      b.addEmpty
    b.endTree()

proc parseSection(ps: var Parser; b: var Builder; kwIdx: int; pl, pc: int32;
                  tag: string): int =
  let kw = ps.tok(kwIdx)
  let next = ps.tok(kwIdx + 1)
  if next.kind == tkEof:
    return kwIdx + 1
  if next.indent >= 0:
    # indented section block: each line at indent > kw.col is one ident-def
    let refIndent = kw.col
    var i = kwIdx + 1
    while ps.tok(i).kind != tkEof and ps.tok(i).indent > refIndent:
      let dhi = ps.lineEnd(i)
      ps.parseSectionDef(b, i, dhi, tag, pl, pc)
      i = dhi
    result = i
  else:
    # inline single ident-def on the keyword's line
    let hi = ps.lineEnd(kwIdx)
    ps.parseSectionDef(b, kwIdx + 1, hi, tag, pl, pc)
    result = hi

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
    of "if": return ps.parseIfLike(b, startIdx, pl, pc, "if")
    of "when": return ps.parseIfLike(b, startIdx, pl, pc, "when")
    of "while": return ps.parseWhile(b, startIdx, pl, pc)
    of "case": return ps.parseCase(b, startIdx, pl, pc)
    of "for": return ps.parseFor(b, startIdx, pl, pc)
    of "try": return ps.parseTry(b, startIdx, pl, pc)
    of "block": return ps.parseBlock(b, startIdx, pl, pc)
    of "break": return ps.parseBreakLike(b, startIdx, pl, pc, "break")
    of "continue": return ps.parseBreakLike(b, startIdx, pl, pc, "continue")
    of "defer": return ps.parseDefer(b, startIdx, pl, pc)
    of "var": return ps.parseSection(b, startIdx, pl, pc, "var")
    of "let": return ps.parseSection(b, startIdx, pl, pc, "let")
    of "const": return ps.parseSection(b, startIdx, pl, pc, "const")
    of "type": return ps.parseTypeSection(b, startIdx, pl, pc)
    else: discard
  # expression / command / assignment statement (single logical line)
  let hi = ps.lineEnd(startIdx)
  ps.parseExprStmt(b, int32(startIdx), int32(hi), pl, pc)
  result = hi
