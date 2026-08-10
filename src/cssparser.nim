## cssparser.nim — CSS ↔ AIF, the `css-parsed` dialect.
##
## THIN aggregator, mirroring `parser.nim`:
##
##   css_spec.nim    — the dialect declaration (drives emit AND render)
##   css_lex.nim     — tokenizer; every token keeps its exact source slice
##   css_parse.nim   — fused parse+emit to a nifbuilder Builder
##
## Rendering is NOT written here: `aowlparse/render.nim` renders any dialect
## from its declaration, so there is no per-dialect renderer to disagree with
## the parser. (There used to be a css_render.nim; it was the same algorithm as
## html_render.nim differing only in two tables, which is precisely what the
## declaration now holds.)
##
## Import THIS module; the include files are not importable on their own.
##
## Round-trip contract, checked by tests/roundtrip.sh:
##   renderCss(cssToAif(s)) == s   for every s, valid CSS or not.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

include css_spec
include css_lex
include css_parse

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

proc renderCss*(aif: string): string =
  renderWith(cssDialect(), aif)

proc cssRoundTrips*(src: string): bool =
  ## The property the gate rests on, as a callable predicate so consumers (and
  ## fuzzers) can assert it directly.
  renderCss(cssToAif(src)) == src
