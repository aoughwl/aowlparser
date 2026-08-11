## html_view.nim — reading things OUT of a parsed HTML document.
##
## The dialect's job is to preserve every byte; this is the other direction —
## small queries over the tree that callers actually want. It is a library
## module rather than a snippet inside an example because the first version
## lived in an example, was wrong, and nothing could test it there.
##
## `<style>` and `<script>` content is RAW TEXT in HTML: the parser does not
## treat it as markup (that is the dialect's headline hazard), so it arrives as
## a plain `text` leaf inside the element. Pulling it back out lets one tool
## hand a `<style>` block to the CSS parser — two dialects composing over one
## tree, which is the whole argument for having one tree.

import aifread

proc lowerAscii(s: string): string =
  result = ""
  for c in s.items:
    if c >= 'A' and c <= 'Z': result.add char(int(c) + 32)
    else: result.add c

proc rawTextOf*(aif: string; tagName: string): seq[string] =
  ## The text content of every `<tagName>` element, in document order.
  ##
  ## The bookkeeping keys on DEPTH, not on a "am I inside a start tag?" flag: a
  ## `stag` contains `(lt)`, `(name …)` and `(gt)`, each with its own closing
  ## paren, so the naive flag is cleared by the first of those and the scan
  ## silently finds nothing. That bug shipped in an example for exactly as long
  ## as it took to write a negative test.
  result = @[]
  let want = lowerAscii(tagName)
  var r = AifReader(src: aif, pos: 0)
  var depth = 0
  var stagDepth = -1
  var isWanted = false
  var expectName = false
  var afterTag = false
  var inText = false
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      depth = depth + 1
      if n.tag == "stag":
        stagDepth = depth
        isWanted = false
      elif n.tag == "name" and stagDepth >= 0:
        expectName = true
      elif n.tag == "text" and afterTag:
        inText = true
      elif n.tag == "etag":
        afterTag = false
    of akStrLit:
      if expectName:
        isWanted = lowerAscii(n.str) == want
        expectName = false
      elif inText:
        result.add n.str
        inText = false
        afterTag = false
    of akParRi:
      if depth == stagDepth:
        stagDepth = -1
        afterTag = isWanted
      depth = depth - 1
    else: discard

proc styleTexts*(aif: string): seq[string] =
  ## Every `<style>` element's CSS.
  rawTextOf(aif, "style")

proc scriptTexts*(aif: string): seq[string] =
  ## Every `<script>` element's source. Note that an external script
  ## (`<script src=…>`) has no text, so it contributes nothing here.
  rawTextOf(aif, "script")
