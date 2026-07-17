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

Where aowlparser goes **beyond** `nifler`: it never dies on the first error.
It **recovers** and keeps parsing, reports **structured diagnostics**
(`--diagnostics:json`), and ships a `check` lint mode — so it's a better front end
for tooling, editors, and CI than the classic one-shot parser.

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
