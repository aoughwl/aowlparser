## vdsparser.nim — MDN value-definition syntax ↔ AIF, the `vds-parsed` dialect.
##
##   vds_spec.nim   — the dialect declaration (drives emit AND render)
##   vds_lex.nim    — tokenizer; the `+`/`*` and `{` ambiguities
##   vds_parse.nim  — a range splitter over VDS combinator precedence
##
## VDS is the language CSS specifications are WRITTEN IN — the grammar strings
## MDN publishes, like `<length-percentage>{1,4} [ / <length-percentage>{1,4} ]?`
## It is a genuine language with its own precedence, so it gets a genuine parser
## rather than living as string-munging inside a validator.
##
## Precedence, loosest to tightest:  `|`  <  `||`  <  `&&`  <  juxtaposition.
## Postfix multipliers: `?` `*` `+` `#` `!` `{m,n}`.
##
## Acceptance corpus is MDN's own baked JSON — 1,224 real grammar strings from
## properties/syntaxes/at-rules/functions/selectors — which is to this dialect
## what bootstrap.css is to css-parsed.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

include vds_spec
include vds_lex
include vds_parse

proc vdsToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = VdsParser(toks: tokenizeVds(src), diags: @[])
  var b = nifbuilder.open(src.len * 4 + 64)
  parseVds(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc vdsToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = vdsToAif(src, ignored)

proc renderVds*(aif: string): string =
  renderWith(vdsDialect(), aif)

proc vdsRoundTrips*(src: string): bool =
  renderVds(vdsToAif(src)) == src
