## py_spec.nim — the `py-parsed` dialect declaration.
##
## INCLUDE file, spliced into `pyparser.nim` first.

proc pyDialect*(): Dialect =
  Dialect(name: "py-parsed", nodes: @[
    struct "module",
    struct "stmt",
    struct "block",
    struct "err",
    # text leaves — raw lexemes. Note there is NO punctuation node here: unlike
    # CSS braces or HTML angle brackets, every byte of Python's structure is
    # already a token (the ':' is an op, the indentation is ws, the newline is
    # nl), so nothing is implied and nothing needs a marker.
    text "ws",
    text "nl",
    text "comment",
    text "name",
    text "kw",
    text "num",
    text "str",
    text "op",
    text "cont",
    text "raw",
    opaque "code",
  ])
