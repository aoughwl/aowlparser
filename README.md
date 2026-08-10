# aowlparser

A pure-**nimony** recursive-descent parser that turns Nim source into the
parse-dialect AIF (`.p.aif`) the compiler frontend consumes — the same job as the
classic compiler's `nifler`, but self-hosted and free of the classic Nim compiler,
so it can be compiled to JavaScript and run in the browser.

Its output is **byte-for-byte identical** to native `nifler` — save for one line
it owns on purpose, the `(.vendor "aowlparser")` header (aowlparser stamps its own
identity rather than impersonating `nifler`). The entire **nimony** source tree and
standard library round-trip (184/184 nimony/src byte-exact, 105/105 nimony/lib
structural parity), and all 169 corpus programs pass — 154 of them byte-for-byte.

Beyond nimony's own tree, aowlparser is validated against the **full upstream Nim
standard library** by differential fuzzing: **all 310 of 310 `Nim/lib` files**
now round-trip **structure-identical** to `nifler` — 283 of them byte-for-byte —
with 0 crashes and 0 hangs. Every construct in the real Nim stdlib parses,
including term-rewriting template patterns, `Inf`/`NaN` hex-bit literals, custom
numeric literals (`1'big`), method-chain continuations, multi-`do` calls, and
pragma-decorated lambda sugar.

Where aowlparser goes **beyond** `nifler` — its diagnostics are built to be a
markedly better front end for editors, LSPs, and CI:

- **Never dies on the first error.** It recovers and keeps parsing, so one run
  surfaces *every* problem — and it never cascades into the phantom
  end-of-file errors a one-shot parser spews once it loses its place. Across the
  full Nim compiler test corpus, on files where both report errors, `nifler`
  emits ~2× the error lines we do.
- **Fix-its.** Every grammar error carries a suggested repair (`help: insert ':'`,
  `help: did you mean '=='?`) — the classic parser has no such concept.
- **Related locations.** A mismatched bracket points at *both* the close and the
  `(` it should have matched (`note: '(' opened here`), as a structured field.
- **Machine-readable.** `--diagnostics:json` emits `{severity, code, message,
  line, col, endCol, fix, related}` per diagnostic, for editor quick-fixes.
- **Full lexer-error parity, and then some.** Every classic lexical error
  `nifler` reports, aowlparser now reports too, recovering past each instead of
  aborting: bad character literals (empty `''`, run-on `'ab'`, unterminated
  `'a`), illegal tabs (anywhere outside strings/comments), unterminated block
  comments (`#[ … `), malformed escapes (`\q`, empty `\x`, empty `\u{}`),
  unterminated triple/raw strings, doubled/trailing underscores in a number,
  and unterminated accent-quoted identifiers.
- **Detections nifler lacks or reports vaguely**: assignment in a condition
  (`if x = 5:` → *did you mean `==`?*), empty conditions (`elif:`), empty comma
  slots (`foo(a,,b)` — while correctly allowing a valid *trailing* comma),
  invalid numeric/identifier literals, and full UTF-8 identifier support.
- **"Forgot the introducer" family.** Where `nifler` only spits a bare *invalid
  indentation* at a stray body line, aowlparser names the actual omission and
  points at the declaration: a routine with a body but no `=`
  (`proc f()` ⏎ `  echo 1`), a `type Name` with an indented body but no
  `= object`/`= enum`, and a colon-block whose body isn't indented past its
  header. Each carries the exact fix-it.
- **Precise grammar diagnostics** where `nifler` is terse or cryptic: `func`
  used in a type description (→ *use `proc` with `{.noSideEffect.}`*), a keyword
  where an enum member is expected (`when` spliced into an `enum` body), an
  empty object-variant branch (`of A:` with no field — we point at the branch
  itself, not the innocent next one), and an `of` with no value before its `:`.
- **Knows what isn't plain Nim.** A file opening with a `#? stdtmpl` source-code
  filter is a template, not Nim — `check` stays silent instead of flagging the
  raw HTML, where `nifler` only tokenizes it by luck.
- Every check is proven **zero-false-positive** against ~600 valid files and the
  whole Nim standard library, and never changes the emitted AIF.

