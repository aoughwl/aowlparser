# A statement-keyword StmtListExpr as the last thing before the block `:` of an
# if/while head: `discard`/`return`-like statements inside the parens were bounded by
# the whole logical line, so the head's own `:` was mistaken for a postExprBlock
# colon and the parser re-entered itself forever (exit 127, no message).
proc f(x: int): bool = x > 0
if f((block:
  discard 1
  discard 2)):
  discard 1
if f((discard 1)):
  discard 1
while f((block: discard 1)):
  discard 1
if f(f((block: discard 1))):
  discard 1
if f(1, (block: discard 1)): discard 1
