## nifparser — a nimony-native Nim-source parser that emits the SAME NIF as the
## classic `nifler`, so it can be compiled to JS (via nim_js) and run in the
## browser where classic-Nim `nifler` cannot.
##
## CLI (mirrors nifler):
##   nifparser p <in.nim> [out.p.nif]     parse a Nim file, produce a NIF file
##
## When the output path is omitted it defaults to `<in>.p.nif`.
##
## This driver is intentionally a thin, top-level-init entry point with only
## file/stdout I/O so the same code path can later back a globalThis-driven JS
## build (no mmap, no PNode AST).

import std/[syncio, os]
import nifbuilder
import tokens, lexer, parser

proc parseToFile(inp, outp, fileField: string; curly: bool) =
  var src = ""
  try:
    src = readFile(inp)
  except:
    write stderr, "cannot read file: " & inp & "\n"
    quit 1
  let toks = tokenize(src)
  var ps = initParser(toks, fileField, curly)
  var b = nifbuilder.open(outp)
  parseModule(ps, b)
  b.close()

proc usage() =
  write stderr, "nifparser — Nim source -> NIF (nifler-compatible)\n"
  write stderr, "usage: nifparser [--curly] p <in.nim> [out.p.nif]\n"
  write stderr, "  --curly   experimental: also accept `{ … }` block bodies\n"
  quit 1

proc main() =
  # Collect positional args, filtering the optional `--curly` flag.
  var params: seq[string] = @[]
  var curly = false
  let cli = commandLineParams()
  for ci in 0 ..< cli.len:
    if cli[ci] == "--curly": curly = true
    else: params.add cli[ci]
  if params.len < 2:
    usage()
  let action = params[0]
  if action != "p" and action != "parse":
    write stderr, "unknown command: " & action & "\n"
    usage()
  let inp = params[1]
  var outp = ""
  if params.len >= 3:
    outp = params[2]
    let n = outp.len
    if n < 4 or outp[n-4 .. n-1] != ".nif":
      outp = outp & ".nif"
  else:
    outp = inp & ".p.nif"
  # `fileField` is the path written into NIF line-info suffixes. nifler uses the
  # cwd-relative path (portablePaths); the harness invokes both tools with the
  # same relative path, so pass the input arg through verbatim.
  parseToFile(inp, outp, inp, curly)

main()
