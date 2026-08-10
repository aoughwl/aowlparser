## html_lex.nim — HTML tokenizer for the `html-parsed` AIF dialect.
##
## INCLUDE file, spliced into `htmlparser.nim`. Do not import.
##
## Same contract as css_lex.nim: every token carries its EXACT source slice in
## `raw`, and concatenating the stream reproduces the input byte-for-byte.
##
## Unlike CSS, HTML tokenization is MODE-DEPENDENT: the content of `<script>`,
## `<style>`, `<textarea>` and `<title>` is not markup, and a `<` inside them is
## just a character. The tokenizer therefore tracks its own mode — it remembers
## which raw-text element it is inside and scans to that element's end tag. A
## tokenizer that ignored this would "find" tags inside JavaScript string
## literals, which is the classic way an HTML parser corrupts a page.

type
  HtmlTokKind* = enum
    htEof
    htText         ## character data (also raw-text element content)
    htComment      ## `<!-- … -->` (raw INCLUDES the delimiters)
    htDoctype      ## `<!DOCTYPE …>` (raw INCLUDES the delimiters)
    htCdata        ## `<![CDATA[ … ]]>`
    htPi           ## `<? … >` processing instruction / bogus comment
    htLt           ## `<` that opens a start tag
    htLtSlash      ## `</` that opens an end tag
    htName         ## a tag name
    htWs           ## whitespace inside a tag
    htAttrName     ## an attribute name
    htEq           ## `=` between attribute name and value
    htAttrValue    ## an attribute value (raw, INCLUDING quotes if quoted)
    htSelfClose    ## the `/` of `/>`
    htGt           ## `>` closing a tag

  HtmlTok* = object
    kind*: HtmlTokKind
    raw*: string
    line*: int32
    col*: int32

const
  VoidElements* = ["area", "base", "br", "col", "embed", "hr", "img", "input",
                   "link", "meta", "param", "source", "track", "wbr"]
  RawTextElements* = ["script", "style", "textarea", "title"]

proc isVoidElement*(name: string): bool =
  let n = lowerAscii(name)
  for v in VoidElements:
    if v == n: return true
  return false

proc isRawTextElement*(name: string): bool =
  let n = lowerAscii(name)
  for v in RawTextElements:
    if v == n: return true
  return false

