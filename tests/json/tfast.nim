## tfast.nim — the `jsonfast` reader against CPython's `json` module.
##
## The reader has no round-trip to hide behind: it throws whitespace away by
## design, so byte-exactness cannot check it at all. What can is an outside
## implementation, on three axes:
##
##   1. ACCEPT/REJECT, on whole files and on thousands of PREFIXES of them.
##      A corpus of valid documents only proves a reader is permissive enough;
##      prefixes are malformed in every direction and catch the dangerous
##      failure — accepting what is not JSON.
##   2. VALUE COUNTS per kind, so a reader that loses a pair or invents one is
##      named rather than merely disagreeing somewhere.
##   3. A DIGEST of every decoded string (FNV-1a over the UTF-8 bytes) and the
##      exact sum of every integer. Escapes, surrogate pairs and duplicate keys
##      all land here — the parts a count alone cannot see.
##
## Floats are compared by count only: `1e2` and `100.0` are the same number,
## and holding the reader to CPython's repr would be testing the wrong thing.
##
## Usage: tfast [<manifest>]   — without a manifest, only the built-in cases run.

import "../../src/jsonfast.nim"
import std/[syncio, os]

var checked = 0
var failures = 0

proc fail(what, detail: string) =
  failures = failures + 1
  echo "FAIL ", what
  if detail.len > 0: echo "     ", detail

proc accepts(label, src: string; want: bool) =
  checked = checked + 1
  let doc = parse(src)
  if ok(doc) != want:
    if want: fail(label & ": rejected", doc.err & " at " & $doc.errPos)
    else: fail(label & ": accepted", "should have been rejected")

# --- valid ------------------------------------------------------------------
accepts("empty object", "{}", true)
accepts("empty array", "[]", true)
accepts("bare int", "0", true)
accepts("negative", "-1", true)
accepts("float", "1.5e-3", true)
accepts("bare string", "\"x\"", true)
accepts("true/false/null", "[true,false,null]", true)
accepts("nested", "{\"a\":[1,{\"b\":2}]}", true)
accepts("whitespace everywhere", " { \"a\" : [ 1 , 2 ] } ", true)
accepts("escapes", "\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\te\"", true)
accepts("unicode escape", "\"\\u00e9\\ud83d\\ude00\"", true)
accepts("duplicate keys", "{\"a\":1,\"a\":2}", true)
accepts("deep but legal", "[[[[[[[[1]]]]]]]]", true)
accepts("big exponent", "1e308", true)
accepts("zero variants", "[0,-0,0.0,0e0]", true)

# --- invalid ----------------------------------------------------------------
accepts("empty input", "", false)
accepts("whitespace only", "   ", false)
accepts("trailing comma in array", "[1,]", false)
accepts("trailing comma in object", "{\"a\":1,}", false)
accepts("leading comma", "[,1]", false)
accepts("single quotes", "'x'", false)
accepts("unquoted key", "{a:1}", false)
accepts("NaN", "NaN", false)
accepts("Infinity", "Infinity", false)
accepts("leading plus", "+1", false)
accepts("leading dot", ".5", false)
accepts("trailing dot", "1.", false)
accepts("leading zero", "01", false)
accepts("hex", "0x1", false)
accepts("bare word", "tru", false)
accepts("unterminated string", "\"abc", false)
accepts("unterminated array", "[1,2", false)
accepts("unterminated object", "{\"a\":1", false)
accepts("mismatched close", "[1}", false)
accepts("two documents", "{} {}", false)
accepts("trailing junk", "1 x", false)
accepts("bad escape", "\"a\\qb\"", false)
accepts("short unicode escape", "\"\\u12\"", false)
accepts("raw control character", "\"a\x01b\"", false)
accepts("colon missing", "{\"a\" 1}", false)
accepts("comment", "{} // hi", false)

# --- accessors --------------------------------------------------------------
proc check(label: string; got, want: string) =
  checked = checked + 1
  if got != want:
    fail(label, "want '" & want & "', got '" & got & "'")

proc checkInt(label: string; got, want: int64) =
  checked = checked + 1
  if got != want:
    fail(label, "want " & $want & ", got " & $got)

block:
  let doc = parse("{\"name\":\"ada\",\"n\":42,\"xs\":[1,2,3],\"deep\":{\"k\":\"v\"}}")
  if not ok(doc):
    fail("accessor fixture", doc.err)
  else:
    check("find string", getStr(doc, find(doc, root(doc), "name")), "ada")
    checkInt("find int", getInt(doc, find(doc, root(doc), "n")), 42)
    checkInt("array length", int64(len(doc, find(doc, root(doc), "xs"))), 3)
    check("nested lookup",
          getStr(doc, find(doc, find(doc, root(doc), "deep"), "k")), "v")
    checkInt("missing key is -1", int64(find(doc, root(doc), "nope")), -1)
    var sum: int64 = 0
    for e in elems(doc, find(doc, root(doc), "xs")):
      sum = sum + getInt(doc, e)
    checkInt("elems iterates every element", sum, 6)
    var keys = ""
    for k, v in fields(doc, root(doc)):
      keys.add getStr(doc, k)
      keys.add " "
    check("fields walks pairs in order", keys, "name n xs deep ")

