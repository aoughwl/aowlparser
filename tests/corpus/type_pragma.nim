proc foo() {.inline.} =
  discard
proc bar(a: int): int {.inline, noSideEffect.} =
  return a
