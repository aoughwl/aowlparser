## css_spec.nim — the `css-parsed` dialect declaration.
##
## INCLUDE file, spliced into `cssparser.nim` first.
##
## This single table drives BOTH the emitter (which validates against it) and
## the renderer (which is now the generic one in aowlparse/render.nim). See
## spec/css-dialect.md for the prose, and aowlparse/nodespec.nim for why there
## is only one table.

proc cssDialect*(): Dialect =
  Dialect(name: "css-parsed", nodes: @[
    # structure
    struct "stylesheet",
    struct "rule",
    struct "sel",
    struct "block",
    struct "decl",
    struct "val",
    struct "atrule",
    struct "prelude",
    struct "err",
    # punctuation — explicit, never implied, so malformed CSS round-trips
    punct("lbrace", "{"),
    punct("rbrace", "}"),
    punct("colon", ":"),
    punct("semi", ";"),
    # text leaves — raw lexemes, nothing decoded
    text "ws",
    text "comment",
    text "ident",
    text "num",
    text "dim",
    text "pct",
    text "str",
    text "hash",
    text "fn",
    text "url",
    text "op",
    text "prop",
    text "name",
    text "raw",
    # metadata: a diagnostic slug, NOT source text
    opaque "code",
  ])
