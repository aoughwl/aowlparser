## jsonfast.nim — a fast, allocation-light JSON reader.
##
## `src/jsonparser.nim` is the AIF DIALECT: it keeps every byte, including
## whitespace, so a document round-trips exactly. That is the right shape for a
## rewriting front end and the wrong shape for reading a 200MB API response.
## This is the reader: same repo, opposite trade.
##
## THE DESIGN, and why each choice is here rather than the obvious one:
##
##  * **A flat tape, not a tree of refs.** Every value is one 16-byte entry in
##    one `seq`. A ref-per-node tree pays an allocation and a cache miss per
##    value; the tape pays neither, and a whole document is freed by dropping
##    one seq. Containers store the index ONE PAST their last descendant, so
##    skipping a 10MB sub-object is `i = node.next`, not a walk.
##
##  * **Zero-copy strings.** A string node records an offset and a length into
##    the source, plus whether it contains an escape. `\n` in the input costs
##    nothing until someone asks for the value, and the common case — no escapes
##    — never copies at all.
##
##  * **Lazy numbers.** Converting text to a float is expensive and most numbers
##    in a large document are never read. The node records the lexeme; `getInt`
##    / `getFloat` convert on demand.
##
##  * **No recursion.** Depth lives in an explicit stack, so a pathological
##    `[[[[…]]]]` is a bounded error rather than a stack overflow — the failure
##    mode a recursive-descent JSON parser is famous for, and one an attacker
##    picks on purpose.
##
##  * **Errors are values.** In keeping with the aoughwl stack: nothing raises;
##    `doc.err` is empty or it names the problem and `doc.errPos` locates it.
##
## Strictness is RFC 8259: no trailing commas, no comments, no `NaN`, no single
## quotes, no leading `+` or `.5`, no control characters inside strings. The
## gate holds it to CPython's `json` module on every `.json` file on this
## machine, accept-or-reject and value-for-value.

## SIMD scanning: `jsonfast_simd.c` finds the next interesting byte sixteen at a
## time for the two loops that consume nearly every byte of a document. It is
## pure scanning — every grammar decision stays here — and it exists because
## nimony cannot take the address of a string's bytes, so the vector tricks are
## not expressible in the language today (filed as an aowlsem requirement).
##
## Compile with `-d:jfPure` for the scalar loops only: a build that must stay
## pure nimony (the JS backend, a non-x86 target without a C toolchain) gets a
## slower parser and the identical answer, which the CPython gate checks both
## ways.
when not defined(jfPure):
  {.compile: "jsonfast_simd.c".}
  proc jfSkipWs(s: cstring; n, i: uint): uint {.importc: "jf_skip_ws".}
  proc jfScanStr(s: cstring; n, i: uint): uint {.importc: "jf_scan_string".}

type
  JfKind* = enum
    jfNull, jfFalse, jfTrue, jfInt, jfFloat, jfString, jfArray, jfObject

  JfNode* = object
    kind*: JfKind
    esc*: bool        ## strings only: the lexeme contains a backslash escape
    start*: int32     ## offset of the lexeme in the source (strings: after `"`)
    size*: int32      ## lexeme length; containers: number of CHILDREN
    next*: int32      ## index one past this value's last descendant

  JsonDoc* = ref object
    ## A REF object rather than a value object wrapped in `ref` at the use
    ## site: nimony's codegen emits uncompilable C for `r[] = <value>` when the
    ## value type has destructors (filed to aowlsem). It is also the better
    ## shape — a document is shared by every view of it, and copying a tape by
    ## accident is exactly the mistake a value type invites.
    src*: string
    nodes*: seq[JfNode]
    count*: int       ## nodes actually used; `nodes` is a CAPACITY buffer
    err*: string      ## empty when the parse succeeded
    errPos*: int

const
  MaxDepth* = 512     ## bounded on purpose; see "No recursion" above

proc isWs(c: char): bool {.inline.} =
  c == ' ' or c == '\n' or c == '\t' or c == '\r'

proc isDigit(c: char): bool {.inline.} =
  c >= '0' and c <= '9'

proc fail(doc: JsonDoc; msg: string; pos: int) =
  if doc.err.len == 0:
    doc.err = msg
    doc.errPos = pos

