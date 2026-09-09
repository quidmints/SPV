#!/usr/bin/env python3
"""blast-radius.py — who else compiles this file, and which lane owns them.

WHY THIS EXISTS: SPRINT.md §COMPILE-COUPLING. The lane partition is cut on FILES; the
compiler is not. Two lanes that stage no common path can still compile a common header,
and THAT break merges CLEAN and lands in the parent -- the lane's own green build proves
nothing. Measured 2026-09-07: imports/LevMath.sol is L4's, and three of L5's four files
import it; four of its signatures moved in one day.

    tools/blast-radius.py imports/LevMath.sol      # or a bare basename, or a full path

⛔ IT FAILS LOUDLY, NEVER SILENTLY. CLAUDE.md §Tooling-traps: every tool trap measured in
this repo failed with exit 0 and no output. So: an unparseable lane table is a hard error,
not an empty map that would report every file as unowned and read like good news.
"""
import os, re, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "evm/src")
TABLE = os.path.join(ROOT, "docs/actionable/SPRINT.md")
# Lane BOOKS were abolished 2026-09-09; the lane TABLE moved into SPRINT.md under §LANES.
# ⛔ Parse ONLY between the markers: SPRINT.md carries a SECOND `| L1 | ... |` table from an
#    older partition (~line 10,335, where L1 is Core.sol rather than .md). Taking the first
#    match reports confident, wrong ownership -- silently.
BEGIN, END = "<!-- LANE-TABLE:BEGIN -->", "<!-- LANE-TABLE:END -->"

def lane_map():
    """Parse the ONE source of truth rather than hardcoding a copy that goes stale."""
    if not os.path.exists(TABLE):
        sys.exit(f"FATAL: no lane table at {TABLE} — cannot say who owns what.")
    owner = {}
    body = open(TABLE).read()
    if BEGIN not in body or END not in body:
        sys.exit(f"FATAL: no {BEGIN} .. {END} fence in {TABLE} -- refusing to guess which lane table "
                 f"is canonical. Restore the fence rather than relaxing this check.")
    for line in body.split(BEGIN, 1)[1].split(END, 1)[0].splitlines():
        m = re.match(r"\|\s*(L\d)\s*\|(.*?)\|", line)
        if m:
            for f in re.findall(r"`([^`]+\.sol)`", m.group(2)):
                owner[os.path.basename(f)] = m.group(1)
    if not owner:
        sys.exit(f"FATAL: parsed 0 files out of {TABLE}. The table format changed; fix this "
                 f"script rather than trusting an empty map.")
    return owner

def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    target = os.path.basename(sys.argv[1])
    owner = lane_map()

    files = [os.path.relpath(os.path.join(d, f), SRC)
             for d, _, fs in os.walk(SRC) for f in fs if f.endswith(".sol")]
    if not any(os.path.basename(f) == target for f in files):
        sys.exit(f"FATAL: no {target} under evm/src — check the name.")

    hits = collections.defaultdict(list)
    for rel in files:
        txt = open(os.path.join(SRC, rel)).read()
        if any(os.path.basename(p) == target for p in re.findall(r'from\s+"([^"]+\.sol)"', txt)):
            hits[owner.get(os.path.basename(rel), "UNOWNED")].append(rel)

    mine = owner.get(target, "UNOWNED")
    print(f"\n{target}  —  owned by: {mine}")
    print(f"imported by {sum(len(v) for v in hits.values())} file(s) under evm/src\n")
    for lane in sorted(hits, key=lambda l: (l == "UNOWNED", l)):
        for rel in sorted(hits[lane]):
            print(f"  {lane:<8} {rel}")

    others = sorted(l for l in hits if l not in ("UNOWNED", mine))
    print()
    if others:
        print(f"🔴 SERIAL WITH {', '.join(others)} — a signature change here merges CLEAN and")
        print( "   breaks the parent build. Announce it (SendMessage) before landing it.")
    if mine == "UNOWNED":
        print(f"⛔ {target} BELONGS TO NO LANE, so it is concurrent with every lane at once.")
        print( "   ADDITIONS ARE FREE; a signature or constant CHANGE must be announced first.")
    if not others and mine != "UNOWNED":
        print(f"✅ Only {mine}'s own files import it. No cross-lane coupling.")

main()
