#!/usr/bin/env python3
"""EIP-170 guard that SEES LIBRARY-LINKED CONTRACTS — which `forge build --sizes` does not.

WHY THIS EXISTS (§E92/E92-a, 2026-08-05)
----------------------------------------
`forge build --sizes` omits any contract with unresolved `linkReferences`. `Core` delegatecalls
BasketLib, FeeLib and OracleLib, so its bytecode carries `__$<34 hex>$__` placeholders until link
time and it NEVER APPEARS in that table. Measured the day this was written: Core was 24,538 bytes
with **38 bytes** of EIP-170 margin, and nothing in the build could report it.

That matters because `forge test` does not enforce EIP-170 either, so `--sizes` was the only guard —
and it is structurally blind to exactly the contracts that need it. This repo has already shipped a
Core at -126 bytes (undeployable) with a fully green suite.

WHY THE MEASUREMENT IS EXACT, NOT AN APPROXIMATION
--------------------------------------------------
A link placeholder `__$<34 hex chars>$__` is 40 hex characters = 20 bytes, which is EXACTLY the size
of the address that replaces it at link time. So the unlinked artifact length equals the linked
deployed size, byte for byte. No adjustment is applied or needed.

USAGE
-----
    python3 tools/check-contract-sizes.py            # report + exit 1 on any violation
    python3 tools/check-contract-sizes.py --top 10   # also show the 10 tightest

Run `forge build` first — this reads `evm/out/`, it does not compile.
"""
import json
import pathlib
import sys

EIP170 = 24_576
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "evm" / "out"
SRC = ROOT / "evm" / "src"


def source_contract_names() -> set[str]:
    """Contract/library names declared under evm/src — the set we actually deploy."""
    names = set()
    for sol in SRC.rglob("*.sol"):
        for line in sol.read_text(errors="replace").splitlines():
            s = line.strip()
            for kw in ("contract ", "library "):
                if s.startswith(kw):
                    names.add(s[len(kw):].split()[0].split("{")[0].strip())
    return names


def main() -> int:
    if not OUT.is_dir():
        print(f"no artifacts at {OUT} — run `forge build` first", file=sys.stderr)
        return 2

    wanted = source_contract_names()
    rows, unreadable = [], []

    for art in OUT.rglob("*.json"):
        name = art.stem
        if name not in wanted:
            continue
        try:
            d = json.loads(art.read_text())
        except Exception as e:              # noqa: BLE001 - report, never silently skip
            unreadable.append((art.name, repr(e)))
            continue
        obj = (d.get("deployedBytecode") or {}).get("object") or ""
        if not obj or obj == "0x":          # interfaces / abstracts have no deployed code
            continue
        size = (len(obj) - 2) // 2
        linked = bool((d.get("bytecode") or {}).get("linkReferences"))
        rows.append((size, name, linked))

    if not rows:
        print("no deployable artifacts matched evm/src declarations", file=sys.stderr)
        return 2

    rows.sort(reverse=True)
    over = [r for r in rows if r[0] > EIP170]

    top = 5
    if "--top" in sys.argv:
        try:
            top = int(sys.argv[sys.argv.index("--top") + 1])
        except (IndexError, ValueError):
            pass

    print(f"EIP-170 = {EIP170} bytes; measured {len(rows)} deployable contracts from evm/src\n")
    print(f"{'contract':<28}{'size':>8}{'margin':>9}   linked")
    for size, name, linked in rows[:top]:
        print(f"{name:<28}{size:>8}{EIP170 - size:>9}   {'yes' if linked else 'no'}")

    # A contract invisible to `forge build --sizes` is the whole reason this script exists — say so
    # explicitly rather than letting it pass silently among the others.
    blind = [r for r in rows[:top] if r[2]]
    if blind:
        print("\nNOTE: the following are LIBRARY-LINKED and do NOT appear in `forge build --sizes`:")
        for size, name, _ in blind:
            print(f"  {name} ({size} bytes, {EIP170 - size} to spare)")

    if unreadable:
        print("\nUNREADABLE ARTIFACTS (not counted — absence here is not proof of safety):")
        for fn, err in unreadable:
            print(f"  {fn}: {err}")

    if over:
        print("\nEIP-170 VIOLATION — these cannot be deployed:")
        for size, name, _ in over:
            print(f"  {name}: {size} bytes ({size - EIP170} OVER)")
        return 1

    print(f"\nOK — tightest is {rows[0][1]} with {EIP170 - rows[0][0]} bytes to spare.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
