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

def split_args(s: str):
    """Split an arg list on TOP-LEVEL commas only. A naive `s.split(",")` splits inside
    `tuple(a, b, c)`, which mangles the key for EVERY function taking a struct — so every
    such function silently failed the `key in compiled` test below and was skipped as
    "not one of ours". That hid a real arity drift in openChannel (2026-08-07)."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out

def type_of(a: str) -> str:
    """The TYPE of one declared arg. `a.split()[0]` is wrong for a struct: it yields
    `tuple(bytes32` and loses the rest. solc's ABI calls a struct input just "tuple"
    (fields live in `components`), so collapse the whole balanced group to that token,
    keeping any `[]` suffix."""
    a = a.strip()
    if a.startswith("tuple("):
        depth = 0
        for i, ch in enumerate(a):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    rest = a[i + 1:].strip()
                    return "tuple" + (rest.split()[0] if rest.startswith("[") else "")
    return a.split()[0]

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

# Functions the SPA calls on contracts this repo does NOT compile (external protocols).
# Deliberately a dict, not a set: an entry must carry the REASON it is not ours, because an
# unmatched name is otherwise indistinguishable from one that was deleted from our contracts.
# Empty today — every unmatched name found on 2026-08-10 turned out to be ours-and-removed.
EXTERNAL_OK: dict = {}

drift, checked = [], 0
for raw in re.findall(r"'(function [^']+)'", ABI.read_text()):
    m = re.match(r"function\s+(\w+)\s*\((.*?)\)\s*(?:external|public|view|pure|returns|$)", raw)
    if not m:
        continue
    name, args = m.group(1), m.group(2)
    argtypes = [norm(type_of(a)) for a in split_args(args) if a.strip()]
    key = f'{name}({",".join(argtypes)})'
    if key not in compiled:
        # ⚠️ THE FIX THAT MATTERS. This used to `continue` unconditionally, so a signature
        # whose ARGUMENTS had drifted was indistinguishable from an ERC20 helper we never
        # compiled — the single most likely kind of drift was the one kind we could not see.
        # If the NAME exists on one of our contracts, an unmatched key IS drift.
        same_name = sorted(k for k in compiled if k.startswith(name + "("))
        if same_name:
            drift.append((key, "ARG DRIFT — no such signature", same_name))
        elif name not in EXTERNAL_OK:
            # ⚠️ THE SECOND HOLE, closed 2026-08-10 (E154). The `continue` below used to be
            # unconditional, on the assumption that a name matching NOTHING is an external
            # contract's. That assumption was false in both cases it covered: `exitInstant`
            # (deleted from Vogue 2026-08-09 — and the SPA still ENCODED A CALL to it, which
            # would hit the fallback and revert) and `recordSpliceOut` (never existed at all).
            # So the most severe drift — the function is GONE — was the one kind invisible here,
            # while mere argument drift was caught. Absence must be louder than mismatch, not
            # quieter. A genuine external belongs in EXTERNAL_OK with a reason.
            drift.append((key, "ORPHAN — no contract has a function of this name", []))
        continue
    checked += 1
    rm = re.search(r"returns\s*\((.*)\)\s*$", raw)
    declared = ",".join(norm(x.split()[0]) for x in rm.group(1).split(",")) if rm else ""
    if declared not in compiled[key]:
        drift.append((key, declared, sorted(compiled[key])))

for key, declared, actual in drift:
    print(f"DRIFT  {key}\n   spa declares: ({declared})")
    print(f"   contract has: {[f'({a})' for a in actual] if actual else 'NOTHING — no function of this name exists'}")
print(f"\nchecked {checked} signatures against evm/out; {len(drift)} drifted")
sys.exit(1 if drift else 0)
