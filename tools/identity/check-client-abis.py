#!/usr/bin/env python3
"""
Cross-check every ethers ABI signature declared in the wallet's TypeScript against the real
compiled Solidity ABIs in forge's `out/`.

This catches the class of bug `tsc --strict` structurally cannot: ethers ABIs are plain STRINGS, so
a TS file can name a Solidity function that was renamed or deleted and still typecheck perfectly,
then revert at runtime. Every contract change we made to the PP fork is a candidate for this.

CONTRACT-AWARE SINCE 2026-07-27, AND THAT IS THE WHOLE POINT. The first version aggregated every
compiled contract into one name-keyed table and asked only "does this signature exist SOMEWHERE?".
That let a real break through: when the ASP tree moved out of Entrypoint into IdentityAspRegistry,
the wallet kept calling admitIdentity/isKnownAspRoot at the ENTRYPOINT address, and this script
stayed green the whole time - because the signatures did still exist, on a different contract. The
client would have reverted on the first call.

Each ABI array in TypeScript must therefore be preceded by a marker naming the contract it is sent
to:

    // @contract IdentityAspRegistry
    const ASP_REGISTRY_ABI = [ ... ];

and every signature in that array is checked against THAT contract only. An ABI array with no
marker is an ERROR, not a skip - otherwise the blind spot silently reopens the moment someone adds
a new client module.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TS_DIRS = [ROOT / "frontend/identity-wallet/src"]
OUT = ROOT / "backend/contracts/out"

# ---- 1. collect every function/event/error signature the compiled contracts actually expose ----
# name -> set of (inputs tuple), aggregated across every contract. Kept only to produce a better
# diagnostic ("exists, but on X") when a per-contract lookup fails.
onchain_funcs = {}
onchain_events = {}
# contract name -> {"functions": {name: {types}}, "events": {name: {types}}}
by_contract = {}
artifact_paths = {}  # contract -> {abi fingerprint -> [paths]}
for artifact in OUT.rglob("*.json"):
    try:
        data = json.loads(artifact.read_text())
    except Exception:
        continue
    abi = data.get("abi")
    if not isinstance(abi, list):
        continue
    contract = artifact.stem  # forge writes out/<Source>.sol/<Contract>.json
    # STALE-ARTIFACT GUARD. `out/` can hold two artifacts for one contract name when a source file
    # moves - e.g. out/Entrypoint.sol/ and a leftover out/pool/Entrypoint.sol/. Merging them makes
    # a REMOVED function look present, which silently defeats the whole point of this script: it is
    # exactly how pointing the wallet at the wrong contract kept passing. Record every path per
    # name and fail below if any name resolves to more than one differing ABI.
    fingerprint = tuple(sorted(
        (e.get("type", ""), e.get("name", ""), tuple(i.get("type", "") for i in e.get("inputs", [])))
        for e in abi if e.get("name")
    ))
    artifact_paths.setdefault(contract, {}).setdefault(fingerprint, []).append(str(artifact.relative_to(OUT)))
    slot = by_contract.setdefault(contract, {"function": {}, "event": {}})
    for entry in abi:
        t = entry.get("type")
        name = entry.get("name")
        if not name:
            continue
        types = tuple(i.get("type", "") for i in entry.get("inputs", []))
        if t == "function":
            onchain_funcs.setdefault(name, set()).add(types)
            slot["function"].setdefault(name, set()).add(types)
        elif t == "event":
            onchain_events.setdefault(name, set()).add(types)
            slot["event"].setdefault(name, set()).add(types)

# ---- 2. collect every signature the TypeScript declares in an ABI string ----
# Capture balanced-ish arg lists: tuples like "(address a,bytes b) x" appear inline in ethers
# human-readable ABIs, so a naive [^)]* stops at the first inner ")".
SIG_RE = re.compile(r'"\s*(function|event)\s+([A-Za-z_]\w*)\s*\((.*?)\)\s*(?:external|view|returns|"|,)')

def split_top_level(raw: str):
    """Split on commas that are NOT inside parentheses, so tuple components stay together."""
    parts, depth, cur = [], 0, ""
    for ch in raw:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts if p.strip()]


def norm_types(raw: str):
    out = []
    for part in split_top_level(raw):
        part = re.sub(r"\b(calldata|memory|storage|indexed)\b", " ", part).strip()
        if part.startswith("("):
            # solc reports struct params as "tuple" in the compiled ABI
            out.append("tuple")
            continue
        tok = part.split()
        if not tok:
            continue
        out.append(tok[0])
    return tuple(out)

# Contract names that resolve to MORE THAN ONE differing ABI in out/. Two distinct contracts may
# legitimately share a name across different source paths (PoseidonUnit2L/3L really do), so this is
# not fatal on its own - it only matters if a client actually targets that name, which is checked
# per-reference below. A leftover artifact from a moved source file lands here too, and that case
# IS fatal: merging it would make a DELETED function look present, which is precisely how pointing
# the wallet at the wrong contract went unnoticed.
ambiguous = {c: v for c, v in artifact_paths.items() if len(v) > 1}

problems = []
checked = 0

# An ABI array declaration, and the `// @contract X` marker that must precede it.
ABI_DECL_RE = re.compile(r"^\s*(?:export\s+)?const\s+(\w*ABI\w*)\s*(?::[^=]+)?=\s*\[", re.M)
MARKER_RE = re.compile(r"//\s*@contract\s+([A-Za-z_]\w*)")


def owning_contract(text: str, decl_start: int):
    """The @contract marker in the comment block immediately above a declaration."""
    head = text[:decl_start]
    # look only at the last few lines, so a marker for an earlier block cannot be borrowed
    tail = "\n".join(head.split("\n")[-25:])
    hits = MARKER_RE.findall(tail)
    return hits[-1] if hits else None


for d in TS_DIRS:
    for ts in d.rglob("*.ts"):
        text = ts.read_text(encoding="utf-8", errors="replace")
        rel = ts.relative_to(ROOT)

        # Map each ABI array's character span to the contract it targets.
        spans = []
        for dm in ABI_DECL_RE.finditer(text):
            end = text.find("]", dm.end())
            end = len(text) if end == -1 else end
            owner = owning_contract(text, dm.start())
            line = text[: dm.start()].count("\n") + 1
            if owner is None:
                problems.append(
                    (f"{rel}:{line}", "abi-block", dm.group(1), (),
                     "NO `// @contract <Name>` MARKER - cannot tell which contract this is sent to")
                )
            spans.append((dm.start(), end, owner, dm.group(1)))

        def span_for(pos):
            for a, b, owner, var in spans:
                if a <= pos <= b:
                    return owner, var
            return None, None

        for m in SIG_RE.finditer(text):
            kind, name, raw_args = m.group(1), m.group(2), m.group(3)
            checked += 1
            types = norm_types(raw_args)
            line = text[: m.start()].count("\n") + 1
            owner, var = span_for(m.start())

            if owner is None:
                # Signature outside any marked ABI array (or in an unmarked one) - already reported.
                continue

            if owner in ambiguous:
                where = sorted(p for paths in ambiguous[owner].values() for p in paths)
                problems.append((f"{rel}:{line}", kind, name, types,
                                 f"@contract {owner} is AMBIGUOUS - {len(where)} artifacts with "
                                 f"different ABIs: {where}. If one is a leftover from a moved "
                                 f"source file, run `forge clean && forge build`."))
                continue

            slot = by_contract.get(owner)
            if slot is None:
                problems.append((f"{rel}:{line}", kind, name, types,
                                 f"declared @contract {owner}, but no such compiled contract"))
                continue

            table = slot[kind]
            if name not in table:
                # The old check would have PASSED here if any other contract had it - which is
                # exactly how the Entrypoint/IdentityAspRegistry break stayed green.
                elsewhere = sorted(
                    c for c, sl in by_contract.items() if name in sl[kind]
                )
                hint = f"; exists on: {elsewhere[:6]}" if elsewhere else ""
                problems.append((f"{rel}:{line}", kind, name, types,
                                 f"NOT ON {owner}{hint}"))
            elif types not in table[name]:
                problems.append((f"{rel}:{line}", kind, name, types,
                                 f"arg mismatch on {owner}; variants: {sorted(table[name])}"))

print(f"checked {checked} ABI signatures declared in TypeScript\n")
if not problems:
    print("OK - every declared signature matches a real compiled contract signature")
    sys.exit(0)
print(f"{len(problems)} MISMATCH(ES):\n")
for loc, kind, name, types, why in problems:
    print(f"  {loc}\n    {kind} {name}{types}\n    -> {why}\n")
sys.exit(1)
