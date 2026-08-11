## yamlparser.nim — YAML ↔ AIF, the `yaml-parsed` dialect.
##
## Block structure: documents, mappings, sequences, indentation nesting,
## comments, block scalars and multi-line flow collections.
##
## THE HAZARD, and it is YAML's version of Markdown's fenced code: **a block
## scalar's content is not YAML**. After `script: |` every indented line is
## literal text that routinely *looks* like markup —
##
##     script: |
##       - not a sequence item
##       key: not a mapping entry
##       # not a comment
##
## — and reading those as structure produces a tree that is nonsense while
## staying perfectly byte-exact. A byte comparison cannot tell the two apart, so
## the shape gate asserts it directly. Multi-line flow collections (`[` / `{`
## left open at end of line) are the same trap in miniature, and a `#` inside a
## quoted scalar is the smallest one.
##
## SCOPE: a block-level concrete-syntax dialect, in the same spirit as
## `md-parsed`. It gives you the document skeleton — keys, values, sequence
## items, nesting, comments, and where each byte came from — which is enough for
## config auditing, key extraction, CI-file rewriting and byte-exact editing. It
## does NOT resolve anchors and aliases, apply tags, decode escapes, fold block
## scalars, or interpret plain scalars as numbers/bools/null. Those are the
## *semantic* layer; this is the syntax, and "approximately right" semantics is
## where a YAML reader stops being useful.
##
## Compact nesting (`- key: value`) is modelled as an `item` containing an
## `entry`; a child block always attaches to the OUTERMOST node of its parent
## line, not to the innermost compact one.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

proc yamlDialect*(): Dialect =
  Dialect(name: "yaml-parsed", nodes: @[
    struct "stream",
    struct "doc",        ## one document: `---` … `...`, or the implicit one
    struct "block",      ## an indented run: the children of the line above
    struct "entry",      ## a `key: value` mapping entry
    struct "item",       ## a `- ` sequence item
    struct "line",       ## a content line that is neither: a plain continuation
    struct "scalar",     ## the swallowed body of a `|` / `>` block scalar
    struct "flow",       ## the continuation lines of a multi-line `[`/`{`
    struct "directive",  ## `%YAML 1.2`, `%TAG !m! !my-`: not a document
    text "marker",       ## `---`, `...`, `-`
    text "key",          ## the key text, quotes and all
    text "colon",        ## the `:` of a mapping entry
    text "value",        ## the rest of the line, unparsed
    text "comment",      ## `#` to end of line
    text "text",         ## a raw line (block scalar / flow continuation)
    text "ws",
    text "nl",
    text "blank",        ## a blank line, raw (may hold trailing spaces)
  ])

type
  YamlParser = object
    lines: seq[string]     ## each INCLUDING its line terminator
    i: int
    diags: seq[Diagnostic]

  LineInfo = object
    blockScalar: bool      ## the value was a `|` / `>` indicator
    flow: int              ## net bracket depth this line leaves open

# --- byte-level helpers -----------------------------------------------------

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

proc stripEol(s: string): string =
  result = ""
  for c in s.items:
    if c == '\n' or c == '\r': break
    result.add c

proc slice(s: string; a, b: int): string =
  result = ""
  var i = a
  while i < b and i < s.len:
    result.add s[i]
    i = i + 1

proc isBlankLine(s: string): bool =
  for c in s.items:
    if c != ' ' and c != '\t' and c != '\n' and c != '\r': return false
  return true

proc indentOf(s: string): int =
  ## Leading SPACES only. A tab is not valid YAML indentation, so a
  ## tab-indented line reports the spaces before it and is treated as content —
  ## never as a deeper level.
  result = 0
  for c in s.items:
    if c == ' ': result = result + 1
    else: break

proc commentOnly(s: string): bool =
  let body = stripEol(s)
  var i = 0
  while i < body.len and (body[i] == ' ' or body[i] == '\t'): i = i + 1
  return i < body.len and body[i] == '#'

