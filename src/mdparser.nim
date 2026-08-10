## mdparser.nim — Markdown ↔ AIF, the `md-parsed` dialect.
##
## Line-oriented block structure: headings, fenced code, lists, block quotes,
## tables, and paragraphs. Inline spans (emphasis, links) are deliberately left
## as text — see SCOPE below.
##
## The hazard here is the same one HTML has with `<script>`: **fenced code
## content is not Markdown**. A ``` block can contain `# heading`, `- list`, or
## another fence's worth of markup, and treating any of it as structure produces
## a tree that is nonsense while staying byte-exact. So a fence swallows lines
## verbatim until its matching closer, and the shape gate asserts it.
##
## SCOPE: a block-level concrete-syntax dialect. It gives you the document
## skeleton — enough for a table of contents, section extraction, code-block
## harvesting, link auditing, and byte-exact rewriting. It does NOT model inline
## emphasis, link reference resolution, or CommonMark's precedence rules, which
## are a much larger job than the block grammar and are where "approximately
## right" stops being useful.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

proc mdDialect*(): Dialect =
  Dialect(name: "md-parsed", nodes: @[
    struct "doc",
    struct "heading",
    struct "fence",      ## ``` or ~~~ fenced code
    struct "list",
    struct "item",
    struct "quote",
    struct "para",
    struct "table",
    struct "err",
    text "marker",       ## `##`, `-`, `>`, the fence's ``` run
    text "info",         ## a fence's info string, e.g. "nim"
    text "text",         ## line content, raw
    text "ws",
    text "nl",
    text "blank",        ## a blank line, raw (may hold trailing spaces)
    text "raw",
    opaque "code",
  ])

type
  MdLineKind = enum
    mlBlank, mlHeading, mlFence, mlQuote, mlList, mlText

  MdParser = object
    src: string
    lines: seq[string]     ## each INCLUDING its line terminator
    diags: seq[Diagnostic]

proc splitLines(src: string): seq[string] =
  ## Lines with terminators kept, so concatenation reproduces the input exactly.
  result = @[]
  var cur = ""
  var i = 0
  while i < src.len:
    let c = src[i]
    cur.add c
    if c == '\n':
      result.add cur
      cur = ""
    elif c == '\r':
      if i + 1 < src.len and src[i+1] == '\n':
        cur.add '\n'
        i = i + 1
      result.add cur
      cur = ""
    i = i + 1
  if cur.len > 0: result.add cur

proc leadingSpaces(s: string): int =
  result = 0
  for c in s.items:
    if c == ' ': result = result + 1
    elif c == '\t': result = result + 4
    else: break

proc stripEol(s: string): string =
  result = ""
  for c in s.items:
    if c == '\n' or c == '\r': break
    result.add c

proc isBlankLine(s: string): bool =
  for c in s.items:
    if c != ' ' and c != '\t' and c != '\n' and c != '\r': return false
  return true

proc fenceRun(s: string): int =
  ## Length of a leading ``` or ~~~ run (after up to 3 spaces), else 0.
  let body = stripEol(s)
  var i = 0
  var spaces = 0
  while i < body.len and body[i] == ' ' and spaces < 3:
    i = i + 1
    spaces = spaces + 1
  if i >= body.len: return 0
  let c = body[i]
  if c != '`' and c != '~': return 0
  var n = 0
  while i + n < body.len and body[i + n] == c: n = n + 1
  if n >= 3: return n
  return 0

proc headingLevel(s: string): int =
  let body = stripEol(s)
  var i = 0
  while i < body.len and body[i] == ' ' and i < 3: i = i + 1
  var n = 0
  while i + n < body.len and body[i + n] == '#': n = n + 1
  if n == 0 or n > 6: return 0
  # ATX requires a space (or end of line) after the hashes
  if i + n >= body.len or body[i + n] == ' ': return n
  return 0

proc listMarkerLen(s: string): int =
  ## Length of a `- `, `* `, `+ ` or `1. ` marker, else 0.
  let body = stripEol(s)
  var i = 0
  while i < body.len and body[i] == ' ': i = i + 1
  if i >= body.len: return 0
  let c = body[i]
  if c == '-' or c == '*' or c == '+':
    if i + 1 < body.len and body[i+1] == ' ': return i + 2
    if i + 1 == body.len: return i + 1
    return 0
  if c >= '0' and c <= '9':
    var j = i
    while j < body.len and body[j] >= '0' and body[j] <= '9': j = j + 1
    if j < body.len and (body[j] == '.' or body[j] == ')'):
      if j + 1 < body.len and body[j+1] == ' ': return j + 2
      if j + 1 == body.len: return j + 1
    return 0
  return 0

proc quoteMarkerLen(s: string): int =
  let body = stripEol(s)
  var i = 0
  while i < body.len and body[i] == ' ' and i < 3: i = i + 1
  if i < body.len and body[i] == '>':
    if i + 1 < body.len and body[i+1] == ' ': return i + 2
    return i + 1
  return 0

