## webmain.nim — browser/Node entry for nifparser, compiled through the
## nimony-web JS backend (`nim_js`). It replaces nifparser.nim's file/stdout
## bridges with in-memory equivalents so the parser runs with NO file I/O:
##
##   * INPUT   — the Nim source text arrives as a JS string in
##               `globalThis.__np_src` (set by the JS glue before `main` runs).
##               The file-field path written into NIF line-info suffixes arrives
##               as `globalThis.__np_file` (defaults to "in.nim" if empty), so
##               the produced bytes can be made byte-identical to native nifler /
##               `bin/nifparser` invoked on that same relative path.
##   * PARSE   — identical to nifparser.parseToFile: tokenize -> initParser ->
##               parseModule, but the builder is an in-MEMORY nifbuilder
##               (`open(sizeHint)`) whose bytes we `extract` instead of flushing
##               to a file.
##   * OUTPUT  — the produced `.p.nif` bytes are handed back to JS on
##               `globalThis.__np_out` (string). No filesystem, no stdout.
##
## This is the proof that nifparser (the parser half of client-side Tier 2) runs
## in the browser. Modeled on nifi/src/nifi/webmain.nim.

when defined(nimony):
  {.feature: "lenientnils".}

import nifbuilder
import tokens, lexer, parser   # lexer exports tokenize + gLexDiags; tokens exports Diagnostic/Severity
import jsffi

proc jsonEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\x08': result.add "\\b"
    of '\x0C': result.add "\\f"
    of '\x0A': result.add "\\n"
    of '\x0D': result.add "\\r"
    of '\x09': result.add "\\t"
    else:
      if c < ' ':
        const hex = "0123456789abcdef"
        result.add "\\u00"
        result.add hex[(ord(c) shr 4) and 0xF]
        result.add hex[ord(c) and 0xF]
      else:
        result.add c

# --- structural bracket validator (mirrors nifparser.nim's checkBrackets) -----
proc closerFor(k: TokKind): char =
  case k
  of tkParLe: ')'
  of tkBracketLe: ']'
  else: '}'
proc openerFor(k: TokKind): char =
  case k
  of tkParLe: '('
  of tkBracketLe: '['
  else: '{'
proc matchesClose(open, close: TokKind): bool =
  (open == tkParLe and close == tkParRi) or
  (open == tkBracketLe and close == tkBracketRi) or
  (open == tkCurlyLe and close == tkCurlyRi)

proc checkBrackets(toks: seq[Token]): seq[Diagnostic] =
  ## Unbalanced/mismatched ()/[]/{} — a validator the range-splitter never
  ## reports. Best-effort: it never blocks the emitted NIF.
  result = @[]
  var stack: seq[Token] = @[]
  for t in toks:
    case t.kind
    of tkParLe, tkBracketLe, tkCurlyLe:
      stack.add t
    of tkParRi, tkBracketRi, tkCurlyRi:
      if stack.len == 0:
        result.add Diagnostic(severity: sevError, code: "unmatched-close",
          message: "unmatched '" & closerFor(t.kind) & "'",
          line: t.line, col: t.col, endCol: t.col + 1)
      elif not matchesClose(stack[stack.len - 1].kind, t.kind):
        let top = stack[stack.len - 1]
        result.add Diagnostic(severity: sevError, code: "mismatched-bracket",
          message: "'" & closerFor(t.kind) & "' does not match '" &
                   openerFor(top.kind) & "' opened at " & $top.line & ":" & $top.col,
          line: t.line, col: t.col, endCol: t.col + 1)
        stack.setLen(stack.len - 1)
      else:
        stack.setLen(stack.len - 1)
    else: discard
  for t in stack:
    result.add Diagnostic(severity: sevError, code: "unclosed-bracket",
      message: "unclosed '" & openerFor(t.kind) & "'",
      line: t.line, col: t.col, endCol: t.col + 1)

proc sevName(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarn: "warning"
  of sevHint: "hint"

proc diagsToJson(ds: seq[Diagnostic]): string =
  ## `[{"severity","code","message","line","col","endCol"}]` — line 1-based,
  ## col/endCol 0-based (the JS glue converts to Monaco's 1-based cols). The
  ## severity lets the editor show warnings/hints instead of blocking on style.
  result = "["
  for i in 0 ..< ds.len:
    if i > 0: result.add ","
    result.add "{\"severity\":\""
    result.add sevName(ds[i].severity)
    result.add "\",\"code\":\""
    result.add ds[i].code
    result.add "\",\"message\":\""
    result.add jsonEscape(ds[i].message)
    result.add "\",\"line\":"
    result.add $ds[i].line
    result.add ",\"col\":"
    result.add $ds[i].col
    result.add ",\"endCol\":"
    result.add $ds[i].endCol
    result.add "}"
  result.add "]"

proc parseToStr(src, fileField: string; curly: bool; diagJson: var string): string =
  ## Parse Nim source text from memory to the `.p.nif` byte string, and set
  ## `diagJson` to the JSON array of RECOVERABLE structured diagnostics (lexer
  ## checks + bracket validation). Parsing is never aborted by them — an editor
  ## gets every problem at once. `curly` enables the experimental `{ … }` mode.
  var errors = 0
  let toks = tokenize(src, defaultLexOptions, errors)
  var ds = gLexDiags                             # lexer diagnostics from tokenize
  for d in checkBrackets(toks): ds.add d
  diagJson = diagsToJson(ds)
  var ps = initParser(toks, fileField, curly)
  var b = nifbuilder.open(src.len * 4 + 256)   # in-memory builder
  parseModule(ps, b)
  result = extract(b)

proc npRun() =
  ## The whole browser entry, run as MODULE INIT (top-level). Like nifi's
  ## webmain it must NOT be `{.exportc: "main".}`: the JS backend emits its own
  ## `main(argc, argv, envp)` that runs the module inits, so a second `main`
  ## would shadow it. Running as top-level code means the generated entry's
  ## module-init call invokes this directly.
  # 1. read the Nim source JS parked on globalThis.__np_src
  let src = global("__np_src").toStr
  # 2. read the file-field path (relative path baked into line-info); default it
  var fileField = global("__np_file").toStr
  if fileField.len == 0:
    fileField = "in.nim"
  # 2b. read the experimental curly-block toggle: a non-empty string ("1") means
  #     accept `{ … }` block bodies; empty/absent means classic indent-only.
  let curly = global("__np_curly").toStr.len != 0
  # 3. parse fully in memory (also collects syntactic diagnostics)
  var diagJson = ""
  let outp = parseToStr(src, fileField, curly, diagJson)
  # 4. return the produced .p.nif bytes + diagnostics JSON to JS
  let g = global("globalThis")
  g.set("__np_out", toJs(outp))
  g.set("__np_diag", toJs(diagJson))

npRun()
