#!/usr/bin/env python3
"""Trailing comments on a CALL line that claim a mechanism the CALLEE does not implement.

VALIDATED, and that validation is the point: run against 50fab6e4^ it finds the ONE known
instance (SwapLib.sol:2209 -> swapOutDeleverAmt, "// amtNative clamped to LIVE debt", where
LevBase.swapOutDeleverAmt has ZERO references to debt); run against HEAD it reports 0. A
detector that reports 0 without ever having been shown to report 1 is unfalsifiable -- check
it against a commit where the instance existed before trusting a clean result.

    python3 tools/check-call-claims.py            # from evm/, scans src/**

This is the exact shape of the one confirmed false comment:

    ILevManagerDeliver(mgr).swapOutDeleverAmt(lp, wantUsd6 * 1e12);  // amtNative clamped to LIVE debt
                                                                    ^ claim about the CALLEE
    function swapOutDeleverAmt(...) { ... }   <- zero references to debt, no clamp

High precision by construction: the claim names a callee, the callee is resolved
in-tree, and its body is searched for the mechanism. Still CANDIDATES -- the
mechanism can legitimately live one frame deeper.
"""
import re, sys, pathlib
from collections import defaultdict

CLAIMS = {
    'clamp': (r'\bclamp(?:ed)?\s+(?:to|at|by)\b',
              r'\bmin\b|\bmax\b|Math\.min|Math\.max|\?\s*\w+\s*:|if\s*\([^)]*[<>]'),
    'cap':   (r'\bcapp?ed\s+(?:to|at|by)\b',
              r'\bmin\b|\bmax\b|Math\.min|if\s*\([^)]*[<>]'),
    'bound': (r'\bbounded\s+(?:to|at|by)\b',
              r'\bmin\b|\bmax\b|Math\.min|if\s*\([^)]*[<>]|require'),
    'rev':   (r'\breverts?\s+(?:if|when|on)\b', r'\brevert\b|\brequire\b'),
}

# index every function body in the tree
bodies = defaultdict(list)
files = [p for p in pathlib.Path('src').rglob('*.sol') if 'identity' not in str(p)]
SIG = re.compile(r'^\s*function\s+(\w+)\s*\(', re.M)
for p in files:
    src = p.read_text()
    for m in SIG.finditer(src):
        i = src.find('{', m.end())
        if i < 0:
            continue
        d, j = 0, i
        while j < len(src):
            if src[j] == '{':
                d += 1
            elif src[j] == '}':
                d -= 1
                if d == 0:
                    break
            j += 1
        body = src[i:j + 1]
        code = re.sub(r'//[^\n]*', '', re.sub(r'/\*.*?\*/', '', body, flags=re.S))
        bodies[m.group(1)].append((str(p), code))

CALL = re.compile(r'\.(\w+)\s*\([^;]*\)\s*;\s*//(.*)$')
hits = []
for p in files:
    for ln, line in enumerate(p.read_text().split('\n'), 1):
        m = CALL.search(line)
        if not m:
            continue
        callee, comment = m.group(1), m.group(2)
        for kind, (claim_re, impl_re) in CLAIMS.items():
            if not re.search(claim_re, comment, re.I):
                continue
            defs = bodies.get(callee)
            if not defs:
                continue                      # not resolvable in-tree; skip rather than guess
            if not any(re.search(impl_re, code) for _, code in defs):
                hits.append((str(p), ln, callee, kind, comment.strip()[:88],
                             [d[0] for d in defs]))

print(f"{len(hits)} call-site comments claim a mechanism the RESOLVED CALLEE lacks\n")
for f, ln, callee, kind, c, where in hits:
    print(f"  [{kind}] {f}:{ln}  -> {callee}()  defined in {', '.join(where)}")
    print(f"        // {c}")
