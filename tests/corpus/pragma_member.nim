proc f() =
  var buf {.noinit.}: array[12, char]
  let tag {.cursor.} = compute()
