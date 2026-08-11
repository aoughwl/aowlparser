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
##
## Two constructs are deliberately NOT modelled, and the suite gate names both
## rather than counting them as agreement: an explicit `? key` and a COLLECTION
## used as a key (`{a: 1}: v`), whose collection stays the key's text.

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
    struct "flow",       ## a `[…]` / `{…}` collection, however many lines
    text "open",         ## `[` or `{`
    text "close",        ## `]` or `}`
    text "comma",
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

proc opensQuote(body: string; i, regionStart: int): bool =
  ## Whether the quote at `i` STARTS a quoted scalar. A quote in the middle of a
  ## plain scalar is an ordinary character: `bla"keks: foo` is a mapping with the
  ## key `bla"keks`, and treating the quote as an opener swallowed the `:` that
  ## made it one (suite case AZW3).
  if i >= body.len: return false
  let c = body[i]
  if c != '\'' and c != '"': return false
  if i == regionStart: return true
  let p = body[i-1]
  return p == ' ' or p == '\t' or p == ',' or p == '[' or p == '{' or p == ':'

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
    if opensQuote(body, i, start):
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
    if opensQuote(body, i, start):
      let j = skipQuoted(body, i)
      if j > i:
        i = j
        continue
    if c == '[' or c == '{': depth = depth + 1
    elif c == ']' or c == '}':
      # Clamped, never negative: a stray `]` in a plain scalar (`bla]keks: foo`)
      # would otherwise leave the scan at depth -1 and hide the real key colon.
      if depth > 0: depth = depth - 1
    elif c == ':' and depth == 0:
      # A TAB separates just as well as a space. YAML forbids tabs for
      # INDENTATION, which is a different rule, and conflating the two made
      # `- foo:<TAB>bar` no mapping at all — caught by the suite's 6BCT/DC7X
      # against the oracle, invisible to the round-trip.
      if i + 1 >= body.len or body[i+1] == ' ' or body[i+1] == '\t': return i
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
  return p + 1 >= body.len or body[p+1] == ' ' or body[p+1] == '\t'

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
  return body.len == 3 or body[3] == ' ' or body[3] == '\t'

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
  return body.len == 3 or body[3] == ' ' or body[3] == '\t'

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

proc flowScalarEnd(body: string; p: int): int =
  ## End of one plain or quoted scalar inside a flow collection: it runs to a
  ## separator (`,`), a close, a `: ` that makes it a key, a nested collection,
  ## or a comment. Trailing spaces are left out so they can be emitted as `ws`.
  var i = p
  while i < body.len:
    let c = body[i]
    if opensQuote(body, i, p):
      let j = skipQuoted(body, i)
      if j > i:
        i = j
        continue
    if c == ',' or c == ']' or c == '}' or c == '[' or c == '{': break
    if c == ':':
      # After a QUOTED scalar a colon separates with no space required — the
      # JSON-compatible spelling `{"foo":bar}`, and `{"key"::value}` whose value
      # really is `:value` (suite cases 5MUD, 5T43, K3WX).
      if i > p and (body[i-1] == '"' or body[i-1] == '\''): break
      if i + 1 >= body.len or body[i+1] == ' ' or body[i+1] == '\t' or
         body[i+1] == ',' or body[i+1] == ']' or body[i+1] == '}': break
    if c == '#' and i > p and (body[i-1] == ' ' or body[i-1] == '\t'): break
    i = i + 1
  while i > p and (body[i-1] == ' ' or body[i-1] == '\t'): i = i - 1
  return i

proc emitFlow(ps: var YamlParser; b: var Builder; p0: int): int
proc emitFlowElement(ps: var YamlParser; b: var Builder; p: int;
                     opener: char): int

