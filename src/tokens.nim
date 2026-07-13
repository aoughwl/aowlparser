## tokens.nim — the Token contract shared by the lexer and parser.
##
## This module DEFINES the lexer<->parser interface: `lexer.nim` produces the
## `Token` stream and `parser.nim` (with its `include`d grammar files) consumes
## it. Both agree on the `Token` shape here.
##
## Design notes
## ------------
## * Significant indentation is carried, Nim-parser style, on the `indent`
##   field: a token that is the first non-whitespace token on its source line
##   records its column in `indent`; every other token has `indent == -1`.
##   That lets the parser implement the off-side rule without a separate
##   Indent/Dedent token kind.
## * `line` is 1-based, `col` is 0-based — matching nimony's `TLineInfo` so the
##   NIF line-info the parser emits lines up with native nifler.

type
  TokKind* = enum
    tkEof            ## end of input
    tkIdent          ## identifier
    tkKeyword        ## a reserved Nim keyword (see `Keywords`)
    tkIntLit         ## integer literal (value in `iVal`)
    tkFloatLit       ## float literal (value in `fVal`)
    tkStrLit         ## "..." string literal (decoded text in `s`)
    tkRStrLit        ## r"..." raw string literal
    tkTripleStrLit   ## """...""" triple-quoted string literal
    tkCharLit        ## '.' character literal (code point in `iVal`)
    tkOperator       ## operator token, e.g. `+`, `/`, `==` (text in `s`)
    tkParLe          ## (
    tkParRi          ## )
    tkBracketLe      ## [
    tkBracketRi      ## ]
    tkCurlyLe        ## {
    tkCurlyRi        ## }
    tkComma          ## ,
    tkSemicolon      ## ;
    tkColon          ## :
    tkDot            ## .
    tkComment        ## a `##` doc comment (regular `#` comments are skipped)

  Token* = object
    kind*: TokKind
    s*: string       ## identifier / operator / decoded string literal text
    iVal*: int64     ## integer or char-literal value
    fVal*: float     ## float-literal value
    suffix*: string  ## numeric literal type suffix, e.g. "i8"
    line*: int32     ## 1-based source line
    col*: int32      ## 0-based source column
    endCol*: int32   ## 0-based column just past the token (for spacing checks)
    indent*: int32   ## column if first token on its line, else -1
    quoted*: bool    ## accent-quoted identifier (`` `foo bar` ``)
    parts*: seq[string]  ## child pieces of an accent-quoted ident (accQuoted rule)

const
  Keywords* = [
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
    "concept", "const", "continue", "converter", "defer", "discard", "distinct",
    "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
    "for", "from", "func", "if", "import", "in", "include", "interface", "is",
    "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
    "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
    "return", "shl", "shr", "static", "template", "try", "tuple", "type",
    "using", "var", "when", "while", "xor", "yield"
  ]

proc isKeyword*(s: string): bool =
  for k in Keywords:
    if k == s: return true
  return false

proc initToken*(kind: TokKind; line, col: int32): Token =
  result = Token(kind: kind, s: "", iVal: 0, fVal: 0.0,
                 suffix: "", line: line, col: col, endCol: col, indent: -1)
