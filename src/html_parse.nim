## html_parse.nim — fused parse+emit for the `html-parsed` AIF dialect.
##
## INCLUDE file, spliced into `htmlparser.nim` after `html_lex.nim`.
##
## Nesting is produced by an open-element stack: `endTree` is called when an
## element closes, so the emitted tree IS the nesting. An end tag that matches an
## element further down the stack implicitly closes everything above it — those
## elements simply get no `(etag)` child, which is exactly how the source read.
## An end tag matching nothing is emitted as a stray top-level `(etag)` rather
## than dropped.
##
## As spec/html-dialect.md states: the nesting is best-effort, the bytes are not.

type
  HtmlParser* = object
    toks*: seq[HtmlTok]
    diags*: seq[Diagnostic]
    open*: seq[string]      ## names of currently open elements, outermost first

proc htTokAt(ps: HtmlParser; i: int): HtmlTok =
  if i < ps.toks.len: ps.toks[i]
  else: HtmlTok(kind: htEof, raw: "", line: 1'i32, col: 0'i32)

proc htKindAt(ps: HtmlParser; i: int): HtmlTokKind =
  htTokAt(ps, i).kind

proc htErr(ps: var HtmlParser; code, message: string; t: HtmlTok) =
  var d = Diagnostic(severity: sevError, code: code, message: message,
                     line: t.line, col: t.col, endCol: t.col, fix: "",
                     relMsg: "", relLine: 0'i32, relCol: 0'i32)
  d.endCol = t.col + int32(t.raw.len)
  ps.diags.add d

proc htLeaf(b: var Builder; tag, raw: string) =
  b.addTree tag
  b.addStrLit raw
  b.endTree()

proc htMark(b: var Builder; tag: string) =
  b.addTree tag
  b.endTree()

## --- start tags ------------------------------------------------------------

proc parseStartTag(ps: var HtmlParser; b: var Builder; start: int;
                   name: var string; selfClose: var bool): int =
  ## Emits the `(stag …)` subtree. `start` indexes the `htLt`.
  var i = start
  let head = htTokAt(ps, i)
  name = ""
  selfClose = false

  b.addTree "stag"
  b.addLineInfo(head.col, head.line)
  htMark(b, "lt")
  i = i + 1

  if htKindAt(ps, i) == htName:
    let nt = htTokAt(ps, i)
    name = nt.raw
    htLeaf(b, "name", nt.raw)
    i = i + 1

  while true:
    let k = htKindAt(ps, i)
    if k == htEof:
      htErr(ps, "unclosed-tag", "start tag is not closed before end of input",
            htTokAt(ps, i))
      break
    if k == htGt:
      htMark(b, "gt")
      i = i + 1
      break
    if k == htSelfClose:
      htMark(b, "selfclose")
      selfClose = true
      i = i + 1
      continue
    if k == htWs:
      htLeaf(b, "ws", htTokAt(ps, i).raw)
      i = i + 1
      continue
    if k == htAttrName or k == htAttrValue:
      b.addTree "attr"
      htLeaf(b, "aname", htTokAt(ps, i).raw)
      i = i + 1
      # `=` may be separated from the name by whitespace: `id = "x"`. That
      # whitespace belongs inside the attr node so document order is preserved.
      var j = i
      var wsRun = 0
      while htKindAt(ps, j) == htWs:
        j = j + 1
        wsRun = wsRun + 1
      if htKindAt(ps, j) == htEq:
        var w = 0
        while w < wsRun:
          htLeaf(b, "ws", htTokAt(ps, i).raw)
          i = i + 1
          w = w + 1
        htMark(b, "eq")
        i = i + 1
        while htKindAt(ps, i) == htWs:
          htLeaf(b, "ws", htTokAt(ps, i).raw)
          i = i + 1
        let vk = htKindAt(ps, i)
        if vk == htAttrValue or vk == htAttrName:
          htLeaf(b, "aval", htTokAt(ps, i).raw)
          i = i + 1
        else:
          htErr(ps, "missing-attr-value", "'=' with no attribute value",
                htTokAt(ps, i))
      b.endTree()   # attr
      continue
    # anything else inside a tag: keep the bytes
    htLeaf(b, "op", htTokAt(ps, i).raw)
    i = i + 1

  b.endTree()   # stag
  result = i