proc skipFlowTrivia(ps: var YamlParser; b: var Builder; p: int): int =
  ## Whitespace, comments and LINE BREAKS between two flow tokens. A flow
  ## collection is the one construct here that ignores line structure, so this
  ## is the only place a line boundary is crossed without ending a node.
  var i = p
  while true:
    let body = stripEol(ps.lines[ps.i])
    i = emitWs(b, body, i)
    if i < body.len and body[i] == '#' and
       (i == 0 or body[i-1] == ' ' or body[i-1] == '\t'):
      leaf(b, "comment", slice(body, i, body.len))
      i = body.len
    if i < body.len: return i
    # EOF inside an unclosed flow: return WITHOUT emitting the terminator, so
    # the caller emits it exactly once. Emitting it here too put a second `\n`
    # in the output of `a: [1, 2` — a byte the input never had.
    if ps.i + 1 >= ps.lines.len: return i
    emitEol(b, ps.lines[ps.i], body.len)
    ps.i = ps.i + 1
    i = 0

proc flowNextSignificant(ps: YamlParser; li0, i0: int): char =
  ## The next character that is not whitespace, a comment or a line break —
  ## `'\0'` at end of input. Read-only: the flow scanner needs to know what
  ## comes next BEFORE deciding which node to open, and opening one is what
  ## makes emission irreversible.
  var li = li0
  var i = i0
  while li < ps.lines.len:
    let body = stripEol(ps.lines[li])
    while i < body.len and (body[i] == ' ' or body[i] == '\t'): i = i + 1
    if i < body.len and body[i] == '#' and
       (i == 0 or body[i-1] == ' ' or body[i-1] == '\t'):
      i = body.len
    if i < body.len: return body[i]
    li = li + 1
    i = 0
  return '\0'

proc flowNextIsColon(ps: YamlParser; li0, i0: int): bool =
  ## Read-only lookahead: is the next significant character a `:`, even if it is
  ## on a LATER line? A flow collection ignores line structure, so
  ##
  ##     { "foo"
  ##       :bar }
  ##
  ## is one key — and deciding on the current line alone made it none, because
  ## the `entry` node has to be opened BEFORE the key leaf is emitted (suite
  ## cases 5MUD, K3WX).
  var li = li0
  var i = i0
  while li < ps.lines.len:
    let body = stripEol(ps.lines[li])
    while i < body.len and (body[i] == ' ' or body[i] == '\t'): i = i + 1
    if i < body.len and body[i] == '#' and
       (i == 0 or body[i-1] == ' ' or body[i-1] == '\t'):
      i = body.len
    if i < body.len: return body[i] == ':'
    li = li + 1
    i = 0
  return false

proc propsEnd(body: string; p: int): int =
  ## Past any leading NODE PROPERTIES — `&anchor`, `!tag`, `!!str` — and the
  ## spaces after them. Properties are not the node; `center: &ORIGIN {x: 1}` is
  ## a flow mapping with an anchor, and stopping at the `&` made the whole line
  ## one opaque scalar with its two keys lost (suite case C4HZ).
  var i = p
  while i < body.len and (body[i] == '&' or body[i] == '!'):
    var j = i
    while j < body.len and body[j] != ' ' and body[j] != '\t' and
          body[j] != ',' and body[j] != ']' and body[j] != '}' and
          body[j] != '[' and body[j] != '{': j = j + 1
    if j == i: break
    i = j
    while i < body.len and (body[i] == ' ' or body[i] == '\t'): i = i + 1
  return i

proc elementEndsAtColon(ps: YamlParser; li0, i0: int): bool =
  ## Read-only: does this flow element finish at a `:`, making it a KEY? The
  ## scan crosses lines, because a plain scalar inside a flow collection may:
  ##
  ##     { multi
  ##       line, a: b}
  ##
  ## is ONE key (`multi line`), and stopping at the line end counted two.
  var li = li0
  var i = i0
  while li < ps.lines.len:
    let body = stripEol(ps.lines[li])
    let e = flowScalarEnd(body, i)
    i = e
    while i < body.len and (body[i] == ' ' or body[i] == '\t'): i = i + 1
    if i < body.len and body[i] == '#' and
       (i == 0 or body[i-1] == ' ' or body[i-1] == '\t'):
      i = body.len
    if i >= body.len:
      li = li + 1
      i = 0
      continue
    return body[i] == ':'
  return false