proc isHtmlSpace(c: char): bool {.inline.} =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc isHtmlNameStart(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= '\x80'

proc isHtmlNameChar(c: char): bool {.inline.} =
  # Deliberately permissive: HTML in the wild carries `:` and `.` in names
  # (namespaced and framework attributes), and rejecting them would push real
  # markup down the error path.
  isHtmlNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '_' or
    c == ':' or c == '.'

type
  HtmlLexer* = object
    src*: string
    pos*: int
    line*: int32
    col*: int32
    inTag*: bool          ## between `<name` and the closing `>`
    rawTextTag*: string   ## non-empty while inside a raw-text element's content

proc atEndH(lx: HtmlLexer): bool {.inline.} =
  lx.pos >= lx.src.len

proc peekH(lx: HtmlLexer; off: int): char {.inline.} =
  let i = lx.pos + off
  if i < lx.src.len: lx.src[i] else: '\0'

proc advanceH(lx: var HtmlLexer) =
  if lx.pos < lx.src.len:
    let c = lx.src[lx.pos]
    if c == '\n':
      lx.line = lx.line + 1'i32
      lx.col = 0'i32
    elif c == '\r':
      if lx.pos + 1 < lx.src.len and lx.src[lx.pos + 1] == '\n':
        discard
      else:
        lx.line = lx.line + 1'i32
        lx.col = 0'i32
    else:
      lx.col = lx.col + 1'i32
    lx.pos = lx.pos + 1

proc sliceFromH(lx: HtmlLexer; start: int): string =
  result = ""
  var i = start
  while i < lx.pos:
    result.add lx.src[i]
    i = i + 1

proc matchesAt(lx: HtmlLexer; off: int; s: string; caseless: bool): bool =
  var i = 0
  while i < s.len:
    var a = peekH(lx, off + i)
    var b = s[i]
    if caseless:
      if a >= 'A' and a <= 'Z': a = char(int(a) + 32)
      if b >= 'A' and b <= 'Z': b = char(int(b) + 32)
    if a != b: return false
    i = i + 1
  return true

proc atEndTagFor(lx: HtmlLexer; name: string): bool =
  ## True when the cursor sits on `</name` followed by a name terminator — the
  ## only sequence that ends a raw-text element.
  if peekH(lx, 0) != '<' or peekH(lx, 1) != '/': return false
  if not matchesAt(lx, 2, name, true): return false
  let after = peekH(lx, 2 + name.len)
  return after == '>' or after == '\0' or isHtmlSpace(after) or after == '/'

proc nextHtmlTok(lx: var HtmlLexer): HtmlTok =
  result = HtmlTok(kind: htEof, raw: "", line: lx.line, col: lx.col)
  if atEndH(lx): return
  let startPos = lx.pos
  let startLine = lx.line
  let startCol = lx.col
  var k = htText

  # --- raw-text element content ------------------------------------------
  if lx.rawTextTag.len > 0:
    if atEndTagFor(lx, lx.rawTextTag):
      lx.rawTextTag = ""
      advanceH(lx); advanceH(lx)      # '</'
      # Leaving raw-text mode must ENTER tag mode. Without this the following
      # `script>` scans as text, the end-tag parser never sees its `>`, and it
      # consumes the rest of the document as opaque tokens. Round-trip stays
      # byte-exact throughout (the bytes are all still there, just in the wrong
      # node), which is exactly why tests/html/tstructure.nim exists.
      lx.inTag = true
      k = htLtSlash
    else:
      while not atEndH(lx) and not atEndTagFor(lx, lx.rawTextTag):
        advanceH(lx)
      k = htText
    return HtmlTok(kind: k, raw: sliceFromH(lx, startPos),
                   line: startLine, col: startCol)

  # --- inside a tag -------------------------------------------------------
  if lx.inTag:
    let c = lx.src[lx.pos]
    if isHtmlSpace(c):
      while not atEndH(lx) and isHtmlSpace(lx.src[lx.pos]): advanceH(lx)
      k = htWs
    elif c == '>':
      advanceH(lx)
      lx.inTag = false
      k = htGt
    elif c == '/' and peekH(lx, 1) == '>':
      advanceH(lx)
      k = htSelfClose
    elif c == '=':
      advanceH(lx)
      k = htEq
    elif c == '"' or c == '\'':
      let q = c
      advanceH(lx)
      while not atEndH(lx) and lx.src[lx.pos] != q: advanceH(lx)
      if not atEndH(lx): advanceH(lx)     # closing quote
      k = htAttrValue
    else:
      # a bare word: an attribute name, or an unquoted attribute value. The
      # parser decides which from position; the lexer just delimits it.
      while not atEndH(lx):
        let d = lx.src[lx.pos]
        if isHtmlSpace(d) or d == '>' or d == '=' or d == '"' or d == '\'':
          break
        if d == '/' and peekH(lx, 1) == '>': break
        advanceH(lx)
      if lx.pos == startPos: advanceH(lx)   # never stall on an odd byte
      k = htAttrName
    return HtmlTok(kind: k, raw: sliceFromH(lx, startPos),
                   line: startLine, col: startCol)

  # --- markup outside a tag -----------------------------------------------
  let c = lx.src[lx.pos]
  if c == '<':
    if matchesAt(lx, 1, "!--", false):
      advanceH(lx); advanceH(lx); advanceH(lx); advanceH(lx)
      while not atEndH(lx):
        if lx.src[lx.pos] == '-' and peekH(lx, 1) == '-' and peekH(lx, 2) == '>':
          advanceH(lx); advanceH(lx); advanceH(lx)
          break
        advanceH(lx)
      k = htComment
    elif matchesAt(lx, 1, "![CDATA[", false):
      while not atEndH(lx):
        if lx.src[lx.pos] == ']' and peekH(lx, 1) == ']' and peekH(lx, 2) == '>':
          advanceH(lx); advanceH(lx); advanceH(lx)
          break
        advanceH(lx)
      k = htCdata
    elif peekH(lx, 1) == '!':
      while not atEndH(lx) and lx.src[lx.pos] != '>': advanceH(lx)
      if not atEndH(lx): advanceH(lx)
      k = htDoctype
    elif peekH(lx, 1) == '?':
      while not atEndH(lx) and lx.src[lx.pos] != '>': advanceH(lx)
      if not atEndH(lx): advanceH(lx)
      k = htPi
    elif peekH(lx, 1) == '/':
      advanceH(lx); advanceH(lx)
      lx.inTag = true
      k = htLtSlash
    elif isHtmlNameStart(peekH(lx, 1)):
      advanceH(lx)
      lx.inTag = true
      k = htLt
    else:
      # a `<` that opens nothing is literal text
      advanceH(lx)
      while not atEndH(lx) and lx.src[lx.pos] != '<': advanceH(lx)
      k = htText
  else:
    while not atEndH(lx) and lx.src[lx.pos] != '<': advanceH(lx)
    k = htText

  return HtmlTok(kind: k, raw: sliceFromH(lx, startPos),
                 line: startLine, col: startCol)

proc tokenizeHtml*(src: string): seq[HtmlTok] =
  result = @[]
  var lx = HtmlLexer(src: src, pos: 0, line: 1'i32, col: 0'i32, inTag: false,
                     rawTextTag: "")
  var expectName = false     ## the next bare word is a TAG name, not an attr name
  var inStartTag = false     ## the tag being scanned opened with `<`, not `</`
  var pendingRaw = ""        ## raw-text element whose content begins at the next `>`
  var selfClosed = false
  while true:
    let t = nextHtmlTok(lx)
    if t.kind == htEof:
      result.add t
      break
    var tok = t
    # The token right after `<` or `</` is a TAG NAME, not an attribute name.
    # The lexer alone cannot tell them apart (both are bare words), so it emits
    # htAttrName and the name is reclassified here, where the previous token is
    # known.
    if expectName and tok.kind == htAttrName:
      tok = HtmlTok(kind: htName, raw: tok.raw, line: tok.line, col: tok.col)
    case tok.kind
    of htLt:
      expectName = true; inStartTag = true; selfClosed = false; pendingRaw = ""
    of htLtSlash:
      expectName = true; inStartTag = false; selfClosed = false; pendingRaw = ""
    of htName:
      expectName = false
      if inStartTag and isRawTextElement(tok.raw):
        pendingRaw = tok.raw
    of htSelfClose:
      selfClosed = true
    of htGt:
      # Arm raw-text mode only for a start tag that actually opened content:
      # `<script/>` self-closes, so its "content" is the rest of the document
      # and treating it as raw text would swallow the page.
      if pendingRaw.len > 0 and not selfClosed:
        lx.rawTextTag = pendingRaw
      pendingRaw = ""
      inStartTag = false
      selfClosed = false
    else:
      expectName = false
    result.add tok

proc concatRawHtml*(toks: seq[HtmlTok]): string =
  result = ""
  for t in toks:
    result.add t.raw
