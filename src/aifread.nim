## aifread.nim — a minimal reader for aifparser's own AIF output.
##
## aifparser has always been one-way (source → AIF). The round-trip gate for the
## document dialects needs the inverse, and this is the smallest thing that can
## provide it.
##
## Why not `nifstreams` / `nifreader` from the nimony lib: those are built for the
## compiler's packed-token world (BiTable interning, PackedLineInfo, TagId) and
## expect the `(.nif27)` magic, which this repo deliberately rebrands to `(.aif27)`.
## The document dialects use a tiny subset — tags, string literals, and line-info
## suffixes — so a ~100-line reader here is both smaller and, more importantly,
## lets the unescaping be written as the EXACT inverse of `nifbuilder.addStrLit`
## (`"` … `"` with `\HH` for `c < ' '` or `c in ControlChars`). Owning both sides
## is what makes the inverse checkable rather than assumed.

type
  AifKind* = enum
    akEof
    akParLe      ## `(tag`
    akParRi      ## `)`
    akStrLit     ## `"..."`
    akOther      ## identifier / number / `.` — carried raw, unused by the doc dialects

  AifNode* = object
    kind*: AifKind
    tag*: string    ## for akParLe
    str*: string    ## for akStrLit / akOther

  AifReader* = object
    src*: string
    pos*: int

const AifControlChars = {'(', ')', '[', ']', '{', '}', '~', '#', '\'', '"', '\\',
                         ':', '@'}

proc hexVal(c: char): int =
  if c >= '0' and c <= '9': int(c) - int('0')
  elif c >= 'A' and c <= 'F': int(c) - int('A') + 10
  elif c >= 'a' and c <= 'f': int(c) - int('a') + 10
  else: -1

proc atEndR(r: AifReader): bool {.inline.} =
  r.pos >= r.src.len

proc skipWs(r: var AifReader) =
  while not atEndR(r):
    let c = r.src[r.pos]
    if c == ' ' or c == '\n' or c == '\t' or c == '\r': r.pos = r.pos + 1
    else: break

proc readStrLit(r: var AifReader): string =
  ## Exact inverse of nifbuilder.addStrLit.
  result = ""
  r.pos = r.pos + 1                     # opening quote
  while not atEndR(r):
    let c = r.src[r.pos]
    if c == '"':
      r.pos = r.pos + 1
      break
    elif c == '\\':
      let h1 = if r.pos + 1 < r.src.len: hexVal(r.src[r.pos + 1]) else: -1
      let h2 = if r.pos + 2 < r.src.len: hexVal(r.src[r.pos + 2]) else: -1
      if h1 >= 0 and h2 >= 0:
        result.add char(h1 * 16 + h2)
        r.pos = r.pos + 3
      else:
        # not a well-formed escape; keep the byte so nothing is silently dropped
        result.add c
        r.pos = r.pos + 1
    else:
      result.add c
      r.pos = r.pos + 1

proc skipSuffixes(r: var AifReader) =
  ## Consume a NIF27 line-info suffix (`@<b62>,<b62>[,file]` or the bare `~<b62>`
  ## shorthand for a negative column) and/or a `#comment#` suffix. These attach
  ## DIRECTLY to the tag with no separating whitespace, so a reader that stops
  ## only at whitespace would fold them into the tag name and every tag match
  ## would silently fail.
  while not atEndR(r):
    let c = r.src[r.pos]
    if c == '@' or c == '~':
      r.pos = r.pos + 1
      while not atEndR(r):
        let d = r.src[r.pos]
        if d == ' ' or d == '\n' or d == '\t' or d == '\r' or d == '(' or
           d == ')' or d == '#':
          break
        r.pos = r.pos + 1
    elif c == '#':
      r.pos = r.pos + 1
      while not atEndR(r) and r.src[r.pos] != '#': r.pos = r.pos + 1
      if not atEndR(r): r.pos = r.pos + 1     # closing '#'
    else:
      break

proc readTag(r: var AifReader): string =
  ## Reads the tag right after `(`. A tag ends at whitespace, `(`, `)`, or the
  ## start of a line-info / comment suffix.
  result = ""
  while not atEndR(r):
    let c = r.src[r.pos]
    if c == ' ' or c == '\n' or c == '\t' or c == '\r' or c == '(' or c == ')' or
       c == '@' or c == '~' or c == '#':
      break
    result.add c
    r.pos = r.pos + 1
  skipSuffixes(r)

proc nextAif*(r: var AifReader): AifNode =
  skipWs(r)
  if atEndR(r):
    return AifNode(kind: akEof, tag: "", str: "")
  let c = r.src[r.pos]
  if c == '(':
    r.pos = r.pos + 1
    let t = readTag(r)
    return AifNode(kind: akParLe, tag: t, str: "")
  elif c == ')':
    r.pos = r.pos + 1
    return AifNode(kind: akParRi, tag: "", str: "")
  elif c == '"':
    let s = readStrLit(r)
    skipSuffixes(r)          # an atom may also carry a line-info/comment suffix
    return AifNode(kind: akStrLit, tag: "", str: s)
  else:
    var s = ""
    while not atEndR(r):
      let d = r.src[r.pos]
      if d == ' ' or d == '\n' or d == '\t' or d == '\r' or d == '(' or d == ')':
        break
      s.add d
      r.pos = r.pos + 1
    if s.len == 0:
      # defensive: never spin on a byte we failed to classify
      r.pos = r.pos + 1
      s.add c
    return AifNode(kind: akOther, tag: "", str: s)

proc dialectOf*(src: string): string =
  ## Reads the `(.dialect "…")` header directive without walking the body.
  var r = AifReader(src: src, pos: 0)
  var guard = 0
  while guard < 64:
    guard = guard + 1
    let n = nextAif(r)
    if n.kind == akEof: break
    if n.kind == akParLe and n.tag == ".dialect":
      let v = nextAif(r)
      if v.kind == akStrLit: return v.str
      return ""
    if n.kind == akParLe and n.tag != "" and n.tag[0] != '.':
      break   # reached the body; no dialect directive present
  return ""