proc emitFlowElement(ps: var YamlParser; b: var Builder; p: int;
                     opener: char): int =
  ## One element: a scalar, a nested collection, or a `key: value` pair. In a
  ## `[` the element is an `item`; a pair inside either bracket is an `entry`,
  ## which is what makes `{a: 1}` and `a:\n  b: 1` count the same to a consumer
  ## asking "what are the mapping entries?".
  var i = p
  var body = stripEol(ps.lines[ps.i])
  let isSeq = opener == '['
  if isSeq: b.addTree "item"

  # Properties (`&anchor`, `!tag`) belong to the node that follows them, so a
  # collection behind an anchor is still a collection.
  var q = propsEnd(body, i)
  if q > i:
    leaf(b, "value", trimRight(slice(body, i, q)))
    i = emitWs(b, body, i + trimRight(slice(body, i, q)).len)

  if i < body.len and (body[i] == '[' or body[i] == '{'):
    i = emitFlow(ps, b, i)
    if isSeq: b.endTree()
    return i

  # Is this element a KEY? In a flow MAPPING every element is one, with or
  # without a value: `{a, b: 1}` has two keys, `a`'s value being null.
  let isKey = elementEndsAtColon(ps, ps.i, i) or not isSeq
  let tag = if isKey: "key" else: "value"
  if isKey: b.addTree "entry"

  # The element's own text, which may continue onto later lines.
  while true:
    body = stripEol(ps.lines[ps.i])
    let e = flowScalarEnd(body, i)
    if e > i: leaf(b, tag, slice(body, i, e))
    i = e
    var k = i
    while k < body.len and (body[k] == ' ' or body[k] == '\t'): k = k + 1
    if k < body.len and body[k] == '#' and
       (k == 0 or body[k-1] == ' ' or body[k-1] == '\t'):
      k = body.len          # a trailing comment is not significant content
    if k < body.len: break     # `:`, `,` or a close on this line: done here
    # Nothing significant left on this line. A plain scalar inside a flow
    # collection MAY continue on the next one, so what happens next decides:
    # a separator or a close ends the element (and its trivia belongs to the
    # collection); anything else is more of this same scalar.
    let nxt = flowNextSignificant(ps, ps.i, i)
    if nxt == ',' or nxt == ']' or nxt == '}' or nxt == '\0': break
    let before = ps.i
    let j = skipFlowTrivia(ps, b, i)
    if ps.i == before and j == i: break
    i = j
    body = stripEol(ps.lines[ps.i])
    if i < body.len and body[i] == ':': break        # the key's colon
    if i >= body.len: break

  if isKey:
    # The colon may be behind a comment and a line break (`{ "foo" # c` ⏎ `:b }`).
    if flowNextSignificant(ps, ps.i, i) == ':':
      i = skipFlowTrivia(ps, b, i)
    body = stripEol(ps.lines[ps.i])
    var k2 = i
    while k2 < body.len and (body[k2] == ' ' or body[k2] == '\t'): k2 = k2 + 1
    if k2 < body.len and body[k2] == ':':
      i = emitWs(b, body, i)
      leaf(b, "colon", ":")
      i = i + 1
      i = skipFlowTrivia(ps, b, i)
      body = stripEol(ps.lines[ps.i])
      if i < body.len and body[i] != ',' and body[i] != ']' and body[i] != '}':
        if body[i] == '[' or body[i] == '{':
          i = emitFlow(ps, b, i)
        else:
          let q2 = propsEnd(body, i)
          if q2 > i:
            leaf(b, "value", trimRight(slice(body, i, q2)))
            i = emitWs(b, body, i + trimRight(slice(body, i, q2)).len)
          if i < body.len and (body[i] == '[' or body[i] == '{'):
            i = emitFlow(ps, b, i)
          else:
            let e2 = flowScalarEnd(body, i)
            if e2 > i: leaf(b, "value", slice(body, i, e2))
            i = e2
    b.endTree()
  if isSeq: b.endTree()
  return i

