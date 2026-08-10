## py_parse.nim — fused parse+emit for the `py-parsed` AIF dialect.
##
## INCLUDE file, spliced into `pyparser.nim` after `py_lex.nim`.
##
## Python's structure is its INDENTATION, so the tree here is built by comparing
## the leading whitespace of successive logical lines. A statement line whose
## successor is indented deeper gets a `(block …)` child holding that suite.
##
## Blank and comment-only lines do NOT affect indentation (Python's rule), so
## they are emitted as trivia and skipped when measuring. This matters: taking a
## blank line's indent of 0 as a dedent would close every open block at the first
## empty line in the file.
##
## Recovery: inconsistent indentation is recorded as a diagnostic and the line is
## still emitted at the current level. Nothing is ever dropped.

type
  PyParser* = object
    toks*: seq[PyTok]
    diags*: seq[Diagnostic]

proc pyTokAt(ps: PyParser; i: int): PyTok =
  if i < ps.toks.len: ps.toks[i]
  else: PyTok(kind: pyEof, raw: "", line: 1'i32, col: 0'i32)

proc pyKindAt(ps: PyParser; i: int): PyTokKind =
  pyTokAt(ps, i).kind

proc pyErr(ps: var PyParser; code, message: string; t: PyTok) =
  var d = Diagnostic(severity: sevError, code: code, message: message,
                     line: t.line, col: t.col, endCol: t.col, fix: "",
                     relMsg: "", relLine: 0'i32, relCol: 0'i32)
  d.endCol = t.col + int32(t.raw.len)
  ps.diags.add d

proc pyTag(k: PyTokKind): string =
  case k
  of pyWs: "ws"
  of pyNl: "nl"
  of pyComment: "comment"
  of pyName: "name"
  of pyKeyword: "kw"
  of pyNumber: "num"
  of pyString: "str"
  of pyOp: "op"
  of pyCont: "cont"
  else: "op"

proc indentWidth(raw: string): int =
  ## Python's own rule: a tab advances to the next multiple of 8.
  result = 0
  for c in raw.items:
    if c == '\t': result = result + (8 - (result mod 8))
    elif c == ' ': result = result + 1
    else: discard

## --- line classification ---------------------------------------------------

proc classifyLine(ps: PyParser; start: int; indent: var int;
                  isStmt: var bool) =
  ## Measures the line beginning at `start` WITHOUT consuming it.
  indent = 0
  isStmt = false
  var i = start
  if pyKindAt(ps, i) == pyWs:
    indent = indentWidth(pyTokAt(ps, i).raw)
    i = i + 1
  let k = pyKindAt(ps, i)
  if k == pyEof or k == pyNl or k == pyComment:
    isStmt = false          # blank or comment-only: no effect on indentation
  else:
    isStmt = true

proc nextStmtIndent(ps: PyParser; start: int; indent: var int;
                    found: var bool) =
  ## The indent of the next line that actually carries a statement, skipping
  ## blank and comment-only lines.
  var i = start
  found = false
  indent = 0
  while true:
    if pyKindAt(ps, i) == pyEof: return
    var ind = 0
    var isStmt = false
    classifyLine(ps, i, ind, isStmt)
    if isStmt:
      indent = ind
      found = true
      return
    # skip this trivia line
    while pyKindAt(ps, i) != pyEof and pyKindAt(ps, i) != pyNl:
      i = i + 1
    if pyKindAt(ps, i) == pyNl: i = i + 1

## --- emission --------------------------------------------------------------

proc emitTriviaLine(ps: PyParser; b: var Builder; start: int): int =
  ## A blank or comment-only line, emitted at the current level.
  var i = start
  while pyKindAt(ps, i) != pyEof and pyKindAt(ps, i) != pyNl:
    let t = pyTokAt(ps, i)
    leaf(b, pyTag(t.kind), t.raw)
    i = i + 1
  if pyKindAt(ps, i) == pyNl:
    leaf(b, "nl", pyTokAt(ps, i).raw)
    i = i + 1
  result = i

proc parseSuite(ps: var PyParser; b: var Builder; start, level: int): int

proc parseStmtLine(ps: var PyParser; b: var Builder; start, level: int): int =
  var i = start
  let head = pyTokAt(ps, i)
  b.addTree "stmt"
  b.addLineInfo(head.col, head.line)
  while pyKindAt(ps, i) != pyEof and pyKindAt(ps, i) != pyNl:
    let t = pyTokAt(ps, i)
    leaf(b, pyTag(t.kind), t.raw)
    i = i + 1
  if pyKindAt(ps, i) == pyNl:
    leaf(b, "nl", pyTokAt(ps, i).raw)
    i = i + 1

  # A deeper-indented successor is this statement's suite.
  var nextInd = 0
  var found = false
  nextStmtIndent(ps, i, nextInd, found)
  if found and nextInd > level:
    b.addTree "block"
    i = parseSuite(ps, b, i, nextInd)
    b.endTree()

  b.endTree()   # stmt
  result = i

proc parseSuite(ps: var PyParser; b: var Builder; start, level: int): int =
  var i = start
  while true:
    if pyKindAt(ps, i) == pyEof: break
    var ind = 0
    var isStmt = false
    classifyLine(ps, i, ind, isStmt)
    if not isStmt:
      i = emitTriviaLine(ps, b, i)
      continue
    if ind < level: break            # dedent: the parent suite resumes
    if ind > level:
      # Deeper than expected without an opening statement. Python would raise
      # IndentationError; we record it and keep the line, because dropping it
      # would lose bytes.
      pyErr(ps, "unexpected-indent", "unexpected indentation", pyTokAt(ps, i))
    let before = i
    i = parseStmtLine(ps, b, i, level)
    if i <= before: i = before + 1
  result = i

proc parseModule*(ps: var PyParser; b: var Builder) =
  addAifHeader(b, "py-parsed")
  b.addTree "module"
  var i = 0
  # The module body is a suite at level 0. A file that opens with indented code
  # is malformed Python, but parseSuite keeps it rather than dropping it.
  i = parseSuite(ps, b, i, 0)
  # Anything parseSuite declined (a dedent below level 0 cannot happen, but be
  # explicit rather than assume) is emitted flat so no byte is lost.
  while pyKindAt(ps, i) != pyEof:
    let t = pyTokAt(ps, i)
    leaf(b, pyTag(t.kind), t.raw)
    i = i + 1
  b.endTree()   # module
