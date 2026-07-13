# nifparser — nimony-native Nim parser → NIF

A parser for Nim source that emits the **same NIF** as the classic
[`nifler`](../nimony/src/nifler) tool — but written in **nimony**, so it can be
compiled to JS (via `nim_js`) and run in the browser, where classic-Nim
`nifler` cannot.

`nifler` is a pure *syntactic* transducer: `Nim source → PNode (classic Nim
parser) → NIF`, with **no** semantic checking and no symbol resolution. Every
symbol comes out as a bare identifier. `nifparser` reproduces that output
without depending on the classic-Nim compiler.

> Status: **broad grammar coverage.** The curated corpus (47 files) matches
> native nifler **byte-for-byte** (46 exact / 1 structural), and **all 29**
> real `nimony/src/lib` modules now match **byte-structurally** end-to-end
> (line-info stripped) — the whole real standard library, zero mismatches. `tests/stress.sh` runs the
> differential harness over arbitrary real `.nim` files.
>
> Covered: full lexer (number bases, typed-literal `(suf …)`, raw/triple
> strings, backtick-quoted idents → `(quoted …)`, `##` doc comments →
> `(comment …)`), expressions & operators (Nim precedence incl. assignment
> ops, spacing-based prefix/infix disambiguation, `-N` literal folding,
> `ident"…"` call-string-literals, `cast`/`addr`, postfix chains), command
> syntax in statement/expression/type position (incl. prefix-op args and
> dotted callees), `if`/`elif`/`else`/`while`/`for`/`case`/`try`/`block`/
> `when`/`static`/`defer` (multi-line **and** one-liner forms), `;`-separated
> statements, StmtListExpr `( … ; … )`, var/let/const sections (pragmas,
> tuple-unpack), type/proc/enum/object defs, anonymous `proc` expressions,
> `from … import`, and statement/decl pragmas. Remaining gaps live in the
> largest modules (anonymous-proc edge cases, `concept` bodies, some deep
> postfix orderings) — see the checklist at the bottom.

### Experimental: curly-brace blocks (`--curly`)

Off by default (so output stays nifler-compatible). With `--curly`, a
`{ … }` block body is accepted **anywhere** a `:` body is, and the two may be
mixed freely:

```nim
if c { echo a } else: echo b      # brace + colon, mixed
while x { dec x; use x }           # `;`-separated statements inside braces
```

A block `{` is the first depth-0 `{` (not a `{.` pragma) that follows an
operand (`if c {`) or a bodiless-block keyword (`else {`, `try {`, `block {`,
`finally {`, `defer {`), so a set literal in the head (`if {1} == x { … }`) is
not mistaken for the body. This is a nifparser extension; native nifler has no
equivalent.

---

## Architecture

**Fused parse + emit.** `nifparser` does *not* build a Nim `PNode` AST. Instead
it is a recursive-descent parser that writes NIF **directly** through
`nifbuilder` as it recognises each construct, using nifler's `bridge.nim` as the
executable output spec. (Rebuilding an object-variant `ref` AST would crash
nimony's field magics — a known constraint — and is unnecessary: the emit is a
single left-to-right walk anyway.)

Layout (`src/`):

| module | role |
|---|---|
| `tokens.nim`   | **The Token contract.** Defines `TokKind` (extensible enum) and the `Token` object shared by the lexer and parser. You extend `TokKind` here; nothing else needs to change. |
| `lexer.nim`    | **STUB hand-lexer.** Tokenizes the bootstrap corpus (idents/keywords, decimal int & float, `"..."` strings, `'c'` chars, operators, punctuation, line comments) with source line/col + off-side `indent`. Meant to be **replaced** by a full lexer. |
| `parser.nim`   | **Recursive-descent + emit.** Statements dispatch by keyword; expressions use a token-range splitter (`parseExprRange`) that finds the lowest-precedence depth-0 operator and emits `(infix op L R)`, recursing on sub-ranges — reproducing nifler's operator nesting and pretty-print indentation. |
| `nifparser.nim`| **CLI driver.** `nifparser p in.nim out.p.nif`, mirroring nifler's CLI. Thin top-level-init entry with only file/stdout I/O (JS-build friendly: no mmap, no PNode). |

