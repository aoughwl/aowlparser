## js_spec.nim — the `js-parsed` dialect declaration.
##
## INCLUDE file, spliced into `jsparser.nim` first.

proc jsDialect*(): Dialect =
  Dialect(name: "js-parsed", nodes: @[
    struct "program",
    struct "group",     ## a (…), […] or {…} run, INCLUDING its delimiters
    struct "err",
    text "ws",
    text "nl",
    text "comment",
    text "name",
    text "kw",
    text "num",
    text "str",
    text "template",    ## `…${…}…` kept whole; see jsparser.nim for why
    text "regex",
    text "op",
    text "raw",
    opaque "code",
  ])
