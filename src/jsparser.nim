## jsparser.nim — JavaScript ↔ AIF, the `js-parsed` dialect.
##
##   js_spec.nim   — the dialect declaration (drives emit AND render)
##   js_lex.nim    — tokenizer: regex-vs-division, template literals, comments
##   js_parse.nim  — the bracket-group tree
##
## SCOPE, stated up front rather than discovered later.
##
## This is a concrete-syntax dialect. It gives you an exact token stream and the
## bracket-group tree — enough for formatting, lenses, rewriting, minification
## analysis, and diffing. Two things it deliberately does NOT do:
##
##  * NO statement structure. JavaScript's Automatic Semicolon Insertion means
##    statement boundaries depend on the grammar, not on punctuation: `return`
##    followed by a newline ends the statement, but `a` followed by a newline and
##    `(b)` does not. Modeling that correctly requires a real expression parser,
##    and modeling it approximately would produce a tree that is wrong in ways no
##    byte-comparison can catch. `nl` tokens are preserved as their own kind, so
##    a consumer that wants ASI has what it needs to compute it.
##
##  * NO sub-tokenization inside template substitutions. A `` `a${b+c}d` `` is one
##    `template` token. This is the same line CSS draws at function nesting: an
##    unterminated template would otherwise need an extra "was it closed" flag
##    purely to stay byte-exact.
##
## Both limits are about honesty. A tree that claims more structure than the
## parser actually understands is worse than one that claims less, because the
## byte-exact gate cannot tell you when the extra structure is wrong.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

include js_spec
include js_lex
include js_parse

proc jsToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = JsParser(toks: tokenizeJs(src), diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseProgram(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc jsToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = jsToAif(src, ignored)

proc renderJs*(aif: string): string =
  renderWith(jsDialect(), aif)

proc jsRoundTrips*(src: string): bool =
  renderJs(jsToAif(src)) == src
