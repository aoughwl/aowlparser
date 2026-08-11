## cfgparser.nim — config files ↔ AIF, the `cfg-parsed` dialect.
##
## Covers the ini family as it actually appears on disk, which for this machine
## means Nim's `nim.cfg` dialect above all: `[sections]`, `key = value`,
## command-line switches (`--path:"$lib"`, `-d:release`), bracketed keys
## (`warning[SmallLshouldNotBeUsed] = off`), `@if`/`@end` conditionals, and
## `#`/`;` comments.
##
## THE HAZARD here is not embedded content, as it is for md/yaml/html — it is
## that **a config file is three grammars wearing one extension**. The same
## directory holds `--path:"x"` (a switch), `path = "x"` (an assignment) and
## `[Package]` (a section header), and a parser that guesses wrong still
## round-trips byte-for-byte because every byte is preserved either way. Only
## the shape gate can tell an `entry` that should have been a `switch`.
##
## SCOPE: concrete syntax. Values keep their quotes, their `$variables` and
## their spelling; nothing is interpolated, resolved against a Nim install, or
## typed. `@if` conditions are text — evaluating them needs the compiler's
## configuration state, which is a different program.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

proc cfgDialect*(): Dialect =
  Dialect(name: "cfg-parsed", nodes: @[
    struct "config",
    struct "section",    ## `[name]` and the entries under it
    struct "entry",      ## `key = value`
    struct "switch",     ## `--key:value` or `-d:x`
    struct "cond",       ## `@if …` / `@elif …` / `@else` / `@end`
    struct "line",       ## a content line matching none of the above
    text "open",         ## `[`
    text "close",        ## `]`
    text "name",         ## a section's name
    text "marker",       ## `--`, `-`, `@`
    text "key",
    text "op",           ## `=` or `:`
    text "value",
    text "comment",
    text "ws",
    text "nl",
    text "blank",
  ])

type
  CfgParser = object
    lines: seq[string]
    i: int
    diags: seq[Diagnostic]

proc splitLines(src: string): seq[string] =
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

proc skipWs(body: string; p: int): int =
  result = p
  while result < body.len and (body[result] == ' ' or body[result] == '\t'):
    result = result + 1

proc emitEol(b: var Builder; line: string; start: int) =
  if start < line.len:
    leaf(b, "nl", slice(line, start, line.len))

proc emitWs(b: var Builder; body: string; p: int): int =
  let e = skipWs(body, p)
  if e > p: leaf(b, "ws", slice(body, p, e))
  return e

proc commentStart(body: string; p: int): int =
  ## `#` or `;` outside a quoted value. A `#` inside `"…"` is part of the value:
  ## `--passC:"-DX=#1"` is one switch, not a switch and a comment.
  var i = p
  var inQuote = false
  while i < body.len:
    let c = body[i]
    if c == '"':
      inQuote = not inQuote
    elif not inQuote and (c == '#' or c == ';'):
      return i
    i = i + 1
  return body.len

proc emitTail(b: var Builder; line, body: string; p: int) =
  ## Trailing whitespace, a comment, and the terminator.
  let q = emitWs(b, body, p)
  if q < body.len:
    leaf(b, "comment", slice(body, q, body.len))
  emitEol(b, line, body.len)

proc emitValue(b: var Builder; line, body: string; p: int) =
  ## The rest of the line up to a comment: value, then the tail.
  let cs = commentStart(body, p)
  var e = cs
  while e > p and (body[e-1] == ' ' or body[e-1] == '\t'): e = e - 1
  if e > p: leaf(b, "value", slice(body, p, e))
  emitTail(b, line, body, e)

proc isSectionHeader(body: string): bool =
  let p = skipWs(body, 0)
  if p >= body.len or body[p] != '[': return false
  # A `]` must follow on the same line, or it is not a header.
  var i = p + 1
  while i < body.len:
    if body[i] == ']': return true
    i = i + 1
  return false

proc switchLen(body: string; p: int): int =
  ## Length of a leading `--` or `-` switch marker, else 0. `-` alone is not a
  ## switch, and neither is a bare `-` followed by a space.
  if p >= body.len or body[p] != '-': return 0
  if p + 1 < body.len and body[p+1] == '-':
    if p + 2 < body.len and body[p+2] != ' ': return 2
    return 0
  if p + 1 < body.len and body[p+1] != ' ' and body[p+1] != '-': return 1
  return 0

