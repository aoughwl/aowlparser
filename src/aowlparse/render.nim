## render.nim — ONE renderer for every dialect.
##
## css_render.nim and html_render.nim were the same algorithm twice, differing
## only in two tables. Here the tables come from the dialect's `NodeSpec`
## declaration — the same one the parser emits against — so a renderer can no
## longer disagree with its parser about whether a byte is emitted.
##
## The algorithm is a PURE IN-ORDER WALK: emit the stored text of `nkText`
## leaves and the declared literal of `nkPunct` markers, in document order, and
## nothing else. No reconstruction, no re-indentation, no re-quoting. Every byte
## of the output came from a leaf the parser recorded or a literal the dialect
## declared.

import ../aifread
import nodespec

proc renderWith*(d: Dialect; aif: string): string =
  result = ""
  var skipDepth = 0
  var wantText = false
  var r = AifReader(src: aif, pos: 0)

  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      if skipDepth > 0:
        skipDepth = skipDepth + 1
      elif n.tag.len > 0 and n.tag[0] == '.':
        skipDepth = 1                       # a header directive
      else:
        case kindOf(d, n.tag)
        of nkPunct:
          result.add litOf(d, n.tag)
          wantText = false
        of nkText:
          wantText = true
        of nkOpaque:
          skipDepth = 1                     # metadata, never source
        of nkStruct:
          wantText = false
    of akParRi:
      if skipDepth > 0:
        skipDepth = skipDepth - 1
      wantText = false
    of akStrLit:
      if skipDepth == 0 and wantText:
        result.add n.str
        wantText = false
    of akOther:
      discard
    of akEof:
      break

proc undeclaredTags*(d: Dialect; aif: string): seq[string] =
  ## Every tag present in `aif` that the dialect does not declare.
  ##
  ## An undeclared tag renders as `nkStruct` — it contributes NO bytes — so
  ## forgetting to declare a node is a SILENT byte loss that only shows up as a
  ## mismatch somewhere in a large corpus file. This turns that into a named,
  ## immediate failure. The gate harness calls it on every case.
  result = @[]
  var r = AifReader(src: aif, pos: 0)
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    if n.kind == akParLe and n.tag.len > 0 and n.tag[0] != '.':
      if not knows(d, n.tag):
        var seen = false
        for t in result:
          if t == n.tag: seen = true
        if not seen: result.add n.tag

proc countTag*(aif, tag: string): int =
  ## Structural counting for shape gates. Uses the reader, not a substring scan,
  ## so a tag name appearing inside a string literal is not miscounted.
  result = 0
  var r = AifReader(src: aif, pos: 0)
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    if n.kind == akParLe and n.tag == tag:
      result = result + 1

proc maxNesting*(aif, tag: string): int =
  ## Deepest nesting of `tag` within itself.
  result = 0
  var cur = 0
  var stack: seq[bool] = @[]
  var r = AifReader(src: aif, pos: 0)
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    if n.kind == akParLe:
      let isIt = n.tag == tag
      stack.add isIt
      if isIt:
        cur = cur + 1
        if cur > result: result = cur
    elif n.kind == akParRi:
      if stack.len > 0:
        let wasIt = stack.pop()
        if wasIt: cur = cur - 1
