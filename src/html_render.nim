## html_render.nim — `html-parsed` AIF → HTML source.
##
## INCLUDE file, spliced into `htmlparser.nim`.
##
## Same pure in-order walk as css_render.nim: leaf text plus fixed punctuation,
## nothing reconstructed. See spec/html-dialect.md.

proc htmlTextTag(tag: string): bool =
  case tag
  of "text", "comment", "doctype", "cdata", "pi", "name", "ws", "aname",
     "aval", "op", "raw": true
  else: false

proc htmlPunct(tag: string): string =
  case tag
  of "lt": "<"
  of "ltslash": "</"
  of "gt": ">"
  of "eq": "="
  of "selfclose": "/"
  else: ""

proc renderHtml*(aif: string): string =
  result = ""
  var r = AifReader(src: aif, pos: 0)
  var skipDepth = 0
  var wantText = false

  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      if skipDepth > 0:
        skipDepth = skipDepth + 1
      elif n.tag.len > 0 and n.tag[0] == '.':
        skipDepth = 1                     # header directive
      elif n.tag == "code":
        skipDepth = 1                     # diagnostic slug, not source
      else:
        let p = htmlPunct(n.tag)
        if p.len > 0:
          result.add p
        wantText = htmlTextTag(n.tag)
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
