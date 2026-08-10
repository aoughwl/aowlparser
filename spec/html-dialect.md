# The `html-parsed` AIF dialect

Header emitted by `aowlparser html`:

```
(.aif27)
(.vendor "aowlparser")
(.dialect "html-parsed")
```

Inherits both governing rules from `spec/css-dialect.md` — **leaves carry raw
lexemes** and **no punctuation is implied** — for the same reason: byte-exact
round-trip is the acceptance criterion, and there is no oracle.

## The byte-exactness checklist

| Fact a naive DOM loses | Representation |
|---|---|
| Tag and attribute name case: `<DIV ID=x>` | raw lexeme in `(name)` / `(aname)` |
| Attribute quoting: `id="x"` vs `id='x'` vs `id=x` | `(aval)` holds the raw span **including** whatever quotes were used |
| Valueless attributes: `<input disabled>` | `(attr)` with an `(aname)` and no `(eq)`/`(aval)` |
| Whitespace inside a tag, incl. before `>` | `(ws)` nodes among the attributes |
| `<br>` vs `<br/>` vs `<br />` | `(selfclose)` node present or absent, plus the `(ws)` before it |
| Omitted end tags (`<li>` closed implicitly) | the `(elem)` simply has no `(etag)` child |
| A stray `</div>` matching nothing | a top-level `(etag)` node, not dropped |
| An unclosed `<div` at EOF | `(stag)` with no `(gt)` child |
| Entity spelling: `&amp;` vs `&#38;` vs a bare `&` | raw, inside `(text)` — never decoded |
| `<script>`/`<style>` content that looks like markup | `(text)` raw, tokenized in raw-text mode |
| Comment/doctype internals and case | `(comment)` / `(doctype)` hold the raw span **including** delimiters |

## Tag vocabulary

```
(doc <node>*)

<node> = (text "…") | (comment "…") | (doctype "…") | (cdata "…") | (pi "…")
       | (elem …) | (etag …)          ; a bare (etag) is a stray close tag

(elem
  (stag
    (lt)                              ; the '<'
    (name "…")                        ; raw tag name
    <ws-or-attr>*
    (selfclose)?                      ; the '/' of '/>' , if written
    (gt)?)                            ; absent iff the tag is unclosed at EOF
  <node>*                             ; children (absent for void elements)
  (etag                               ; absent when the end tag was omitted
    (ltslash) (name "…") (ws …)* (gt)?))

(attr (aname "…") (eq)? (aval "…")?)  ; aval raw, INCLUDING quotes if quoted
```

Rendering is a pure in-order walk, exactly as for CSS: `(lt)`→`<`, `(gt)`→`>`,
`(ltslash)`→`</`, `(eq)`→`=`, `(selfclose)`→`/`, and every other emitted byte is the
stored text of a leaf.

## Tree shape is best-effort; bytes are not

HTML's implicit end tags are a deep well (`<p>` closed by a following `<div>`, tables
that relocate their own content). This dialect does **not** implement the full WHATWG
insertion-mode algorithm. It maintains an open-element stack, knows the void and
raw-text elements, closes to a match on an end tag, and emits an unmatched end tag as
a stray `(etag)`.

So the **nesting** is a good-faith approximation and may differ from a browser's DOM
on pathological input. The **bytes** are not an approximation: every token is
recorded, so round-trip is exact regardless of how the tree came out. A consumer that
needs browser-identical nesting should build it from this dialect rather than expect
it here — and that is a deliberate line, stated rather than discovered later.
