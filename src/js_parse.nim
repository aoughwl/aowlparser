## js_parse.nim — fused parse+emit for the `js-parsed` AIF dialect.
##
## INCLUDE file, spliced into `jsparser.nim` after `js_lex.nim`.
##
## The tree here is the BRACKET-GROUP tree: every `(…)`, `[…]` and `{…}` run
## becomes a `(group …)` containing its delimiters and contents. Statement
## structure is deliberately NOT modeled — see jsparser.nim for why.
##
## An unmatched closing delimiter is emitted as an ordinary `op` rather than
## closing a group it does not belong to, and an unclosed group simply ends at
## EOF. Both keep every byte.

type
  JsParser* = object
    toks*: seq[JsTok]
    diags*: seq[Diagnostic]

proc jsTokAt(ps: JsParser; i: int): JsTok =
  if i < ps.toks.len: ps.toks[i]
  else: JsTok(kind: jsEof, raw: "", line: 1'i32, col: 0'i32)

proc jsKindAt(ps: JsParser; i: int): JsTokKind =
  jsTokAt(ps, i).kind

proc jsErr(ps: var JsParser; code, message: string; t: JsTok) =
  var d = Diagnostic(severity: sevError, code: code, message: message,
                     line: t.line, col: t.col, endCol: t.col, fix: "",
                     relMsg: "", relLine: 0'i32, relCol: 0'i32)
  d.endCol = t.col + int32(t.raw.len)
  ps.diags.add d

proc jsTag(k: JsTokKind): string =
  case k
  of jsWs: "ws"
  of jsNl: "nl"
  of jsComment: "comment"
  of jsName: "name"
  of jsKeyword: "kw"
  of jsNumber: "num"
  of jsString: "str"
  of jsTemplate: "template"
  of jsRegex: "regex"
  else: "op"

proc isOpener(t: JsTok): bool =
  t.kind == jsOp and (t.raw == "(" or t.raw == "[" or t.raw == "{")

proc closerFor(open: string): string =
  case open
  of "(": ")"
  of "[": "]"
  of "{": "}"
  else: ""

proc isCloser(t: JsTok): bool =
  t.kind == jsOp and (t.raw == ")" or t.raw == "]" or t.raw == "}")

proc parseGroup(ps: var JsParser; b: var Builder; start: int;
                depth: int): int =
  ## `start` indexes the opening delimiter. Emits `(group …)` including both
  ## delimiters as `op` leaves.
  var i = start
  let head = jsTokAt(ps, i)
  let want = closerFor(head.raw)
  b.addTree "group"
  b.addLineInfo(head.col, head.line)
  leaf(b, "op", head.raw)
  i = i + 1

  while true:
    let t = jsTokAt(ps, i)
    if t.kind == jsEof:
      jsErr(ps, "unclosed-group", "'" & head.raw & "' is never closed", t)
      break
    if isCloser(t):
      if t.raw == want:
        leaf(b, "op", t.raw)
        i = i + 1
        break
      # A closer for an OUTER group: stop here without consuming it, so the
      # outer group can close on it. Consuming it would nest the rest of the
      # file inside this group.
      jsErr(ps, "mismatched-close",
            "expected '" & want & "' but found '" & t.raw & "'", t)
      break
    if isOpener(t):
      # Bound the recursion: pathological input must not blow the stack. Past
      # the limit the delimiter is kept as a flat token, so bytes survive.
      if depth < 200:
        i = parseGroup(ps, b, i, depth + 1)
      else:
        leaf(b, "op", t.raw)
        i = i + 1
      continue
    leaf(b, jsTag(t.kind), t.raw)
    i = i + 1

  b.endTree()   # group
  result = i

proc parseProgram*(ps: var JsParser; b: var Builder) =
  addAifHeader(b, "js-parsed")
  b.addTree "program"
  var i = 0
  while true:
    let t = jsTokAt(ps, i)
    if t.kind == jsEof: break
    let before = i
    if isOpener(t):
      i = parseGroup(ps, b, i, 0)
    else:
      if isCloser(t):
        jsErr(ps, "unmatched-close",
              "'" & t.raw & "' closes nothing", t)
      leaf(b, jsTag(t.kind), t.raw)
      i = i + 1
    if i <= before: i = before + 1
  b.endTree()   # program
