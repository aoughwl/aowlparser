## css_view.nim — a DECODED view of `css-parsed` AIF.
##
## The dialect stores raw lexemes because that is what makes byte-exactness
## reachable. A consumer that wants to reason about CSS rather than reproduce it
## needs the other shape: selectors, properties, and values as plain strings.
## That is this module — a read-only projection, not a second parser.
##
## The point of it is the pipeline it unlocks:
##
##     source.css  --aowlparser-->  .css.aif  --cssDeclarations-->  (prop, value)
##                                                     |
##                                        aoughwl-css validateValue(prop, value)
##
## aowlparser owns the SYNTAX (full CSS, error-recovering, never dies); the CSS
## library owns the SEMANTICS (MDN grammar matching). They compose because the
## validator's API is value-level. Neither has to absorb the other.
##
## `!important` is deliberately left ON the value string: `validator.nim` already
## peels it, and stripping it here would mean two places implementing the same
## rule and eventually disagreeing.

import aifread

type
  CssDecl* = object
    selector*: string    ## the enclosing rule's selector text, trimmed
    atRule*: string      ## enclosing at-rule name (e.g. "@media"), "" at top level
    prop*: string        ## property name, raw (case preserved)
    value*: string       ## value text, trimmed, `!important` included
    line*: int32

proc trimText(s: string): string =
  var a = 0
  var b = s.len
  while a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r'):
    a = a + 1
  while b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\n' or
                   s[b-1] == '\r'):
    b = b - 1
  result = ""
  var i = a
  while i < b:
    result.add s[i]
    i = i + 1

proc collapseWs(s: string): string =
  ## Runs of whitespace become a single space — the shape a value matcher wants,
  ## and the reason this is a VIEW and not the stored form.
  result = ""
  var lastWasWs = false
  for c in s.items:
    let isWs = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'
    if isWs:
      if not lastWasWs: result.add ' '
      lastWasWs = true
    else:
      result.add c
      lastWasWs = false

proc cssDeclarations*(aif: string): seq[CssDecl] =
  ## Every declaration in a `css-parsed` artifact, with its enclosing selector.
  result = @[]
  var r = AifReader(src: aif, pos: 0)
  var stack: seq[string] = @[]

  var selector = ""      ## selector of the innermost open rule
  var atRule = ""
  var curProp = ""
  var curVal = ""
  var collecting = ""    ## "sel" | "val" | "prop" | "name" | ""
  var selDepth = -1
  var atDepth = -1
  # Comments are TRIVIA. The dialect stores them inside `val` and `sel` because
  # byte-exactness requires it, but a decoded view must drop them: bootstrap ships
  # `transform: rotate(360deg) /* rtl:ignore */`, and folding that comment into the
  # value string makes a correct validator reject correct CSS. Found exactly that
  # way — 3 spurious findings over 4,368 real declarations.
  var inComment = false

  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      stack.add n.tag
      case n.tag
      of "sel":
        selector = ""
        collecting = "sel"
        selDepth = stack.len
      of "prelude":
        collecting = ""
      of "atrule":
        atDepth = stack.len
      of "name":
        if atDepth >= 0: collecting = "name"
      of "decl":
        curProp = ""
        curVal = ""
      of "prop":
        collecting = "prop"
      of "val":
        curVal = ""
        collecting = "val"
      of "comment":
        inComment = true
      else:
        discard
    of akStrLit:
      if not inComment:
        case collecting
        of "sel": selector.add n.str
        of "val": curVal.add n.str
        of "prop": curProp.add n.str
        of "name": atRule.add n.str
        else: discard
        if collecting == "prop" or collecting == "name": collecting = ""
    of akParRi:
      if stack.len > 0:
        let closed = stack.pop()
        if closed == "comment":
          inComment = false
        elif closed == "sel":
          collecting = ""
        elif closed == "val":
          collecting = ""
        elif closed == "decl":
          if curProp.len > 0:
            result.add CssDecl(selector: trimText(collapseWs(selector)),
                               atRule: atRule,
                               prop: trimText(curProp),
                               value: trimText(collapseWs(curVal)),
                               line: 0'i32)
          curProp = ""
          curVal = ""
        elif closed == "atrule":
          if stack.len < atDepth:
            atRule = ""
            atDepth = -1
    of akOther:
      discard
    of akEof:
      break

proc cssSelectors*(aif: string): seq[string] =
  ## Every rule's selector text, in document order.
  ##
  ## Tracked on the tag STACK, not on a bare flag: a `sel` node contains leaf
  ## nodes, each with its own closing paren, so "close on the next ParRi" would
  ## end the selector at its first token.
  result = @[]
  var r = AifReader(src: aif, pos: 0)
  var stack: seq[string] = @[]
  var cur = ""
  var inSel = false
  var inComment = false
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      stack.add n.tag
      if n.tag == "sel":
        inSel = true
        cur = ""
      elif n.tag == "comment":
        inComment = true
    of akStrLit:
      if inSel and not inComment: cur.add n.str
    of akParRi:
      if stack.len > 0:
        let closed = stack.pop()
        if closed == "comment":
          inComment = false
        elif closed == "sel":
          let t = trimText(collapseWs(cur))
          if t.len > 0: result.add t
          inSel = false
    of akOther:
      discard
    of akEof:
      break
