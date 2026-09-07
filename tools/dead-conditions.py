#!/usr/bin/env python3
"""Guards that cannot fire, because an earlier guard in the same function already returned.

THE SHAPE, measured in SwapLib.deleverEthOnDelivery:
    if (venue == address(0)) return 0;            // line 34
    ...
    if (venue == address(0) || amtNative == 0) return 0;   // line 47  <- half of this is dead

The second test re-asks a question the first already answered with a RETURN, so that operand
can never be true. It is not a bug, it is a lie about what the function can be handed — and it
makes a reader defend against a state the code has already excluded.

⛔ REPORTS, NEVER REWRITES. A repeat is not automatically dead: the variable may be reassigned
between the two guards, and a loop re-enters. Every hit needs a human to check for a write in
between, which is exactly why this prints file:line pairs instead of patching.
"""
import re, sys, pathlib, collections

GUARD = re.compile(r'^\s*if\s*\((.+?)\)\s*(?:return|revert)\b')
FUNC  = re.compile(r'^\s*function\s+(\w+)')

def operands(cond):
    """Split a guard into its top-level || operands — each is independently sufficient."""
    parts, depth, cur = [], 0, ""
    i = 0
    while i < len(cond):
        c = cond[i]
        if c == "(": depth += 1
        elif c == ")": depth -= 1
        if depth == 0 and cond[i:i+2] == "||":
            parts.append(cur.strip()); cur = ""; i += 2; continue
        cur += c; i += 1
    if cur.strip(): parts.append(cur.strip())
    return [p.strip() for p in parts if p.strip()]

hits = 0
for f in sys.argv[1:]:
    p = pathlib.Path(f)
    if not p.is_file(): continue
    L = p.read_text(errors="ignore").splitlines()
    fn, seen = None, {}
    for i, raw in enumerate(L, 1):
        line = re.sub(r'//.*$', '', raw)
        m = FUNC.match(line)
        if m:
            fn, seen = m.group(1), {}
            continue
        g = GUARD.match(line)
        if not g or fn is None: continue
        for op in operands(g.group(1)):
            key = re.sub(r'\s+', '', op)
            if key in seen:
                print(f"{f}:{i}  in {fn}()")
                print(f"    operand : {op}")
                print(f"    already returned at :{seen[key]} — check for a write in between")
                hits += 1
            else:
                seen[key] = i
print(f"\n{hits} repeated guard operand(s) to check" if hits else "\nno repeated guard operands ✅")
