## mcfgconsts.nim — a nimony PLUGIN that turns a config file into constants.
##
## This exists to answer a fair question: what is a byte-exact CST of a non-Nim
## file actually FOR? Here is one concrete answer that only works because both
## halves speak the same tree model.
##
##     template cfgConsts(path: string) {.plugin: "mcfgconsts".}
##     cfgConsts("app.cfg")
##     echo appName          # a real const, checked by the compiler
##
## A nimony plugin is a program the compiler runs: it reads a NIF tree from
## `paramStr(1)` and writes one to `paramStr(2)` (see src/nimony/semos.nim,
## `runPlugin` — the input is content-addressed by checksum, so the result is
## cached). That means a plugin is free to read anything else while it runs —
## and with aowlparser linked in, "anything else" includes a `.cfg`, `.yaml` or
## `.css` file parsed into the SAME node model the plugin is already emitting.
##
## What that buys over `staticRead` + a hand-rolled split:
##   * one parser, already validated on 1,070 real config files, instead of a
##     regex that works until someone writes `--passC:"-DX=#1"`;
##   * the file's structure, so a switch and an assignment are different nodes
##     rather than both being "a line with an = in it";
##   * positions, so a bad entry can be reported at its line and column;
##   * and the same reader vocabulary on both sides of the plugin.
##
## 🔴 THE TRAP, WHICH THIS EXAMPLE EXISTS TO DOCUMENT AS MUCH AS ANYTHING.
##
## This plugin takes a PATH and reads the file itself, and that is **silently
## wrong the moment anyone edits the config**. Reproduced, not theorised:
## changing `version = "0.4.0"` to `"9.9.9-CHANGED"` and rebuilding still
## printed `0.4.0`, with no error and no warning.
##
## `runPlugin` keys its cache on `computeChecksum(pluginInput)`, and the input
## here is only `(stmts cfgConsts "app.cfg")` — unchanged by editing the file.
## A plugin may read whatever it likes, but the compiler tracks only what it was
## HANDED, and the protocol has no way for a plugin to say "I also depend on
## this file".
##
## The obvious fix — pass `staticRead("app.cfg")` so the bytes land in the input
## and the checksum moves with them — does not work either: nimony has no
## `staticRead`, and its `slurp` is an ordinary runtime `readFile`. Filed to
## `aowlsem` as a requirement.
##
## Until then: `touch` this plugin's source when the config changes (the cache
## also re-runs when the plugin binary is newer than its output), or do not use
## a plugin at all — generate a `.nim` with `aowlparser cfg` as a build step,
## which the compiler tracks correctly because it is an ordinary input.
##
## SCOPE: `key = value` entries become string constants. Switches, sections and
## conditionals are deliberately skipped rather than guessed at — see the
## `cfg-parsed` dialect for what they parse into.

import plugins
import std / syncio

import cfgparser
import aifread

proc isIdentStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

proc isIdentChar(c: char): bool =
  isIdentStart(c) or (c >= '0' and c <= '9')

proc isNimIdent(s: string): bool =
  ## Only entries whose key is already a legal Nim identifier become constants.
  ## Mangling `warning[X]` into `warningX` would invent a name the config file
  ## does not contain, and the caller would have no way to know what to type.
  if s.len == 0: return false
  if not isIdentStart(s[0]): return false
  for c in s.items:
    if not isIdentChar(c): return false
  return true

type
  Entry = object
    key, value: string

proc collectEntries(aif: string): seq[Entry] =
  ## Walk the `cfg-parsed` AIF and pick up every `(entry (key …) (op "=") …
  ## (value …))`. The reader is the dialect's own, so this cannot drift from
  ## what the parser emits.
  result = @[]
  var r = AifReader(src: aif, pos: 0)
  var inEntry = false
  var depth = 0
  var wantKey = false
  var wantValue = false
  var cur = Entry(key: "", value: "")
  while true:
    let n = nextAif(r)
    if n.kind == akEof: break
    case n.kind
    of akParLe:
      if n.tag == "entry":
        inEntry = true
        depth = 0
        cur = Entry(key: "", value: "")
      elif inEntry:
        depth = depth + 1
        wantKey = n.tag == "key"
        wantValue = n.tag == "value"
    of akStrLit:
      if inEntry and wantKey and cur.key.len == 0:
        cur.key = n.str
      elif inEntry and wantValue and cur.value.len == 0:
        cur.value = n.str
      wantKey = false
      wantValue = false
    of akParRi:
      if inEntry:
        if depth == 0:
          inEntry = false
          if cur.key.len > 0: result.add cur
        else:
          depth = depth - 1
    else: discard

proc unquote(s: string): string =
  ## Config values are usually quoted; the constant should hold the text, not
  ## the quotes. A value with only one quote is left exactly as written.
  if s.len >= 2 and s[0] == '"' and s[s.len-1] == '"':
    result = ""
    var i = 1
    while i < s.len - 1:
      result.add s[i]
      i = i + 1
  else:
    result = s

proc transform(n: NifCursor): NifBuilder =
  let info = n.info
  var args = callArgs(n)
  if args.kind != StrLit:
    return errorTree("cfgConsts expects a string literal path", args)
  let path = stringValue(args)

  var text = ""
  var readOk = true
  try:
    text = readFile(path)
  except:
    readOk = false
  if not readOk:
    return errorTree("cfgConsts: cannot read '" & path & "'", args)

  let entries = collectEntries(cfgToAif(text))
  result = createTree()
  result.withTree StmtsS, info:
    var emitted = 0
    for e in entries.items:
      if not isNimIdent(e.key): continue
      # (const <name> <exported> <pragmas> <type> <value>) — the shape the Nim
      # front end emits for `const x = "y"`, confirmed by running
      # `aowlparser p` on exactly that source rather than by guessing.
      result.withTree ConstS, info:
        # An IDENTIFIER, not `addSymDef`. A symbol definition minted by the
        # plugin is hygienic — it exists, it type-checks, and the caller cannot
        # see it, which is exactly what `genSym` is for. A plain identifier is
        # bound by sem in the CALLER's scope, which is what "declare a constant
        # for me" has to mean.
        result.addIdent(e.key)
        result.addEmptyNode3(info)
        result.addStrLit(unquote(e.value))
      emitted = emitted + 1
    if emitted == 0:
      # A config with no usable entries is far more likely to be the wrong file
      # than an intentional no-op, and an empty expansion would be silent.
      result.addTree errorTree("cfgConsts: no `key = value` entries with " &
                               "identifier-shaped keys in '" & path & "'", args)

var inp = loadPluginInput()
saveTree transform(inp)
