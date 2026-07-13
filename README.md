# nifparser — nimony-native Nim parser → NIF

A parser for Nim source that emits the **same NIF** as the classic
[`nifler`](../nimony/src/nifler) tool — but written in **nimony**, so it can be
compiled to JavaScript (via the nimony JS backend) and run in the browser, where
the classic-Nim `nifler` cannot.

`nifler` is a pure *syntactic* transducer: `Nim source → PNode (classic Nim
parser) → NIF`, with **no** semantic checking and no symbol resolution — every
symbol comes out as a bare identifier. `nifparser` reproduces that `.p.nif`
output without depending on the classic-Nim compiler.

## Status

The bar is **byte-for-byte-identical output** to native `nifler`, checked by a
differential harness (see below). Two levels: **structural** (token trees equal
after line-info is stripped — the pass criterion) and **exact** (byte-identical
`.p.nif`, line-info included).

| suite | files | result |
|---|---|---|
| curated corpus (`tests/diff.sh`) | 47 | **47 pass**, 46 byte-exact |
| whole nimony standard library (`nimony/src/lib`) | 29 | **29 pass** structurally, 0 crash |
| whole nimony compiler tree (`nimony/src`) | 184 | **127 pass**, 57 known-gap, **0 crash / 0 hang** |

The entire real standard library round-trips structurally identical to native
nifler. Across the much larger compiler-internals tree the parser never crashes
or hangs; the 57 structural mismatches fall into a small set of catalogued
edge-case categories (see [Known gaps](#known-gaps)).

### Experimental: curly-brace blocks (`--curly`)

Off by default, so output stays nifler-compatible. With `--curly`, a `{ … }`
block body is accepted **anywhere** a `:` body is, and the two may be mixed
freely:

```nim
if c { echo a } else: echo b      # brace + colon, mixed
while x { dec x; use x }           # `;`-separated statements inside braces
```

A block `{` is the first depth-0 `{` (not a `{.` pragma) that follows an operand
(`if c {`) or a bodiless-block keyword (`else {`, `try {`, `block {`,
`finally {`, `defer {`), so a set literal in the head (`if {1} == x { … }`) is
not mistaken for the body. This is a nifparser extension; native nifler has no
equivalent.

---

## Architecture

**Fused parse + emit.** `nifparser` does *not* build a Nim `PNode` AST. It is a
recursive-descent parser that writes NIF **directly** through `nifbuilder` as it
recognises each construct. (Rebuilding an object-variant `ref` AST would crash
nimony's field magics — a known constraint — and is unnecessary: the emit is a
single left-to-right walk anyway.) Line-info suffixes are emitted relative to
each node's parent so the output matches native nifler byte-for-byte.

**Range-splitter expressions.** Operator precedence is resolved by finding the
lowest-precedence depth-0 operator in a token span and recursing on the two
sides, which reproduces nifler's operator nesting (and pretty-print indentation)
for free — no separate precedence-climbing state.

Layout (`src/`):

| module | role |
|---|---|
| `tokens.nim`   | The `Token` contract — `TokKind` and the `Token` object shared by lexer and parser. |
| `lexer.nim`    | Full hand-written lexer: identifiers/keywords, all numeric bases + typed suffixes, raw/triple/char strings with escapes, backtick-quoted idents → `(quoted …)`, `#`/`#[ ]#`/`##`/`##[ ]##` comments, significant indentation. |
| `parser.nim`   | Thin aggregator: `include`s the grammar files (order matters) and holds the module loop `parseModule`. |
| `parsecore.nim`| Shared spine — `Parser` type, token cursor, line-info emission, operator classification, range-scanning helpers, and the cross-file forward declarations. |
| `parse_expr.nim`| Expressions, operators, constructors, named args. |
| `parse_type.nim`| Type defs, routine/proc defs, params, generics, pragmas. |
| `parse_stmt.nim`| Statements, control flow, `var`/`let`/`const` sections. |
| `nifparser.nim`| CLI driver — `nifparser [--curly] p in.nim [out.p.nif]`, mirroring nifler. Thin top-level-init entry with only file I/O (JS-build friendly: no mmap, no PNode). |

The grammar files are spliced by `parser.nim` in the order
`parsecore → parse_expr → parse_type → parse_stmt`. Because they are `include`d
into one module, mutual recursion across files resolves through the forward
declarations in `parsecore.nim`'s `FORWARD DECLS` block.

### The oracle spec

`nifparser`'s target is defined operationally by the classic Nim compiler's
lexer and parser (`/home/savant/Nim/compiler/{lexer,parser}.nim`), which `nifler`
mirrors exactly. The subtle rules reproduced here come straight from there:
`accQuoted` piece-splitting, `scanComment` run-merging, `getPrecedence`
(assignment ops → 1, arrows → 0), the `*:` split, `##`-as-`nkCommentStmt`,
`##[ ]##` doc blocks, spacing-based prefix/infix disambiguation, and
`postExprBlocks`.

---

## Build

Requires the nimony toolchain at `/home/savant/nimony` (provides `nimony`,
`nifbuilder`, and the `nifler` oracle binary at `bin/nifler`).

```bash
NIM=/home/savant/nimony
bash /home/savant/.claude/jobs/8d47d301/tmp/nifi-build-lock.sh \
  "$NIM/bin/nimony" c \
  -p:"$NIM/src/lib" -p:"$NIM/src/nimony" -p:"$NIM/src/models" \
  -p:"$NIM/src/gear2" -p:src \
  --nimcache:./nimcache -o:./bin/nifparser src/nifparser.nim
```

Produces `bin/nifparser`. (The build lock serialises nimony compiles that share
one static object file.) Run it:

```bash
bin/nifparser p tests/corpus/proc_return.nim /tmp/out.p.nif
bin/nifparser --curly p mixed_blocks.nim /tmp/out.p.nif
```

### JS build

The design keeps the JS path open: a top-level-init driver, `globalThis` I/O
instead of file reads, and no mmap of source paths. Nothing in the parser blocks
it; the JS glue is future work.

---

## Differential harness

For every input, run the **native nifler oracle** and **nifparser**, then compare
their NIF after canonicalisation.

```bash
bash tests/diff.sh                       # curated corpus, PASS/FAIL per file
VERBOSE=1 bash tests/diff.sh             # + canonical diff for failures
bash tests/stress.sh                     # differential over nimony/src/lib
bash tests/stress.sh /path/to/dir ...    # over any dirs/files
```

Two comparisons per file:

* **Structural** (the pass criterion) — `tests/canon.py` strips line-info
  (`@…`/`~…`) and comment suffixes and normalises whitespace, then the two token
  trees must be identical. String-literal contents are preserved (NIF escapes all
  marker bytes inside strings, so they cannot be confused with a suffix).
* **Exact** (bonus) — byte-identical `.p.nif`, line-info included.

`stress.sh` additionally reports crashes/hangs (`our-crash`) and files the oracle
itself skips (`oracle-skip`), so a run over a fresh tree is a full robustness
check, not just a correctness one.

---

## What's covered

- **Lexer** — all numeric bases (`0x`/`0o`/`0b`/`0c`) and `_` separators (nifler
  emits decimal only), typed literal suffixes → `(suf …)`, `"…"`/`r"…"`/`"""…"""`
  strings and `'c'` chars with full escape decoding, backtick-quoted idents →
  `(quoted …)` (per the `accQuoted` piece rule), `#` line / `#[ ]#` block /
  `##` doc / `##[ ]##` doc-block comments (standalone doc comments → `(comment)`,
  trailing ones dropped, consecutive `##` lines merged), the `*:` split, and
  significant indentation carried on `Token.indent`.
- **Expressions** — Nim's real precedence (assignment operators → 1, arrows → 0),
  spacing-based prefix/infix disambiguation (`f $v` vs `a $ b`), `-N` and
  `-N'suf` literal folding, `ident"…"` call-string-literals, postfix chains
  (`.`, `[]` → `at`, `{}` → `curlyat`, `()` → `call`/`oconstr`), `cast[T](x)`,
  `addr`, `nil`, `if`/`when`/`try` **expressions**, anonymous `proc` expressions,
  tuple `(a, b)` vs paren `(a)`, set/array/table constructors, StmtListExpr
  `( … ; … )`, named args `k = v` (`vv`) and colon pairs `k: v` (`kv`).
- **Commands** — in statement, expression **and** type position, with prefix-op
  args (`add $v`), dotted callees (`result.add c`), and `postExprBlocks`
  (`foo(x): body`, inline and indented).
- **Control flow** — `if`/`elif`/`else`, `case`/`of` with `(ranges …)`, `while`,
  `for` with `unpackflat`/`unpacktup`, `try`/`except`/`finally`, `when`, `block`,
  `break`/`continue`, `defer`, `static` — in multi-line **and** one-liner forms,
  as statements **and** as multi-line values (`let x = try:` …), plus
  `;`-separated statements.
- **Sections** — `var`/`let`/`const` with no wrapper node (each ident-def a
  sibling, type & value duplicated across a multi-name group), visibility `*`,
  pragma split, and var-tuple unpacking → `(unpackdecl … (unpacktup …))`.
- **Type / routine defs** — `object` (inheritance, fields, variant `case`, `when`
  conditional fields), `enum` (`efld`, one-per-line), `tuple`,
  `ref`/`ptr`/`distinct`, `concept`, proc/iterator **types**
  (`proctype`/`itertype`), generics `[T; U: C]` → `(typevars …)`, and `{. … .}`
  pragmas on decls and as `pragmax`.

---

## Known gaps

The 57 structural mismatches over the full `nimony/src` tree cluster into these
categories (all produce well-formed NIF — none crash or hang). Ordered roughly by
frequency:

- **Doc-comment placement** — a few standalone-vs-trailing `##` boundary cases
  where a comment node lands on a different sibling than nifler chooses.
- **Routine / proc-type pragma & empty-param shapes** — some `(params)` vs `.`
  and pragma-slot orderings on proc **types** and forward decls.
- **`nil` in annotation position** — e.g. `(nil)` inside certain pragma/type
  contexts.
- **Generalised call-string-literals** — `expr"…"` where the callee is not a bare
  identifier (`pkg.mod"…"`, `(expr)"…"`).
- **`@`-prefix and quoted-ident corners** — a handful of `(prefix @ …)` and
  `(quoted …)` placements in dense expressions.
- **Assorted control-flow-value wrapping** — a few `(stmts …)`-vs-bare and
  `(call … (stmts …))` postExprBlock orderings in the largest modules.

These are grammar-completion tasks, not defects in the spine: the range-splitter,
line-info model, and section/type machinery are all correct where they fire.

---

## Layout

```
src/
  tokens.nim      # Token contract
  lexer.nim       # full hand-written lexer
  parsecore.nim   # parser spine: cursor, line-info, op tables, range scan
  parse_expr.nim  # expressions / operators / constructors
  parse_type.nim  # type defs, routine defs, params, generics, pragmas
  parse_stmt.nim  # statements, control flow, var/let/const sections
  parser.nim      # include aggregator + module loop
  nifparser.nim   # CLI driver
tests/
  corpus/*.nim    # curated differential inputs
  canon.py        # NIF structural canonicaliser (strips line-info)
  diff.sh         # differential harness over the corpus
  stress.sh       # differential harness over arbitrary real .nim files
```
