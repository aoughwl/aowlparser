import std/syncio

proc fib(n: int): int =
  if n < 2: return n
  return fib(n-1) + fib(n-2)

for i in 0..10:
  echo i, " -> ", fib(i)
