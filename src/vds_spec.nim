## vds_spec.nim — the `vds-parsed` dialect declaration.
##
## INCLUDE file, spliced into `vdsparser.nim` first.
##
## VDS (MDN value-definition syntax) is the grammar language CSS specs are
## written in — `<length-percentage>{1,4} [ / <length-percentage>{1,4} ]?`. It is
## a real language with its own precedence, and it gets the same treatment as
## every other dialect here: raw lexemes, explicit punctuation, byte-exact.

proc vdsDialect*(): Dialect =
  Dialect(name: "vds-parsed", nodes: @[
    struct "vds",
    # combinators, loosest to tightest
    struct "alt",       ## `|`   exactly one
    struct "any",       ## `||`  one or more, any order
    struct "all",       ## `&&`  all, any order
    struct "juxta",     ## juxtaposition: all, in order
    struct "comp",      ## an atom plus its postfix multipliers
    struct "group",     ## `[ … ]`
    struct "fn",        ## `abs( … )`
    struct "paren",     ## `( … )`
    struct "block",     ## `{ … }` (at-rule bodies)
    struct "err",
    # punctuation
    punct("lbracket", "["),
    punct("rbracket", "]"),
    punct("lparen", "("),
    punct("rparen", ")"),
    punct("lbrace", "{"),
    punct("rbrace", "}"),
    # text leaves — raw lexemes
    text "ws",
    text "type",        ## `<length>`, `<length [0,∞]>`
    text "propref",     ## `<'margin-top'>`
    text "kw",          ## a bare keyword: auto, none, element
    text "str",         ## `"<charset>"` and `'+'`
    text "num",
    text "lit",         ## `,` `/` `;` `:` and other literal delimiters
    text "op",          ## a combinator token: `|` `||` `&&`
    text "mult",        ## `?` `*` `+` `#` `!`
    text "range",       ## `{1,4}` `{1,}`
    text "fname",       ## the `abs(` of a function
    text "raw",
    opaque "code",
  ])
