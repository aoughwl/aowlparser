## js_lex.nim — JavaScript tokenizer for the `js-parsed` AIF dialect.
##
## INCLUDE file, spliced into `jsparser.nim`. Sits on aowlparse/scan.nim.
##
## JavaScript's signature tokenizer hazard is that `/` is AMBIGUOUS: it starts a
## regex literal in expression position and is division in operand position, and
## the two scan completely differently. `a = b / c / d` is two divisions;
## `a = /b/ / c` is a regex then a division. No amount of lookahead settles it —
## it depends on what came BEFORE, so the tokenizer tracks the last significant
## token and decides from that. Getting this wrong silently swallows code into a
## "regex" that runs to the end of the line.
##
## Template literals are kept as ONE token including their `${…}` substitutions,
## with nesting tracked so a `}` inside a nested template or string does not end
## them early. The substitution contents are therefore not sub-tokenized — the
## same deliberate line CSS draws at function nesting, and stated in jsparser.nim.

type
  JsTokKind* = enum
    jsEof
    jsWs         ## horizontal whitespace
    jsNl         ## a line terminator (kept separate: ASI depends on newlines)
    jsComment    ## `//…` or `/*…*/`
    jsName
    jsKeyword
    jsNumber
    jsString
    jsTemplate
    jsRegex
    jsOp

  JsTok* = object
    kind*: JsTokKind
    raw*: string
    line*: int32
    col*: int32

const
  JsKeywords* = [
    "await", "break", "case", "catch", "class", "const", "continue",
    "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
    "false", "finally", "for", "function", "if", "import", "in", "instanceof",
    "let", "new", "null", "return", "static", "super", "switch", "this",
    "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield",
    "async", "get", "set", "of"
  ]
  # Longest first — the scanner takes the first match.
  JsOperators* = [
    ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=",
    "??=",
    "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=",
    "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>",
    "{", "}", "(", ")", "[", "]", ";", ",", "<", ">", "+", "-", "*", "/", "%",
    "&", "|", "^", "!", "~", "?", ":", "=", ".", "#", "@"
  ]

proc isJsKeyword*(s: string): bool =
  for k in JsKeywords:
    if k == s: return true
  return false

proc regexAllowedAfter(k: JsTokKind; raw: string): bool =
  ## Whether a `/` in this position starts a REGEX rather than being division.
  ##
  ## The rule is about what precedes: after a value (identifier, literal, or a
  ## closing `)`/`]`) a `/` is division; after an operator, `(`, `,`, `return`,
  ## etc. it opens a regex. `}` is genuinely ambiguous (block end vs object
  ## literal end) — treated as allowing a regex, which is right for
  ## `if (x) {} /re/.test(s)` and the far more common case.
  case k
  of jsName, jsNumber, jsString, jsTemplate, jsRegex:
    return false
  of jsKeyword:
    # Keywords that produce a VALUE are followed by division; all others
    # (return, typeof, case, in, of, …) are followed by an expression.
    return not (raw == "this" or raw == "super" or raw == "true" or
                raw == "false" or raw == "null")
  of jsOp:
    if raw == ")" or raw == "]": return false
    return true
  else:
    return true

proc scanJsString(s: var Scanner) =
  let q = cur(s)
  advance(s)
  while not atEnd(s):
    let c = cur(s)
    if c == '\\':
      advance(s)
      if not atEnd(s): advance(s)
      continue
    if c == q:
      advance(s)
      return
    if c == '\n':
      return                      # unterminated: ends at the line
    advance(s)

proc scanJsTemplate(s: var Scanner) =
  ## Consumes a whole template literal, tracking `${…}` nesting so that a `}`
  ## inside a nested string or template does not end it early.
  advance(s)                      # the opening backtick
  var braceDepth = 0
  while not atEnd(s):
    let c = cur(s)
    if c == '\\':
      advance(s)
      if not atEnd(s): advance(s)
      continue
    if braceDepth == 0 and c == '`':
      advance(s)
      return
    if c == '$' and peek(s, 1) == '{':
      advance(s); advance(s)
      braceDepth = braceDepth + 1
      continue
    if braceDepth > 0:
      if c == '{':
        advance(s); braceDepth = braceDepth + 1; continue
      if c == '}':
        advance(s); braceDepth = braceDepth - 1; continue
      if c == '"' or c == '\'':
        scanJsString(s); continue
      if c == '`':
        scanJsTemplate(s); continue
    advance(s)

