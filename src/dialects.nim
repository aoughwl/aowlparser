## dialects.nim — the registry: every dialect this build can read and write.
##
## One table, so nothing has to be listed twice. The CLI's `dialects` command
## prints it, `auto` dispatches on file extension, and `render` dispatches on the
## `.dialect` header — all from here.
##
## Adding a dialect means adding ONE row. If a row is missing, the failure is a
## clear "no dialect for .foo" rather than a silent fallthrough.

import tokens
import aowlparse/nodespec
import cssparser, htmlparser, pyparser, jsparser, jsonparser, vdsparser

type
  DialectEntry* = object
    name*: string          ## the `.dialect` header value, e.g. "css-parsed"
    command*: string       ## the CLI subcommand, e.g. "css"
    exts*: seq[string]     ## file extensions that select it, with the dot
    summary*: string
    parse*: proc (src: string; diags: var seq[Diagnostic]): string
    render*: proc (aif: string): string

## Uniquely-named wrappers, one per dialect.
##
## These exist ONLY to work around a nimony crash: using an OVERLOADED proc as a
## value in an object field hits an AssertionDefect in nifstreams.nim(307)
## (`n.kind in {Symbol, SymbolDef}`) rather than resolving or diagnosing. Each
## `xToAif` has a with-diags and a without-diags overload — an ordinary API
## shape — and naming a single arity here sidesteps it.
##
## Minimal repro + control live in the scratchpad and are filed to `aowlsem`;
## per the do-not-fix-nimony rule this is recorded, not patched upstream.
## Delete these wrappers once overload resolution completes before the
## proc-to-value conversion.
proc pCss(src: string; diags: var seq[Diagnostic]): string = cssToAif(src, diags)
proc pHtml(src: string; diags: var seq[Diagnostic]): string = htmlToAif(src, diags)
proc pPy(src: string; diags: var seq[Diagnostic]): string = pyToAif(src, diags)
proc pJs(src: string; diags: var seq[Diagnostic]): string = jsToAif(src, diags)
proc pJson(src: string; diags: var seq[Diagnostic]): string = jsonToAif(src, diags)
proc pVds(src: string; diags: var seq[Diagnostic]): string = vdsToAif(src, diags)

proc allDialects*(): seq[DialectEntry] =
  result = @[
    DialectEntry(name: "css-parsed", command: "css", exts: @[".css"],
      summary: "CSS Syntax Level 3, trivia-preserving",
      parse: pCss, render: renderCss),
    DialectEntry(name: "html-parsed", command: "html",
      exts: @[".html", ".htm", ".xhtml"],
      summary: "HTML with raw-text elements (script/style/textarea/title)",
      parse: pHtml, render: renderHtml),
    DialectEntry(name: "py-parsed", command: "py", exts: @[".py", ".pyi"],
      summary: "Python: indentation tree, implicit/explicit line joining",
      parse: pPy, render: renderPy),
    DialectEntry(name: "js-parsed", command: "js",
      exts: @[".js", ".mjs", ".cjs"],
      summary: "JavaScript: regex-vs-division, templates, bracket groups",
      parse: pJs, render: renderJs),
    DialectEntry(name: "json-parsed", command: "json", exts: @[".json"],
      summary: "JSON preserving key order, duplicates and number spelling",
      parse: pJson, render: renderJson),
    DialectEntry(name: "vds-parsed", command: "vds", exts: @[".vds"],
      summary: "MDN value-definition syntax (the language CSS specs use)",
      parse: pVds, render: renderVds),
  ]

proc specOf*(cmd: string): Dialect =
  ## The node declaration for a dialect, looked up separately from the registry.
  ##
  ## It is NOT a field on DialectEntry: an object-with-a-seq sitting beside proc
  ## fields made nimony emit C that references a struct member it never defined
  ## ("has no member named 'X60Qii_6'") — a codegen defect that type-checks clean
  ## and fails at cc. Keeping the registry to strings and procs sidesteps it, and
  ## is arguably the better shape anyway.
  case cmd
  of "css": cssDialect()
  of "html": htmlDialect()
  of "py": pyDialect()
  of "js": jsDialect()
  of "json": jsonDialect()
  of "vds": vdsDialect()
  else: Dialect(name: "", nodes: @[])

proc byCommand*(cmd: string): int =
  ## Index into `allDialects()`, or -1.
  let all = allDialects()
  var i = 0
  while i < all.len:
    if all[i].command == cmd: return i
    i = i + 1
  return -1

proc byDialectName*(name: string): int =
  let all = allDialects()
  var i = 0
  while i < all.len:
    if all[i].name == name: return i
    i = i + 1
  return -1

proc lowerExt(path: string): string =
  ## The extension of `path`, lower-cased, including the dot. "" when there is
  ## none, or when the dot belongs to a directory component.
  var dot = -1
  var i = path.len - 1
  while i >= 0:
    let c = path[i]
    if c == '/': break
    if c == '.' and dot < 0: dot = i
    i = i - 1
  if dot < 0: return ""
  result = ""
  var j = dot
  while j < path.len:
    let c = path[j]
    if c >= 'A' and c <= 'Z': result.add char(int(c) + 32)
    else: result.add c
    j = j + 1

proc byExtension*(path: string): int =
  ## Which dialect handles this file, by extension. -1 when none does.
  let ext = lowerExt(path)
  if ext.len == 0: return -1
  let all = allDialects()
  var i = 0
  while i < all.len:
    let exts = all[i].exts
    for k in 0 ..< exts.len:
      if exts[k] == ext: return i
    i = i + 1
  return -1

proc knownExtensions*(): string =
  result = ""
  # Bind to a local first: nimony's borrow checker rejects iterating a proc
  # RESULT directly (`for d in allDialects()`), the same way it rejects
  # `for x in commandLineParams()`.
  let all = allDialects()
  var i = 0
  while i < all.len:
    let exts = all[i].exts
    for k in 0 ..< exts.len:
      if result.len > 0: result.add " "
      result.add exts[k]
    i = i + 1