proc skipQuoted(body: string; start: int): int =
  ## Index just past the quoted scalar beginning at `start`, or `start` when
  ## there is no quote there. An unterminated quote consumes the rest of the
  ## line — which is what makes `key: "a # b` not grow a phantom comment.
  if start >= body.len: return start
  let q = body[start]
  if q != '\'' and q != '"': return start
  var i = start + 1
  while i < body.len:
    if q == '\'':
      if body[i] == '\'':
        if i + 1 < body.len and body[i+1] == '\'':
          i = i + 2
          continue
        return i + 1
      i = i + 1
    else:
      if body[i] == '\\':
        i = i + 2
        continue
      if body[i] == '"': return i + 1
      i = i + 1
  return body.len

proc commentStart(body: string; start: int): int =
  ## Where an end-of-line comment begins, or `body.len`. A `#` only starts one
  ## at the beginning of the scanned region or after whitespace — `a#b` is a
  ## plain scalar — and never inside a quoted scalar.
  var i = start
  while i < body.len:
    let c = body[i]
    if c == '\'' or c == '"':
      let j = skipQuoted(body, i)
      if j > i:
        i = j
        continue
    if c == '#':
      if i == start or body[i-1] == ' ' or body[i-1] == '\t': return i
    i = i + 1
  return body.len

proc findKeyColon(body: string; start: int): int =
  ## Index of the `:` that makes this line a mapping entry, or -1.
  ##
  ## It must be at flow depth 0, outside quotes, and followed by a space or the
  ## end of the line — the rule that keeps `url: http://x` one key (the first
  ## colon wins) and `- http://x` no key at all.
  var depth = 0
  var i = start
  let stop = commentStart(body, start)
  while i < stop:
    let c = body[i]
    if c == '\'' or c == '"':
      let j = skipQuoted(body, i)
      if j > i:
        i = j
        continue
    if c == '[' or c == '{': depth = depth + 1
    elif c == ']' or c == '}': depth = depth - 1
    elif c == ':' and depth == 0:
      if i + 1 >= body.len or body[i+1] == ' ': return i
    i = i + 1
  return -1

proc flowDelta(body: string; start, stop: int): int =
  ## Net `[`/`{` depth opened over a region, quotes excluded.
  result = 0
  var i = start
  while i < stop:
    let c = body[i]
    if c == '\'' or c == '"':
      let j = skipQuoted(body, i)
      if j > i:
        i = j
        continue
    if c == '[' or c == '{': result = result + 1
    elif c == ']' or c == '}': result = result - 1
    i = i + 1

proc isSeqMarker(body: string; p: int): bool =
  ## `-` is a sequence marker only when a space or the line end follows it;
  ## `-1` and `-foo` are scalars.
  if p >= body.len or body[p] != '-': return false
  return p + 1 >= body.len or body[p+1] == ' '

proc isBlockScalarValue(v: string): bool =
  ## `|`, `>`, and their chomping/indentation indicators (`|-`, `>2`, `|+2`).
  if v.len == 0: return false
  if v[0] != '|' and v[0] != '>': return false
  var i = 1
  while i < v.len:
    let c = v[i]
    if c != '+' and c != '-' and (c < '0' or c > '9'): return false
    i = i + 1
  return true

proc trimRight(s: string): string =
  var e = s.len
  while e > 0 and (s[e-1] == ' ' or s[e-1] == '\t'): e = e - 1
  result = slice(s, 0, e)

proc isDocStart(s: string): bool =
  let body = stripEol(s)
  if body.len < 3: return false
  if body[0] != '-' or body[1] != '-' or body[2] != '-': return false
  return body.len == 3 or body[3] == ' '

proc isDirective(s: string): bool =
  ## `%YAML`/`%TAG` at column 0, BETWEEN documents. A directive is not content
  ## and does not start a document: the yaml-test-suite's event streams give
  ## `%YAML 1.2` + `--- text` exactly one `+DOC`, and reading the directive as
  ## an implicit document made it two. Inside a document a `%` line never
  ## reaches here — it is consumed as content, which is what YAML says it is.
  return s.len > 0 and s[0] == '%'

proc isDocEnd(s: string): bool =
  let body = stripEol(s)
  if body.len < 3: return false
  if body[0] != '.' or body[1] != '.' or body[2] != '.': return false
  return body.len == 3 or body[3] == ' '

