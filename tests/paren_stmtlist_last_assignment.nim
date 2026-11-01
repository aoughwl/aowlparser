import std/syncio
type
  Ip = ref object
    h: int
proc f(ip: Ip): int =
  if ip.h >= 0: (ip.h = 1; ip.h = 0)
  result = ip.h
let ip = Ip(h: 3)
echo f(ip)
