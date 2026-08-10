## vds_parse.nim — fused parse+emit for the `vds-parsed` AIF dialect.
##
## INCLUDE file, spliced into `vdsparser.nim` after `vds_lex.nim`.
##
## A RANGE SPLITTER, structurally the same technique as this repo's Nim front
## end: given a token range, find the LOOSEST combinator at depth 0 and split
## there, recursing on each side. VDS precedence, loosest to tightest:
##
##     |   <   ||   <   &&   <   juxtaposition
##
## Wrapper nodes are only emitted when they carry more than one operand, so
## `auto` is `(kw "auto")` and not four nested singleton combinators. That needs
## the operand count BEFORE emitting, which is exactly what a range splitter can
## answer cheaply and a streaming parser cannot.

type
  VdsParser* = object
    toks*: seq[VdsTok]
    diags*: seq[Diagnostic]

proc vTokAt(ps: VdsParser; i: int): VdsTok =
  if i < ps.toks.len: ps.toks[i]
  else: VdsTok(kind: vdEof, raw: "", line: 1'i32, col: 0'i32)

proc vKindAt(ps: VdsParser; i: int): VdsTokKind = vTokAt(ps, i).kind

proc vErr(ps: var VdsParser; code, message: string; t: VdsTok) =
  var d = Diagnostic(severity: sevError, code: code, message: message,
                     line: t.line, col: t.col, endCol: t.col, fix: "",
                     relMsg: "", relLine: 0'i32, relCol: 0'i32)
  d.endCol = t.col + int32(t.raw.len)
  ps.diags.add d

proc vTag(k: VdsTokKind): string =
  case k
  of vdWs: "ws"
  of vdType: "type"
  of vdPropRef: "propref"
  of vdIdent: "kw"
  of vdStr: "str"
  of vdNum: "num"
  of vdMult: "mult"
  of vdRange: "range"
  of vdFunc: "fname"
  of vdBar, vdBarBar, vdAmpAmp: "op"
  else: "lit"

proc isOpener(k: VdsTokKind): bool =
  k == vdLBracket or k == vdLParen or k == vdLBrace

proc isCloser(k: VdsTokKind): bool =
  k == vdRBracket or k == vdRParen or k == vdRBrace

proc matchClose(ps: VdsParser; open, hi: int): int =
  ## Index of the delimiter matching the opener at `open`, or `hi` if unclosed.
  var depth = 0
  var i = open
  while i < hi:
    let k = vKindAt(ps, i)
    if isOpener(k) or k == vdFunc:
      depth = depth + 1
    elif isCloser(k):
      depth = depth - 1
      if depth == 0: return i
    i = i + 1
  return hi

proc atomExtent(ps: VdsParser; i, hi: int): int =
  let k = vKindAt(ps, i)
  if isOpener(k) or k == vdFunc:
    let c = matchClose(ps, i, hi)
    if c < hi: return c + 1
    return hi
  return i + 1

proc compExtent(ps: VdsParser; i, hi: int): int =
  ## An atom plus every postfix multiplier glued to it.
  var j = atomExtent(ps, i, hi)
  while j < hi and (vKindAt(ps, j) == vdMult or vKindAt(ps, j) == vdRange):
    j = j + 1
  return j

proc findOp(ps: VdsParser; lo, hi: int; want: VdsTokKind): bool =
  ## Is `want` present at nesting depth 0 within [lo, hi)?
  var depth = 0
  var i = lo
  while i < hi:
    let k = vKindAt(ps, i)
    if isOpener(k) or k == vdFunc:
      depth = depth + 1
    elif isCloser(k):
      if depth > 0: depth = depth - 1
    elif depth == 0 and k == want:
      return true
    i = i + 1
  return false

proc countComponents(ps: VdsParser; lo, hi: int): int =
  result = 0
  var i = lo
  while i < hi:
    let k = vKindAt(ps, i)
    if k == vdWs:
      i = i + 1
      continue
    if isCloser(k) or k == vdMult or k == vdRange:
      i = i + 1
      continue
    result = result + 1
    let j = compExtent(ps, i, hi)
    i = if j > i: j else: i + 1

proc parseRange(ps: var VdsParser; b: var Builder; lo, hi, depth: int)