block:
  let doc = parse("\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\te\\u00e9\\ud83d\\ude00\"")
  if not ok(doc):
    fail("escape fixture", doc.err)
  else:
    check("escapes decode",
          getStr(doc, root(doc)),
          "a\"b\\c/d\b\f\n\r\te\xc3\xa9\xf0\x9f\x98\x80")

block:
  # Duplicate keys are KEPT: dropping one silently changes the document, and a
  # dict-shaped reader cannot even represent the difference.
  let doc = parse("{\"a\":1,\"a\":2}")
  checkInt("duplicates are two pairs", int64(len(doc, root(doc))), 2)
  checkInt("find returns the first", getInt(doc, find(doc, root(doc), "a")), 1)

block:
  # Depth is bounded rather than fatal: a recursive reader dies here.
  var deep = ""
  var i = 0
  while i < 4000:
    deep.add '['
    i = i + 1
  let doc = parse(deep)
  checked = checked + 1
  if ok(doc):
    fail("deep nesting", "should have been refused, not accepted")
  elif doc.err.len == 0:
    fail("deep nesting", "no error message")

# --- views: chained access with nothing materialized ------------------------
block:
  let d = parse("{\"user\":{\"name\":\"ada\",\"age\":36},\"tags\":[\"x\",\"y\"]," &
                     "\"ok\":true,\"nil\":null}")
  let v = view(d)
  check("view chain", v{"user"}{"name"}.str(""), "ada")
  checkInt("view int", v{"user"}{"age"}.num(0), 36)
  check("view array element", v{"tags"}.at(1).str(""), "y")
  checkInt("view array length", int64(v{"tags"}.len), 2)
  check("missing key chains to the default", v{"nope"}{"deep"}.str("fb"), "fb")
  check("wrong-kind access chains too", v{"user"}.at(3).str("fb"), "fb")
  checked = checked + 1
  if not v{"ok"}.boolean(false): fail("view bool", "expected true")
  checked = checked + 1
  if not v{"nil"}.isNull: fail("view null", "expected null")
  checked = checked + 1
  if v{"nope"}.valid: fail("view validity", "a missing key must be invalid")
  var joined = ""
  for e in v{"tags"}.items:
    joined.add e.str("")
  check("view items", joined, "xy")
  var keys = ""
  for k, val in v.pairs:
    keys.add k.str("")
    keys.add " "
  check("view pairs", keys, "user tags ok nil ")

block:
  # A rejected document yields an invalid root, so every chain off it is safe.
  let d = parse("{oops")
  let v = view(d)
  checked = checked + 1
  if v.valid: fail("invalid document view", "root should be invalid")
  check("chain off a failed parse", v{"a"}{"b"}.str("fb"), "fb")

# --- the CPython manifest ---------------------------------------------------
proc splitOn(s: string; sep: char): seq[string] =
  result = @[]
  var cur = ""
  for c in s.items:
    if c == sep:
      result.add cur
      cur = ""
    elif c != '\r':
      cur.add c
  result.add cur

proc parseIntField(field: string; name: var string; value: var int64): bool =
  ## `k=v`, where the hash-valued fields are hex and the counts are decimal.
  ## The base is chosen by NAME, not by guessing from the digits: a hash that
  ## happens to be all decimal digits would otherwise be read in the wrong base
  ## and silently compare unequal.
  name = ""
  value = 0
  var i = 0
  while i < field.len and field[i] != '=':
    name.add field[i]
    i = i + 1
  if i >= field.len or name.len == 0: return false
  let hex = name == "shash" or name == "isum" or name == "fhash"
  i = i + 1
  var any = false
  var acc: uint64 = 0
  while i < field.len:
    let c = field[i]
    var d = -1
    if c >= '0' and c <= '9': d = int(c) - int('0')
    elif hex and c >= 'a' and c <= 'f': d = int(c) - int('a') + 10
    elif hex and c >= 'A' and c <= 'F': d = int(c) - int('A') + 10
    if d < 0: return false
    acc = acc * (if hex: 16'u64 else: 10'u64) + uint64(d)
    any = true
    i = i + 1
  value = cast[int64](acc)
  return any

const
  FnvOffset = 0xCBF29CE484222325'u64
  FnvPrime = 0x100000001B3'u64

type Tally = object
  obj, arr, str, num, flt, tru, fls, nul: int
  shash: uint64
  isum: uint64