## --- end tags --------------------------------------------------------------

proc parseEndTag(ps: var HtmlParser; b: var Builder; start: int;
                 name: var string): int =
  ## Emits the `(etag …)` subtree. `start` indexes the `htLtSlash`.
  var i = start
  let head = htTokAt(ps, i)
  name = ""
  b.addTree "etag"
  b.addLineInfo(head.col, head.line)
  htMark(b, "ltslash")
  i = i + 1
  if htKindAt(ps, i) == htName:
    let nt = htTokAt(ps, i)
    name = nt.raw
    htLeaf(b, "name", nt.raw)
    i = i + 1
  while true:
    let k = htKindAt(ps, i)
    if k == htEof: break
    if k == htGt:
      htMark(b, "gt")
      i = i + 1
      break
    if k == htWs:
      htLeaf(b, "ws", htTokAt(ps, i).raw)
    else:
      htLeaf(b, "op", htTokAt(ps, i).raw)
    i = i + 1
  b.endTree()   # etag
  result = i

## --- the document ----------------------------------------------------------

proc namesEqual(a, b: string): bool =
  lowerAscii(a) == lowerAscii(b)

proc findOpen(ps: HtmlParser; name: string): int =
  ## Index of the innermost open element matching `name`, or -1.
  var i = ps.open.len - 1
  while i >= 0:
    if namesEqual(ps.open[i], name): return i
    i = i - 1
  return -1

proc parseDocument*(ps: var HtmlParser; b: var Builder) =
  b.addRaw "(.aif27)\n"
  b.addRaw "(.vendor "
  b.addStrLit "aowlparser"
  b.addRaw ")\n"
  b.addRaw "(.dialect "
  b.addStrLit "html-parsed"
  b.addRaw ")\n"
  b.addTree "doc"

  var i = 0
  while true:
    let k = htKindAt(ps, i)
    if k == htEof: break
    let before = i
    case k
    of htText:
      htLeaf(b, "text", htTokAt(ps, i).raw); i = i + 1
    of htComment:
      htLeaf(b, "comment", htTokAt(ps, i).raw); i = i + 1
    of htDoctype:
      htLeaf(b, "doctype", htTokAt(ps, i).raw); i = i + 1
    of htCdata:
      htLeaf(b, "cdata", htTokAt(ps, i).raw); i = i + 1
    of htPi:
      htLeaf(b, "pi", htTokAt(ps, i).raw); i = i + 1
    of htLt:
      var name = ""
      var selfClose = false
      b.addTree "elem"
      i = parseStartTag(ps, b, i, name, selfClose)
      if selfClose or isVoidElement(name) or name.len == 0:
        # No content and no end tag: close the element now. A void element
        # written as `<br></br>` still works — the stray `</br>` matches nothing
        # and lands as its own node, which is what the bytes said.
        b.endTree()
      else:
        ps.open.add name
    of htLtSlash:
      # The element an end tag closes is not known until its NAME is read, but
      # the `(etag)` subtree has to be emitted INSIDE that element — after the
      # `endTree` calls that close everything above it. So parse into a scratch
      # builder, then splice the finished subtree at the right depth.
      var scratch = nifbuilder.open(64)
      var endName = ""
      let ni = parseEndTag(ps, scratch, i, endName)
      let sub = extract(scratch)
      let target = findOpen(ps, endName)
      if target >= 0:
        # Implicitly close everything above the match (they get no etag).
        var d = ps.open.len - 1
        while d > target:
          b.endTree()
          discard ps.open.pop()
          d = d - 1
        b.addRaw sub
        b.endTree()               # the matched element
        discard ps.open.pop()
      else:
        htErr(ps, "stray-end-tag",
              "end tag </" & endName & "> matches no open element",
              htTokAt(ps, i))
        b.addRaw sub
      i = ni
    else:
      # htName/htWs/htEq/... outside a tag: cannot happen from the tokenizer,
      # but keep the bytes rather than assume.
      htLeaf(b, "op", htTokAt(ps, i).raw); i = i + 1
    if i <= before: i = before + 1

  # Anything still open at EOF closes here, with no etag — the source had none.
  while ps.open.len > 0:
    b.endTree()
    discard ps.open.pop()

  b.endTree()   # doc
