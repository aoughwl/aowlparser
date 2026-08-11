# aowlparser

> **Where this repo lives.** The canonical name is **aowlparser** (the remote is
> `github.com/aoughwl/aowlparser`, the binary is `aowlparser`), but the local
> checkout is `~/aifparser` and older references call it `nifparser`. All three
> names mean this repo.

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

## Linking aowlparser as a library

Import the aggregator modules — `parser`, `cssparser`, `htmlparser`, `pyparser`,
`jsparser`, `jsonparser`, `completeness`. The grammar files (`parsecore.nim`,
`parse_expr.nim`, `css_lex.nim`, …) are `include` files spliced into their
aggregator: **`import parsecore` fails hard.**

### `completeness` — "is this finished, or still being typed?"

```nim
import completeness
completeness("x + 1").verdict       # ckComplete
completeness("if x > 1:").verdict   # ckIncomplete  (dangling-token)
completeness("foo(").verdict        # ckIncomplete  (unclosed-bracket)
completeness("foo)").verdict        # ckInvalid     (unmatched-close)
```

```sh
aowlparser complete in.nim    # exit 0 complete / 2 incomplete / 1 invalid
```

This is the one question `check` deliberately cannot answer: `type`,
`if x > 1:` and `proc twice(x: int): int =` produce **no diagnostics**, because
reading them as empty-bodied constructs is required for `nifler` compatibility.
Correct for `check`, useless for a REPL. The distinction that matters is
`ckIncomplete` (can be finished by typing more) versus `ckInvalid` (cannot).

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

### The dialects

Each is a first-class parser, not a demo. All are byte-exact on real corpora:

| dialect | command | validated on |
|---|---|---|
| `nim-parsed` | `aowlparser p` | 172/172 corpus + full Nim stdlib, vs the `nifler` oracle |
| `css-parsed` | `aowlparser css` | bootstrap x2 + doxygen suite, 543KB |
| `html-parsed` | `aowlparser html` | 150 diverse real pages |
| `py-parsed` | `aowlparser py` | **all 2,885 `.py` on this machine**, 8s |
| `js-parsed` | `aowlparser js` | **11,556 `.js`, 557MB**, 100s |
| `json-parsed` | `aowlparser json` | **all 4,326 `.json`**, 8s |
| `vds-parsed` | `aowlparser vds` | **1,224 MDN grammar strings** (the language CSS specs use) |
| `md-parsed` | `aowlparser md` | **all 5,920 `.md`**, 6s |
| `yaml-parsed` | `aowlparser yaml` | **all 2,112 `.yaml`/`.yml`**, 0.3s — *and* the official **yaml-test-suite**, 402 cases |

```sh
aowlparser auto file.py      # pick the dialect from the extension
aowlparser dialects          # list every dialect and its node vocabulary
tests/run.sh                 # THE gate: every dialect, the CLI, robustness,
                             # and the Nim differential, in one command
```

## `jsonfast` — the reader, when you want the data and not the bytes

Every dialect above keeps every byte, because a rewriting front end must. That
is the wrong shape for *reading* a 200MB API response, so `src/jsonfast.nim` is
the opposite trade: a JSON reader that throws the whitespace away and goes fast.

Measured on this machine, best of 25, DOM-building and parse-only:

| reader | 9.9MB catalog | 1.5MB source index | 1.3MB protocol |
|---|---|---|---|
| **jsonfast (tape)** | **902 MB/s** | **1351 MB/s** | **687 MB/s** |
| V8 `JSON.parse` (node 25) | 606 MB/s | 765 MB/s | 560 MB/s |
| CPython `json` (C accelerated) | 208 MB/s | 268 MB/s | 298 MB/s |
| `aowljson` (ref tree) | 165 MB/s | 336 MB/s | 196 MB/s |

`tests/json/bench.sh` runs that table. **It is not the fastest JSON parser in
existence** — simdjson uses SIMD to do several bytes per instruction and lands
in the GB/s range on the same shapes. This is the fastest thing here without
intrinsics, and it beats the two readers most software actually runs through.

Where the speed comes from, and what each choice costs:

- **A flat tape, not a tree of refs.** One 16-byte entry per value in one `seq`:
  no allocation per value, no pointer chase, and a container stores the index
  one past its last descendant, so skipping a 10MB sub-object is one assignment.
- **Zero-copy strings and lazy numbers.** A string is an offset and a length
  until someone asks for it; a number is its lexeme until someone wants its
  value. Most values in a big document are never read.
