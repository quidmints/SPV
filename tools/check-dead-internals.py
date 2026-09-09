#!/usr/bin/env python3
"""Zero-caller scan for `internal`/`private` Solidity functions in `evm/src`.

WHY THIS IS ONLY VALID FOR internal/private, and why the tool refuses to do more:
CLAUDE.md measures the precision of a zero-caller scan on THIS tree at **1 in 5**, and it is
USELESS on entry points — an `external`/`public` function's callers are not in the repo and never
will be (a Morpho callback, an ERC-4626 obligation, the SPA encoding a signature). Scanning those
produces confident deletions of live code. So this walks declarations and SKIPS anything not
`internal` or `private`.

🔴 THE BUG THIS TOOL SHIPPED WITH, KEPT AS ITS OWN ACCEPTANCE TEST. The first version excluded
library-qualified calls — it matched `name(` with a negative lookbehind on `.`, so `SwapLib.plainNet(`
did not count — and reported EVERY function as zero-caller (`uses=1 decls=1`, the declaration
counting itself). This architecture calls almost everything as `Lib.fn()`, so the scan was inverted.
⇒ ACCEPTANCE TEST, run it before believing any output:

    `plainNet` MUST NOT appear in the output. It has three call sites
    (BtcLib.sol:381, Quid.sol:327, Quid.sol:515), all `SwapLib.plainNet(`.

A detector that cannot fail certifies. Run the KNOWN POSITIVE, never a clean run.

⚠️ AND A ZERO-CALLER HIT IS A QUESTION, NOT A VERDICT. Measured 2026-09-08 on a green tree, all four
hits were documented KEEPS: `Basket._lzReceive` (a LayerZero override whose caller is in the vendored
base, which `.graphifyignore` excludes), `OracleLib.curvePriceWad` x2 (unwired ON PURPOSE, §V-DOLLARS)
(`SwapLib._applySkew` was on this list and was DELETED 2026-09-09: its open design question
was moot once the charge became a flat fee.) Read what is written at the site before
deleting anything — an undecided design question is not a revival hypothetical.

Usage:  python3 tools/check-dead-internals.py     (from the repo root)
"""
import re, os
SKIP={'out','lib','cache','identity'}   # identity = generated verifiers, deferred
def strip(s):
    s=re.sub(r'/\*.*?\*/','',s,flags=re.S); return re.sub(r'//[^\n]*','',s)
files=[]
for r in ('evm/src',):
    for dp,dns,fns in os.walk(r):
        dns[:]=[d for d in dns if d not in SKIP]
        files+=[os.path.join(dp,f) for f in fns if f.endswith('.sol')]
# whole-tree CODE corpus (comments stripped) for reference counting
corpus=[]
for r in ('evm/src','evm/test','evm/script'):
    for dp,dns,fns in os.walk(r):
        dns[:]=[d for d in dns if d in ('.',) or d not in ('out','lib','cache')]
        for f in fns:
            if f.endswith('.sol'):
                try: corpus.append(strip(open(os.path.join(dp,f),errors='ignore').read()))
                except: pass
code='\n'.join(corpus)
rows=[]
for p in files:
    src=strip(open(p).read())
    for m in re.finditer(r'function\s+(\w+)\s*\(([^)]*)\)([^{;]*)[{;]', src, re.S):
        name,vis = m.group(1), m.group(3)
        if not re.search(r'\b(internal|private)\b', vis): continue
        # count CALL references: name followed by '(' , minus its own declarations
        uses = len(re.findall(r'\b'+re.escape(name)+r'\s*\(', code))
        decls= len(re.findall(r'function\s+'+re.escape(name)+r'\s*\(', code))
        if uses - decls <= 0:
            rows.append((p, name, vis.strip()[:40], uses, decls))
for p,n,v,u,d in sorted(rows): print(f"{p:44s} {n:36s} uses={u} decls={d}")
print(f"\n{len(rows)} internal/private functions with ZERO call references")
