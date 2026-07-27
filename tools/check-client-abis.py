#!/usr/bin/env python3
"""Compare the SPA's hand-written ABI signatures against the compiled contract ABIs.

Catches the class of drift that shipped undetected as §A.5-D1: `spa/src/lib/abi.ts` declared
`get_deposits() returns (uint[13], uint[13], ...)` while the contract returns `uint[15]`. With static
arrays that shifts the head, so every field AFTER the arrays decodes from inside them — silently wrong
numbers on screen, no error anywhere.

Usage:  python3 tools/check-client-abis.py            (from the repo root)
Exit 1 if any signature drifts. Requires `forge build` to have been run.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT  = ROOT / "evm" / "out"
ABI  = ROOT / "spa" / "src" / "lib" / "abi.ts"

def norm(t: str) -> str:
    t = t.strip()
    t = re.sub(r"\buint\b(?!\d)", "uint256", t)
    t = re.sub(r"\bint\b(?!\d)", "int256", t)
    return re.sub(r"\s+", "", t)

def sig_from_artifact(entry) -> str:
    def ty(c):
        return c["type"]
    return f'{entry["name"]}({",".join(norm(ty(i)) for i in entry.get("inputs", []))})'

def ret_from_artifact(entry) -> str:
    return ",".join(norm(o["type"]) for o in entry.get("outputs", []))

# index every compiled function: name(argtypes) -> returns
compiled = {}
for f in OUT.rglob("*.json"):
    try:
        art = json.loads(f.read_text())
    except Exception:
        continue
    for e in art.get("abi", []) or []:
        if e.get("type") != "function":
            continue
        compiled.setdefault(sig_from_artifact(e), set()).add(ret_from_artifact(e))

if not compiled:
    print("no compiled ABIs found under evm/out — run `forge build` first", file=sys.stderr)
    sys.exit(2)

drift, checked = [], 0
for raw in re.findall(r"'(function [^']+)'", ABI.read_text()):
    m = re.match(r"function\s+(\w+)\s*\((.*?)\)\s*(?:external|public|view|pure|returns|$)", raw)
    if not m:
        continue
    name, args = m.group(1), m.group(2)
    argtypes = [norm(a.split()[0]) for a in args.split(",") if a.strip()]
    key = f'{name}({",".join(argtypes)})'
    if key not in compiled:
        continue                       # not one of ours (ERC20 helpers etc.) — skip, don't guess
    checked += 1
    rm = re.search(r"returns\s*\((.*)\)\s*$", raw)
    declared = ",".join(norm(x.split()[0]) for x in rm.group(1).split(",")) if rm else ""
    if declared not in compiled[key]:
        drift.append((key, declared, sorted(compiled[key])))

for key, declared, actual in drift:
    print(f"DRIFT  {key}\n   spa declares: ({declared})\n   contract has: {[f'({a})' for a in actual]}")
print(f"\nchecked {checked} signatures against evm/out; {len(drift)} drifted")
sys.exit(1 if drift else 0)
