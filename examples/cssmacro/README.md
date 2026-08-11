# cssmacro — `css"""…"""`, checked by the compiler

```sh
nimony c --path:$PWD/src --path:$PWD/examples/cssmacro examples/cssmacro/cssdemo.nim
```

```nim
template css(s: string): string {.plugin: "mcsslit".}

const style = css"""body { color: red; }"""   # ok
const bad   = css"""body { color: red;"""     # build fails: '{' is never closed
```

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
- HTML is **not** currently validated the way CSS is: `html-parsed` recovers
  silently from a mismatched `</div>` and reports no error, so an
  `html"""…"""` macro built the same way would accept it. The dialect would need
  tag-matching diagnostics first.

## What else this shape can do

Once the tree is in hand: emit class names as constants so `styles.header` is
compile-checked, minify, rewrite `url(…)` to content-addressed paths, or enforce
a property allow-list. All of it is a walk over the AIF the dialect already
produced.