proc findAssign(body: string; p, stop: int): int =
  ## Index of the `=` or `:` that separates a key from a value, or -1. Quoted
  ## text is skipped so `path = "a:b"` splits at the `=`, not inside the value.
  var i = p
  var inQuote = false
  while i < stop:
    let c = body[i]
    if c == '"': inQuote = not inQuote
    elif not inQuote and (c == '=' or c == ':'): return i
    i = i + 1
  return -1

proc emitKeyed(b: var Builder; line, body: string; p, stop: int) =
  ## `key <op> value`, where the op may be absent (a bare flag).
  let a = findAssign(body, p, stop)
  if a < 0:
    var e = stop
    while e > p and (body[e-1] == ' ' or body[e-1] == '\t'): e = e - 1
    if e > p: leaf(b, "key", slice(body, p, e))
    emitTail(b, line, body, e)
    return
  var ke = a
  while ke > p and (body[ke-1] == ' ' or body[ke-1] == '\t'): ke = ke - 1
  if ke > p: leaf(b, "key", slice(body, p, ke))
  discard emitWs(b, body, ke)
  leaf(b, "op", slice(body, a, a + 1))
  let v = emitWs(b, body, a + 1)
  emitValue(b, line, body, v)

proc parseConfig(ps: var CfgParser; b: var Builder) =
  addAifHeader(b, "cfg-parsed")
  b.addTree "config"
  var inSection = false
  let n = ps.lines.len
  while ps.i < n:
    let line = ps.lines[ps.i]
    let body = stripEol(line)
    if isBlankLine(line):
      leaf(b, "blank", line)
      ps.i = ps.i + 1
      continue
    let p0 = skipWs(body, 0)
    if p0 < body.len and (body[p0] == '#' or body[p0] == ';'):
      discard emitWs(b, body, 0)
      leaf(b, "comment", slice(body, p0, body.len))
      emitEol(b, line, body.len)
      ps.i = ps.i + 1
      continue

    if isSectionHeader(body):
      # A header ENDS the previous section and opens a new one, so entries nest
      # under the header they follow — the one structural claim this dialect
      # makes that a byte comparison cannot check.
      if inSection: b.endTree()
      b.addTree "section"
      inSection = true
      discard emitWs(b, body, 0)
      leaf(b, "open", "[")
      var i = p0 + 1
      var e = i
      while e < body.len and body[e] != ']': e = e + 1
      if e > i: leaf(b, "name", slice(body, i, e))
      leaf(b, "close", "]")
      emitTail(b, line, body, e + 1)
      ps.i = ps.i + 1
      continue

    let cs = commentStart(body, p0)
    if body[p0] == '@':
      b.addTree "cond"
      discard emitWs(b, body, 0)
      leaf(b, "marker", "@")
      emitKeyed(b, line, body, p0 + 1, cs)
      b.endTree()
      ps.i = ps.i + 1
      continue

    let sw = switchLen(body, p0)
    if sw > 0:
      b.addTree "switch"
      discard emitWs(b, body, 0)
      leaf(b, "marker", slice(body, p0, p0 + sw))
      emitKeyed(b, line, body, p0 + sw, cs)
      b.endTree()
      ps.i = ps.i + 1
      continue

    if findAssign(body, p0, cs) >= 0:
      b.addTree "entry"
      discard emitWs(b, body, 0)
      emitKeyed(b, line, body, p0, cs)
      b.endTree()
      ps.i = ps.i + 1
      continue

    b.addTree "line"
    discard emitWs(b, body, 0)
    emitValue(b, line, body, p0)
    b.endTree()
    ps.i = ps.i + 1
  if inSection: b.endTree()
  b.endTree()

proc cfgToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = CfgParser(lines: splitLines(src), i: 0, diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseConfig(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc cfgToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = cfgToAif(src, ignored)

proc renderCfg*(aif: string): string =
  renderWith(cfgDialect(), aif)

proc cfgRoundTrips*(src: string): bool =
  renderCfg(cfgToAif(src)) == src