proc walk(doc: JsonDoc; i: int32; t: var Tally) =
  case kindOf(doc, i)
  of jfObject:
    t.obj = t.obj + 1
    for k, v in fields(doc, i):
      t.str = t.str + 1
      let s = getStr(doc, k)
      for c in s.items:
        t.shash = (t.shash xor uint64(int(c) and 0xFF)) * FnvPrime
      t.shash = (t.shash xor 0'u64) * FnvPrime
      walk(doc, v, t)
  of jfArray:
    t.arr = t.arr + 1
    for e in elems(doc, i):
      walk(doc, e, t)
  of jfString:
    t.str = t.str + 1
    let s = getStr(doc, i)
    for c in s.items:
      t.shash = (t.shash xor uint64(int(c) and 0xFF)) * FnvPrime
    t.shash = (t.shash xor 0'u64) * FnvPrime
  of jfInt:
    t.num = t.num + 1
    t.isum = t.isum + cast[uint64](getInt(doc, i))
  of jfFloat: t.flt = t.flt + 1
  of jfTrue: t.tru = t.tru + 1
  of jfFalse: t.fls = t.fls + 1
  of jfNull: t.nul = t.nul + 1

proc prefixOf(s: string; n: int): string =
  result = ""
  var i = 0
  while i < n and i < s.len:
    result.add s[i]
    i = i + 1

let args = commandLineParams()
var files = 0
var prefixChecks = 0
var skipped = 0

if args.len >= 1:
  var manifest = ""
  var mok = true
  try:
    manifest = readFile(args[0])
  except:
    mok = false
  if not mok:
    echo "FAIL cannot read manifest: ", args[0]
    quit 1

  var lastPath = ""
  var lastSrc = ""
  var lastHash: uint64 = 0
  var moved = false
  var movedFiles = 0
  let lines = splitOn(manifest, '\n')
  for line in lines.items:
    if line.len == 0: continue
    let f = splitOn(line, '\t')
    if f.len < 2: continue
    let verb = f[0]
    let path = f[1]
    if path != lastPath:
      lastPath = path
      lastSrc = ""
      moved = false
      try:
        lastSrc = readFile(path)
      except:
        lastSrc = ""
      lastHash = FnvOffset
      for c in lastSrc.items:
        lastHash = (lastHash xor uint64(int(c) and 0xFF)) * FnvPrime
    if verb == "SKIP":
      skipped = skipped + 1
      continue
    if verb == "OK" or verb == "ERR":
      # Did the file MOVE since the oracle read it? Much of a real machine's
      # `.json` is live state, and a corpus that changes under the test looks
      # exactly like a parser defect — this one cost two integers' worth of
      # chasing before the mtime gave it away.
      var fh: int64 = 0
      var fname = ""
      if f.len > 2 and parseIntField(f[2], fname, fh) and fname == "fhash":
        if cast[uint64](fh) != lastHash:
          moved = true
          movedFiles = movedFiles + 1
          echo "  skip: ", path, " (changed on disk since the oracle read it)"
          continue
    if verb == "ERR":
      files = files + 1
      checked = checked + 1
      let doc = parse(lastSrc)
      if ok(doc):
        fail("[json-oracle] " & path, "accepted; CPython rejects it")
      continue
    if verb == "PFX":
      if moved: continue
      var n = 0
      var i = 0
      while i < f[2].len:
        n = n * 10 + (int(f[2][i]) - int('0'))
        i = i + 1
      let want = f[3] == "OK"
      let doc = parse(prefixOf(lastSrc, n))
      checked = checked + 1
      prefixChecks = prefixChecks + 1
      if ok(doc) != want:
        if want:
          fail("[json-oracle] " & path & " prefix " & $n & ": rejected",
               doc.err & " — CPython accepts this prefix")
        else:
          fail("[json-oracle] " & path & " prefix " & $n & ": accepted",
               "CPython rejects this prefix")
      continue
    if verb != "OK" or moved: continue
    files = files + 1
    let doc = parse(lastSrc)
    checked = checked + 1
    if not ok(doc):
      fail("[json-oracle] " & path, "rejected: " & doc.err & " at " & $doc.errPos)
      continue
    var t = Tally(obj: 0, arr: 0, str: 0, num: 0, flt: 0, tru: 0, fls: 0,
                  nul: 0, shash: FnvOffset, isum: 0'u64)
    walk(doc, root(doc), t)
    for fi in 2 ..< f.len:
      var name = ""
      var want: int64 = 0
      if not parseIntField(f[fi], name, want): continue
      var got: int64 = 0
      case name
      of "obj": got = int64(t.obj)
      of "arr": got = int64(t.arr)
      of "str": got = int64(t.str)
      of "int": got = int64(t.num)
      of "flt": got = int64(t.flt)
      of "true": got = int64(t.tru)
      of "false": got = int64(t.fls)
      of "null": got = int64(t.nul)
      of "shash": got = cast[int64](t.shash)
      of "isum": got = cast[int64](t.isum)
      else: continue
      checked = checked + 1
      if got != want:
        fail("[json-oracle] " & path & ": " & name,
             "ours " & $got & ", CPython " & $want)

  echo "oracle: ", files, " file(s) and ", prefixChecks,
       " prefix verdict(s) against CPython; ", skipped,
       " skipped (not UTF-8), ", movedFiles, " skipped (changed on disk)"

echo "jsonfast: ", checked - failures, "/", checked, " ok"
quit (if failures > 0: 1 else: 0)