proc parseComponent(ps: var VdsParser; b: var Builder; lo, hi, depth: int) =
  ## An atom plus its multipliers. Wrapped in `(comp …)` only when at least one
  ## multiplier is present.
  var i = lo
  let k = vKindAt(ps, i)
  let ext = compExtent(ps, i, hi)
  let atomEnd = atomExtent(ps, i, hi)
  let hasMult = ext > atomEnd

  if hasMult:
    b.addTree "comp"
    b.addLineInfo(vTokAt(ps, i).col, vTokAt(ps, i).line)

  # the atom
  if isOpener(k) or k == vdFunc:
    let close = matchClose(ps, i, hi)
    var tag = "group"
    if k == vdLParen: tag = "paren"
    elif k == vdLBrace: tag = "block"
    elif k == vdFunc: tag = "fn"
    b.addTree tag
    b.addLineInfo(vTokAt(ps, i).col, vTokAt(ps, i).line)
    if k == vdFunc:
      leaf(b, "fname", vTokAt(ps, i).raw)     # includes the '('
    else:
      case k
      of vdLBracket: mark(b, "lbracket")
      of vdLParen: mark(b, "lparen")
      else: mark(b, "lbrace")
    if depth < 200:
      parseRange(ps, b, i + 1, close, depth + 1)
    else:
      var t = i + 1
      while t < close:
        leaf(b, vTag(vKindAt(ps, t)), vTokAt(ps, t).raw)
        t = t + 1
    if close < hi:
      case vKindAt(ps, close)
      of vdRBracket: mark(b, "rbracket")
      of vdRParen: mark(b, "rparen")
      of vdRBrace: mark(b, "rbrace")
      else: discard
    else:
      vErr(ps, "unclosed-group", "group is never closed", vTokAt(ps, i))
    b.endTree()
    i = atomEnd
  else:
    leaf(b, vTag(k), vTokAt(ps, i).raw)
    i = i + 1

  # trailing multipliers
  while i < ext:
    leaf(b, vTag(vKindAt(ps, i)), vTokAt(ps, i).raw)
    i = i + 1

  if hasMult:
    b.endTree()

proc parseJuxta(ps: var VdsParser; b: var Builder; lo, hi, depth: int) =
  let n = countComponents(ps, lo, hi)
  let wrap = n > 1
  if wrap:
    b.addTree "juxta"
  var i = lo
  while i < hi:
    let k = vKindAt(ps, i)
    if k == vdWs:
      leaf(b, "ws", vTokAt(ps, i).raw)
      i = i + 1
      continue
    if isCloser(k) or k == vdMult or k == vdRange:
      # a stray closer or an orphan multiplier: keep the bytes
      leaf(b, vTag(k), vTokAt(ps, i).raw)
      i = i + 1
      continue
    let ext = compExtent(ps, i, hi)
    parseComponent(ps, b, i, hi, depth)
    i = if ext > i: ext else: i + 1
  if wrap:
    b.endTree()

proc parseLevel(ps: var VdsParser; b: var Builder; lo, hi, depth: int;
                op: VdsTokKind; tag: string;
                tighter: proc (ps: var VdsParser; b: var Builder;
                               lo, hi, depth: int)) =
  ## Split [lo,hi) on `op` at depth 0, emitting `(tag …)` around the operands.
  b.addTree tag
  var segStart = lo
  var d = 0
  var i = lo
  while i < hi:
    let k = vKindAt(ps, i)
    if isOpener(k) or k == vdFunc:
      d = d + 1
    elif isCloser(k):
      if d > 0: d = d - 1
    elif d == 0 and k == op:
      tighter(ps, b, segStart, i, depth)
      leaf(b, "op", vTokAt(ps, i).raw)
      segStart = i + 1
    i = i + 1
  tighter(ps, b, segStart, hi, depth)
  b.endTree()

proc parseAll(ps: var VdsParser; b: var Builder; lo, hi, depth: int) =
  if findOp(ps, lo, hi, vdAmpAmp):
    parseLevel(ps, b, lo, hi, depth, vdAmpAmp, "all", parseJuxta)
  else:
    parseJuxta(ps, b, lo, hi, depth)

proc parseAny(ps: var VdsParser; b: var Builder; lo, hi, depth: int) =
  if findOp(ps, lo, hi, vdBarBar):
    parseLevel(ps, b, lo, hi, depth, vdBarBar, "any", parseAll)
  else:
    parseAll(ps, b, lo, hi, depth)

proc parseRange(ps: var VdsParser; b: var Builder; lo, hi, depth: int) =
  if lo >= hi: return
  if findOp(ps, lo, hi, vdBar):
    parseLevel(ps, b, lo, hi, depth, vdBar, "alt", parseAny)
  else:
    parseAny(ps, b, lo, hi, depth)

proc parseVds*(ps: var VdsParser; b: var Builder) =
  addAifHeader(b, "vds-parsed")
  b.addTree "vds"
  var hi = ps.toks.len
  while hi > 0 and vKindAt(ps, hi - 1) == vdEof: hi = hi - 1
  parseRange(ps, b, 0, hi, 0)
  b.endTree()
