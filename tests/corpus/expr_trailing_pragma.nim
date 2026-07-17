proc h() =
  let f = x {.noSideEffect.} => x + 1
  let g = (name: string) {.noSideEffect.} => name
  type T = (string {.noSideEffect.} -> string)
