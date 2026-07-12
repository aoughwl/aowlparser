proc f(a, b: int; c: string): seq[int] =
  discard
proc apply(cb: proc(a: int): int, x: int): int =
  return x
proc h(a: int = 5, b: var string) =
  discard
proc mk(): ref int =
  discard
