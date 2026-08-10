## pyparser.nim — Python ↔ AIF, the `py-parsed` dialect.
##
##   py_spec.nim   — the dialect declaration (drives emit AND render)
##   py_lex.nim    — tokenizer: implicit/explicit line joining, prefixed and
##                   triple-quoted strings
##   py_parse.nim  — indentation-driven suite structure
##
## The FIRST dialect written on aowlparse rather than refactored into it: the
## cursor, the emitters, the renderer, and the whole gate harness came for free,
## and what had to be written was only what is genuinely Python-specific.
##
## Scope, stated rather than discovered later: this is a CONCRETE-SYNTAX dialect,
## like css-parsed and html-parsed. It gives you tokens, logical lines, and the
## indentation tree — enough for formatting, lenses, rewriting, and diffing. It
## is NOT a semantic front end: there is no name resolution, no type model, and
## no expression precedence tree. Python's dynamic semantics are a separate
## project from reading its syntax.

import tokens
import nifbuilder
import aifread
import aowlparse/[nodespec, scan, emit, render]

include py_spec
include py_lex
include py_parse

proc pyToAif*(src: string; diags: var seq[Diagnostic]): string =
  var ps = PyParser(toks: tokenizePy(src), diags: @[])
  var b = nifbuilder.open(src.len * 3 + 64)
  parseModule(ps, b)
  for d in ps.diags: diags.add d
  result = extract(b)

proc pyToAif*(src: string): string =
  var ignored: seq[Diagnostic] = @[]
  result = pyToAif(src, ignored)

proc renderPy*(aif: string): string =
  renderWith(pyDialect(), aif)

proc pyRoundTrips*(src: string): bool =
  renderPy(pyToAif(src)) == src
