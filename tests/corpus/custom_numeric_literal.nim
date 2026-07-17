proc f() =
  doAssert -1'big == 1'big - 2'big
  doAssert 0xff'big == 255.big
  doAssert 0b101'big == 5.big
  doAssert -12'big == big"-12"
  doAssert 0xffffffffffffffff'big == (1'big shl 64'big) - 1'big
