#!/usr/bin/env python3
"""oracle.py — expected results for the jsonfast reader, from CPython's `json`.

Two things are recorded per file:

  OK  <path> <counts…> shash=<hex> isum=<hex>   the document CPython read
  ERR <path>                                     CPython rejected it

plus, per sampled PREFIX of the file:

  PFX <path> <nbytes> OK|ERR

The prefixes are the point. A corpus of valid documents only ever proves a
parser is permissive enough; almost every prefix of a valid document is
malformed in a different way, and ACCEPT/REJECT agreement on thousands of them
is the only cheap way to find a reader that is too permissive — which is the
dangerous direction for a JSON reader.

The digest deliberately does NOT include float formatting: `1e2` and `100.0`
are the same number and differently spelled, and holding a reader to CPython's
repr would be testing the wrong thing. Floats are compared by COUNT; strings by
a hash of their decoded bytes; integers by their exact sum.

Usage: oracle.py <out-manifest> (<file.json>... | @listfile)
"""

import json
import sys

MASK = (1 << 64) - 1
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3


class Digest(object):
    def __init__(self):
        self.counts = dict(obj=0, arr=0, str=0, int=0, flt=0,
                           true=0, false=0, null=0)
        self.shash = FNV_OFFSET
        self.isum = 0

    def feed_str(self, s):
        for b in s.encode("utf-8", "surrogatepass"):
            self.shash = ((self.shash ^ b) * FNV_PRIME) & MASK
        self.shash = ((self.shash ^ 0) * FNV_PRIME) & MASK

    def walk(self, v):
        if v is None:
            self.counts["null"] += 1
        elif v is True:
            self.counts["true"] += 1
        elif v is False:
            self.counts["false"] += 1
        elif isinstance(v, str):
            self.counts["str"] += 1
            self.feed_str(v)
        elif isinstance(v, int):
            self.counts["int"] += 1
            self.isum = (self.isum + v) & MASK
        elif isinstance(v, float):
            self.counts["flt"] += 1
        elif isinstance(v, list):
            self.counts["arr"] += 1
            for x in v:
                self.walk(x)
        elif isinstance(v, dict):
            self.counts["obj"] += 1
            for k, x in v.items():
                self.counts["str"] += 1        # the key is a string value too
                self.feed_str(k)
                self.walk(x)
        else:
            raise TypeError(type(v).__name__)


def digest_of(text):
    # object_pairs_hook keeps duplicate keys, which a strict reader must also
    # keep: `{"a":1,"a":2}` is two pairs, and a dict would silently drop one.
    d = Digest()
    d.walk(json.loads(text, object_pairs_hook=lambda ps: _Pairs(ps)))
    return d


class _Pairs(list):
    """A dict-like that keeps duplicates, so the digest sees every pair."""


def _walk_pairs(d, v):
    if isinstance(v, _Pairs):
        d.counts["obj"] += 1
        for k, x in v:
            d.counts["str"] += 1
            d.feed_str(k)
            _walk_pairs(d, x)
    elif isinstance(v, list):
        d.counts["arr"] += 1
        for x in v:
            _walk_pairs(d, x)
    elif v is None:
        d.counts["null"] += 1
    elif v is True:
        d.counts["true"] += 1
    elif v is False:
        d.counts["false"] += 1
    elif isinstance(v, str):
        d.counts["str"] += 1
        d.feed_str(v)
    elif isinstance(v, int):
        d.counts["int"] += 1
        d.isum = (d.isum + v) & MASK
    elif isinstance(v, float):
        d.counts["flt"] += 1
    else:
        raise TypeError(type(v).__name__)


def digest(text):
    v = loads(text)
    d = Digest()
    _walk_pairs(d, v)
    return d


def _no_constants(name):
    # CPython accepts NaN, Infinity and -Infinity by default. They are NOT
    # JSON (RFC 8259 has no such literals), and a reader that takes them is
    # more permissive than the format. Rejecting them here keeps the oracle
    # measuring JSON rather than CPython's extension to it.
    raise ValueError("non-standard constant: %s" % name)


def loads(text):
    return json.loads(text, object_pairs_hook=_Pairs,
                      parse_constant=_no_constants)


def accepts(text):
    try:
        loads(text)
        return True
    except Exception:                                # noqa: BLE001
        return False


def fingerprint(raw):
    """FNV-1a over the file's bytes, so the gate can tell if it MOVED.

    Half this machine's `.json` files are live state — editor sessions, package
    caches, Claude Code's own config, which rewrote itself mid-run and made a
    correct parser look wrong by two integers. A corpus that changes under the
    test is not a defect in the thing being tested, but it has to be DETECTED,
    or it reads as one.
    """
    h = FNV_OFFSET
    for b in raw:
        h = ((h ^ b) * FNV_PRIME) & MASK
    return h


PREFIX_SAMPLES = 48


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: oracle.py <out-manifest> "
                         "(<file.json>... | @listfile)\n")
        return 2
    out, paths = sys.argv[1], sys.argv[2:]
    if len(paths) == 1 and paths[0].startswith("@"):
        with open(paths[0][1:]) as fh:
            paths = [ln.strip() for ln in fh if ln.strip()]

    lines, oks, errs, prefixes = [], 0, 0, 0
    for path in paths:
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
            text = raw.decode("utf-8")
        except Exception:                            # noqa: BLE001
            # Not decodable as UTF-8: CPython and we would both be guessing.
            lines.append("SKIP\t%s\tnot-utf8" % path)
            continue
        try:
            d = digest(text)
            lines.append("OK\t%s\tfhash=%x\t%s\tshash=%x\tisum=%x" % (
                path, fingerprint(raw),
                "\t".join("%s=%d" % (k, v) for k, v in sorted(d.counts.items())),
                d.shash, d.isum))
            oks += 1
        except Exception:                            # noqa: BLE001
            lines.append("ERR\t%s\tfhash=%x" % (path, fingerprint(raw)))
            errs += 1
            continue

        # Prefix accept/reject agreement.
        step = max(1, len(raw) // PREFIX_SAMPLES)
        n = 0
        while n <= len(raw):
            chunk = raw[:n]
            try:
                verdict = "OK" if accepts(chunk.decode("utf-8")) else "ERR"
            except Exception:                        # noqa: BLE001
                verdict = "ERR"
            lines.append("PFX\t%s\t%d\t%s" % (path, n, verdict))
            prefixes += 1
            n += step

    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("manifest: %d accepted, %d rejected by CPython, %d prefix verdicts"
          % (oks, errs, prefixes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