- **No recursion.** Depth is an explicit stack with a bound, so `[[[[…]]]]` is a
  named error rather than the stack overflow recursive-descent JSON parsers are
  famous for.
- **Pre-sized tape.** Growing by doubling copies the whole tape each time; on
  10MB that was 9% of the total runtime, spent on `memcpy` before the parse had
  learned anything.

**Correctness is not asserted, it is measured.** `tests/json/tfast.nim` holds
the reader to CPython's `json` module on **every `.json` file on this machine —
10,029 of them — and on 494,373 sampled PREFIXES of those files**: 602,527
checks, all agreeing. The prefixes are the important half. A corpus of valid
documents only proves a reader is permissive *enough*; a prefix is malformed in
a different way each time, and accept/reject agreement on half a million of them
is what catches the dangerous direction — accepting what is not JSON. Strictness
is RFC 8259, which is stricter than CPython: `NaN` and `Infinity` are not JSON,
so the oracle is configured to reject them too rather than letting the reader
inherit CPython's extension.

Two things the gate had to learn to say out loud: files that are **not UTF-8**
(neither side is truth there), and files that **changed on disk mid-run** —
this machine's `.json` is full of live state, and Claude Code's own config
rewrote itself during a sweep and made a correct parser look wrong by two
integers.

### Using it with `aowljson`

```nim
import jsonfast
let doc = parse(src)              # 900 MB/s, nothing materialized
if not ok(doc): echo doc.err, " at ", doc.errPos
let v = view(doc)
echo v{"user"}{"name"}.str("")    # chain-safe, allocation-free
for tag in v{"tags"}.items: echo tag.str("")
```

```nim
import jsonfast_aowljson           # when you need the aowljson value tree
var err = ""
let v = parseJsonFast(src, err)    # drop-in for aowljson.parseJson
```

Be honest about which one to reach for: **the drop-in is not the fast path.**
Building a `ref`-per-value tree with a string copy per value costs about six
times the parse itself, so `parseJsonFast` lands near `aowljson.parseJson` and
the speed above simply does not survive materialization. If you want the speed,
stay on the tape and use views — that is what they are for. Building the tree
did surface one real defect in `aowljson`, now fixed there: `[]=` rescans every
existing key, so a parser using it is quadratic in object width *and* silently
collapses the duplicate keys a faithful reader must keep. `addPair` is the
parser's door.

### An outside oracle, where one exists

`yaml-parsed` is the first document dialect with **third-party truth** available:
the official [yaml-test-suite](https://github.com/yaml/yaml-test-suite) ships a
canonical event stream per case, so `tests/yaml/tsuite.nim` checks the document
count against it rather than against assertions written by whoever wrote the
parser. That distinction is not academic — it is the whole reason the check
exists. The dialect passed its own round-trip gate on all 2,112 YAML files on
this machine, its own hand-written shape assertions, and every truncation fuzz,
**while getting the document count wrong in 20 of the suite's 255 cases**: a
`%YAML`/`%TAG` directive was being read as an implicit document, and a `...`
with nothing open was opening the document it exists to close. Both bugs are
invisible to `render(parse(s)) == s`, because the bytes come back either way.

Two counts are compared — **documents** (255 cases) and **mapping keys** (179
cases). The key count is the dialect's real structural claim, and widening it
found seven more defects the round-trip could not: a tab after `:` is valid
separation and was rejected (`- foo:<TAB>bar` was no mapping at all); a quote
mid-scalar was read as a string opener (`bla"keks: foo`); a stray `]` in a plain
scalar left the scan at depth -1; `{"foo":bar}` needs no space after the colon;
a plain scalar inside a flow collection may continue on the next line; a comment
may sit between a key and its colon; and `&anchor {x: 1}` is a flow mapping
behind an anchor, not one opaque scalar.

76 cases are **not** comparable on keys, and are excluded by name with the count
printed: explicit `? ` keys, block scalar bodies, anchor names containing a
colon, and a collection used as a key (`{a: 1}: v`). Those are the dialect's
scope boundary, not defects — and an exclusion nobody sees reads exactly like a
pass. A falsification control keeps the check honest: perturbing the expected
count by one turns every comparison red.

`src/jsonparser.nim` is the economy check: declaration, tokenizer, parser,
renderer and all, in **one short file**, because everything except the JSON
grammar already existed. A new format should cost only what is genuinely new
about it.

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
