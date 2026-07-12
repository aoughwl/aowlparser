import std/syncio

proc steps(n0: int): int =
  var n = n0
  result = 0
  while n != 1:
    if n mod 2 == 0: n = n div 2
    else: n = 3*n + 1
    inc result

for n in 1..12:
  echo n, ": ", steps(n), " steps"