### The Token contract (`src/tokens.nim`)

```nim
type
  TokKind* = enum
    tkEof, tkIdent, tkKeyword,
    tkIntLit, tkFloatLit, tkStrLit, tkRStrLit, tkTripleStrLit, tkCharLit,
    tkOperator,
    tkParLe, tkParRi, tkBracketLe, tkBracketRi, tkCurlyLe, tkCurlyRi,
    tkComma, tkSemicolon, tkColon, tkDot,
    tkNewline

  Token* = object
    kind*: TokKind
    s*: string       # identifier / operator / decoded string-literal text
    iVal*: int64     # integer or char-literal value
    fVal*: float     # float-literal value
    base*: int32     # numeric base (reserved for the full lexer)
    suffix*: string  # numeric/string type suffix, e.g. "i8" (reserved)
    line*: int32     # 1-based source line
    col*: int32      # 0-based source column
    indent*: int32   # column if first token on its line, else -1
```

Significant indentation is carried, Nim-parser style, on `indent` (first-on-line
tokens record their column; everyone else is `-1`) rather than as explicit
Indent/Dedent tokens — though `tkNewline` is reserved for a lexer that prefers
layout tokens. `line`/`col` match nimony's `TLineInfo` bases so the NIF
line-info diffs line up with native nifler.

The lexer→parser boundary is *only* this contract, so a richer lexer is a
drop-in replacement.

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

Produces `bin/nifparser`. (The build lock serialises nimony compiles across
parallel agents — they share one static object file.)

Run it:

```bash
bin/nifparser p tests/corpus/proc_return.nim /tmp/out.p.nif
```

### JS build (not wired up yet)

The design keeps the JS path open (mirror `/home/savant/nifi/webtest/build.sh`):
top-level-init driver, `globalThis` I/O instead of file reads, no mmap of source
paths. Nothing here blocks it; the JS glue is future work.

---

## Differential harness (`tests/diff.sh`)

The most important deliverable: for every `tests/corpus/*.nim`, run the **native
nifler oracle** and **nifparser**, then compare their NIF.

```bash
bash tests/diff.sh              # PASS/FAIL per file
VERBOSE=1 bash tests/diff.sh    # + canonical diff for failures
```

Two comparisons per file:

* **STRUCTURAL** (the PASS criterion): `tests/canon.py` strips line-info
  (`@…`/`~…`) and comment (`#…#`) suffixes and normalises whitespace, then the
  two token trees must be identical. String-literal contents are preserved
  (NIF escapes all marker bytes inside strings, so they can't be confused with a
  suffix).
* **EXACT** (bonus): byte-identical `.p.nif`. nifparser aims for this and
  currently achieves it on every supported construct.

Exit status is non-zero iff any file fails the structural check.

### Current harness report

```
corpus: 12   PASS: 10   FAIL: 2   (exact byte-match: 10)
```

| corpus file | construct | result |
|---|---|---|
| `int_lit.nim`     | `42` | PASS (exact) |
| `str_lit.nim`     | `"hi"` | PASS (exact) |
| `float_lit.nim`   | `3.14` | PASS (exact) |
| `call.nim`        | `foo(1, 2)` (paren call) | PASS (exact) |
| `echo_cmd.nim`    | `echo "hi"` (command) | PASS (exact) |
| `import.nim`      | `import std/syncio` (import + `/` infix) | PASS (exact) |
| `proc_return.nim` | `proc add(a, b: int): int = return a + b` | PASS (exact) |
| `infix_nested.nim`| `discard 3*n + 1` (nested infix + precedence) | PASS (exact) |
| `assign.nim`      | `n = 3*n + 1` (assignment) | PASS (exact) |
| `cmd_multi.nim`   | `echo i, " -> ", fib(i)` (multi-arg cmd + call) | PASS (exact) |
| `fib.nim`         | full Fibonacci (if / for / return-in-branch) | **FAIL** — grammar not yet built |
| `collatz.nim`     | full Collatz (var / while / if-else / for) | **FAIL** — grammar not yet built |