# --- emitting ---------------------------------------------------------------

proc emitEol(b: var Builder; line: string; start: int) =
  if start < line.len:
    leaf(b, "nl", slice(line, start, line.len))

proc emitWs(b: var Builder; body: string; p: int): int =
  var i = p
  var ws = ""
  while i < body.len and (body[i] == ' ' or body[i] == '\t'):
    ws.add body[i]
    i = i + 1
  if ws.len > 0: leaf(b, "ws", ws)
  return i

proc emitRest(b: var Builder; line, body: string; p: int; info: var LineInfo) =
  ## Value, trailing comment and terminator — everything from `p` on.
  let cs = commentStart(body, p)
  let raw = slice(body, p, cs)
  let core = trimRight(raw)
  if core.len > 0:
    leaf(b, "value", core)
    if isBlockScalarValue(core): info.blockScalar = true
  if raw.len > core.len:
    leaf(b, "ws", slice(raw, core.len, raw.len))
  if cs < body.len:
    leaf(b, "comment", slice(body, cs, body.len))
  info.flow = info.flow + flowDelta(body, p, cs)
  emitEol(b, line, body.len)

proc lineTag(body: string; p: int): string =
  if isSeqMarker(body, p): return "item"
  if findKeyColon(body, p) >= 0: return "entry"
  return "line"

proc emitInner(b: var Builder; line, body: string; p0: int; outermost: bool;
               info: var LineInfo) =
  ## Emits one content line from `p0`. The OUTERMOST node is opened by the
  ## caller (it needs to stay open for the child block); compact nesting —
  ## `- key: value`, `- - x` — opens its own.
  var p = p0
  if isSeqMarker(body, p):
    if not outermost: b.addTree "item"
    leaf(b, "marker", "-")
    p = p + 1
    p = emitWs(b, body, p)
    if p < body.len:
      emitInner(b, line, body, p, false, info)
    else:
      emitEol(b, line, body.len)
    if not outermost: b.endTree()
    return
  let c = findKeyColon(body, p)
  if c >= 0:
    if not outermost: b.addTree "entry"
    if c > p: leaf(b, "key", slice(body, p, c))
    leaf(b, "colon", ":")
    p = emitWs(b, body, c + 1)
    emitRest(b, line, body, p, info)
    if not outermost: b.endTree()
    return
  if not outermost: b.addTree "line"
  emitRest(b, line, body, p, info)
  if not outermost: b.endTree()

proc emitTrivia(ps: var YamlParser; b: var Builder) =
  ## A blank or comment-only line, emitted where it stands.
  let line = ps.lines[ps.i]
  if isBlankLine(line):
    leaf(b, "blank", line)
  else:
    let body = stripEol(line)
    let p = emitWs(b, body, 0)
    leaf(b, "comment", slice(body, p, body.len))
    emitEol(b, line, body.len)
  ps.i = ps.i + 1

proc swallowScalar(ps: var YamlParser; b: var Builder; ind: int) =
  ## A block scalar's body is NOT YAML: every line more indented than its
  ## introducer is literal text, whatever it looks like. Blank lines belong to
  ## it too. This is the single most important rule in this dialect.
  b.addTree "scalar"
  while ps.i < ps.lines.len:
    let l = ps.lines[ps.i]
    if isBlankLine(l):
      leaf(b, "blank", l)
      ps.i = ps.i + 1
      continue
    if indentOf(l) <= ind: break
    leaf(b, "text", l)
    ps.i = ps.i + 1
  b.endTree()

proc swallowFlow(ps: var YamlParser; b: var Builder; depth0: int) =
  ## A `[` or `{` left open at end of line: the following lines are part of one
  ## flow collection, so a leading `- ` in them is punctuation, not an item.
  var depth = depth0
  b.addTree "flow"
  while ps.i < ps.lines.len and depth > 0:
    let l = ps.lines[ps.i]
    let body = stripEol(l)
    leaf(b, "text", l)
    depth = depth + flowDelta(body, 0, commentStart(body, 0))
    ps.i = ps.i + 1
  b.endTree()

