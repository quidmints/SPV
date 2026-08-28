#!/usr/bin/env python3
"""The query circuit's public-signal ORDER must match what Solidity reads at fixed offsets.

WHY THIS EXISTS (GAP 2, 2026-08-03). `query_identity`/`query_identity_td1` were recorded as having
"zero #[test]", but the selector logic they wrap IS tested - 14 tests in `noir_dl_lib/src/query.nr`
cover which bits disclose what. What NOTHING covered is the seam between the two artifacts:

  * the circuit returns 23 public signals, and their ORDER is decided by a tuple literal in main.nr
  * `sdk/lib/PublicSignalsBuilder.sol` writes each signal at a HARDCODED assembly offset
    (`mstore(add(dataPointer_, 416), selector_)`, documented as "index 12")

Neither side can see the other. Transpose two entries in the tuple, or shift one offset, and
everything still compiles, every Noir test still passes, every Forge test still passes - and the
verifier then reads `timestampUpperbound` out of the slot holding `timestampLowerbound`. The proof
verifies. It just means something else. That is the same class of defect as the LeanIMT sibling
ordering and the relay `context` pin, both of which this repo already guards with cross-artifact
checks rather than more same-language tests.

Run after touching either file:  python3 tools/check-query-public-signals.py
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CIRCUIT = ROOT / "backend/circuits/query_identity/src/main.nr"
BUILDER = ROOT / "backend/contracts/contracts/sdk/lib/PublicSignalsBuilder.sol"

# The first nine signals come from the library's own return tuple (`tmp.0` .. `tmp.8`) and are not
# named in the wrapper, so this check covers indices 9-22: everything main.nr names for itself.
FIRST_LIBRARY_SIGNALS = 9


# Deliberate, reviewed equivalences - NOT a loosening of the check. The two artifacts spell the same
# signal differently, and each pair was confirmed to be the same value in the same slot:
#   identity_count_* (circuit, matching noir_dl::query's parameter names)
#   identityCounter* (Solidity, matching the rarimo SDK's vocabulary)
# Anything NOT listed here must match exactly, so a genuine transposition still fails.
ALIASES = {
    "identitycountlowerbound": "identitycounterlowerbound",
    "identitycountupperbound": "identitycounterupperbound",
}


def normalise(name: str) -> str:
    flat = name.replace("_", "").lower()
    return ALIASES.get(flat, flat)


def circuit_order() -> list[str]:
    """The tuple main() returns, in order. Index N here is public signal N."""
    src = CIRCUIT.read_text()
    tail = src[src.rindex("(tmp.0"):]
    tuple_body = tail[: tail.index(")")]
    return [item.strip() for item in tuple_body.lstrip("(").split(",")]


def solidity_order() -> dict[int, str]:
    """Every signal Solidity writes, keyed by index, taken from the ASSEMBLY OFFSET rather than the
    doc comment - the offset is what actually runs. Slot 0 sits at offset 32 (the array's length
    word occupies the first slot), so index = offset/32 - 1."""
    src = BUILDER.read_text()
    found: dict[int, str] = {}
    for match in re.finditer(r"mstore\(add\(dataPointer_,\s*(\d+)\),\s*([A-Za-z_][A-Za-z0-9_]*)\)", src):
        offset, symbol = int(match.group(1)), match.group(2)
        if symbol == "ZERO_DATE":       # defaults written by the initialiser, not a named signal
            continue
        index = offset // 32 - 1
        found.setdefault(index, symbol.rstrip("_"))
    return found


def main() -> int:
    circuit = circuit_order()
    solidity = solidity_order()

    problems: list[str] = []
    checked = 0

    if len(circuit) != 23:
        problems.append(f"main.nr returns {len(circuit)} signals, expected 23")

    for index, sol_name in sorted(solidity.items()):
        if index < FIRST_LIBRARY_SIGNALS:
            continue                     # produced by the library, not named in the wrapper
        if index >= len(circuit):
            problems.append(f"Solidity writes index {index} ({sol_name}) but the circuit emits only "
                            f"{len(circuit)} signals")
            continue
        checked += 1
        if normalise(circuit[index]) != normalise(sol_name):
            problems.append(f"index {index}: circuit emits {circuit[index]!r} but Solidity writes "
                            f"{sol_name!r} there")

    # A check that verifies nothing is worse than no check - this repo has shipped one such already.
    if checked == 0:
        problems.append("matched no signals at all - the parser is not reading one of the files")

    print(f"  circuit: {len(circuit)} public signals from {CIRCUIT.relative_to(ROOT)}")
    print(f"  solidity: {len(solidity)} named writes in {BUILDER.relative_to(ROOT)}")
    print(f"  compared: {checked} signals (indices {FIRST_LIBRARY_SIGNALS}+; earlier ones come from "
          f"the library's return tuple)")

    if problems:
        print("\nMISMATCH - a proof would verify while meaning something else:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print("\nOK - every named public signal sits at the index Solidity reads it from")
    return 0


if __name__ == "__main__":
    sys.exit(main())
