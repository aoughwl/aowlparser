#!/usr/bin/env python3
"""oracle.py — write a token/structure manifest for the py-parsed gate.

CPython's own `tokenize` is third-party truth about a Python file: how many
NAMEs, NUMBERs, STRINGs, COMMENTs and OPs it holds, how many logical lines
(NEWLINE), and how many indented suites (INDENT). `tests/py/toracle.nim` reads
this manifest and holds `py-parsed` to it.

Why a manifest and not a comparison here: the counting on our side has to go
through the AIF reader, not a substring scan, or a tag name inside a string
literal is miscounted. So Python produces the expected numbers, Nim produces the
actual ones, and neither side can quietly agree with itself.

Usage: oracle.py <out-manifest> <file.py>...
A file CPython itself cannot tokenize is written as a SKIP line with the reason,
never dropped: a silently missing file reads exactly like a passing one.
"""

import io
import sys
import token
import tokenize


class OracleTooOld(Exception):
    """This CPython predates syntax the file uses, so it is not an oracle for it."""


def counts_for(path):
    with open(path, "rb") as fh:
        data = fh.read()
    # The walrus operator is 3.8+. An older tokenizer splits `:=` into `:` and
    # `=` and would report `py-parsed` — which is right — as wrong by two ops.
    # An oracle that is BEHIND the thing it measures is not evidence, so say so
    # instead of quietly counting it as a mismatch.
    if sys.version_info < (3, 8) and b":=" in data:
        raise OracleTooOld("walrus operator needs CPython 3.8+, this is %d.%d"
                           % sys.version_info[:2])
    counts = {"stmt": 0, "block": 0, "name": 0, "num": 0, "str": 0,
              "comment": 0, "op": 0}
    readline = io.BytesIO(data).readline
    last_newline_row = 0
    for tok in tokenize.tokenize(readline):
        t = tok.type
        if t == token.ERRORTOKEN and tok.string.strip():
            # CPython could not lex this byte (e.g. a combining mark inside an
            # identifier, which it splits into several NAMEs). Where the oracle
            # itself reports an error it is not truth about the token stream,
            # and `py-parsed` deliberately never errors.
            raise OracleTooOld("CPython emits ERRORTOKEN at line %d" % tok.start[0])
        if t == token.NAME:
            counts["name"] += 1
        elif t == token.NUMBER:
            counts["num"] += 1
        elif t == token.STRING:
            counts["str"] += 1
        elif t == tokenize.COMMENT:
            counts["comment"] += 1
        elif t == token.OP:
            counts["op"] += 1
        elif t == token.NEWLINE:
            counts["stmt"] += 1
            last_newline_row = tok.start[0]
        elif t == token.INDENT:
            counts["block"] += 1
    # A file not ending in a newline can get a SYNTHETIC NEWLINE from tokenize.
    # When the last line carries a statement that token is the statement's real
    # terminator; when it is a comment or blank AND the token sits on that very
    # row, it is a tokenizer artifact and counting it would demand a statement
    # that is not there. Checking the ROW matters: `…\n    ` (trailing spaces,
    # no newline) gets no synthetic token, and subtracting blind made the oracle
    # itself wrong by one.
    if data and not data.endswith(b"\n"):
        rows = data.split(b"\n")
        last = rows[-1].strip()
        if (not last or last.startswith(b"#")) and last_newline_row == len(rows):
            counts["stmt"] -= 1
    return counts


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: oracle.py <out-manifest> <file.py>...\n")
        return 2
    out, paths = sys.argv[1], sys.argv[2:]
    # `@list` reads the paths from a file. Passing thousands of paths on the
    # command line lets xargs split the run into batches, and each batch would
    # OVERWRITE the manifest — leaving a gate that measures the last batch and
    # reports success for the whole corpus.
    if len(paths) == 1 and paths[0].startswith("@"):
        with open(paths[0][1:]) as fh:
            paths = [ln.strip() for ln in fh if ln.strip()]
    lines, skipped = [], 0
    for path in paths:
        try:
            c = counts_for(path)
        except OracleTooOld as exc:
            lines.append("SKIP\t%s\t%s" % (path, exc))
            skipped += 1
            continue
        except Exception as exc:                     # noqa: BLE001
            lines.append("SKIP\t%s\t%s" % (path, type(exc).__name__))
            skipped += 1
            continue
        lines.append("%s\t%s" % (path, "\t".join(
            "%s=%d" % (k, v) for k, v in sorted(c.items()))))
    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("manifest: %d file(s), %d not tokenizable by CPython" %
          (len(paths) - skipped, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