proc parseNodes(ps: var YamlParser; b: var Builder; minIndent: int) =
  ## Every line at `minIndent` or deeper, until the block ends. Recurses for a
  ## deeper run, which is what makes nesting a tree rather than a line list.
  let n = ps.lines.len
  while ps.i < n:
    let line = ps.lines[ps.i]
    if isBlankLine(line) or commentOnly(line):
      if minIndent > 0 and not isBlankLine(line) and indentOf(line) < minIndent:
        # a dedented comment belongs to the enclosing block, not this one
        return
      emitTrivia(ps, b)
      continue
    if isDocStart(line) or isDocEnd(line): return
    let ind = indentOf(line)
    if ind < minIndent: return
    let body = stripEol(line)
    let p = emitWs(b, body, 0)
    var info = LineInfo(blockScalar: false, flow: 0)
    let tag = lineTag(body, p)
    b.addTree tag
    emitInner(b, line, body, p, true, info)
    ps.i = ps.i + 1
    if info.blockScalar:
      swallowScalar(ps, b, ind)
    elif info.flow > 0:
      swallowFlow(ps, b, info.flow)
    else:
      # Children: the next CONTENT line, if it is deeper. Trivia in between is
      # emitted inside the child block so document order is preserved.
      var j = ps.i
      while j < n and (isBlankLine(ps.lines[j]) or commentOnly(ps.lines[j])):
        j = j + 1
      if j < n and not isDocStart(ps.lines[j]) and not isDocEnd(ps.lines[j]) and
         indentOf(ps.lines[j]) > ind:
        b.addTree "block"
        while ps.i < j: emitTrivia(ps, b)
        parseNodes(ps, b, ind + 1)
        b.endTree()
    b.endTree()

proc emitMarkerLine(ps: var YamlParser; b: var Builder; marker: string) =
  let line = ps.lines[ps.i]
  let body = stripEol(line)
  leaf(b, "marker", marker)
  var info = LineInfo(blockScalar: false, flow: 0)
  let p = emitWs(b, body, marker.len)
  if p < body.len:
    emitInner(b, line, body, p, false, info)
  else:
    emitEol(b, line, body.len)
  ps.i = ps.i + 1

proc parseStream(ps: var YamlParser; b: var Builder) =
  addAifHeader(b, "yaml-parsed")
  b.addTree "stream"
  var openDoc = false
  let n = ps.lines.len
  while ps.i < n:
    let line = ps.lines[ps.i]
    if isBlankLine(line) or commentOnly(line):
      emitTrivia(ps, b)
      continue
    if isDocStart(line):
      if openDoc:
        b.endTree()
        openDoc = false
      b.addTree "doc"
      openDoc = true
      emitMarkerLine(ps, b, "---")
      continue
    if isDirective(line):
      # A directive belongs to the document that FOLLOWS it, so it closes any
      # document still open and opens none of its own.
      if openDoc:
        b.endTree()
        openDoc = false
      b.addTree "directive"
      let body = stripEol(line)
      var dinfo = LineInfo(blockScalar: false, flow: 0)
      emitRest(b, line, body, 0, dinfo)
      b.endTree()
      ps.i = ps.i + 1
      continue
    if isDocEnd(line):
      # `...` with nothing open ends nothing: a stream that is only `...`, or a
      # comment then `...`, contains ZERO documents — the oracle's count, and
      # opening one here to hold the marker made it one.
      emitMarkerLine(ps, b, "...")
      if openDoc:
        b.endTree()
        openDoc = false
      continue
    if not openDoc:
      b.addTree "doc"
      openDoc = true
    parseNodes(ps, b, 0)
  if openDoc: b.endTree()
  b.endTree()

proc yamlToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = YamlParser(lines: splitLines(src), i: 0, diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseStream(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc yamlToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = yamlToAif(src, ignored)

proc renderYaml*(aif: string): string =
  renderWith(yamlDialect(), aif)

proc yamlRoundTrips*(src: string): bool =
  renderYaml(yamlToAif(src)) == src
