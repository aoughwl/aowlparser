## htmlparser.nim — HTML ↔ AIF, the `html-parsed` dialect.
##
## THIN aggregator, mirroring `parser.nim` and `cssparser.nim`:
##
##   html_spec.nim    — the dialect declaration (drives emit AND render)
##   html_lex.nim     — mode-switching tokenizer (raw-text elements)
##   html_parse.nim   — fused parse+emit, open-element stack for nesting
##
## Rendering comes from `aowlparse/render.nim`, driven by the declaration — see
## cssparser.nim for why there is no per-dialect renderer any more.
##
## Import THIS module; the include files are not importable on their own.
##
## Two contracts, and neither implies the other (see aowlparse/gate.nim):
##   renderHtml(htmlToAif(s)) == s        for every s, well-formed or not
##   the resulting TREE is right          — only shape assertions can see this

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

include html_spec
include html_lex
include html_parse

proc htmlToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = HtmlParser(toks: tokenizeHtml(src), diags: @[], open: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseDocument(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc htmlToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = htmlToAif(src, ignored)

proc renderHtml*(aif: string): string =
  renderWith(htmlDialect(), aif)

proc htmlRoundTrips*(src: string): bool =
  renderHtml(htmlToAif(src)) == src