proc emitFlow(ps: var YamlParser; b: var Builder; p0: int): int =
  ## A whole `[…]` / `{…}`, which may span any number of lines. Returns the
  ## index just past the close, on whatever line that turned out to be
  ## (`ps.i` is left on that line).
  var body = stripEol(ps.lines[ps.i])
  let opener = body[p0]
  b.addTree "flow"
  leaf(b, "open", slice(body, p0, p0 + 1))
  var i = p0 + 1
  while true:
    i = skipFlowTrivia(ps, b, i)
    body = stripEol(ps.lines[ps.i])
    if i >= body.len: break                   # EOF: the flow is never closed
    let c = body[i]
    if c == ']' or c == '}':
      leaf(b, "close", slice(body, i, i + 1))
      i = i + 1
      break
    if c == ',':
      leaf(b, "comma", ",")
      i = i + 1
      continue
    let beforeLine = ps.i
    let beforeI = i
    i = emitFlowElement(ps, b, i, opener)
    if ps.i == beforeLine and i == beforeI:
      # No progress: a byte no rule claims. Emit it verbatim and step over it,
      # so malformed input cannot hang the parser — `robust.sh` holds every
      # dialect to that, and a flow scanner is where a spin would hide.
      leaf(b, "value", slice(body, i, i + 1))
      i = i + 1
  b.endTree()
  return i

proc emitRest(ps: var YamlParser; b: var Builder; line, body: string; p: int;
              info: var LineInfo) =
  ## Value, trailing comment and terminator — everything from `p` on.
  let pq = propsEnd(body, p)
  if pq < body.len and (body[pq] == '[' or body[pq] == '{'):
    # A flow collection is the WHOLE value, and it may run past the end of this
    # line. Brackets elsewhere in a plain scalar (`note: see [1]`) are ordinary
    # characters and never reach here. Node properties in front of it — an
    # anchor or a tag — are emitted first and do not hide the collection.
    var i = p
    if pq > p:
      leaf(b, "value", trimRight(slice(body, p, pq)))
      i = emitWs(b, body, p + trimRight(slice(body, p, pq)).len)
    i = emitFlow(ps, b, i)
    let endBody = stripEol(ps.lines[ps.i])
    i = emitWs(b, endBody, i)
    if i < endBody.len:
      let cs2 = commentStart(endBody, i)
      if cs2 > i: leaf(b, "value", slice(endBody, i, cs2))
      if cs2 < endBody.len: leaf(b, "comment", slice(endBody, cs2, endBody.len))
    emitEol(b, ps.lines[ps.i], endBody.len)
    return
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
  emitEol(b, line, body.len)

proc lineTag(body: string; p: int): string =
  if isSeqMarker(body, p): return "item"
  if findKeyColon(body, p) >= 0: return "entry"
  return "line"

proc emitInner(ps: var YamlParser; b: var Builder; line, body: string;
               p0: int; outermost: bool; info: var LineInfo) =
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
      emitInner(ps, b, line, body, p, false, info)
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
    emitRest(ps, b, line, body, p, info)
    if not outermost: b.endTree()
    return
  if not outermost: b.addTree "line"
  emitRest(ps, b, line, body, p, info)
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
    emitInner(ps, b, line, body, p, true, info)
    # `emitInner` may have consumed further lines (a flow collection spanning
    # them), so the cursor is wherever it left off — not necessarily `line`.
    ps.i = ps.i + 1
    if info.blockScalar:
      swallowScalar(ps, b, ind)
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
    emitInner(ps, b, line, body, p, false, info)
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
      emitRest(ps, b, line, body, 0, dinfo)
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
