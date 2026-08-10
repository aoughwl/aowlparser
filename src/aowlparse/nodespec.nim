## nodespec.nim — the ONE declaration a dialect makes about its nodes.
##
## This is the core idea of aowlparse. A dialect declares, once, what each of
## its tags IS:
##
##   nkText    a leaf whose string child is source text        (ws, ident, name)
##   nkPunct   a marker standing for fixed literal bytes       (lbrace -> "{")
##   nkStruct  structure only; contributes no bytes            (rule, elem, doc)
##   nkOpaque  a leaf whose string child is NOT source         (code, in err nodes)
##
## BOTH the parser and the renderer read this same declaration. That is the
## point. Writing them separately — as css_render.nim and html_render.nim
## originally were — lets a renderer disagree with its parser about whether a
## byte is emitted, and that disagreement is precisely the bug class the
## byte-exact gate exists to catch. Here it is not merely caught, it is
## unrepresentable: there is one table, and both sides obey it.
##
## A dialect that adds a node and forgets to classify it gets a loud failure
## from `validateSpec` rather than a silent byte loss.

type
  NodeKind* = enum
    nkText      ## string child is source text, emitted verbatim
    nkPunct     ## no child; stands for `lit` bytes
    nkStruct    ## structure only; emits nothing itself
    nkOpaque    ## string child is metadata, never emitted

  NodeSpec* = object
    tag*: string
    kind*: NodeKind
    lit*: string      ## for nkPunct: the literal bytes this tag stands for

  Dialect* = object
    name*: string        ## the `.dialect` header value, e.g. "css-parsed"
    nodes*: seq[NodeSpec]

proc text*(tag: string): NodeSpec =
  NodeSpec(tag: tag, kind: nkText, lit: "")

proc punct*(tag, lit: string): NodeSpec =
  NodeSpec(tag: tag, kind: nkPunct, lit: lit)

proc struct*(tag: string): NodeSpec =
  NodeSpec(tag: tag, kind: nkStruct, lit: "")

proc opaque*(tag: string): NodeSpec =
  NodeSpec(tag: tag, kind: nkOpaque, lit: "")

proc find*(d: Dialect; tag: string): int =
  ## Index of `tag` in the dialect, or -1. Linear is fine: dialects have tens of
  ## tags, and a hash table here would cost more than it saves.
  var i = 0
  while i < d.nodes.len:
    if d.nodes[i].tag == tag: return i
    i = i + 1
  return -1

proc kindOf*(d: Dialect; tag: string): NodeKind =
  let i = find(d, tag)
  if i >= 0: d.nodes[i].kind else: nkStruct

proc litOf*(d: Dialect; tag: string): string =
  let i = find(d, tag)
  if i >= 0: d.nodes[i].lit else: ""

proc knows*(d: Dialect; tag: string): bool =
  find(d, tag) >= 0

proc validateSpec*(d: Dialect): string =
  ## Returns "" when the declaration is well formed, else the first problem.
  ## Called by the gate harness so a malformed dialect fails loudly at test time
  ## rather than silently dropping bytes at render time.
  var i = 0
  while i < d.nodes.len:
    let n = d.nodes[i]
    if n.tag.len == 0:
      return "a node spec has an empty tag"
    if n.kind == nkPunct and n.lit.len == 0:
      return "punct node '" & n.tag & "' declares no literal"
    if n.kind != nkPunct and n.lit.len > 0:
      return "non-punct node '" & n.tag & "' declares a literal"
    var j = i + 1
    while j < d.nodes.len:
      if d.nodes[j].tag == n.tag:
        return "duplicate node spec for '" & n.tag & "'"
      j = j + 1
    i = i + 1
  return ""
