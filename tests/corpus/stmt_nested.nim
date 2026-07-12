proc f(n: int): int =
  var
    a = 1
    b = 2
  while a < n:
    if a mod 2 == 0:
      a = a + b
    else:
      a = a + 1
  return a
