## mweblit.nim — `web"""…"""`: one literal, both parsers.
##
##     const page = web"""
##       <style>body { color: red; }</style>
##       <div class="x">hi</div>
##     """
##
## The markup is checked by `html-parsed`, and the contents of every `<style>`
## element are then checked by `css-parsed`. Break either one and the build
## fails, pointing at the language that is actually wrong:
##
##     <style>body { color: red;</style>   →  invalid CSS inside <style>: '{' is never closed
##     <div><span>hi</div>                 →  invalid HTML: <span> is never closed
##
## THIS IS THE ARGUMENT FOR ONE TREE MODEL, in its smallest honest form. A
## `<style>` element's content is not HTML — the dialect already treats it as
## raw text, the same way it treats `<script>` — so finding it is a walk over
## nodes rather than a regex over bytes. Handing that text to the CSS parser is
## then one call, because both dialects emit the same AIF and this plugin reads
## both with the same reader. Nothing here knows about "web" as a language; it
## composes two parsers that were written separately.
##
## The `<style>` extraction lives in `src/html_view.nim`, not here: its first
## version was wrong, and nothing in an example directory could test it. It is
## now a library proc with the rest of the parsers.
##
## What it deliberately does NOT do: `<script>` content is left alone. The
## `js-parsed` dialect is bracket-and-token level, not a JavaScript grammar, so
## it cannot tell a broken script from a working one — and a check that cannot
## fail is worse than no check, because it reads as coverage.

import plugins
import std / syncio

import htmlparser
import cssparser
import html_view      # styleTexts — a library proc, so it is testable
import tokens

proc transform(n: NifCursor): NifBuilder =
  var args = callArgs(n)
  var lit = args
  if args.kind == TagLit and tagText(args) == "suf":
    lit = firstChild(args)
  if lit.kind != StrLit:
    return errorTree("web expects a string literal", args)
  let text = stringValue(lit)

  var hdiags: seq[Diagnostic] = @[]
  let aif = htmlToAif(text, hdiags)
  for d in hdiags.items:
    if d.severity == sevError:
      return errorTree("invalid HTML at line " & $d.line & ", column " &
                       $d.col & ": " & d.message & " [" & d.code & "]", args)

  let styles = styleTexts(aif)
  for css in styles.items:
    var cdiags: seq[Diagnostic] = @[]
    discard cssToAif(css, cdiags)
    for d in cdiags.items:
      if d.severity == sevError:
        # The line number is relative to the <style> content, and saying so is
        # the difference between a useful message and a confusing one.
        return errorTree("invalid CSS inside <style> (line " & $d.line &
                         " of the style block): " & d.message &
                         " [" & d.code & "]", args)

  result = createTree()
  result.addStrLit(text)

var inp = loadPluginInput()
saveTree transform(inp)