Measured against the full Nim compiler test corpus (2890 files): where `nifler`
reports a syntax error, aowlparser now reports one too — except a small residue
of *indentation-context* errors deliberately left out (see below). We report
**zero** false errors on files `nifler` accepts, and we parse cleanly **6 files
that crash `nifler` outright**.

Honest limitation: `nifler` still flags a handful of subtle *indentation-context*
errors we don't — those are deliberately left out rather than risk a false
positive on valid code.

**📖 Full docs → [aoughwl.github.io/docs/aowlparser](https://aoughwl.github.io/docs/aowlparser)**

- [Architecture](https://aoughwl.github.io/docs/aowlparser/architecture) — fused parse + emit, the range-splitter, the module map, the oracle
- [Grammar coverage](https://aoughwl.github.io/docs/aowlparser/grammar) — every construct reproduced
- [Differential testing](https://aoughwl.github.io/docs/aowlparser/testing) — the `nifler` oracle harness
- [Configuration](https://aoughwl.github.io/docs/aowlparser/configuration) — brace blocks (`--curly`), indentation/whitespace policy, lint checks, `--strict`/`--max-depth`, and stdio I/O
- [Known gaps](https://aoughwl.github.io/docs/aowlparser/known-gaps) — the honest edge-case catalog

```sh
aowlparser p in.nim out.p.aif           # parse Nim source -> nifler-compatible AIF
aowlparser check in.nim                  # lint / report diagnostics, recovering past errors
aowlparser p --diagnostics:json in.nim out.p.aif   # structured diagnostics for tooling
```

Everything is off by default, so a plain run is byte-compatible with `nifler`.

## aowlparse — the generic parsing core

`src/aowlparse/` is a small library for building byte-exact source→AIF front
ends. The dialects in this repo are its first users, and each is a first-class
parser in its own right rather than a demo.

| module | what it owns |
|---|---|
| `nodespec.nim` | a dialect declares each tag as **text / punct / struct / opaque**, once |
| `scan.nim` | the byte cursor: position, 1-based line, 0-based column, `\r\n` as one break |
| `emit.nim` | AIF header, `leaf`/`mark`, validated against the declaration |
| `render.nim` | **one renderer for every dialect**, driven by the declaration |
| `gate.nim` | the acceptance harness: identity, round-trip, declared, shape, fuzz |

**Why one declaration.** A hand-written renderer can disagree with its parser
about whether a byte is emitted, and that disagreement is exactly the bug class a
byte-exact gate exists to catch. Both sides read `NodeSpec`, so the divergence is
not merely caught — it is unrepresentable. `undeclaredTags` closes the other
door: an undeclared tag would render as *nothing*, so forgetting to declare a
node is a silent byte loss, and the gate names it instead.

**Why four checks and not one** (`gate.nim` documents this at length):

- **identity** — the token stream concatenates back to the input, checked before
  a tree exists to blame.
- **round-trip** — `render(parse(s)) == s`. Proves the renderer inverts the
  parser, and *nothing about whether the tree is right*.
- **declared** — every emitted tag is in the declaration.
- **shape** — node counts and nesting depth. The only check that sees tree
  correctness. A dialect supplying none has opted out of ever detecting a wrong
  tree.

Adding a dialect means writing a tokenizer, a fused parse+emit, and a
declaration. Rendering, gating, and fuzzing come for free.

## Document dialects: CSS

Beyond Nim, aowlparser ingests document formats into AIF. The first is CSS, as the
`css-parsed` dialect (`spec/css-dialect.md`):

```sh
aowlparser css in.css out.css.aif        # CSS -> css-parsed AIF
aowlparser render out.css.aif            # AIF -> CSS source (inverse of the above)
```

`render` is the first **reader** side this repo has had — the Nim front end is
one-way — and it dispatches on the `.dialect` header, not the file extension.

**The acceptance criterion is byte-exactness, not structural equivalence.** The Nim
front end is checked differentially against native `nifler`; CSS has no such oracle,
so the gate is the round-trip itself:

```sh
tests/roundtrip.sh     # css -> aif -> render -> cmp, must be byte-identical
```

Currently **543,847 bytes byte-exact** across bootstrap (both the 221KB and 281KB
builds) and the doxygen/mimalloc stylesheets, plus ~350 truncation-fuzz cases.

Two design rules make that reachable, and both are the opposite of what the Nim
dialect does:

- **Leaves carry raw lexemes.** Nothing is decoded, unescaped, or case-folded.
  `COLOR` stays `COLOR`, `.5` does not become `0.5`, `'x'` keeps its quote.
- **No punctuation is implied.** `(lbrace)`, `(rbrace)`, `(colon)`, `(semi)` are
  explicit nodes, so rendering emits no byte that was not in the source — and
  malformed CSS round-trips too, rather than gaining braces it never had.

Parsing never fails: unclassifiable spans become `(err (code …) (raw …))` holding the
skipped bytes verbatim, and diagnostics land on the usual `--diagnostics:json` path.

## Document dialects: HTML

```sh
aowlparser html in.html out.html.aif     # HTML -> html-parsed AIF
aowlparser render out.html.aif           # AIF -> HTML source
```

Same two rules as CSS (`spec/html-dialect.md`). The tokenizer is mode-switching:
`<script>`, `<style>`, `<textarea>` and `<title>` content is scanned as raw text, so a
`<div>` inside a JavaScript string is never mistaken for a tag.

Validated on **150 diverse real-world pages** (doxygen, Nim docgen, npm docs, mark.js
fixtures) — all byte-exact, plus truncation fuzzing.

**Nesting is best-effort; bytes are not.** This is not a full WHATWG insertion-mode
implementation: it keeps an open-element stack, knows the void and raw-text elements,
closes to a match, and emits an unmatched end tag as a stray `(etag)`. Pathological
input may nest differently from a browser. Every token is still recorded, so
round-trip is exact regardless.

### Why there are two gates, not one

`tests/roundtrip.sh` proves the renderer inverts the parser — and **nothing about
whether the tree is correct**, because a token's bytes survive no matter which node
they land in. Measured, not assumed: disabling raw-text mode entirely left the
round-trip gate at 44/44 PASS with `<script>` content parsed as markup.

So `tests/html/tstructure.nim` asserts *shape* — node counts by kind and nesting
depth — and every assertion in it is one a byte-comparison is blind to. It found a
real bug on its first run (`</script>` left raw-text mode without entering tag mode,
so the end-tag parser ate the rest of the document as opaque leaves, byte-exactly).

## Source dialects: Python and JavaScript

```sh
aowlparser py in.py   out.py.aif      # Python -> py-parsed AIF
aowlparser js in.js   out.js.aif      # JavaScript -> js-parsed AIF
aowlparser render out.py.aif          # AIF -> source
```

**Python** (`py-parsed`) models the thing that makes Python Python: the
**indentation tree**. A statement line whose successor is indented deeper gets a
`(block …)` child. The tokenizer handles implicit line joining (a newline inside
brackets is not a terminator), explicit `\`-joining, and prefixed/triple-quoted
strings. Blank and comment-only lines do not affect indentation — taking a blank
line's indent of 0 as a dedent would close every open block at the first empty
line, while staying perfectly byte-exact, which is why that has a shape assertion.

Validated on **all 2,885 Python files on this machine** — byte-exact, in 10s.

**JavaScript** (`js-parsed`) handles the hazard that defines JS tokenizing:
`/` is a regex in expression position and division in operand position, decided
by the *preceding* token. Getting it wrong silently swallows code into a regex
that runs to end-of-line — byte-exactly — so the shape gate concentrates there.
Template literals are kept whole, with `${…}` nesting tracked so a `}` inside a
nested string does not end them early.

Validated on **11,556 real JavaScript files** (557MB, including minified
bundles).

**Scope, stated up front.** Both are *concrete-syntax* dialects, like CSS and
HTML: exact tokens plus a structural tree (indentation for Python, bracket groups
for JavaScript). Neither models statement structure via ASI, expression
precedence, name resolution, or types. That line is deliberate — a tree claiming
more structure than the parser understands is worse than one claiming less,
because byte-exactness cannot tell you when the extra structure is wrong.
