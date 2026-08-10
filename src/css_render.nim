## css_render.nim — `css-parsed` AIF → CSS source.
##
## INCLUDE file, spliced into `cssparser.nim`. Do not import.
##
## This is a PURE IN-ORDER WALK: it emits the stored text of leaf nodes and the
## fixed text of punctuation nodes, in the order they appear, and nothing else.
## There is no reconstruction, no re-indentation, no re-quoting — every byte of
## the output came from a leaf that the parser recorded.
##
## That property is the whole design. It means byte-exactness does not depend on
## the renderer agreeing with the parser about optional syntax, because there IS
## no optional syntax at this layer: what was written is what was stored.

proc cssTextTag(tag: string): bool =
  ## Leaf tags whose string child IS source text.
  case tag
  of "ws", "comment", "ident", "num", "dim", "pct", "str", "hash", "fn", "url",
     "op", "prop", "name", "raw": true
  else: false

proc cssPunct(tag: string): string =
  ## Tags that stand for a fixed punctuation byte.
  case tag
  of "lbrace": "{"
  of "rbrace": "}"
  of "colon": ":"
  of "semi": ";"
  else: ""

proc renderCss*(aif: string): string =
  result = ""
  var r = AifReader(src: aif, pos: 0)
  # `skip` counts nesting inside a subtree whose text must NOT be emitted: the
  # header directives, and `(code "...")` inside an err node (that string is a
  # diagnostic slug, not source).
  var skipDepth = 0
  var stack: seq[string] = @[]
  var pendingText = ""
  var wantText = false

  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      stack.add n.tag
      if skipDepth > 0:
        skipDepth = skipDepth + 1
      elif n.tag.len > 0 and n.tag[0] == '.':
        skipDepth = 1                     # a header directive
      elif n.tag == "code":
        skipDepth = 1                     # error slug, not source
      else:
        let p = cssPunct(n.tag)
        if p.len > 0:
          result.add p
        wantText = cssTextTag(n.tag)
        pendingText = ""
    of akParRi:
      if stack.len > 0:
        discard stack.pop()
      if skipDepth > 0:
        skipDepth = skipDepth - 1
      wantText = false
    of akStrLit:
      if skipDepth == 0 and wantText:
        result.add n.str
        wantText = false
      pendingText = n.str
    of akOther:
      discard
    of akEof:
      break
