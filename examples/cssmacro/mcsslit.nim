## mcsslit.nim — `css"""…"""`, checked by the compiler.
##
##     const style = css"""body { color: red; }"""   # ok
##     const bad   = css"""body { color: red;"""     # BUILD FAILS: '{' never closed
##
## This is the embedded-DSL shape: a generalized raw string literal is just a
## call, `css"…"` calls the `css` template, and that template is a plugin. The
## plugin gets the text, parses it with aowlparser's `css-parsed` dialect, and
## either fails the build with the parser's own diagnostic — message, line and
## column — or hands back the validated string.
##
## WHY A STRING LITERAL RATHER THAN A FILE. The literal's bytes are part of the
## plugin's input, so the compiler's cache key covers them: edit the CSS, get a
## rebuild. A plugin that reads a FILE has no such guarantee and goes silently
## stale (see examples/cfgconsts, and the note filed to aowlsem). For inline
## DSLs the trap simply does not apply.
##
## WHY NOT NIM SYNTAX. You cannot write bare CSS or HTML as Nim — the lexer
## would reject it. A raw string literal is the escape hatch, and it has a real
## advantage over a Nim-shaped DSL: the text is the actual language, so it can
## be pasted straight from a stylesheet, and the error positions point into it.
##
## WHAT ELSE A PLUGIN COULD DO HERE, once the tree is in hand: emit the class
## names as constants so `styles.header` is compile-checked; minify; rewrite
## `url(…)` to content-addressed paths; reject a property allow-list. All of it
## is a walk over the AIF the dialect already produced.

import plugins
import std / syncio

import cssparser
import tokens

proc transform(n: NifCursor): NifBuilder =
  let info = n.info
  var args = callArgs(n)
  # A raw/triple-quoted literal does NOT arrive as a bare string: `css"""…"""`
  # comes through as `(suf "…" "T")` — the text plus a suffix marking how it was
  # written (T for triple-quoted, R for raw). Unwrap it, or the plugin rejects
  # exactly the spelling the DSL exists to accept.
  var lit = args
  if args.kind == TagLit and tagText(args) == "suf":
    lit = firstChild(args)
  if lit.kind != StrLit:
    return errorTree("css expects a string literal", args)
  let text = stringValue(lit)

  var diags: seq[Diagnostic] = @[]
  discard cssToAif(text, diags)

  # The parser recovers and reports EVERY problem; the build should fail on the
  # first error but name it precisely, since the literal's own line numbers are
  # what the author is looking at.
  for d in diags.items:
    if d.severity == sevError:
      return errorTree("invalid CSS at line " & $d.line & ", column " &
                       $d.col & ": " & d.message & " [" & d.code & "]", args)

  result = createTree()
  result.addStrLit(text)

var inp = loadPluginInput()
saveTree transform(inp)
