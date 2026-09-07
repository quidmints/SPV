#!/usr/bin/env python3
"""check-doc-md.py — every `X.md` a doc cites, classified: FOLDED / RENAMED / TOMBSTONE.

The .md twin of tools/check-doc-symbols.py, which only covers `Something.sol`. Measured
2026-09-07: SPRINT.md cites 84 distinct .md files and 52 DO NOT EXIST, across 286 citations.

⚠️ THE POINT IS THE CLASSIFICATION, NOT THE COUNT. CLAUDE.md's RENAMES section already learned
this on the .sol side: "TOMBSTONE is WRONG for a third of them - the binary is the defect."
Three buckets, and only one is actionable:

  FOLDED    the file was folded INTO another and deleted; the content is LIVE under a § anchor.
            ⇒ DESTALE THE COORDINATE. This is the bucket that misleads, because the grep looks
            identical to a tombstone and the reader concludes the work was removed.
  RENAMED   a case variant or typo of a file that exists. ⇒ fix the spelling.
  TOMBSTONE deleted with no successor. ⇒ LEAVE IT. The citation is history, and "fixing" it into
            a name that resolves to nothing is strictly worse than an obviously-old name.

    tools/check-doc-md.py [doc ...]        # default: docs/actionable/SPRINT.md
"""
import os, re, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Verified folds. Each entry: cited name -> (anchor it folded into, the commit/date note).
FOLDS = {
    "QUEUE.md": ("§FROM-QUEUE", "deleted 2026-08-29; 150 work + 78 knowledge + 19 check rows re-triaged"),
    "BUILD-QUEUE-AND-107.md": ("§BUILD-QUEUE-FOLD", "folded in WHOLE 2026-08-29; -OPEN holds the 8 unique rows"),
    "REFILL-AND-RESTORATION.md": ("§REFILL fold at :31659", "folded verbatim 2026-08-29 — found 2026-09-07 while working E48, which still says 'build from REFILL-AND-RESTORATION.md'"),
}

def tree_md():
    names, paths = set(), set()
    for d, _, fs in os.walk(ROOT):
        if os.sep + ".git" in d: continue
        for f in fs:
            if f.endswith(".md"):
                names.add(f); paths.add(os.path.relpath(os.path.join(d, f), ROOT))
    return names, paths

def main():
    docs = sys.argv[1:] or ["docs/actionable/SPRINT.md"]
    names, paths = tree_md()
    if not names:
        sys.exit("FATAL: found zero .md files under the repo — the walk is wrong, not the docs.")
    rc = 0
    for doc in docs:
        full = os.path.join(ROOT, doc)
        if not os.path.exists(full): sys.exit(f"FATAL: no such doc {doc}")
        cites = collections.Counter(re.findall(r"([A-Za-z0-9._/-]+\.md)", open(full).read()))
        buckets = collections.defaultdict(list)
        for c, n in cites.items():
            base = os.path.basename(c)
            if c in paths or base in names: continue
            if base in FOLDS:                      buckets["FOLDED"].append((c, n))
            elif base.lower() in {x.lower() for x in names}: buckets["RENAMED"].append((c, n))
            else:                                  buckets["TOMBSTONE"].append((c, n))
        tot = sum(n for v in buckets.values() for _, n in v)
        print(f"\n{doc} — {len(cites)} distinct .md cited, {tot} citations do not resolve\n")
        for b, why in (("FOLDED",   "🔴 ACTIONABLE — content is LIVE; destale the coordinate"),
                       ("RENAMED",  "⚠️  fix the spelling"),
                       ("TOMBSTONE","✅ LEAVE IT — the citation is history")):
            rows = sorted(buckets[b], key=lambda x: -x[1])
            if not rows: continue
            print(f"  {b}  ({sum(n for _, n in rows)} citations)  {why}")
            for c, n in rows:
                extra = f"   -> {FOLDS[os.path.basename(c)][0]}  ({FOLDS[os.path.basename(c)][1]})" if b == "FOLDED" else ""
                print(f"    {n:>4}x  {c}{extra}")
            print()
            if b == "FOLDED": rc = 1
    sys.exit(rc)   # non-zero ONLY when a FOLDED citation is still stale — the actionable bucket

main()
