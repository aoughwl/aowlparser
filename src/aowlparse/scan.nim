## scan.nim — the byte cursor every dialect tokenizer sits on.
##
## Tracks position, 1-based line and 0-based column, with `\r\n` counted as ONE
## line break. This was written twice (css_lex.nim, html_lex.nim) byte-identical
## before being lifted here.
##
## Deliberately NOT generic over a token type: dialects keep their own token
## enums, because unifying those is where genericity stops paying and starts
## costing. What is shared is the cursor, the slicing, and the classification
## predicates that every text format needs.

type
  Scanner* = object
    src*: string
    pos*: int
    line*: int32
    col*: int32

proc initScanner*(src: string): Scanner =
  Scanner(src: src, pos: 0, line: 1'i32, col: 0'i32)

proc atEnd*(s: Scanner): bool {.inline.} =
  s.pos >= s.src.len

proc peek*(s: Scanner; off: int): char {.inline.} =
  let i = s.pos + off
  if i < s.src.len: s.src[i] else: '\0'

proc cur*(s: Scanner): char {.inline.} =
  if s.pos < s.src.len: s.src[s.pos] else: '\0'

proc advance*(s: var Scanner) =
  ## Consume one byte, maintaining line/col. `\r\n` is one line break; a lone
  ## `\r` (old-Mac) is also one.
  if s.pos < s.src.len:
    let c = s.src[s.pos]
    if c == '\n':
      s.line = s.line + 1'i32
      s.col = 0'i32
    elif c == '\r':
      if s.pos + 1 < s.src.len and s.src[s.pos + 1] == '\n':
        discard                       # the '\n' will bump the line
      else:
        s.line = s.line + 1'i32
        s.col = 0'i32
    else:
      s.col = s.col + 1'i32
    s.pos = s.pos + 1

proc sliceFrom*(s: Scanner; start: int): string =
  ## The exact source bytes from `start` to the cursor. This is what makes
  ## raw-lexeme tokens possible, and therefore what makes byte-exactness
  ## reachable.
  result = ""
  var i = start
  while i < s.pos:
    result.add s.src[i]
    i = i + 1

proc matchesAt*(s: Scanner; off: int; lit: string; caseless = false): bool =
  var i = 0
  while i < lit.len:
    var a = peek(s, off + i)
    var b = lit[i]
    if caseless:
      if a >= 'A' and a <= 'Z': a = char(int(a) + 32)
      if b >= 'A' and b <= 'Z': b = char(int(b) + 32)
    if a != b: return false
    i = i + 1
  return true

proc skipWhile*(s: var Scanner; pred: proc (c: char): bool) =
  while not atEnd(s) and pred(s.src[s.pos]): advance(s)

## --- character classes shared across text formats --------------------------

proc isSpaceCh*(c: char): bool {.inline.} =
  c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f'

proc isBlankCh*(c: char): bool {.inline.} =
  ## Horizontal whitespace only — for indentation-sensitive formats (Python),
  ## where a newline is structure, not trivia.
  c == ' ' or c == '\t' or c == '\f'

proc isDigitCh*(c: char): bool {.inline.} =
  c >= '0' and c <= '9'

proc isHexCh*(c: char): bool {.inline.} =
  isDigitCh(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')

proc isAlphaCh*(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc isIdentStartCh*(c: char): bool {.inline.} =
  ## Bytes >= 0x80 count as identifier characters, which makes UTF-8 sequences
  ## fall through byte-by-byte with no decoding — correct for every dialect here.
  isAlphaCh(c) or c == '_' or c >= '\x80'

proc isIdentCh*(c: char): bool {.inline.} =
  isIdentStartCh(c) or isDigitCh(c)

proc lowerAscii*(s: string): string =
  result = ""
  for c in s.items:
    if c >= 'A' and c <= 'Z': result.add char(int(c) + 32)
    else: result.add c