proc scanJsRegex(s: var Scanner) =
  advance(s)                      # the opening slash
  var inClass = false
  while not atEnd(s):
    let c = cur(s)
    if c == '\\':
      advance(s)
      if not atEnd(s): advance(s)
      continue
    if c == '\n':
      return                      # a regex cannot span lines
    if c == '[':
      inClass = true
    elif c == ']':
      inClass = false
    elif c == '/' and not inClass:
      advance(s)
      while not atEnd(s) and isIdentCh(cur(s)): advance(s)   # flags
      return
    advance(s)

proc scanJsNumber(s: var Scanner) =
  if cur(s) == '0' and (peek(s, 1) == 'x' or peek(s, 1) == 'X' or
                        peek(s, 1) == 'o' or peek(s, 1) == 'O' or
                        peek(s, 1) == 'b' or peek(s, 1) == 'B'):
    advance(s); advance(s)
    while not atEnd(s) and (isHexCh(cur(s)) or cur(s) == '_'): advance(s)
  else:
    while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '_'): advance(s)
    if not atEnd(s) and cur(s) == '.':
      advance(s)
      while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '_'): advance(s)
    if not atEnd(s) and (cur(s) == 'e' or cur(s) == 'E'):
      let n1 = peek(s, 1)
      if isDigitCh(n1) or ((n1 == '+' or n1 == '-') and isDigitCh(peek(s, 2))):
        advance(s)
        if cur(s) == '+' or cur(s) == '-': advance(s)
        while not atEnd(s) and isDigitCh(cur(s)): advance(s)
  if not atEnd(s) and cur(s) == 'n': advance(s)      # BigInt

proc matchJsOperator(s: Scanner): string =
  for op in JsOperators:
    if matchesAt(s, 0, op): return op
  return ""

proc tokenizeJs*(src: string): seq[JsTok] =
  result = @[]
  var s = initScanner(src)
  var lastKind = jsEof        ## last SIGNIFICANT token (not ws/nl/comment)
  var lastRaw = ""
  while true:
    if atEnd(s):
      result.add JsTok(kind: jsEof, raw: "", line: s.line, col: s.col)
      break
    let startPos = s.pos
    let startLine = s.line
    let startCol = s.col
    let c = cur(s)
    var k = jsOp

    if c == '\n' or c == '\r':
      advance(s)
      if src[s.pos - 1] == '\r' and not atEnd(s) and cur(s) == '\n': advance(s)
      k = jsNl
    elif isBlankCh(c):
      while not atEnd(s) and isBlankCh(cur(s)): advance(s)
      k = jsWs
    elif c == '/' and peek(s, 1) == '/':
      while not atEnd(s) and cur(s) != '\n' and cur(s) != '\r': advance(s)
      k = jsComment
    elif c == '/' and peek(s, 1) == '*':
      advance(s); advance(s)
      while not atEnd(s):
        if cur(s) == '*' and peek(s, 1) == '/':
          advance(s); advance(s)
          break
        advance(s)
      k = jsComment
    elif c == '/' and regexAllowedAfter(lastKind, lastRaw):
      scanJsRegex(s)
      k = jsRegex
    elif c == '"' or c == '\'':
      scanJsString(s)
      k = jsString
    elif c == '`':
      scanJsTemplate(s)
      k = jsTemplate
    elif isIdentStartCh(c) or c == '$':
      advance(s)
      while not atEnd(s) and (isIdentCh(cur(s)) or cur(s) == '$'): advance(s)
      let word = sliceFrom(s, startPos)
      k = if isJsKeyword(word): jsKeyword else: jsName
    elif isDigitCh(c) or (c == '.' and isDigitCh(peek(s, 1))):
      scanJsNumber(s)
      k = jsNumber
    else:
      let op = matchJsOperator(s)
      if op.len > 0:
        var i = 0
        while i < op.len:
          advance(s)
          i = i + 1
      else:
        advance(s)
      k = jsOp

    let raw = sliceFrom(s, startPos)
    if k != jsWs and k != jsNl and k != jsComment:
      lastKind = k
      lastRaw = raw
    result.add JsTok(kind: k, raw: raw, line: startLine, col: startCol)

proc concatRawJs*(toks: seq[JsTok]): string =
  result = ""
  for t in toks:
    result.add t.raw
