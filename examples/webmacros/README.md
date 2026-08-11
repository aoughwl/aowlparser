# webmacros — CSS, HTML and both-at-once, checked by the compiler

```sh
nimony c --path:$PWD/src --path:$PWD/examples/webmacros examples/webmacros/webdemo.nim
```

```nim
template css(s: string): string {.plugin: "mcsslit".}
template html(s: string): string {.plugin: "mhtmllit".}
template web(s: string): string {.plugin: "mweblit".}

const style    = css"""body { color: red; }"""          # ok
const fragment = html"""<div><span>hi</span></div>"""     # ok
const page     = web"""<style>a{}</style><p>hi</p>"""     # ok, BOTH parsers

const b1 = css"""body { color: red;"""                    # fails: '{' is never closed
const b2 = html"""<div><span>hi</div>"""                  # fails: <span> is never closed
const b3 = web"""<style>a{</style><p>hi</p>"""            # fails: invalid CSS inside <style>
```

All six of those are verified — three accepted, three rejected — because a
validator that cannot fail is worse than none.

`web` is the one that earns the shared tree model: `<style>` content is raw text
to the HTML dialect, so finding it is a walk over nodes (`src/html_view.nim`)
rather than a regex for `<style` that would also match inside a comment. Handing
that text to the CSS parser is then one call, because both dialects emit the
same AIF and one reader reads both.

A generalized raw string literal is just a call — `css"…"` calls the `css`
template — and that template is a plugin. The plugin gets the text, parses it
with aowlparser's `css-parsed` dialect, and either fails the build with the
parser's own diagnostic (message, line, column) or returns the validated string.

**You cannot write bare CSS or HTML as Nim** — the lexer would reject it. The
raw string literal is the escape hatch, and it beats a Nim-shaped DSL in one
respect: the text is the real language, so it pastes straight out of a
stylesheet and the error positions point into it.

**Why a literal and not a file path:** the literal's bytes are part of the
plugin's input, so the compiler's cache key covers them — edit the CSS, get a
rebuild. A plugin that reads a *file* has no such guarantee and goes silently
stale (see `examples/cfgconsts`).

## Two things that will bite you

- A triple-quoted literal does **not** arrive as a bare string. `css"""x"""`
  reaches the plugin as `(suf "x" "T")` — text plus a suffix marking how it was
  written. Unwrap it, or the plugin rejects the exact spelling it exists to
  accept.
- HTML validation had to be BUILT for this to be worth anything. The dialect
  used to recover silently from an unclosed element, so the macro would have
  accepted `<div><span>hi</div>` — the exact mistake it exists to catch. It now
  reports `unclosed-element` at the opening tag with a fix-it, while leaving
  alone the elements whose end tag HTML makes optional (`<li>`, `<td>`, `<p>`).
  Measured before shipping: 400 real pages, 3 reports, all three genuine.
- `<script>` is deliberately NOT checked. `js-parsed` is bracket-and-token
  level, not a JavaScript grammar, so it cannot tell broken from working — and a
  check that cannot fail reads as coverage while providing none.
- Plugin output is cached per input, and `--base` puts that cache next to the
  SOURCE being compiled. Testing a plugin fix from a scratch directory reused a
  stale result and told me the fix had not worked. Change the test file's name
  (its path is in the input) or clear the right `nimcache`.

## What else this shape can do

Once the tree is in hand: emit class names as constants so `styles.header` is
compile-checked, minify, rewrite `url(…)` to content-addressed paths, or enforce
a property allow-list. All of it is a walk over the AIF the dialect already
produced.
