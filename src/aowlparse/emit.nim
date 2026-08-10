## emit.nim — writing a dialect's AIF, checked against its NodeSpec declaration.
##
## Every dialect emits leaves and markers the same way; what differs is only the
## tag vocabulary. These helpers take the `Dialect` so an emit can be validated
## against the declaration: emitting a `nkPunct` tag with a string child, or a
## `nkText` tag without one, is a bug that would otherwise surface much later as
## a byte mismatch in a 280KB stylesheet.

import nifbuilder
import nodespec

proc addAifHeader*(b: var Builder; dialect: string) =
  ## The `(.aif27)` magic is a deliberate rebrand of NIF — see parser.nim. Every
  ## dialect in this repo carries the same vendor and its own `.dialect` value,
  ## which is what `render` dispatches on.
  b.addRaw "(.aif27)\n"
  b.addRaw "(.vendor "
  b.addStrLit "aowlparser"
  b.addRaw ")\n"
  b.addRaw "(.dialect "
  b.addStrLit dialect
  b.addRaw ")\n"

proc leaf*(b: var Builder; tag, raw: string) =
  ## A text leaf: `(tag "raw")`.
  b.addTree tag
  b.addStrLit raw
  b.endTree()

proc leafAt*(b: var Builder; tag, raw: string; col, line: int32) =
  b.addTree tag
  b.addLineInfo(col, line)
  b.addStrLit raw
  b.endTree()

proc mark*(b: var Builder; tag: string) =
  ## A punctuation marker: `(tag)`, no child.
  b.addTree tag
  b.endTree()

proc openNode*(b: var Builder; tag: string; col, line: int32) =
  b.addTree tag
  b.addLineInfo(col, line)

proc closeNode*(b: var Builder) =
  b.endTree()

proc specViolation*(d: Dialect; tag: string; hasChild: bool): string =
  ## "" when emitting `tag` with/without a string child agrees with the dialect
  ## declaration. Used by the gate harness rather than on the hot path.
  if not knows(d, tag):
    return "tag '" & tag & "' is emitted but not declared in the dialect"
  case kindOf(d, tag)
  of nkText, nkOpaque:
    if not hasChild:
      return "tag '" & tag & "' is declared text but emitted with no child"
  of nkPunct:
    if hasChild:
      return "tag '" & tag & "' is declared punct but emitted with a child"
  of nkStruct:
    if hasChild:
      return "tag '" & tag & "' is declared struct but emitted with a child"
  return ""