proc scanString(doc: JsonDoc; s: string; cs: cstring; p: int;
                node: var JfNode): int =
  ## `p` is at the opening quote. Returns the index past the closing quote, or
  ## -1 on error. The body is NOT copied or unescaped here.
  var i = p + 1
  node.kind = jfString
  node.start = int32(i)
  node.esc = false
  while i < s.len:
    # Run to the next byte that can end the string: the closing quote, an
    # escape, or a control character. This is where the document's bytes
    # actually go, so it is the loop worth vectorising.
    when not defined(jfPure):
      i = int(jfScanStr(cs, uint(s.len), uint(i)))
      if i >= s.len: break
    let c = s[i]
    if c == '"':
      node.size = int32(i) - node.start
      return i + 1
    if c == '\\':
      node.esc = true
      if i + 1 >= s.len: break
      let e = s[i+1]
      case e
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
        i = i + 2
      of 'u':
        if i + 5 >= s.len:
          fail(doc, "truncated \\u escape", i)
          return -1
        var k = 0
        while k < 4:
          let h = s[i + 2 + k]
          let ok = isDigit(h) or (h >= 'a' and h <= 'f') or (h >= 'A' and h <= 'F')
          if not ok:
            fail(doc, "invalid \\u escape", i)
            return -1
          k = k + 1
        i = i + 6
      else:
        fail(doc, "invalid escape", i)
        return -1
      continue
    if c < ' ':
      fail(doc, "control character in string", i)
      return -1
    i = i + 1
  fail(doc, "unterminated string", p)
  return -1

proc scanNumber(doc: JsonDoc; s: string; p: int; node: var JfNode): int =
  ## RFC 8259 number grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE][+-]?[0-9]+)?`
  var i = p
  var isFloat = false
  if i < s.len and s[i] == '-': i = i + 1
  if i >= s.len or not isDigit(s[i]):
    fail(doc, "invalid number", p)
    return -1
  if s[i] == '0':
    i = i + 1
  else:
    while i < s.len and isDigit(s[i]): i = i + 1
  if i < s.len and s[i] == '.':
    isFloat = true
    i = i + 1
    if i >= s.len or not isDigit(s[i]):
      fail(doc, "digit expected after '.'", i)
      return -1
    while i < s.len and isDigit(s[i]): i = i + 1
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    isFloat = true
    i = i + 1
    if i < s.len and (s[i] == '+' or s[i] == '-'): i = i + 1
    if i >= s.len or not isDigit(s[i]):
      fail(doc, "digit expected in exponent", i)
      return -1
    while i < s.len and isDigit(s[i]): i = i + 1
  node.kind = if isFloat: jfFloat else: jfInt
  node.start = int32(p)
  node.size = int32(i - p)
  return i

proc matches(s: string; p: int; word: string): bool {.inline.} =
  if p + word.len > s.len: return false
  var k = 0
  while k < word.len:
    if s[p + k] != word[k]: return false
    k = k + 1
  return true

proc addNode(doc: JsonDoc; n: JfNode) {.inline.} =
  ## One 16-byte store in the common case. Growth doubles and copies, which is
  ## why the initial reserve matters more than it looks.
  if doc.count >= doc.nodes.len:
    var bigger = newSeq[JfNode](doc.nodes.len * 2)
    var k = 0
    while k < doc.count:
      bigger[k] = doc.nodes[k]
      k = k + 1
    doc.nodes = bigger
  doc.nodes[doc.count] = n
  doc.count = doc.count + 1