The two failing files are the playground programs from
`/home/savant/nimony-playground/examples.js`, kept in the corpus deliberately:
they exercise control-flow / sections the skeleton does not implement yet, so
the harness **flags exactly the grammar the next wave of agents must add**.

Covered spine constructs (all byte-exact vs native nifler): integer / float /
string / char literals, identifiers, operators-as-idents with correct
precedence & left-associativity, paren calls `f(a,b)`, command calls `f a, b`,
`(infix …)` / `(prefix …)`, assignment `(asgn …)`, `import`/`include`/`export`,
`return`/`discard`/`raise`/`yield`, and `proc`/`func`/… routine defs with
`(params …)` (multi-name flatten, return-type-after-params) and an indented body
block — including the relative NIF line-info diffs.

---

## Remaining grammar checklist

Pick-up points for the next wave of agents. Each should add corpus files and get
them to PASS (ideally EXACT) against native nifler. The byte-level emit contract
for every construct is in
`/home/savant/.claude/jobs/8d47d301/tmp/nifler-nif-spec.md`.

- [ ] **Lexer (replace the stub)** — number bases (`0x`/`0o`/`0b`) & underscores
      (nifler emits **decimal** only), typed literal suffixes → `(suf …)`,
      `r"…"`/`"""…"""` strings, string & char escape sequences, unicode /
      multi-char operators, backtick-quoted identifiers, block comments, and
      proper significant-indentation (Indent/Dedent or robust `indent` use).
- [ ] **Expressions / operators** — prefix operators beyond the basic case,
      `a.b` dot, `a[b]` (`at`), `a{b}` (`curlyat`), `cast[T](x)`, `addr`,
      `typeof`, `..` ranges in expression position, `f"…"` call-string-lit,
      tuple `(a, b)` vs paren `(a)`, set/array/table constructors, `if`/`case`
      **expressions**, object constructors `T(f: v)`, named args `k = v` (`vv`),
      colon pairs `k: v` (`kv`).
- [ ] **Statements / control-flow** — `if`/`elif`/`else`, `case`/`of` with the
      `(ranges …)` wrapper + `handleCaseIdentDefs`, `while`, `for` with
      `unpackflat`/`unpacktup` normalisation, `block`, `break`/`continue`,
      `try`/`except`/`finally`, `defer`, `when`, `static`, `asm`, `using`,
      `bind`/`mixin`. *(These are what `fib.nim`/`collatz.nim` need.)*
- [ ] **var / let / const sections** — multi-name flatten (type & value
      duplicated into each def), visibility `*` → ` x`, pragma split, var-tuple
      unpacking `var (a, b) = x` → `(unpackdecl … (unpacktup …))`.
- [ ] **Type / proc defs** — `type` sections & `nkTypeDef` shape, `object`
      (inherit, fields, variant `case`), `enum` (`efld` shape), `tuple`,
      `ref`/`ptr`/`distinct`/`concept`, `proc`/`iterator` **types**
      (`proctype`/`itertype` 8-slot shape), aliases.
- [ ] **Pragmas / generics** — `{. … .}` pragmas on decls & as `pragmax`,
      generic params `[T]` → `(typevars …)`, term-rewriting patterns.
- [ ] **Literal edge cases** — `(suf …)` typed ints/uints/floats, untyped uint
      `123u`, `(inf)`/`(nan)`/`(neginf)`, `-0.0`, uppercase float exponent `E`,
      raw-hex string escaping (not Nim-style), `nil`.
- [ ] **Module / deps** — `--deps` producing the `.deps.nif` file (import graph
      with `(when …)` guards), `--docs` (`#…#` doc-comment suffixes), the
      `OnlyIfChanged` write mode, absolute vs relative line-info & `portablePaths`.

---

## Layout

```
src/
  tokens.nim      # Token contract (extend TokKind here)
  lexer.nim       # stub hand-lexer (replace)
  parser.nim      # recursive-descent + fused NIF emit
  nifparser.nim   # CLI driver
tests/
  corpus/*.nim    # differential test inputs
  canon.py        # NIF structural canonicaliser (strips line-info)
  diff.sh         # differential harness vs native nifler
```
