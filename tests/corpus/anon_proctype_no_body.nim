proc f() =
  result.callbacks = initDeque[proc () {.closure, gcsafe.}](64)
  var d = newSeq[proc (x: int): bool]()
