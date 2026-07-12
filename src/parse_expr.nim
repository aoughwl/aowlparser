## parse_expr.nim — EXPRESSIONS & OPERATORS (owned by the expressions agent).
##
## Spliced after parsecore.nim (and parse_type.nim / parse_stmt.nim resolve
## against `parseExprRange` via the forward decl in parsecore.nim).
##
## Expression strategy: a token-range splitter. `parseExprRange [lo,hi)` finds the
## lowest-precedence depth-0 binary operator (rightmost = left-assoc) and emits
## `(infix op L R)`, recursing on the sub-ranges — reproducing nifler's operator
## nesting and pretty-print indentation. `parsePrimaryRange` handles atoms/calls/
## grouping/prefix, plus HIGH-PRECEDENCE POSTFIX chains (`.`/`[]`/`{}`/`()`) and
## keyword-led forms (`nil`/`cast`/`addr`/`if`). Constructors (`bracket`/`curly`/
## `tup`/`par`/`oconstr`/`tabconstr`) and named args (`kv`/`vv`) live here too.
## See nifler-nif-spec.md §3. Line-info is emitted relative to parent via emitInfo.

# postfix kinds
const
  pkDot = 1
  pkAt = 2
  pkCurly = 3
  pkCall = 4

proc depth0Colon(ps: Parser; lo, hi: int): int =
  ## First depth-0 `tkColon` in `[lo, hi)`, or -1 (named-arg / table entry).
  var depth = 0
  result = -1
  var i = lo
  while i < hi:
    let t = ps.tok(i)
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    elif depth == 0 and t.kind == tkColon:
      return i
    inc i

proc findPostfix(ps: Parser; lo, hi: int; kind: var int): int =
  ## Rightmost depth-0 postfix operator in `(lo, hi)`, or -1. Sets `kind`.
  var depth = 0
  result = -1
  kind = 0
  var i = lo
  while i < hi:
    let t = ps.tok(i)
    if depth == 0 and i > lo:
      case t.kind
      of tkDot: result = i; kind = pkDot
      of tkBracketLe: result = i; kind = pkAt
      of tkCurlyLe: result = i; kind = pkCurly
      of tkParLe: result = i; kind = pkCall
      else: discard
    if isOpenBracket(t.kind): inc depth
    elif isCloseBracket(t.kind):
      if depth > 0: dec depth
    inc i

