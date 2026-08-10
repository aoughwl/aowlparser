## completeness.nim — "could this source be continued?", as a library call.
##
## Requested by aowlrepl (aoughwl/aowlrepl v0.2.0) via the message bus. A REPL,
## and an editor deciding whether to offer a continuation, needs one question
## answered that `check` deliberately cannot answer:
##
##     is this input FINISHED, or is the user still typing?
##
## `aowlparser check` returns no diagnostics for `type`, `if x > 1:`, or
## `proc twice(x: int): int =` because reading those as empty-bodied constructs
## is required for nifler compatibility. That is correct for `check` and useless
## for a REPL. And the diagnostics that WOULD help — the bracket checks and
## `expression-expected` — live in the CLI driver, so an in-process consumer
## importing `parser` never sees them.
##
## This module answers the REPL's question directly, from the TOKEN stream,
## which aowlrepl measured as authoritative (string / char / comment / numeric
## suffix cases all come out right).
##
## NOTE for anyone linking this library: `parsecore.nim`, `parse_expr.nim`,
## `parse_type.nim` and `parse_stmt.nim` are `include` files spliced into
## `parser.nim` — `import parsecore` fails hard. Import `parser`, `cssparser`,
## `htmlparser`, `pyparser`, `jsparser`, `jsonparser`, or this module.

import tokens, lexer

type
  Completeness* = enum
    ckComplete     ## a full unit; a REPL should evaluate it now
    ckIncomplete   ## syntactically unfinished; keep reading
    ckInvalid      ## cannot be finished by appending — a real error

  CompletenessResult* = object
    verdict*: Completeness
    reason*: string    ## short stable slug, e.g. "unclosed-bracket"
    detail*: string    ## human-readable, for a REPL to show on demand

proc isOpenBracket(k: TokKind): bool =
  k == tkParLe or k == tkBracketLe or k == tkCurlyLe

proc isCloseBracket(k: TokKind): bool =
  k == tkParRi or k == tkBracketRi or k == tkCurlyRi

proc matchesPair(open, close: TokKind): bool =
  (open == tkParLe and close == tkParRi) or
  (open == tkBracketLe and close == tkBracketRi) or
  (open == tkCurlyLe and close == tkCurlyRi)

proc endsStatement(t: Token): bool =
  ## Whether a logical unit could END on this token. A trailing operator, colon,
  ## comma, or dot means more input is required.
  case t.kind
  of tkOperator, tkColon, tkComma, tkDot, tkSemicolon:
    return false
  of tkKeyword:
    # A lone section or block introducer cannot end a unit: `type`, `if`, `else`,
    # `try` etc. all require a body. But several keywords are complete statements
    # or values on their own, and treating them as danglers would make a REPL
    # hang waiting for input that is never coming.
    let s = t.s
    if s == "nil" or s == "discard" or s == "return" or s == "break" or
       s == "continue" or s == "raise" or s == "yield":
      return true
    return false
  of tkEof:
    return true
  else:
    return true

proc completenessOf*(toks: seq[Token]; lexDiags: seq[Diagnostic]):
    CompletenessResult =
  ## The verdict for an already-lexed unit. Exposed separately so a caller that
  ## already tokenized does not pay for it twice.
  result = CompletenessResult(verdict: ckComplete, reason: "", detail: "")

  # 1. Unterminated lexical constructs — an unclosed string or block comment can
  #    always be finished by typing more, so they are INCOMPLETE, not invalid.
  for d in lexDiags:
    let c = d.code
    if c.len >= 13 and c[0 .. 12] == "unterminated-":
      return CompletenessResult(verdict: ckIncomplete, reason: c,
                                detail: d.message)

  # 2. Bracket balance. A surplus or mismatched close can NOT be repaired by
  #    appending, so it is invalid; an unclosed opener is merely unfinished.
  var stack: seq[Token] = @[]
  for t in toks:
    if isOpenBracket(t.kind):
      stack.add t
    elif isCloseBracket(t.kind):
      if stack.len == 0:
        return CompletenessResult(verdict: ckInvalid, reason: "unmatched-close",
          detail: "a closing bracket matches nothing")
      elif not matchesPair(stack[stack.len - 1].kind, t.kind):
        return CompletenessResult(verdict: ckInvalid,
          reason: "mismatched-bracket",
          detail: "closing bracket does not match its opener")
      else:
        stack.setLen(stack.len - 1)
  if stack.len > 0:
    return CompletenessResult(verdict: ckIncomplete, reason: "unclosed-bracket",
      detail: "a bracket opened here is never closed")

  # 3. The last significant token. A unit ending on an operator, colon, comma,
  #    dot, or a block-introducing keyword is still being typed.
  var last = -1
  var i = 0
  while i < toks.len:
    let k = toks[i].kind
    if k != tkEof and k != tkComment: last = i
    i = i + 1
  if last >= 0 and not endsStatement(toks[last]):
    return CompletenessResult(verdict: ckIncomplete, reason: "dangling-token",
      detail: "input ends on '" & toks[last].s &
              "', which cannot end a statement")

  # 4. A trailing colon-block header with no body: `if x > 1:` reads to `check`
  #    as a valid empty-bodied construct, which is exactly the case a REPL must
  #    treat as unfinished. Caught by rule 3 via the trailing `:`.
  return CompletenessResult(verdict: ckComplete, reason: "", detail: "")

proc completeness*(src: string): CompletenessResult =
  ## The whole question in one call, for a REPL or an editor.
  ##
  ##   completeness("x + 1").verdict          == ckComplete
  ##   completeness("if x > 1:").verdict      == ckIncomplete
  ##   completeness("foo(").verdict           == ckIncomplete
  ##   completeness("foo)").verdict           == ckInvalid
  # The lexer publishes its diagnostics through the module-level `gLexDiags`
  # (set by `tokenize`), which is how the driver reads them too.
  let toks = tokenize(src, defaultLexOptions)
  result = completenessOf(toks, gLexDiags)

proc isComplete*(src: string): bool =
  ## Convenience for the common REPL branch.
  completeness(src).verdict == ckComplete
