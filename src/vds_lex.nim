## vds_lex.nim — tokenizer for MDN value-definition syntax.
##
## INCLUDE file, spliced into `vdsparser.nim`. Sits on aowlparse/scan.nim.
##
## Two genuine ambiguities, both resolved by POSITION (whether a component has
## just been read), which is why the tokenizer tracks that one bit:
##
##   * `+` and `*` are BOTH postfix multipliers and literal component values.
##     `<len>+` is "one or more"; `[ '+' | '-' ]` is the literal plus sign. After
##     a component they are multipliers; otherwise they are literals.
##   * `{` opens a RANGE multiplier (`{1,4}`, `{1,}`) or a literal brace block
##     (at-rule bodies: `@media { <rule-list> }`). Distinguished by lookahead —
##     a range contains only digits and a comma before its `}`.

type
  VdsTokKind* = enum
    vdEof
    vdWs
    vdType        ## `<length>` / `<length [0,∞]>`
    vdPropRef     ## `<'margin-top'>`
    vdIdent       ## a bare keyword
    vdFunc        ## `abs(` — name immediately followed by `(`
    vdStr         ## `"…"` or `'…'`
    vdNum
    vdBar         ## `|`
    vdBarBar      ## `||`
    vdAmpAmp      ## `&&`
    vdLBracket
    vdRBracket
    vdLParen
    vdRParen
    vdLBrace      ## a LITERAL `{`
    vdRBrace      ## a LITERAL `}`
    vdRange       ## `{1,4}` — a multiplier, not a brace
    vdMult        ## `?` `*` `+` `#` `!`
    vdLit         ## `,` `/` `;` `:` and other literal delimiters

  VdsTok* = object
    kind*: VdsTokKind
    raw*: string
    line*: int32
    col*: int32

proc looksLikeRange(s: Scanner): bool =
  ## True when the `{` at the cursor opens `{m}` / `{m,n}` / `{m,}` rather than a
  ## literal brace block.
  var i = 1
  var sawDigit = false
  while true:
    let c = peek(s, i)
    if c == '\0': return false
    if isDigitCh(c):
      sawDigit = true
    elif c == ',' or c == ' ':
      discard
    elif c == '}':
      return sawDigit
    else:
      return false
    i = i + 1

proc scanAngle(s: var Scanner; isProp: var bool) =
  ## `<…>`, which may contain a bracketed range (`<length [0,∞]>`) and, for a
  ## property reference, quotes (`<'margin-top'>`).
  isProp = false
  advance(s)                                  # '<'
  if cur(s) == '\'': isProp = true
  var depth = 0
  while not atEnd(s):
    let c = cur(s)
    if c == '[':
      depth = depth + 1
    elif c == ']':
      if depth > 0: depth = depth - 1
    elif c == '>' and depth == 0:
      advance(s)
      return
    advance(s)

proc nextVdsTok(s: var Scanner; afterComponent: bool): VdsTok =
  if atEnd(s):
    return VdsTok(kind: vdEof, raw: "", line: s.line, col: s.col)
  let startPos = s.pos
  let startLine = s.line
  let startCol = s.col
  let c = cur(s)
  var k = vdLit

  if isSpaceCh(c):
    while not atEnd(s) and isSpaceCh(cur(s)): advance(s)
    k = vdWs
  elif c == '<':
    var isProp = false
    scanAngle(s, isProp)
    k = if isProp: vdPropRef else: vdType
  elif c == '"' or c == '\'':
    let q = c
    advance(s)
    while not atEnd(s) and cur(s) != q: advance(s)
    if not atEnd(s): advance(s)
    k = vdStr
  elif c == '|':
    advance(s)
    if not atEnd(s) and cur(s) == '|':
      advance(s); k = vdBarBar
    else:
      k = vdBar
  elif c == '&' and peek(s, 1) == '&':
    advance(s); advance(s)
    k = vdAmpAmp
  elif c == '[':
    advance(s); k = vdLBracket
  elif c == ']':
    advance(s); k = vdRBracket
  elif c == '(':
    advance(s); k = vdLParen
  elif c == ')':
    advance(s); k = vdRParen
  elif c == '{':
    if looksLikeRange(s):
      while not atEnd(s) and cur(s) != '}': advance(s)
      if not atEnd(s): advance(s)
      k = vdRange
    else:
      advance(s); k = vdLBrace
  elif c == '}':
    advance(s); k = vdRBrace
  elif c == '?' or c == '#' or c == '!':
    advance(s); k = vdMult
  elif c == '+' or c == '*':
    # THE positional ambiguity: a multiplier after a component, a literal
    # otherwise. `<len>+` vs `[ '+' | '-' ]`.
    advance(s)
    k = if afterComponent: vdMult else: vdLit
  elif isDigitCh(c):
    while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '.'): advance(s)
    k = vdNum
  elif isIdentStartCh(c) or c == '-' or c == '@' or c == '.' or c == ':':
    # Identifiers here are permissive on purpose: MDN grammars carry things like
    # `@media`, `.class`, `::before`, `-webkit-box` as bare component values.
    advance(s)
    while not atEnd(s) and (isIdentCh(cur(s)) or cur(s) == '-' or
                            cur(s) == '.' or cur(s) == ':'): advance(s)
    if not atEnd(s) and cur(s) == '(':
      advance(s)
      k = vdFunc
    else:
      k = vdIdent
  else:
    advance(s)
    k = vdLit

  result = VdsTok(kind: k, raw: sliceFrom(s, startPos),
                  line: startLine, col: startCol)

proc startsComponentKind(k: VdsTokKind): bool =
  k == vdType or k == vdPropRef or k == vdIdent or k == vdFunc or
  k == vdStr or k == vdNum or k == vdLBracket or k == vdLParen or
  k == vdLBrace or k == vdLit

proc endsComponentKind(k: VdsTokKind): bool =
  ## After these, a `+`/`*` is a MULTIPLIER.
  k == vdType or k == vdPropRef or k == vdIdent or k == vdStr or k == vdNum or
  k == vdRBracket or k == vdRParen or k == vdRBrace or k == vdMult or
  k == vdRange

proc tokenizeVds*(src: string): seq[VdsTok] =
  result = @[]
  var s = initScanner(src)
  var afterComponent = false
  while true:
    let t = nextVdsTok(s, afterComponent)
    if t.kind == vdEof:
      result.add t
      break
    if t.kind != vdWs:
      afterComponent = endsComponentKind(t.kind)
    result.add t

proc concatRawVds*(toks: seq[VdsTok]): string =
  result = ""
  for t in toks:
    result.add t.raw