proc parseArg(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  ## One comma-delimited element: `k: v` -> `(kv k v)`, `k = v` -> `(vv k v)`,
  ## else a plain expression. `if`/`case`-led args keep their own colons.
  let head = ps.tok(int(lo))
  let guardKw = head.kind == tkKeyword and (head.s == "if" or head.s == "case")
  if not guardKw:
    let ci = ps.depth0Colon(int(lo), int(hi))
    if ci >= 0:
      let op = ps.tok(ci)
      b.addTree "kv"
      ps.emitInfo(b, op.line, op.col, pl, pc, false)   # kv node = ':' pos
      ps.parseExprRange(b, lo, int32(ci), op.line, op.col)
      ps.parseExprRange(b, int32(ci) + 1, hi, op.line, op.col)
      b.endTree()
      return
    let ei = ps.findAssign(int(lo), int(hi))
    if ei >= 0:
      let op = ps.tok(ei)
      b.addTree "vv"
      ps.emitInfo(b, op.line, op.col, pl, pc, false)   # vv node = '=' pos
      ps.parseExprRange(b, lo, int32(ei), op.line, op.col)
      ps.parseExprRange(b, int32(ei) + 1, hi, op.line, op.col)
      b.endTree()
      return
  ps.parseExprRange(b, lo, hi, pl, pc)

proc parseArgList(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  ## Emit each comma-separated element of `[lo, hi)` as an arg, parent (pl,pc).
  let starts = ps.splitArgs(int(lo), int(hi))
  for ai in 0 ..< starts.len:
    let aLo = starts[ai]
    let aHi = if ai + 1 < starts.len: starts[ai+1] - 1 else: int(hi)
    if aLo < aHi:
      ps.parseArg(b, int32(aLo), int32(aHi), pl, pc)

proc parseIfExpr(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  ## Single-line `if C: A (elif C: A)* (else: B)` -> `(if (elif C (stmts A))...)`.
  let ifTok = ps.tok(int(lo))
  b.addTree "if"
  ps.emitInfo(b, ifTok.line, ifTok.col, pl, pc, false)   # if node = 'if' kw pos
  # branch boundaries: depth-0 `elif`/`else` keywords.
  var i = int(lo)
  while i < int(hi):
    let kw = ps.tok(i)          # `if` (first) / `elif` / `else`
    let isElse = kw.kind == tkKeyword and kw.s == "else"
    # find the branch body colon (depth 0) and the next branch keyword.
    var depth = 0
    var colon = -1
    var nxt = int(hi)
    var j = i + 1
    while j < int(hi):
      let t = ps.tok(j)
      if isOpenBracket(t.kind): inc depth
      elif isCloseBracket(t.kind):
        if depth > 0: dec depth
      elif depth == 0 and t.kind == tkColon and colon < 0:
        colon = j
      elif depth == 0 and t.kind == tkKeyword and (t.s == "elif" or t.s == "else"):
        nxt = j; break
      inc j
    let bodyLo = colon + 1
    if isElse:
      b.addTree "else"
      ps.emitInfo(b, kw.line, kw.col, ifTok.line, ifTok.col, false)
      let bt = ps.tok(bodyLo)
      b.addTree "stmts"
      ps.emitInfo(b, bt.line, bt.col, kw.line, kw.col, false)
      ps.parseExprRange(b, int32(bodyLo), int32(nxt), bt.line, bt.col)
      b.endTree()
      b.endTree()
    else:
      # first `if` and every `elif` both emit an `elif` node at the COND pos.
      let ct = ps.tok(i + 1)     # condition first token
      b.addTree "elif"
      ps.emitInfo(b, ct.line, ct.col, ifTok.line, ifTok.col, false)
      ps.parseExprRange(b, int32(i + 1), int32(colon), ct.line, ct.col)
      let bt = ps.tok(bodyLo)
      b.addTree "stmts"
      ps.emitInfo(b, bt.line, bt.col, ct.line, ct.col, false)
      ps.parseExprRange(b, int32(bodyLo), int32(nxt), bt.line, bt.col)
      b.endTree()
      b.endTree()
    i = nxt
  b.endTree()   # close the `if` node

proc parseCastExpr(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  ## `cast[T](x)` -> `(cast T x)`; type & value both relative to the cast node.
  let castTok = ps.tok(int(lo))
  b.addTree "cast"
  ps.emitInfo(b, castTok.line, castTok.col, pl, pc, false)  # cast node = 'cast' kw
  let lb = int(lo) + 1                       # `[`
  let rb = ps.matchClose(lb)                 # `]`
  discard ps.parseType(b, lb + 1, castTok.line, castTok.col)
  # value: contents of the `(...)` after `]`
  let lp = rb + 1                            # `(`
  let rp = ps.matchClose(lp)
  ps.parseExprRange(b, int32(lp + 1), int32(rp), castTok.line, castTok.col)
  b.endTree()

proc parseCmdKw(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  ## Keyword-led command in expr position, e.g. `addr x` -> `(cmd addr x)`.
  let kw = ps.tok(int(lo))
  b.addTree "cmd"
  ps.emitInfo(b, kw.line, kw.col, pl, pc, false)   # cmd node = keyword pos
  b.addIdent kw.s
  ps.emitInfo(b, kw.line, kw.col, kw.line, kw.col, false)
  ps.parseArgList(b, lo + 1, hi, kw.line, kw.col)
  b.endTree()

proc parsePrimaryRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  let t = ps.tok(int(lo))
  # --- leading prefix operator (binds looser than postfix): `-a.b` ---
  if t.kind == tkOperator:
    b.addTree "prefix"
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
    b.addIdent t.s
    ps.emitInfo(b, t.line, t.col, t.line, t.col, false)
    if int(lo) + 1 < int(hi):
      ps.parseExprRange(b, lo + 1, hi, t.line, t.col)
    b.endTree()
    return
  # --- keyword-led forms ---
  if t.kind == tkKeyword:
    case t.s
    of "nil":
      b.addTree "nil"
      ps.emitInfo(b, t.line, t.col, pl, pc, false)
      b.endTree()
      return
    of "not":
      b.addTree "prefix"
      ps.emitInfo(b, t.line, t.col, pl, pc, false)
      b.addIdent t.s
      ps.emitInfo(b, t.line, t.col, t.line, t.col, false)
      if int(lo) + 1 < int(hi):
        ps.parseExprRange(b, lo + 1, hi, t.line, t.col)
      b.endTree()
      return
    of "cast":
      if int(lo) + 1 < int(hi) and ps.tok(int(lo)+1).kind == tkBracketLe:
        ps.parseCastExpr(b, lo, hi, pl, pc)
        return
    of "if":
      ps.parseIfExpr(b, lo, hi, pl, pc)
      return
    of "addr":
      if int(lo) + 1 < int(hi):
        ps.parseCmdKw(b, lo, hi, pl, pc)
        return
    else: discard
  # --- postfix chain: rightmost depth-0 `.`/`[`/`{`/`(` ---
  var pkind = 0
  let k = ps.findPostfix(int(lo), int(hi), pkind)
  if k >= 0:
    let opTok = ps.tok(k)
    case pkind
    of pkDot:
      b.addTree "dot"
      ps.emitInfo(b, opTok.line, opTok.col, pl, pc, false)   # dot node = '.' pos
      ps.parsePrimaryRange(b, lo, int32(k), opTok.line, opTok.col)
      let r = ps.tok(k + 1)
      b.addIdent r.s
      ps.emitInfo(b, r.line, r.col, opTok.line, opTok.col, false)
      b.endTree()
    of pkAt:
      let rp = ps.matchClose(k)
      b.addTree "at"
      ps.emitInfo(b, opTok.line, opTok.col, pl, pc, false)   # at node = '[' pos
      ps.parsePrimaryRange(b, lo, int32(k), opTok.line, opTok.col)
      ps.parseArgList(b, int32(k + 1), int32(rp), opTok.line, opTok.col)
      b.endTree()
    of pkCurly:
      let rp = ps.matchClose(k)
      b.addTree "curlyat"
      ps.emitInfo(b, opTok.line, opTok.col, pl, pc, false)   # curlyat node = '{' pos
      ps.parsePrimaryRange(b, lo, int32(k), opTok.line, opTok.col)
      ps.parseArgList(b, int32(k + 1), int32(rp), opTok.line, opTok.col)
      b.endTree()
    else:  # pkCall
      let rp = ps.matchClose(k)
      let starts = ps.splitArgs(k + 1, rp)
      var isObj = false
      if starts.len > 0:
        let a0Hi = if starts.len > 1: starts[1] - 1 else: rp
        isObj = ps.depth0Colon(starts[0], a0Hi) >= 0
      b.addTree(if isObj: "oconstr" else: "call")
      ps.emitInfo(b, opTok.line, opTok.col, pl, pc, false)   # node = '(' pos
      ps.parsePrimaryRange(b, lo, int32(k), opTok.line, opTok.col)
      ps.parseArgList(b, int32(k + 1), int32(rp), opTok.line, opTok.col)
      b.endTree()
    return
  # --- leaf atoms / grouping / constructors ---
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
    # `(...)` grouping — `(par x)` or `(tup a b)`
    let rpIdx = ps.matchClose(int(lo))
    let starts = ps.splitArgs(int(lo) + 1, rpIdx)
    let tag = if starts.len > 1: "tup" else: "par"
    b.addTree tag
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
    ps.parseArgList(b, int32(int(lo) + 1), int32(rpIdx), t.line, t.col)
    b.endTree()
  of tkBracketLe:
    # `[a, b]` array/seq constructor -> `(bracket ...)`
    let rpIdx = ps.matchClose(int(lo))
    b.addTree "bracket"
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
    ps.parseArgList(b, int32(int(lo) + 1), int32(rpIdx), t.line, t.col)
    b.endTree()
  of tkCurlyLe:
    # `{a, b}` set -> `(curly ...)`; `{k: v}` table -> `(tabconstr (kv ...))`
    let rpIdx = ps.matchClose(int(lo))
    let isTab = ps.depth0Colon(int(lo) + 1, rpIdx) >= 0
    b.addTree(if isTab: "tabconstr" else: "curly")
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
    ps.parseArgList(b, int32(int(lo) + 1), int32(rpIdx), t.line, t.col)
    b.endTree()
  of tkIdent, tkKeyword:
    b.addIdent t.s
    ps.emitInfo(b, t.line, t.col, pl, pc, false)
  else:
    b.addEmpty

proc parseExprRange(ps: var Parser; b: var Builder; lo, hi, pl, pc: int32) =
  # Keyword-led expression forms must NOT be split by the operator scanner
  # (their conditions/bodies contain operators that are not top-level).
  let head = ps.tok(int(lo))
  if head.kind == tkKeyword and head.s == "if":
    ps.parsePrimaryRange(b, lo, hi, pl, pc)
    return
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
