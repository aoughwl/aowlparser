## bench.nim — how fast does `jsonfast` read a document?
##
## Parse-only, DOM-building, no serialization: the file is read once, then
## parsed `iterations` times, and the best wall time is reported. Best rather
## than mean on purpose — the mean measures the machine's noise, the minimum
## measures the parser.
##
## `tests/json/bench.sh` runs this against CPython's `json` (C-accelerated),
## V8's `JSON.parse`, `jq`, and aowljson's reference reader on the same file, so
## the number has something to be compared to. A MB/s figure with no contender
## beside it is marketing.
##
## Build with `-d:danger` for the real number; a bounds-checked debug build
## measures the checks.
##
## Usage: bench <file.json> [iterations]

import "../../src/jsonfast.nim"
import std/[syncio, os, monotimes]

let args = commandLineParams()
if args.len < 1:
  echo "usage: bench <file.json> [iterations]"
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

# Warm the allocator and the page cache before timing anything.
var warm = parse(src)
if not ok(warm):
  echo "REJECTED: ", warm.err, " at ", warm.errPos
  quit 1
let values = valueCount(warm)

# Two numbers, because they answer different questions. A ONE-OFF parse
# allocates and zeroes a fresh tape; a server parsing a stream of documents
# reuses one parser and pays that once. simdjson reports the reused number and
# so should we — alongside the cold one, so neither is hidden.
var best = 0.0
var it = 0
while it < iterations:
  # nimony's monotimes exposes `ticks` (nanoseconds) and no Duration type.
  let t0 = ticks(getMonoTime())
  let doc = parse(src)
  let dt = float64(ticks(getMonoTime()) - t0) / 1_000_000_000.0
  if not ok(doc):
    echo "REJECTED mid-benchmark: ", doc.err
    quit 1
  if best == 0.0 or dt < best: best = dt
  it = it + 1

let reused = newJsonDoc()
parseInto(reused, src)
var bestReuse = 0.0
it = 0
while it < iterations:
  let t0 = ticks(getMonoTime())
  parseInto(reused, src)
  let dt = float64(ticks(getMonoTime()) - t0) / 1_000_000_000.0
  if not ok(reused):
    echo "REJECTED mid-benchmark: ", reused.err
    quit 1
  if bestReuse == 0.0 or dt < bestReuse: bestReuse = dt
  it = it + 1

let mb = float64(src.len) / 1_048_576.0
echo "jsonfast  ", args[0]
echo "  bytes      ", src.len
echo "  values     ", values
echo "  best       ", best * 1000.0, " ms"
echo "  throughput ", mb / best, " MB/s"
echo "  reused     ", bestReuse * 1000.0, " ms"
echo "  throughput-reused ", mb / bestReuse, " MB/s"