proc parseInto*(doc: JsonDoc; src: string) =
  ## Parse into an EXISTING document, reusing its tape.
  ##
  ## This is the shape a server wants and the reason it exists: `newSeq` zeroes
  ## what it allocates, and after the allocator overhead was removed that memset
  ## was 36% of the profile — paid again on every document. Reusing one parser
  ## across many documents pays it once. The contract is simdjson's: the
  ## previous document's values are invalidated by the next parse.
  doc.src = src
  doc.count = 0
  doc.err = ""
  doc.errPos = 0
  # THE TAPE IS A MANUALLY GROWN BUFFER, not a seq being `add`ed to.
  #
  # Profiling said so: on a 1.3MB document, 26% of all instructions were
  # mimalloc bookkeeping — `mi_usable_size`, `mi_page_decode_padding`,
  # `_mi_arena_contains` — because nimony's `seq.add` asks the allocator about
  # the block on EVERY append. At ~40k values that was ~390 instructions per
  # value for what should be a 16-byte store.
  #
  # So: allocate once, write by index, and grow by hand on the rare miss. The
  # reserve is deliberately not generous — `newSeq` zeroes what it allocates,
  # and that memset was another 30% of the profile, so reserving twice what is
  # needed costs twice the memset.
  var cap = src.len div 32
  if cap < 16: cap = 16
  if doc.nodes.len < cap:
    doc.nodes = newSeq[JfNode](cap)
  # The C scanners need a pointer to the bytes. `toCString` wants a mutable
  # string, and the document already owns one: `doc.src`, so no copy is made
  # for the sake of the fast path. Bound unconditionally — guarding it with
  # `when not defined(jfPure)` left the pure build referring to an identifier
  # that did not exist, and the failure hid behind a stale test binary that
  # reported a clean sweep for code that had not compiled.
  let cs = toCString(doc.src)
  # NOTE: the parameter is indexed DIRECTLY. `var s = src` — the obvious
  # spelling — memcpy'd the whole document before parsing a byte of it, and
  # even `let s = src` kept part of that cost.
  var i = 0
  when defined(jfPure):
    while i < src.len and isWs(src[i]): i = i + 1
  else:
    if i < src.len and isWs(src[i]):
      i = int(jfSkipWs(cs, uint(src.len), 1'u))
  if i >= src.len:
    fail(doc, "empty document", 0)
    return

  # The open-container stack: tape index of each container we are inside.
  var stack: seq[int32] = @[]
  # What the parser expects next, as a tiny state rather than a call frame.
  #   0 = a value, 1 = ',' or a close, 2 = a key or '}' , 3 = ':'
  var state = 0
  var done = false

  while true:
    when defined(jfPure):
      while i < src.len and isWs(src[i]): i = i + 1
    else:
      # GUARDED call. Compact JSON — most machine-generated JSON — has no
      # whitespace between tokens at all, so calling the scanner per token was
      # a cross-translation-unit call that immediately returned. gcc cannot
      # inline it away, and at ~260k tokens the call overhead alone rivalled
      # the parse. One compare answers the common case.
      if i < src.len and isWs(src[i]):
        i = int(jfSkipWs(cs, uint(src.len), uint(i + 1)))
    if i >= src.len:
      if not done: fail(doc, "unexpected end of input", i)
      break
    let c = src[i]

    # A jump table rather than an if-chain: every token pays for the chain, and
    # the ordering that suits objects penalises arrays.
    case state
    of 1:
      if c == ',':
        let top = stack[stack.len - 1]
        state = if doc.nodes[top].kind == jfObject: 2 else: 0
        i = i + 1
        continue
      if c == ']' or c == '}':
        if stack.len == 0:
          fail(doc, "unexpected '" & c & "'", i)
          break
        let top = stack[stack.len - 1]
        let want = if doc.nodes[top].kind == jfObject: '}' else: ']'
        if c != want:
          fail(doc, "mismatched close", i)
          break
        doc.nodes[top].next = int32(doc.count)
        discard stack.pop()
        i = i + 1
        if stack.len == 0:
          done = true
          state = 4        # only trailing whitespace may follow
          continue
        state = 1
        continue
      fail(doc, "',' or a close expected", i)
      break

    of 4:
      fail(doc, "trailing content after the document", i)
      break
    of 3:
      if c != ':':
        fail(doc, "':' expected", i)
        break
      i = i + 1
      state = 0
      continue

    of 2:
      if c == '}':
        let top = stack[stack.len - 1]
        if doc.nodes[top].size > 0'i32:
          fail(doc, "trailing comma", i)
          break
        doc.nodes[top].next = int32(doc.count)
        discard stack.pop()
        i = i + 1
        if stack.len == 0:
          done = true
          state = 4
          continue
        state = 1
        continue
      if c != '"':
        fail(doc, "a key string expected", i)
        break
      var key = JfNode(kind: jfString, esc: false, start: 0'i32, size: 0'i32,
                       next: 0'i32)
      let e = scanString(doc, src, cs, i, key)
      if e < 0: break
      key.next = int32(doc.count + 1)
      addNode(doc, key)
      i = e
      state = 3
      continue

    else:
      discard
    if state != 0: continue

    # state == 0: a value.
    if stack.len > 0:
      let top = stack[stack.len - 1]
      doc.nodes[top].size = doc.nodes[top].size + 1'i32

    var node = JfNode(kind: jfNull, esc: false, start: int32(i), size: 0'i32,
                      next: 0'i32)
    case c
    of '{', '[':
      if stack.len >= MaxDepth:
        fail(doc, "nesting deeper than " & $MaxDepth, i)
        break
      node.kind = if c == '{': jfObject else: jfArray
      node.size = 0'i32
      stack.add int32(doc.count)
      addNode(doc, node)
      i = i + 1
      # An empty container closes immediately; otherwise expect a key or value.
      var j = i
      when defined(jfPure):
        while j < src.len and isWs(src[j]): j = j + 1
      else:
        if j < src.len and isWs(src[j]):
          j = int(jfSkipWs(cs, uint(src.len), uint(j + 1)))
      if j < src.len and ((c == '{' and src[j] == '}') or (c == '[' and src[j] == ']')):
        let top = stack[stack.len - 1]
        doc.nodes[top].next = int32(doc.count)
        discard stack.pop()
        i = j + 1
        if stack.len == 0:
          done = true
          state = 4
        else:
          state = 1
        continue
      state = if c == '{': 2 else: 0
      continue
    of '"':
      let e = scanString(doc, src, cs, i, node)
      if e < 0: break
      node.next = int32(doc.count + 1)
      addNode(doc, node)
      i = e
    of 't':
      if not matches(src, i, "true"):
        fail(doc, "invalid literal", i)
        break
      node.kind = jfTrue
      node.size = 4'i32
      node.next = int32(doc.count + 1)
      addNode(doc, node)
      i = i + 4
    of 'f':
      if not matches(src, i, "false"):
        fail(doc, "invalid literal", i)
        break
      node.kind = jfFalse
      node.size = 5'i32
      node.next = int32(doc.count + 1)
      addNode(doc, node)
      i = i + 5
    of 'n':
      if not matches(src, i, "null"):
        fail(doc, "invalid literal", i)
        break
      node.kind = jfNull
      node.size = 4'i32
      node.next = int32(doc.count + 1)
      addNode(doc, node)
      i = i + 4
    else:
      if c == '-' or isDigit(c):
        let e = scanNumber(doc, src, i, node)
        if e < 0: break
        node.next = int32(doc.count + 1)
        addNode(doc, node)
        i = e
      else:
        fail(doc, "a value expected", i)
        break
    if stack.len == 0:
      done = true
      state = 4
    else:
      state = 1

  if doc.err.len == 0 and stack.len > 0:
    fail(doc, "unclosed container", src.len)
  if doc.err.len == 0 and not done:
    fail(doc, "no value in document", 0)

proc parse*(src: string): JsonDoc =
  ## Parse into a fresh document. Convenient, and the right call for a one-off;
  ## `parseInto` with a reused document is the one for a stream of them.
  result = JsonDoc(src: "", nodes: @[], err: "", errPos: 0, count: 0)
  parseInto(result, src)

proc newJsonDoc*(): JsonDoc =
  ## An empty document to reuse as a parser: `let p = newJsonDoc()` then
  ## `parseInto(p, text)` per document.
  JsonDoc(src: "", nodes: @[], err: "", errPos: 0, count: 0)

proc ok*(doc: JsonDoc): bool = doc.err.len == 0

proc valueCount*(doc: JsonDoc): int = doc.count
  ## How many values the document holds. NOT `nodes.len`, which is the
  ## capacity of the tape buffer rather than the part of it that is in use.

proc root*(doc: JsonDoc): int32 = 0'i32

proc kindOf*(doc: JsonDoc; i: int32): JfKind = doc.nodes[i].kind

proc len*(doc: JsonDoc; i: int32): int =
  ## Elements of an array, or PAIRS of an object.
  int(doc.nodes[i].size)

proc firstChild*(doc: JsonDoc; i: int32): int32 = i + 1'i32

proc nextSibling*(doc: JsonDoc; i: int32): int32 = doc.nodes[i].next

proc rawLexeme*(doc: JsonDoc; i: int32): string =
  ## The bytes as they appear in the source: for a string, WITHOUT the quotes
  ## and WITHOUT unescaping.
  let n = doc.nodes[i]
  result = ""
  var k = 0
  while k < int(n.size):
    result.add doc.src[int(n.start) + k]
    k = k + 1

proc hexVal(c: char): int {.inline.} =
  if c >= '0' and c <= '9': int(c) - int('0')
  elif c >= 'a' and c <= 'f': int(c) - int('a') + 10
  elif c >= 'A' and c <= 'F': int(c) - int('A') + 10
  else: 0

proc addUtf8(dest: var string; cp: int) =
  if cp < 0x80:
    dest.add char(cp)
  elif cp < 0x800:
    dest.add char(0xC0 or (cp shr 6))
    dest.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    dest.add char(0xE0 or (cp shr 12))
    dest.add char(0x80 or ((cp shr 6) and 0x3F))
    dest.add char(0x80 or (cp and 0x3F))
  else:
    dest.add char(0xF0 or (cp shr 18))
    dest.add char(0x80 or ((cp shr 12) and 0x3F))
    dest.add char(0x80 or ((cp shr 6) and 0x3F))
    dest.add char(0x80 or (cp and 0x3F))

proc getStr*(doc: JsonDoc; i: int32): string =
  ## The decoded string. Escape-free lexemes — the overwhelming majority — are
  ## copied straight out; only a lexeme with a backslash pays for decoding.
  let n = doc.nodes[i]
  result = ""
  if n.kind != jfString: return
  let a = int(n.start)
  let b = a + int(n.size)
  if not n.esc:
    var k = a
    while k < b:
      result.add doc.src[k]
      k = k + 1
    return
  var k = a
  while k < b:
    let c = doc.src[k]
    if c != '\\':
      result.add c
      k = k + 1
      continue
    let e = doc.src[k+1]
    case e
    of '"': result.add '"'
    of '\\': result.add '\\'
    of '/': result.add '/'
    of 'b': result.add '\b'
    of 'f': result.add '\f'
    of 'n': result.add '\n'
    of 'r': result.add '\r'
    of 't': result.add '\t'
    of 'u':
      var cp = (hexVal(doc.src[k+2]) shl 12) or (hexVal(doc.src[k+3]) shl 8) or
               (hexVal(doc.src[k+4]) shl 4) or hexVal(doc.src[k+5])
      k = k + 6
      # A surrogate PAIR is one code point; a lone surrogate is passed through
      # as U+FFFD rather than producing invalid UTF-8.
      if cp >= 0xD800 and cp <= 0xDBFF:
        if k + 5 < b and doc.src[k] == '\\' and doc.src[k+1] == 'u':
          let lo = (hexVal(doc.src[k+2]) shl 12) or (hexVal(doc.src[k+3]) shl 8) or
                   (hexVal(doc.src[k+4]) shl 4) or hexVal(doc.src[k+5])
          if lo >= 0xDC00 and lo <= 0xDFFF:
            cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
            k = k + 6
          else:
            cp = 0xFFFD
        else:
          cp = 0xFFFD
      elif cp >= 0xDC00 and cp <= 0xDFFF:
        cp = 0xFFFD
      addUtf8(result, cp)
      continue
    else: discard
    k = k + 2

proc getInt*(doc: JsonDoc; i: int32; default: int64 = 0): int64 =
  let n = doc.nodes[i]
  if n.kind != jfInt: return default
  var k = int(n.start)
  let b = k + int(n.size)
  var neg = false
  if k < b and doc.src[k] == '-':
    neg = true
    k = k + 1
  var v: int64 = 0
  while k < b:
    v = v * 10 + int64(int(doc.src[k]) - int('0'))
    k = k + 1
  if neg: -v else: v

proc getBool*(doc: JsonDoc; i: int32; default = false): bool =
  case doc.nodes[i].kind
  of jfTrue: true
  of jfFalse: false
  else: default

proc isNull*(doc: JsonDoc; i: int32): bool = doc.nodes[i].kind == jfNull

iterator elems*(doc: JsonDoc; arr: int32): int32 =
  ## Array elements, skipping each one's whole subtree in O(1).
  var c = arr + 1'i32
  var seen = 0
  let total = int(doc.nodes[arr].size)
  while seen < total:
    yield c
    c = doc.nodes[c].next
    seen = seen + 1

iterator fields*(doc: JsonDoc; obj: int32): (int32, int32) =
  ## `(key node, value node)` per pair, in document order — duplicates and all.
  var c = obj + 1'i32
  var seen = 0
  let total = int(doc.nodes[obj].size)
  while seen < total:
    let v = c + 1'i32
    yield (c, v)
    c = doc.nodes[v].next
    seen = seen + 1

proc findIn(doc: JsonDoc; obj: int32; key: string): int32

type
  JsonView* = object
    ## A cursor into a parsed document: chain-safe access with NOTHING
    ## materialized.
    ##
    ## `parseJsonFast` (jsonfast_aowljson.nim) hands back an `aowljson` tree,
    ## which costs a ref object and a string copy per value — measured at ~6x
    ## the parse itself, and the reason a "faster parser" that ends in a tree is
    ## barely faster at all. Most readers do not need the tree: they want three
    ## fields out of a response. A view gives them `v{"user"}{"name"}.str("")`
    ## at tape speed.
    ##
    ## Absence is a view with `idx < 0`, and every accessor returns its default
    ## for one — so a chain through a missing key cannot fault, and no
    ## allocation happens on the way.
    doc*: JsonDoc
    idx*: int32

proc view*(doc: JsonDoc): JsonView =
  ## A cursor at the document's root, or an invalid one if it failed to parse.
  JsonView(doc: doc, idx: if doc.err.len == 0: 0'i32 else: -1'i32)

proc valid*(v: JsonView): bool = v.idx >= 0'i32

proc `{}`*(v: JsonView; key: string): JsonView =
  ## The member `key`, or an invalid view. Chains never fault.
  if v.idx < 0'i32 or v.doc.nodes[v.idx].kind != jfObject:
    return JsonView(doc: v.doc, idx: -1'i32)
  JsonView(doc: v.doc, idx: findIn(v.doc, v.idx, key))

proc at*(v: JsonView; i: int): JsonView =
  ## The i-th array element, or an invalid view.
  if v.idx < 0'i32 or v.doc.nodes[v.idx].kind != jfArray:
    return JsonView(doc: v.doc, idx: -1'i32)
  var c = v.idx + 1'i32
  var k = 0
  let total = int(v.doc.nodes[v.idx].size)
  while k < total:
    if k == i: return JsonView(doc: v.doc, idx: c)
    c = v.doc.nodes[c].next
    k = k + 1
  JsonView(doc: v.doc, idx: -1'i32)

proc len*(v: JsonView): int =
  if v.idx < 0'i32: 0 else: int(v.doc.nodes[v.idx].size)

proc str*(v: JsonView; default = ""): string =
  if v.idx < 0'i32 or v.doc.nodes[v.idx].kind != jfString: default
  else: getStr(v.doc, v.idx)

proc num*(v: JsonView; default: int64 = 0): int64 =
  if v.idx < 0'i32: default else: getInt(v.doc, v.idx, default)

proc boolean*(v: JsonView; default = false): bool =
  if v.idx < 0'i32: default else: getBool(v.doc, v.idx, default)

proc isNull*(v: JsonView): bool =
  v.idx >= 0'i32 and v.doc.nodes[v.idx].kind == jfNull

iterator items*(v: JsonView): JsonView =
  if v.idx >= 0'i32 and v.doc.nodes[v.idx].kind == jfArray:
    var c = v.idx + 1'i32
    var k = 0
    let total = int(v.doc.nodes[v.idx].size)
    while k < total:
      yield JsonView(doc: v.doc, idx: c)
      c = v.doc.nodes[c].next
      k = k + 1

iterator pairs*(v: JsonView): (JsonView, JsonView) =
  ## `(key view, value view)`. The key is a VIEW, not a string, so walking an
  ## object allocates nothing: call `.str()` on the key only if you need it.
  if v.idx >= 0'i32 and v.doc.nodes[v.idx].kind == jfObject:
    var c = v.idx + 1'i32
    var k = 0
    let total = int(v.doc.nodes[v.idx].size)
    while k < total:
      let val = c + 1'i32
      yield (JsonView(doc: v.doc, idx: c), JsonView(doc: v.doc, idx: val))
      c = v.doc.nodes[val].next
      k = k + 1

proc find*(doc: JsonDoc; obj: int32; key: string): int32 =
  ## The value for `key`, or -1. Linear, which is the right answer for the
  ## object sizes JSON actually contains; a hash would cost more to build than
  ## it saves on a handful of keys.
  if doc.nodes[obj].kind != jfObject: return -1'i32
  for k, v in fields(doc, obj):
    let n = doc.nodes[k]
    if not n.esc and int(n.size) == key.len:
      var same = true
      var j = 0
      while j < key.len:
        if doc.src[int(n.start) + j] != key[j]:
          same = false
          break
        j = j + 1
      if same: return v
    elif n.esc and getStr(doc, k) == key:
      return v
  return -1'i32

proc findIn(doc: JsonDoc; obj: int32; key: string): int32 =
  find(doc, obj, key)
