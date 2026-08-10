## tgate.nim — the `json-parsed` acceptance gate.
##
## Shape assertions target what a parse-to-a-value-tree round trip destroys and
## a byte comparison cannot see on its own: key ORDER, duplicate keys, and the
## object/array nesting.

import "../../src/jsonparser.nim"
import "../../src/aowlparse/gate.nim"
import "../../src/aowlparse/nodespec.nim"
import std/[syncio, os]

proc parse(src: string): string = jsonToAif(src)

var g = initGate("json", jsonDialect(), parse)
checkSpec(g)

roundTrip(g, "empty", "")
roundTrip(g, "empty object", "{}")
roundTrip(g, "empty array", "[]")
roundTrip(g, "simple", "{\"a\": 1}")
roundTrip(g, "pretty printed", "{\n  \"a\": 1,\n  \"b\": [2, 3]\n}\n")
roundTrip(g, "nested", "{\"a\":{\"b\":{\"c\":[1,{\"d\":null}]}}}")
roundTrip(g, "escapes", "{\"a\": \"x\\\"y\\\\z\\u00e9\"}")
roundTrip(g, "number spellings", "[1, 1.0, -0, 1e2, 1E+2, -1.5e-3, 0.10]")
roundTrip(g, "literals", "[true, false, null]")
roundTrip(g, "unicode content", "{\"k\": \"caf\xc3\xa9 \xe2\x9c\x93\"}")
roundTrip(g, "no trailing newline", "{\"a\":1}")
roundTrip(g, "crlf", "{\r\n  \"a\": 1\r\n}\r\n")
roundTrip(g, "tabs", "{\n\t\"a\": 1\n}")
roundTrip(g, "duplicate keys", "{\"a\": 1, \"a\": 2}")
roundTrip(g, "deep array", "[[[[[1]]]]]")

# malformed
roundTrip(g, "unclosed object", "{\"a\": 1")
roundTrip(g, "unclosed array", "[1, 2")
roundTrip(g, "missing colon", "{\"a\" 1}")
roundTrip(g, "trailing comma", "[1, 2, ]")
roundTrip(g, "bare word", "{a: 1}")
roundTrip(g, "unterminated string", "{\"a\": \"oops")
roundTrip(g, "garbage", "@#$")
roundTrip(g, "only whitespace", "  \n\t")

# --- shape ------------------------------------------------------------------
# Key ORDER and duplicates are exactly what a value-tree round trip loses. A
# byte-exact gate alone cannot tell you the parser kept them as distinct members.
expectCount(g, "duplicate keys are two members", "{\"a\":1,\"a\":2}", "member", 2)
expectCount(g, "three members", "{\"a\":1,\"b\":2,\"c\":3}", "member", 3)
expectCount(g, "empty object has no members", "{}", "member", 0)
expectCount(g, "one object", "{\"a\":1}", "object", 1)
expectCount(g, "nested objects", "{\"a\":{\"b\":1}}", "object", 2)
expectNesting(g, "object nesting depth", "{\"a\":{\"b\":{\"c\":1}}}", "object", 3)
expectNesting(g, "array nesting depth", "[[[1]]]", "array", 3)
expectNesting(g, "siblings do not nest", "[[1],[2]]", "array", 2)
expectCount(g, "brace inside a string is not an object",
  "{\"a\": \"{not an object}\"}", "object", 1)
expectCount(g, "escaped quote does not end the string",
  "{\"a\": \"x\\\"y\"}", "member", 1)

let cli = commandLineParams()
for ci in 0 ..< cli.len:
  let path = cli[ci]
  var src = ""
  var ok = true
  try:
    src = readFile(path)
  except:
    ok = false
  if ok:
    roundTrip(g, path, src)
  else:
    echo "FAIL could not read ", path

var fuzzBudget = 3
if cli.len > fuzzBudget:
  echo "note: truncation fuzz limited to the first ", fuzzBudget, " of ",
       cli.len, " files"
for ci in 0 ..< cli.len:
  if ci >= fuzzBudget: break
  let path = cli[ci]
  var src = ""
  var ok = true
  try:
    src = readFile(path)
  except:
    ok = false
  if ok:
    fuzzTruncations(g, "truncations of " & path, src)

quit report(g)
