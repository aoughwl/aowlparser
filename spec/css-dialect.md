# The `css-parsed` AIF dialect

Header emitted by `aowlparser css`:

```
(.aif27)
(.vendor "aowlparser")
(.dialect "css-parsed")
```

## The governing rule: leaves carry RAW lexemes

Every leaf node stores the **exact source text** of its lexeme, undecoded and
un-normalised. `COLOR` stays `COLOR`; `.5` does not become `0.5`; `\32 0` keeps its
escape; a string keeps the quote character it was written with.

This is the opposite of the `nim-parsed` dialect, which decodes string literals and
normalises identifiers. The reason is the acceptance gate: with no oracle to diff
against, byte-exact round-trip *is* the correctness criterion, and any normalisation
at parse time makes it unreachable. Decoding is a consumer's job — a lens or the
validator — not the parser's.

## The byte-exactness checklist

A naive CSS tree silently loses the following. Each one has an explicit
representation here, and each one has a corpus case in `tests/css/corpus/`:

| Fact a naive tree loses | Representation |
|---|---|
| Whitespace runs, and where they fall | `(ws "…")` sibling nodes, in document order |
| Comments, and their exact text | `(comment "…")` — raw **including** the `/*` `*/` delimiters. Inner-text-only was the first design and it was wrong: an unterminated comment has no closing delimiter, so a renderer that re-adds one cannot round-trip. The `unterminated comment` corpus case pins this. |
| Trailing `;` on the final declaration in a block (optional in CSS) | `(semi)` child, present iff written |
| Identifier / property / at-keyword case | raw lexeme in the leaf |
| Number spelling: `.5`, `0.50`, `+1`, `1e3` | raw lexeme in `(num)` |
| String quote character: `'a'` vs `"a"` | raw lexeme *including* quotes in `(str)` |
| `!important` internal spacing and case: `! IMPORTANT` | `(important "…")` holds the raw span |
| At-rule terminated by `;` vs by a block | `(atrule)` has either a `(semi)` or a `(block)` child |
| Unicode escapes in identifiers: `\32` | raw lexeme |
| A final newline, or its absence, at EOF | trailing `(ws)` present or absent |

### No punctuation is implied

Braces, the `:` in a declaration, and `;` are **explicit nodes** — `(lbrace)`,
`(rbrace)`, `(colon)`, `(semi)` — never inferred from structure.

Implying them was the first design and it was wrong. Punctuation that is mandatory in
*valid* CSS is exactly what goes missing in *invalid* CSS: a rule with no `{` would
render braces that were never written, and a declaration with a missing colon would
gain one. Every such case would need its own "was it actually there" flag, and they
land precisely on the error-recovery paths `tests/robust.sh` exercises.

With punctuation explicit, **rendering is a pure in-order walk that emits no byte not
present in the source**, and byte-exactness on malformed input falls out for free
instead of being a per-case fix.

## Tag vocabulary

```
(stylesheet <child>*)

<child> = (ws "…") | (comment "…") | (rule …) | (atrule …) | (err …)

(rule
  (sel <sel-child>*)          ; raw selector run, trivia preserved inside
  (block <decl-or-trivia>*))

(atrule
  (name "media")              ; raw, WITHOUT the leading '@'
  (prelude <child>*)          ; raw token run, may be empty
  (semi) | (block …))         ; exactly one

(decl
  (prop "…")                  ; raw property name
  (val <val-child>*)          ; FLAT typed token run — see below
  (semi)?)                    ; present iff a ';' was written

<val-child> = (ws …) | (comment …) | (ident "…") | (num "…") | (dim "…")
            | (pct "…") | (str "…") | (hash "…") | (fn "…") | (op "…")
```

### Why values are a flat token run, not a nested tree

`(fn …)` carries the raw `calc(` lexeme and does **not** open a subtree; the matching
`)` is a sibling `(op ")")`. Function nesting is deliberately deferred to a consumer.

Two reasons. An unclosed `calc(` at EOF has no closing paren, so a nesting parser
needs an extra "was it closed" flag purely to stay byte-exact — structure bought at
the cost of the property the gate rests on. And the consumer that matters,
`aoughwl-css/css/validator.nim`, has a **value-level** API (`validateValue(prop, val)`
takes the value as text), so nesting would be built here only to be flattened again
there. Structure lives where consumers need it — stylesheet, rule, decl — and stops
where it would cost more than it returns.

## Errors are nodes, never exceptions

CSS is defined by its error-recovery behaviour, so a parse must always produce a
tree. Unrecoverable spans become `(err (code "…") (raw "…"))`, where `raw` holds the
skipped source verbatim — so **even a malformed stylesheet round-trips byte-exactly**.
That property is what makes `tests/robust.sh` a real gate rather than a crash check.

Diagnostics are additionally recorded on `ps.diags` using the existing `Diagnostic`
shape from `src/tokens.nim`, so `--diagnostics:json` works for CSS unchanged.
