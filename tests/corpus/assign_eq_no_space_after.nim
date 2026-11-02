# `=` is a reserved token for nifler: it never starts a command-call argument,
# so `a.b =c` (space before, none after) is an ASSIGNMENT, not the command
# call `b(=c)`. Real source: result.play =mrect(float(left), y, ...).
type R = object
  play: int
var a, c, x, y, i, h: int
var result: R
proc f(p: int; q =y; r = 3; s=4): int = p
proc g(p: int, q: int =y): int = p
let la =c
let lb= c
let lc=c
var va: int =c
var vb: int= c
var vc: int=c
const k =1
const k2: int =2
a ==c
a =>c
a !=c
a <=c
a >=c
x = f(1, q =y)
x = f(1, q=y)
x = f(q =y, p = 2)
a =c
result.play =c
result.play =f(1)
a =-c
a =~c
a =c.len
a =not c
a =[c]
a =(c)
a ={c}
a =""
a ='c'
a =1
a =@[c]
a =cast[int](c)
a =if c > 0: 1 else: 2
a =proc (): int = 1
a =func1 c
if a == 1: a =c
while a < 1: a =c
for i in 0 ..< 3: a =c
x +=c
x -=c
x[0] =c
x.y.z =c
x.y[0] =c
(a, c) =(c, a)
a =
  c
