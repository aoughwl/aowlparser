## jsonfast_aowljson.nim — the bridge to `aowljson`'s value tree.
##
## `jsonfast` is fast because it does NOT build a node per value. Some callers
## want the node per value anyway: `aowljson.JsonValue` chains safely
## (`v{"a"}{"b"}.getStr("")`), builds by hand, and is what the rest of the
## aoughwl stack passes around. This module gives you both — read on the tape,
## hand over a tree — and a drop-in replacement for `aowljson.parseJson`:
##
##     import jsonfast_aowljson
##     var err = ""
##     let v = parseJsonFast(src, err)      # same signature, same value type
##
## Even paying for the whole tree it is measurably faster than the reference
## reader, because the scan itself is one pass with no per-value allocation and
## the tree is then built in document order without re-lexing. Where a caller
## does NOT need the tree — counting, extracting a few fields, streaming — stay
## on the tape and skip the materialization entirely; that is where the large
## win is.
##
## Errors stay values: `err` is empty, or it names the fault and its offset.
## Nothing raises.
##
## This module is SEPARATE from jsonfast.nim on purpose: `src/jsonfast.nim`
## depends on nothing, so a consumer that does not use aowljson never pays for
## it, and aowlparser's own build does not gain a dependency.

import jsonfast
import aowljson

proc toJsonValue*(doc: JsonDoc; i: int32): JsonValue =
  ## One tape node — and everything under it — as an `aowljson` value.
  ##
  ## Numbers keep their SPELLING: a float becomes `newJRawNumber` with the
  ## original lexeme rather than a re-formatted double, so `1e2` does not come
  ## back as `100.0` and a 20-digit integer is not silently rounded through a
  ## float.
  case kindOf(doc, i)
  of jfNull: newJNull()
  of jfTrue: newJBool(true)
  of jfFalse: newJBool(false)
  of jfString: newJString(getStr(doc, i))
  of jfInt, jfFloat:
    # The RAW lexeme for both, not `newJInt`: aowljson stores numbers as text,
    # so going through int64 would parse the digits and then print them back —
    # two conversions to arrive at the bytes already in hand.
    newJRawNumber(rawLexeme(doc, i))
  of jfArray:
    let arr = newJArray()
    for e in elems(doc, i):
      add(arr, toJsonValue(doc, e))
    arr
  of jfObject:
    let obj = newJObject()
    for k, v in fields(doc, i):
      # `addPair`, never `[]=`: the latter rescans every key already present,
      # making a wide object quadratic, and collapses duplicate keys the
      # document really does contain.
      addPair(obj, getStr(doc, k), toJsonValue(doc, v))
    obj

proc parseJsonFast*(src: string; err: var string): JsonValue =
  ## Drop-in for `aowljson.parseJson`: same signature, same value type, same
  ## error-as-value contract — a faster scanner underneath.
  let doc = parse(src)
  if not ok(doc):
    err = doc.err & " at offset " & $doc.errPos
    return newJNull()
  err = ""
  result = toJsonValue(doc, root(doc))
