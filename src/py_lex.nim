## py_lex.nim — Python tokenizer for the `py-parsed` AIF dialect.
##
## INCLUDE file, spliced into `pyparser.nim`. Sits on aowlparse/scan.nim.
##
## Same contract as every dialect here: tokens carry raw source slices and
## concatenate back to the input exactly.
##
## Python's three tokenizer hazards, all handled here rather than in the parser:
##
##   * IMPLICIT LINE JOINING — a newline inside `(`/`[`/`{` is not a statement
##     terminator. The tokenizer tracks bracket depth and marks such newlines as
##     ordinary whitespace, so the parser never has to count brackets.
##   * EXPLICIT LINE JOINING — a backslash immediately before a newline joins the
##     lines; it is emitted as `cont` so it is neither trivia nor a terminator.
##   * TRIPLE-QUOTED AND PREFIXED STRINGS — `rb'''…'''`, f-strings, and friends.
##     A backslash suppresses a closing quote even in raw strings (Python's own
##     rule: `r"\""` does not end at the middle quote), so one escape rule covers
##     both raw and cooked.

type
  PyTokKind* = enum
    pyEof
    pyWs         ## horizontal whitespace (and newlines joined into a line)
    pyNl         ## a newline that TERMINATES a logical line
    pyComment    ## `# …` to end of line (the newline is a separate token)
    pyName       ## identifier
    pyKeyword    ## a reserved word
    pyNumber
    pyString     ## including any prefix and both quote styles
    pyOp         ## operator or delimiter
    pyCont       ## a backslash-newline line join

  PyTok* = object
    kind*: PyTokKind
    raw*: string
    line*: int32
    col*: int32

const
  PyKeywords* = [
    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
    "class", "continue", "def", "del", "elif", "else", "except", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    "match", "case"
  ]
  # Longest first: the scanner takes the first match, so `**=` must be tried
  # before `**`, and `**` before `*`.
  PyOperators* = [
    "**=", "//=", ">>=", "<<=", "...", "!=", ">=", "<=", "==", "->", ":=",
    "**", "//", ">>", "<<", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
    "@=", "~=",
    "+", "-", "*", "/", "%", "@", "&", "|", "^", "~", "<", ">", "(", ")",
    "[", "]", "{", "}", ",", ":", ".", ";", "="
  ]

proc isPyKeyword*(s: string): bool =
  for k in PyKeywords:
    if k == s: return true
  return false

proc isStringPrefix(s: string): bool =
  ## r, b, f, u and the two-letter combinations, any case.
  if s.len == 0 or s.len > 2: return false
  let t = lowerAscii(s)
  if t.len == 1:
    return t == "r" or t == "b" or t == "f" or t == "u"
  return t == "rb" or t == "br" or t == "fr" or t == "rf" or t == "bf" or
         t == "fb"

proc scanPyString(s: var Scanner) =
  ## Consumes a string literal, assuming the cursor is on the opening quote.
  let q = cur(s)
  var triple = false
  if peek(s, 1) == q and peek(s, 2) == q:
    triple = true
    advance(s); advance(s); advance(s)
  else:
    advance(s)
  while not atEnd(s):
    let c = cur(s)
    if c == '\\':
      # A backslash suppresses the next byte for delimiter purposes in BOTH raw
      # and cooked strings — Python's own rule, so one branch covers both.
      advance(s)
      if not atEnd(s): advance(s)
      continue
    if c == q:
      if triple:
        if peek(s, 1) == q and peek(s, 2) == q:
          advance(s); advance(s); advance(s)
          return
        advance(s)
        continue
      advance(s)
      return
    if not triple and c == '\n':
      return                # unterminated single-quoted string ends at the line
    advance(s)

