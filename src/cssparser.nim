## cssparser.nim — CSS ↔ AIF, the `css-parsed` dialect.
##
## THIN aggregator, mirroring `parser.nim`. The implementation is split across
## include files, spliced in dependency order:
##
##   css_lex.nim     — tokenizer; every token keeps its exact source slice
##   css_parse.nim   — fused parse+emit to a nifbuilder Builder
##   css_render.nim  — the inverse: AIF → CSS source, a pure in-order walk
##
## The include files are NOT importable on their own (same trap `parsecore.nim`
## has). Import THIS module.
##
## Round-trip contract, checked by tests/roundtrip.sh:
##   renderCss(cssToAif(s)) == s   for every s, valid CSS or not.

import tokens
import nifbuilder
import aifread

include css_lex
include css_parse
include css_render

proc cssToAif*(src: string; diags: var seq[Diagnostic]): string =
  ## Parse CSS to `css-parsed` AIF. Never raises; problems land in `diags` and
  ## the returned AIF still reproduces the input.
  var ps = CssParser(toks: tokenizeCss(src), diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseStylesheet(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc cssToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = cssToAif(src, ignored)

proc cssRoundTrips*(src: string): bool =
  ## The property the gate rests on, as a callable predicate so consumers (and
  ## fuzzers) can assert it directly.
  renderCss(cssToAif(src)) == src
