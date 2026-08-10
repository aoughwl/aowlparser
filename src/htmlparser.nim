## htmlparser.nim — HTML ↔ AIF, the `html-parsed` dialect.
##
## THIN aggregator, mirroring `parser.nim` and `cssparser.nim`:
##
##   html_lex.nim     — mode-switching tokenizer (raw-text elements)
##   html_parse.nim   — fused parse+emit, open-element stack for nesting
##   html_render.nim  — the inverse: AIF → HTML source, a pure in-order walk
##
## Import THIS module; the include files are not importable on their own.
##
## Round-trip contract, checked by tests/roundtrip.sh:
##   renderHtml(htmlToAif(s)) == s   for every s, well-formed HTML or not.

import tokens
import nifbuilder
import aifread

include html_lex
include html_parse
include html_render

proc htmlToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = HtmlParser(toks: tokenizeHtml(src), diags: @[], open: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseDocument(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc htmlToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = htmlToAif(src, ignored)

proc htmlRoundTrips*(src: string): bool =
  renderHtml(htmlToAif(src)) == src
