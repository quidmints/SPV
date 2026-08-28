#!/usr/bin/env python3
"""Audit every passport profile's generics against what the circuit actually asserts.

  python3 tools/check-passport-profiles.py

WHY THIS EXISTS. A profile is 14 compile-time constants, and a wrong one produces a verifier that is
either degenerate (proves nothing) or unbuildable. Three such profiles reached the manifest before
this check existed - `21_160_1_2_560_576_NA`, `14_256_1_4_1752_576_1_1496_3_512` and
`1_256_1_5_2376_336_1_2120_4_512`, all declaring `dg1` with length 0, i.e. a passport circuit that
reads NO MRZ. Two of them were added and quarantined on the same day.

THE INVARIANTS ARE TRANSCRIBED, NOT INVENTED. They come from
`backend/circuits/noir_dl_lib/src/not_passports_zk_circuits.nr:117-125`:

    for i in 0..DG_HASH_ALGO { assert(dg1_hash[i]  == ec[i + DG1_SHIFT])  }
    for i in 0..DG_HASH_ALGO { assert(dg15_hash[i] == ec[i + DG15_SHIFT]) }   // DG15_LEN != 0
    for i in 0..HASH_ALGO    { assert(ec_hash[i]   == sa[i + EC_SHIFT])   }

**GETTING THESE FROM MEMORY PRODUCED THREE FALSE POSITIVES.** An earlier pass compared `EC_SHIFT`
against `EC_LEN` (it indexes `sa`, not `ec`) and used `DG_HASH_ALGO` for the `ec_hash` loop (it uses
`HASH_ALGO`), flagging four healthy profiles. If you change these, re-read the circuit first.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "backend/circuits/passport-profiles.json"
CIRCUIT = ROOT / "backend/circuits/noir_dl_lib/src/not_passports_zk_circuits.nr"


def check(name: str, g: dict) -> list[str]:
    dgh, h = g["DG_HASH_ALGO"], g["HASH_ALGO"]
    bad = []

    # A zero-length buffer means the circuit cannot see that input at all. `dg1` is the MRZ: a
    # profile with DG1_LEN == 0 proves nothing about a document, and beta.26 refuses to compile it.
    for field in ("DG1_LEN", "EC_LEN", "SA_LEN", "N"):
        if g[field] == 0:
            bad.append(f"{field}=0 — the circuit reads no {field.split('_')[0].lower()}")

    # Every shift is an index into a FIXED-size array; the hash written at that offset must fit.
    if g["DG1_SHIFT"] + dgh > g["EC_LEN"]:
        bad.append(f"DG1_SHIFT {g['DG1_SHIFT']}+{dgh} overruns EC_LEN {g['EC_LEN']}")
    if g["DG15_LEN"] and g["DG15_SHIFT"] + dgh > g["EC_LEN"]:
        bad.append(f"DG15_SHIFT {g['DG15_SHIFT']}+{dgh} overruns EC_LEN {g['EC_LEN']}")
    if g["EC_SHIFT"] + h > g["SA_LEN"]:
        bad.append(f"EC_SHIFT {g['EC_SHIFT']}+{h} overruns SA_LEN {g['SA_LEN']}")

    # Active Authentication is gated on AA_SIG_TYPE != 0 and reads DG15. Asking for one without the
    # other is incoherent. The REVERSE is legal and common: DG15 present, hashed into EC, AA not
    # verified in-circuit — so it is deliberately NOT flagged.
    if g["AA_SIG_TYPE"] and not g["DG15_LEN"]:
        bad.append("AA_SIG_TYPE set but DG15_LEN=0 — active auth with nothing to read")
    if g["AA_SIG_TYPE"] and g["AA_SHIFT"] >= g["DG15_LEN"]:
        bad.append(f"AA_SHIFT {g['AA_SHIFT']} outside DG15_LEN {g['DG15_LEN']}")

    # The MRZ is 93 bytes on a TD3 passport and 95 on a TD1 card. Anything else is a decode error.
    if g["DG1_LEN"] not in (0, 93, 95):
        bad.append(f"DG1_LEN={g['DG1_LEN']} is neither TD3 (93) nor TD1 (95)")
    return bad


def main() -> int:
    if not CIRCUIT.exists():
        print(f"cannot find {CIRCUIT} — the invariants below are transcribed from it", file=sys.stderr)
        return 2

    profiles = json.loads(MANIFEST.read_text())["profiles"]
    failed = {n: b for n, g in profiles.items() if (b := check(n, g["generics"]))}

    print(f"checked {len(profiles)} live profiles against {CIRCUIT.name}")
    if not failed:
        print("OK — every profile's shifts land inside the buffers the circuit indexes")
        return 0

    for name, issues in failed.items():
        print(f"\n  {name}")
        for i in issues:
            print(f"      - {i}")
    print(f"\n{len(failed)} profile(s) would build a verifier that cannot verify a real document.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