proc scanPyNumber(s: var Scanner) =
  if cur(s) == '0' and (peek(s, 1) == 'x' or peek(s, 1) == 'X' or
                        peek(s, 1) == 'o' or peek(s, 1) == 'O' or
                        peek(s, 1) == 'b' or peek(s, 1) == 'B'):
    advance(s); advance(s)
    while not atEnd(s) and (isHexCh(cur(s)) or cur(s) == '_'): advance(s)
    return
  while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '_'): advance(s)
  if not atEnd(s) and cur(s) == '.' and isDigitCh(peek(s, 1)):
    advance(s)
    while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '_'): advance(s)
  elif not atEnd(s) and cur(s) == '.':
    advance(s)
    while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '_'): advance(s)
  if not atEnd(s) and (cur(s) == 'e' or cur(s) == 'E'):
    let n1 = peek(s, 1)
    if isDigitCh(n1) or ((n1 == '+' or n1 == '-') and isDigitCh(peek(s, 2))):
      advance(s)
      if cur(s) == '+' or cur(s) == '-': advance(s)
      while not atEnd(s) and (isDigitCh(cur(s)) or cur(s) == '_'): advance(s)
  if not atEnd(s) and (cur(s) == 'j' or cur(s) == 'J'): advance(s)

proc matchPyOperator(s: Scanner): string =
  for op in PyOperators:
    if matchesAt(s, 0, op): return op
  return ""

proc tokenizePy*(src: string): seq[PyTok] =
  result = @[]
  var s = initScanner(src)
  var depth = 0          ## bracket nesting: newlines inside are not terminators
  while true:
    if atEnd(s):
      result.add PyTok(kind: pyEof, raw: "", line: s.line, col: s.col)
      break
    let startPos = s.pos
    let startLine = s.line
    let startCol = s.col
    let c = cur(s)
    var k = pyOp

    if c == '\\' and (peek(s, 1) == '\n' or
                      (peek(s, 1) == '\r' and peek(s, 2) == '\n')):
      advance(s); advance(s)
      if s.pos < src.len and src[s.pos - 1] == '\r': advance(s)
      k = pyCont
    elif c == '\n' or c == '\r':
      advance(s)
      if src[s.pos - 1] == '\r' and not atEnd(s) and cur(s) == '\n': advance(s)
      # Inside brackets a newline is just whitespace — this is what makes
      # multi-line calls and literals work without the parser counting anything.
      k = if depth > 0: pyWs else: pyNl
    elif isBlankCh(c):
      while not atEnd(s) and isBlankCh(cur(s)): advance(s)
      k = pyWs
    elif c == '#':
      while not atEnd(s) and cur(s) != '\n' and cur(s) != '\r': advance(s)
      k = pyComment
    elif c == '"' or c == '\'':
      scanPyString(s)
      k = pyString
    elif isIdentStartCh(c):
      while not atEnd(s) and isIdentCh(cur(s)): advance(s)
      let word = sliceFrom(s, startPos)
      # A prefixed string literal: the identifier is glued to a quote.
      if not atEnd(s) and (cur(s) == '"' or cur(s) == '\'') and
         isStringPrefix(word):
        scanPyString(s)
        k = pyString
      elif isPyKeyword(word):
        k = pyKeyword
      else:
        k = pyName
    elif isDigitCh(c) or (c == '.' and isDigitCh(peek(s, 1))):
      scanPyNumber(s)
      k = pyNumber
    else:
      let op = matchPyOperator(s)
      if op.len > 0:
        var i = 0
        while i < op.len:
          advance(s)
          i = i + 1
        if op == "(" or op == "[" or op == "{": depth = depth + 1
        elif op == ")" or op == "]" or op == "}":
          if depth > 0: depth = depth - 1
        k = pyOp
      else:
        advance(s)          # unknown byte: keep it, never stall
        k = pyOp

    result.add PyTok(kind: k, raw: sliceFrom(s, startPos),
                     line: startLine, col: startCol)

proc concatRawPy*(toks: seq[PyTok]): string =
  result = ""
  for t in toks:
    result.add t.raw