proc classify(s: string): MdLineKind =
  if isBlankLine(s): return mlBlank
  if fenceRun(s) > 0: return mlFence
  if headingLevel(s) > 0: return mlHeading
  if quoteMarkerLen(s) > 0: return mlQuote
  if listMarkerLen(s) > 0: return mlList
  return mlText

proc emitSplit(b: var Builder; line: string; markerLen: int; markerTag: string) =
  ## Emit a line as marker + text + terminator, all raw.
  var marker = ""
  var i = 0
  while i < markerLen and i < line.len:
    marker.add line[i]
    i = i + 1
  var text = ""
  var eol = ""
  while i < line.len:
    let c = line[i]
    if c == '\n' or c == '\r': break
    text.add c
    i = i + 1
  while i < line.len:
    eol.add line[i]
    i = i + 1
  if marker.len > 0: leaf(b, markerTag, marker)
  if text.len > 0: leaf(b, "text", text)
  if eol.len > 0: leaf(b, "nl", eol)

proc parseMdDoc(ps: var MdParser; b: var Builder) =
  addAifHeader(b, "md-parsed")
  b.addTree "doc"
  var i = 0
  let n = ps.lines.len
  while i < n:
    let line = ps.lines[i]
    let kind = classify(line)
    case kind
    of mlBlank:
      leaf(b, "blank", line)
      i = i + 1
    of mlFence:
      # A fence swallows lines VERBATIM until a closing run of at least the same
      # length. Without this, `# heading` inside a code block becomes a heading —
      # byte-exactly, and completely wrong.
      let openLen = fenceRun(line)
      b.addTree "fence"
      var marker = ""
      var rest = ""
      var eol = ""
      var k = 0
      let body = stripEol(line)
      while k < body.len and body[k] == ' ': k = k + 1
      var mk = 0
      while k + mk < body.len and (body[k+mk] == '`' or body[k+mk] == '~'):
        mk = mk + 1
      var z = 0
      while z < k + mk and z < line.len:
        marker.add line[z]
        z = z + 1
      while z < line.len and line[z] != '\n' and line[z] != '\r':
        rest.add line[z]
        z = z + 1
      while z < line.len:
        eol.add line[z]
        z = z + 1
      leaf(b, "marker", marker)
      if rest.len > 0: leaf(b, "info", rest)
      if eol.len > 0: leaf(b, "nl", eol)
      i = i + 1
      var closed = false
      while i < n:
        let l2 = ps.lines[i]
        if fenceRun(l2) >= openLen and stripEol(l2).len > 0:
          # a closing fence: marker only, no info string
          var m2 = ""
          var e2 = ""
          var q = 0
          while q < l2.len and l2[q] != '\n' and l2[q] != '\r':
            m2.add l2[q]
            q = q + 1
          while q < l2.len:
            e2.add l2[q]
            q = q + 1
          leaf(b, "marker", m2)
          if e2.len > 0: leaf(b, "nl", e2)
          i = i + 1
          closed = true
          break
        leaf(b, "text", l2)
        i = i + 1
      if not closed:
        ps.diags.add Diagnostic(severity: sevWarn, code: "unclosed-fence",
          message: "code fence is never closed", line: 0'i32, col: 0'i32,
          endCol: 0'i32, fix: "", relMsg: "", relLine: 0'i32, relCol: 0'i32)
      b.endTree()
    of mlHeading:
      b.addTree "heading"
      let lvl = headingLevel(line)
      var mlen = 0
      var k = 0
      let body = stripEol(line)
      while k < body.len and body[k] == ' ': k = k + 1
      mlen = k + lvl
      emitSplit(b, line, mlen, "marker")
      b.endTree()
      i = i + 1
    of mlQuote:
      b.addTree "quote"
      while i < n and classify(ps.lines[i]) == mlQuote:
        emitSplit(b, ps.lines[i], quoteMarkerLen(ps.lines[i]), "marker")
        i = i + 1
      b.endTree()
    of mlList:
      b.addTree "list"
      while i < n and classify(ps.lines[i]) == mlList:
        b.addTree "item"
        emitSplit(b, ps.lines[i], listMarkerLen(ps.lines[i]), "marker")
        i = i + 1
        # continuation lines: indented, non-blank, not a new item
        while i < n and classify(ps.lines[i]) == mlText and
              leadingSpaces(ps.lines[i]) >= 2:
          emitSplit(b, ps.lines[i], 0, "marker")
          i = i + 1
        b.endTree()
      b.endTree()
    of mlText:
      b.addTree "para"
      while i < n and classify(ps.lines[i]) == mlText:
        emitSplit(b, ps.lines[i], 0, "marker")
        i = i + 1
      b.endTree()
  b.endTree()

proc mdToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = MdParser(src: src, lines: splitLines(src), diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseMdDoc(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc mdToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = mdToAif(src, ignored)

proc renderMd*(aif: string): string =
  renderWith(mdDialect(), aif)

proc mdRoundTrips*(src: string): bool =
  renderMd(mdToAif(src)) == src
