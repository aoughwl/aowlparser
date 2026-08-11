## mhtmllit.nim — `html"""…"""`, checked by the compiler.
##
##     const page = html"""<div class="x">hi</div>"""     # ok
##     const bad  = html"""<div><span>hi</div>"""         # BUILD FAILS: <span> never closed
##
## Same shape as `mcsslit`: a raw string literal is a call, the template is a
## plugin, the plugin parses the text with aowlparser's `html-parsed` dialect
## and either fails the build with the parser's diagnostic or hands back the
## validated string.
##
## HTML needed work before this was worth writing. The dialect used to recover
## silently from an unclosed element, so a macro built on it would have accepted
## `<div><span>hi</div>` — which is the exact mistake a compile-time check
## exists to catch. It now reports `unclosed-element` at the OPENING tag with a
## fix-it, while leaving alone the elements whose end tag HTML makes optional
## (`<li>`, `<td>`, `<p>` …). Measured before shipping: 400 real pages on this
## machine, 3 reports, all three genuine (one is a Nim test file that says
## `<!-- error: > missing -->` in its own source).

import plugins
import std / syncio

import htmlparser
import tokens

proc transform(n: NifCursor): NifBuilder =
  var args = callArgs(n)
  var lit = args
  if args.kind == TagLit and tagText(args) == "suf":
    lit = firstChild(args)
  if lit.kind != StrLit:
    return errorTree("html expects a string literal", args)
  let text = stringValue(lit)

  var diags: seq[Diagnostic] = @[]
  discard htmlToAif(text, diags)
  for d in diags.items:
    if d.severity == sevError:
      return errorTree("invalid HTML at line " & $d.line & ", column " &
                       $d.col & ": " & d.message & " [" & d.code & "]", args)

  result = createTree()
  result.addStrLit(text)

var inp = loadPluginInput()
saveTree transform(inp)
