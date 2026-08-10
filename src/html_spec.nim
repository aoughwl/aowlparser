## html_spec.nim — the `html-parsed` dialect declaration.
##
## INCLUDE file, spliced into `htmlparser.nim` first. Drives both the emitter
## and the generic renderer. See spec/html-dialect.md.

proc htmlDialect*(): Dialect =
  Dialect(name: "html-parsed", nodes: @[
    # structure
    struct "doc",
    struct "elem",
    struct "stag",
    struct "etag",
    struct "attr",
    struct "err",
    # punctuation — explicit, so an unclosed tag renders without a '>' it
    # never had
    punct("lt", "<"),
    punct("ltslash", "</"),
    punct("gt", ">"),
    punct("eq", "="),
    punct("selfclose", "/"),
    # text leaves — raw lexemes, entities never decoded
    text "text",
    text "comment",
    text "doctype",
    text "cdata",
    text "pi",
    text "name",
    text "ws",
    text "aname",
    text "aval",
    text "op",
    text "raw",
    # metadata
    opaque "code",
  ])
