## bench_aowljson.nim — the same measurement for aowljson's reference reader.
##
## aowljson builds a `ref` value tree, which is the ergonomic shape and the
## expensive one: an allocation per value and a pointer chase per access. This
## exists so the jsonfast number has an in-house contender and the cost of the
## tree is a measured figure rather than an assertion.

import aowljson
import std/[syncio, os, monotimes]

let args = commandLineParams()
if args.len < 1:
  echo "usage: bench_aowljson <file.json> [iterations]"
  quit 2

var iterations = 20
if args.len >= 2:
  var n = 0
  for c in args[1].items:
    if c >= '0' and c <= '9': n = n * 10 + (int(c) - int('0'))
  if n > 0: iterations = n

var src = ""
try:
  src = readFile(args[0])
except:
  echo "cannot read ", args[0]
  quit 1

var err = ""
let warm = parseJson(src, err)
if err.len > 0:
  echo "REJECTED: ", err
  quit 1

var best = 0.0
var it = 0
while it < iterations:
  let t0 = ticks(getMonoTime())
  var e2 = ""
  let v = parseJson(src, e2)
  let dt = float64(ticks(getMonoTime()) - t0) / 1_000_000_000.0
  if e2.len > 0:
    echo "REJECTED mid-benchmark: ", e2
    quit 1
  if best == 0.0 or dt < best: best = dt
  it = it + 1

let mb = float64(src.len) / 1_048_576.0
echo "aowljson  ", args[0]
echo "  best       ", best * 1000.0, " ms"
echo "  throughput ", mb / best, " MB/s"
