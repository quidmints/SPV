#!/usr/bin/env python3
"""Census of comment sites naming a symbol that no longer exists in CODE.

Rule 20 in instrument form: the question "is this comment stale" is answered from
the code, never from other prose. So the corpus of "what exists" is built from
source with every comment STRIPPED — otherwise a symbol that survives only in the
comments that mention it would vote for its own liveness.

A declaration COUNTS as existing here (unlike the caller census, which must
subtract declarations — that is the check-orphans.py trap). The question is
"does this name still appear in the program", not "does anything call it".
"""
import pathlib, re, collections, sys

ROOT = pathlib.Path(".")
SRC = [p for d in ("evm/src", "evm/script", "evm/test", "quid-ln") for p in ROOT.glob(f"{d}/**/*")
       if p.suffix in (".sol", ".rs") and p.is_file()]

line_c  = re.compile(r'//.*$', re.M)
block_c = re.compile(r'/\*.*?\*/', re.S)

def strip(t):
    return line_c.sub("", block_c.sub("", t))

code_corpus = []
for p in SRC:
    try: code_corpus.append(strip(p.read_text(errors="ignore")))
    except Exception: pass
CODE = "\n".join(code_corpus)
code_idents = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', CODE))

# candidate symbols = backticked identifiers inside comments
tick = re.compile(r'`([A-Za-z_][A-Za-z0-9_]*)(?:\(\))?`')
targets = sys.argv[1:] or [str(p) for p in SRC if "evm/src" in str(p) or "quid-ln" in str(p)]

hits  = collections.defaultdict(list)
maybe = collections.defaultdict(list)
for f in targets:
    p = pathlib.Path(f)
    if not p.is_file(): continue
    for i, l in enumerate(p.read_text(errors="ignore").splitlines(), 1):
        s = l.strip()
        if not (s.startswith("//") or s.startswith("*") or s.startswith("///")): continue
        for m in tick.finditer(l):
            n = m.group(1)
            if len(n) < 4: continue
            if n in code_idents:
                continue
            # ⚠️ NEITHER SUBSTRING RULE IS RIGHT ON ITS OWN — BOTH ERRORS WERE MEASURED.
            #   Suppressing nothing: `ChopIsBenign` reported dead, but it is the tail of the
            #     live test `test_RunSim_IL_Baseline_ChopIsBenign` (Alles.t.sol:3533). The
            #     tokenizer matches WHOLE identifiers, so a comment naming the distinctive
            #     half of a longer symbol has no token of its own and reads as gone.
            #   Suppressing every substring: `trackOpen` is GENUINELY dead, and got
            #     suppressed because `untrackOpen` contains it.
            # So a substring hit is neither "dead" nor "live" — it is CHECK BY HAND, and it
            # goes in its own bucket rather than silently joining either answer.
            owner = next((ident for ident in code_idents if n in ident), None)
            (maybe if owner else hits)[str(p)].append((i, n, owner) if owner else (i, n))

tot = 0
for f in sorted(hits, key=lambda k: -len(hits[k])):
    syms = sorted({n for _, n in hits[f]})
    print(f"{len(hits[f]):4d}  {f}")
    print(f"       {', '.join(syms)}")
    tot += len(hits[f])
print(f"\nTOTAL {tot} comment sites naming {len({n for v in hits.values() for _, n in v})} dead symbols")
if maybe:
    m = {(n, o) for v in maybe.values() for _, n, o in v}
    print(f"\n⚠️  {len(m)} CHECK BY HAND — the word is a substring of a live identifier, which")
    print("   means EITHER it is that identifier's distinctive half (live) OR a shorter name")
    print("   the longer one merely contains (dead). Grep at a word boundary to decide:")
    for n, o in sorted(m)[:40]:
        print(f"     {n:<34} inside  {o}")
