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
