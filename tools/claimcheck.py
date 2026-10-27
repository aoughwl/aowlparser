#!/usr/bin/env python3
"""
tools/claimcheck.py -- every number this repo's documentation states must name
the gate that printed it, and must still agree with what that gate prints.

WHY THIS EXISTS
---------------
Three times in two days, across three repos, documentation stated a gate score
that no gate had ever printed:

  * the docs site said aowlsem was "498/498 byte-exact modules". 498 was an
    hconv-site census (REQUIREMENTS.md: "oracle 527 | ours 498") reworded into a
    module count. The real figure at the time was 46/55.
  * aowlc's README said twoprinters was "73/73". The script's own output said
    66/67.
  * the same README said "77/77" beside single-all.sh, which prints 78/78 --
    the corpus grew by one and the prose did not follow.

None of these were caught by a test, because no test read the prose. Each was
found by a human re-running a gate and noticing. This script is that human.

THE DISCIPLINE IT ENCODES
-------------------------
A number in a document is a CLAIM. A claim has exactly one honest provenance:
some command printed it. So every claim gets a row in CLAIMS.tsv naming that
command, and this script re-runs (or re-reads) it and compares.

The hard part is not the comparison; it is the three honest ways a claim can
resist checking, each of which must be told apart from "wrong":

  UNVERIFIABLE  the gate ran but refused to answer -- stale artifacts, a fixture
                that would not build, an infra event. aowli and aowlsem gates
                already exit 2 and print "THIS RUN IS NOT EVIDENCE" for exactly
                this. A refusal is NOT a disagreement, and a refused run must
                never be allowed to rewrite a number.
  DECLARED      the claim is deliberately not a current measurement: a floor or
                baseline (BASELINE), a figure that is only meaningful on one
                platform (PLATFORM -- Windows and Linux baselines are NOT
                comparable here, module ids are content-hashed and the trees
                differ), a dated historical record (HISTORICAL), or a gate too
                expensive to run every time (EXPENSIVE, run with --all).
  UNATTRIBUTED  no command produces this number at all. This is the 498/498
                category and it is a HARD FAILURE. The fix is to measure it or
                to DELETE it from the document -- never to invent a plausible
                replacement.

The rule the whole thing exists to enforce:

    NEVER REWRITE A NUMBER YOU DID NOT MEASURE.

So this script only ever REPORTS. It has no --fix and will not get one. When it
says a claim is wrong it prints what the gate printed, and a human pastes that.

EXIT CODES (the house convention: 0 clean / 1 real failure / 2 not evidence)
  0  every checkable claim agrees
  1  a claim disagrees with its gate, or is UNATTRIBUTED, or CLAIMS.tsv has
     drifted from the document it describes
  2  nothing disagreed, but something could not be checked

USAGE
  python3 tools/claimcheck.py                # cheap rows only
  python3 tools/claimcheck.py --all          # also the EXPENSIVE ones
  python3 tools/claimcheck.py --sweep        # also hunt for UNDECLARED numbers
  python3 tools/claimcheck.py --list         # print the manifest, run nothing
  python3 tools/claimcheck.py --only diff    # rows whose id/file matches

CLAIMS.tsv FORMAT -- tab separated, '#' comments, blank lines ignored:

  FILE  ANCHOR  CLASS  NUMBER  SOURCE  EXTRACT  [GUARD]

  FILE     path relative to the repo root that contains the claim
  ANCHOR   a literal substring of that file that CONTAINS the number. It must
           occur exactly once. If it stops occurring, the manifest is stale and
           that is a failure -- which is what stops a doc edit from silently
           orphaning its own check.
  CLASS    GATE | EXPENSIVE | BASELINE | PLATFORM | HISTORICAL | UNATTRIBUTED
  NUMBER   the claimed value, exactly as written ("78/78", "42s", "55 lines").
           Must be a substring of ANCHOR.
  SOURCE   GATE/EXPENSIVE: the shell command, run from the repo root.
           everything else: the reason, in prose. Never empty.
  EXTRACT  GATE/EXPENSIVE: a regex with ONE capturing group, applied to the
           command's combined output; the LAST match wins (gates print a running
           log and then a summary). Empty for the other classes.
  GUARD    optional. A regex that, when it matches the command's output, forces
           UNVERIFIABLE even though EXTRACT found a number. It is for gates that
           answer zero when they mean "I could not measure": aowlparser's
           stress.sh prints `pass=0 ... oracle-skip=225` when the nifler oracle
           is absent, and a checker without a GUARD would read that as a
           disagreement with 184/184 rather than as a refusal to answer.

  Rows sharing a SOURCE run the command once.

  Two directives may also appear:
    SWEEP   <path>          include this file in --sweep
    IGNORE  <path>  <regex> lines matching the regex are exempt from --sweep
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

CLASSES = ("GATE", "EXPENSIVE", "BASELINE", "PLATFORM", "HISTORICAL", "UNATTRIBUTED")

# A gate that declines to answer says so in one of these ways. This list is
# deliberately generous: mistaking a refusal for a measurement is the failure
# mode that would let this script itself launder an unmeasured number, so it errs
# toward "could not check".
REFUSAL = re.compile(
    r"NOT EVIDENCE"
    r"|did not run"
    r"|PARTIAL RUN"
    r"|^\s*INFRA\b"
    r"|are stale|is stale|STALE"
    r"|refus(e|ed|es)"
    r"|no oracle"
    r"|cannot (be )?(measure|check|run|compare)"
    r"|WORK_STALE_OK"
    r"|SKIPPED THE WHOLE"
    r"|fixture did not build"
    r"|oracle not found"
    r"|no such file|not found:"
    r"|run \./build\.sh first",
    re.I | re.M,
)

NUMBERISH = re.compile(r"\b\d[\d,]*\s*/\s*\d[\d,]*\b|\b\d+(?:\.\d+)?\s*%")


class Row:
    __slots__ = ("lineno", "file", "anchor", "cls", "number", "source", "extract", "guard")


def parse_manifest(path):
    rows, sweeps, ignores, errs = [], [], {}, []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cells = line.split("\t")
            cells = [c.strip() for c in cells if c.strip() != ""] if cells[0] in ("SWEEP", "IGNORE") else cells
            if cells[0] == "SWEEP":
                sweeps.append(cells[1])
                continue
            if cells[0] == "IGNORE":
                ignores.setdefault(cells[1], []).append(re.compile(cells[2]))
                continue
            if len(cells) < 5:
                errs.append(f"CLAIMS.tsv:{lineno}: need at least 5 tab-separated fields, got {len(cells)}")
                continue
            r = Row()
            r.lineno = lineno
            r.file, r.anchor, r.cls, r.number, r.source = (c.strip() for c in cells[:5])
            r.extract = cells[5].strip() if len(cells) > 5 else ""
            r.guard = cells[6].strip() if len(cells) > 6 else ""
            if r.cls not in CLASSES:
                errs.append(f"CLAIMS.tsv:{lineno}: unknown CLASS {r.cls!r}; one of {', '.join(CLASSES)}")
                continue
            if not r.source:
                errs.append(f"CLAIMS.tsv:{lineno}: SOURCE is empty. A claim with no stated provenance is the defect this file exists to catch.")
                continue
            if r.cls in ("GATE", "EXPENSIVE") and not r.extract:
                errs.append(f"CLAIMS.tsv:{lineno}: {r.cls} needs an EXTRACT regex")
                continue
            rows.append(r)
    return rows, sweeps, ignores, errs


def check_anchor(root, r):
    """Free, and the most valuable check here: does the document still say what
    the manifest says it says? Returns an error string or None."""
    p = os.path.join(root, r.file)
    if not os.path.exists(p):
        return f"{r.file} does not exist"
    if r.number not in r.anchor:
        return f"manifest is self-inconsistent: NUMBER {r.number!r} is not inside ANCHOR {r.anchor!r}"
    text = open(p, encoding="utf-8", errors="replace").read()
    n = text.count(r.anchor)
    if n == 0:
        return (f"ANCHOR no longer occurs in {r.file}. The document changed and this row did not; "
                f"re-anchor it or drop it. Anchor was: {r.anchor!r}")
    if n > 1:
        return f"ANCHOR occurs {n} times in {r.file}; it must be unique so the row names one claim"
    return None


# Every gate in this toolchain is a bash script, and on Windows `shell=True`
# would hand the command line to cmd.exe, where `$(...)` and `[ -f x ]` are not
# syntax. A command that fails to PARSE would be reported as a gate that produced
# no number -- an unverifiable, which is survivable, but it would make the check
# quietly useless on the platform where all three of the original defects were
# found. So: bash, explicitly.
_BASH = shutil.which("bash") or shutil.which("sh")


def run(cmd, root, timeout):
    argv = [_BASH, "-c", cmd] if _BASH else cmd
    try:
        p = subprocess.run(argv, shell=(_BASH is None), cwd=root, capture_output=True, text=True,
                           errors="replace", timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") + (e.stderr or "")
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return 124, out + f"\n[claimcheck] TIMED OUT after {timeout}s"
    except OSError as e:
        return 127, f"[claimcheck] could not run: {e}"


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--manifest", default="CLAIMS.tsv")
    ap.add_argument("--root", default=None, help="repo root (default: the manifest's directory)")
    ap.add_argument("--all", action="store_true", help="also run EXPENSIVE rows")
    ap.add_argument("--sweep", action="store_true", help="report numbers in swept files that no row declares")
    ap.add_argument("--list", action="store_true", help="print the manifest and run nothing")
    ap.add_argument("--only", default=None, help="substring filter on FILE or SOURCE")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--label", default=os.path.basename(os.getcwd()),
                    help="prefix for the final summary line, so a gate runner can grep it")
    args = ap.parse_args()

    manifest = os.path.abspath(args.manifest)
    root = os.path.abspath(args.root) if args.root else os.path.dirname(manifest)
    if not os.path.exists(manifest):
        print(f"claimcheck: no manifest at {manifest}", file=sys.stderr)
        return 1

    rows, sweeps, ignores, errs = parse_manifest(manifest)
    if args.only:
        rows = [r for r in rows if args.only in r.file or args.only in r.source]

    if args.list:
        for r in rows:
            print(f"{r.cls:<13} {r.file}:{r.number:<12} {r.source}")
        return 0

    wrong, unverifiable, ok, declared = [], [], [], []

    # ---- pass 1: anchors (free) --------------------------------------------
    live = []
    for r in rows:
        e = check_anchor(root, r)
        if e:
            errs.append(f"CLAIMS.tsv:{r.lineno}: {e}")
        else:
            live.append(r)

    # ---- pass 2: the classes that are deliberately not measured now ---------
    to_run = []
    for r in live:
        if r.cls == "UNATTRIBUTED":
            wrong.append((r, "UNATTRIBUTED",
                          "no command produces this number. Measure it and paste what the gate printed, "
                          "or delete the number. Do not replace it with a guess.\n"
                          f"                  note: {r.source}"))
        elif r.cls in ("BASELINE", "PLATFORM", "HISTORICAL"):
            declared.append((r, r.cls, r.source))
        elif r.cls == "EXPENSIVE" and not args.all:
            declared.append((r, "EXPENSIVE", f"not run without --all -- {r.source}"))
        else:
            to_run.append(r)

    # ---- pass 3: run each distinct command once ----------------------------
    cache = {}
    for r in to_run:
        if r.source not in cache:
            print(f"claimcheck: running  {r.source}", file=sys.stderr)
            cache[r.source] = run(r.source, root, args.timeout)
        rc, out = cache[r.source]

        if REFUSAL.search(out):
            why = next((l.strip() for l in out.splitlines() if REFUSAL.search(l)), "the gate declined to answer")
            unverifiable.append((r, "REFUSED", f"the gate declined to answer -- {why[:160]}"))
            continue
        if rc == 2:
            unverifiable.append((r, "REFUSED", "exit 2: the house code for 'this run is not evidence'"))
            continue
        if rc in (124, 127):
            unverifiable.append((r, "REFUSED", f"the command could not complete (rc={rc})"))
            continue

        if r.guard and re.search(r.guard, out, re.M):
            unverifiable.append((r, "REFUSED",
                                 f"the gate's own guard fired (/{r.guard}/): it produced a number, "
                                 f"but not one that measures this claim"))
            continue
        try:
            pat = re.compile(r.extract, re.M)
        except re.error as e:
            errs.append(f"CLAIMS.tsv:{r.lineno}: bad EXTRACT regex: {e}")
            continue
        found = pat.findall(out)
        if not found:
            unverifiable.append((r, "NO NUMBER",
                                 f"the command produced no match for /{r.extract}/ "
                                 f"(rc={rc}). Either the summary line moved or the gate did not get that far."))
            continue
        got = found[-1]
        if isinstance(got, tuple):
            got = got[0]
        got = got.strip()
        if got == r.number:
            ok.append((r, got))
        else:
            wrong.append((r, "WRONG",
                          f"document says {r.number!r}; `{r.source}` printed {got!r}.\n"
                          f"                  paste what the gate printed -- do not average, round or guess."))

    # ---- pass 4: the sweep -------------------------------------------------
    undeclared = []
    if args.sweep:
        anchored = [r.anchor for r in rows]
        for rel in sweeps:
            p = os.path.join(root, rel)
            if not os.path.exists(p):
                errs.append(f"CLAIMS.tsv: SWEEP names {rel}, which does not exist")
                continue
            pats = ignores.get(rel, [])
            for i, line in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
                if not NUMBERISH.search(line):
                    continue
                if any(q.search(line) for q in pats):
                    continue
                if any(a in line for a in anchored):
                    continue
                undeclared.append((rel, i, line.strip()[:140]))

    # ---- report ------------------------------------------------------------
    W = "=" * 70
    print(W)
    print(f"claimcheck: {len(rows)} claim(s) declared in {os.path.relpath(manifest, root)}")
    print(W)
    for r, got in ok:
        print(f"  ok           {r.file}  {r.number}   <- {r.source}")
    for r, kind, why in declared:
        print(f"  declared     {r.file}  {r.number}   [{kind}] {why}")
    for r, kind, why in unverifiable:
        print(f"  UNVERIFIABLE {r.file}  {r.number}   [{kind}]")
        print(f"                  {why}")
        print(f"                  settle it with: {r.source}")
    for r, kind, why in wrong:
        print(f"  {kind:<12} {r.file}  {r.number}")
        print(f"                  {why}")
    if errs:
        print("  MANIFEST DRIFT")
        for e in errs:
            print(f"                  {e}")
    if undeclared:
        print(f"  UNDECLARED   {len(undeclared)} number(s) in swept files with no row naming a command:")
        for rel, i, line in undeclared:
            print(f"                  {rel}:{i}: {line}")
        print("                  Each is either a claim (give it a row) or prose (add an IGNORE).")

    print(W)
    summary = (f"{args.label} claimcheck: {len(ok)}/{len(ok) + len(wrong) + len(unverifiable)} verified, "
               f"{len(wrong)} wrong, {len(unverifiable)} unverifiable, {len(declared)} declared-not-run"
               + (f", {len(errs)} manifest drift" if errs else "")
               + (f", {len(undeclared)} undeclared" if undeclared else ""))
    print(summary)
    print(W)

    if wrong or errs:
        return 1
    if unverifiable:
        print("Nothing disagreed, but something could not be checked. That is not a green run.")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
