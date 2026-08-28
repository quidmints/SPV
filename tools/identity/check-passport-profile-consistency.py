#!/usr/bin/env python3
"""Self-consistency checks on passport circuit parameter tuples.

WHY THIS EXISTS. `passport-profiles.json` recovers each profile's 14 generics from rarimo's published
artifacts and cross-checks them against that artifact's OWN abi - `dg1`/`dg15`/`ec`/`sa`/`pk` array
lengths must equal DG1_LEN/DG15_LEN/EC_LEN/SA_LEN/N. **That check compares each length to itself and
nothing else.** It cannot see a tuple whose lengths are individually plausible but jointly impossible,
and three published profiles are exactly that.

WHAT IT MISSED, twice, both found only when a build failed hours later:

  * `21_160_1_2_560_576_NA`, `14_256_1_4_1752_576_1_1496_3_512`, `1_256_1_5_2376_336_1_2120_4_512`
    declare DG1_SHIFT == EC_LEN, so `assert(dg1_hash[i] == ec[i + DG1_SHIFT])` reads past `ec`.
    0 of the 78 working profiles do this.
  * `20_256_3_5_336_248_25_2120_5_1816` places an AA key at AA_SHIFT with 2*32 bytes to follow, in a
    dg15 of 283 - eight bytes short.

Both are arithmetic on numbers already in the manifest. Neither needed a document, a build, or a
container to detect. THAT is the point of this file: these are cheap checks that run in milliseconds
and would have moved both discoveries months earlier, from "a 32 GiB build failed" to "the manifest
refuses to load".

⚠️ ONE CHECK IS DELIBERATELY A WARNING, NOT AN ERROR. `EC_SHIFT + HASH_ALGO == SA_LEN` holds for 76
of 78 profiles - strong enough to be worth reporting, not strong enough to reject on. A check that
fires on correct input is a clamp, not a check.

Run: python3 tools/check-passport-profile-consistency.py
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "backend/circuits/passport-profiles.json"

AA_ECDSA_DEFAULT = 32

# GROUND TRUTH: the coordinate width each curve actually has. This is the table the code is checked
# AGAINST, not a copy of it - the whole point is to catch the code falling through to the 32-byte
# default for a curve that is not 32 bytes. AA_SIG_TYPE 24 (secp224r1) did exactly that, and the one
# profile using it had already been built and marked live before this check existed.
AA_CURVE_BYTES = {20: 32, 21: 32, 22: 40, 23: 24, 24: 28, 25: 48, 26: 64, 27: 66}


def aa_ecdsa_bytes() -> dict[int, int]:
    """Coordinate width `extract_dg15_pk_hash` ACTUALLY uses per AA_SIG_TYPE, parsed from the circuit.

    ⚠️ PARSED, NOT MIRRORED, and that is the point. This was a hand-written dict and it drifted the
    moment a branch was added to the circuit - the checker went on reporting a curve as wrong after it
    had been fixed. A copy of the code is a comment about the code, and goes stale the same way.
    """
    import re

    src = CIRCUIT.read_text()
    body = src[src.index("fn extract_dg15_pk_hash<"):]
    return {
        int(m.group(1)): int(m.group(2))
        for m in re.finditer(
            r"if \(AA_SIG_TYPE == (\d+)\)\s*\{[^}]*?EC_FIELD_SIZE = (\d+)", body, re.S
        )
    }


def aa_key_bytes(aa_sig_type: int) -> int:
    return AA_ECDSA_BYTES.get(aa_sig_type, AA_ECDSA_DEFAULT)


def aa_hash_size(aa_sig_type: int) -> int:
    """Bytes of each coordinate folded into the Poseidon leaf, capped by the coordinate width."""
    return min(31, aa_key_bytes(aa_sig_type))


CIRCUIT = ROOT / "backend/circuits/noir_dl_lib/src/not_passports_zk_circuits.nr"


def implemented_sig_types() -> set[int]:
    """Every SIG_TYPE `verify_signature` actually has a branch for.

    ⚠️ THIS IS A SOUNDNESS CHECK, NOT A TIDINESS ONE, and it is the one that matters most in this
    file. `verify_signature` returns nothing, is called as `let _ = verify_signature::<...>`, and
    each branch asserts internally. So a SIG_TYPE with NO branch does not fail - **the function body
    does nothing and registration proceeds with the document signature unverified.** The Merkle step
    still proves the DSC public key is in the ICAO tree, but DSC public keys are published in the
    ICAO master list, so that alone lets a prover assert an arbitrary MRZ.

    `28_384_3_3_576_264_24_2024_4_2792` shipped in exactly that state, upstream and here.
    """
    import re

    src = CIRCUIT.read_text()
    start = src.index("fn verify_signature<")
    body = src[start:]
    return {int(m.group(1)) for m in re.finditer(r"if \(SIG_TYPE == (\d+)\)", body)}


IMPLEMENTED = implemented_sig_types()
AA_ECDSA_BYTES = aa_ecdsa_bytes()

RSA = ROOT / "backend/circuits/noir_dl_lib/src/rsa.nr"

# SIG_TYPEs that dispatch to `verify_rsa` (PKCS#1 v1.5). The PSS types (10-15) go to `verify_rsa_pss`,
# which does NOT need this check - it ends in an unconditional assert and so fails CLOSED on a hash
# size it does not implement.
PKCS_SIG_TYPES = {1, 2, 3, 4, 5, 6, 7, 8}


def verify_rsa_tails() -> dict[int, set[int]]:
    """Per-HASH_SIZE block -> the modulus sizes N it asserts top-limb padding for.

    The top two limbs (the 0x00 0x01 header and the leading 0xFF run) are asserted in an
    `if (N == n)` tail inside each hash block. An N with no tail skips those assertions, which is the
    same fail-open shape as a missing hash block, one level down.
    """
    import re

    src = RSA.read_text()
    body = src[src.index("pub fn verify_rsa<"):]
    parts = re.split(r"if \(HASH_SIZE == (\d+)\)", body)
    out: dict[int, set[int]] = {}
    for i in range(1, len(parts), 2):
        out[int(parts[i])] = {int(m) for m in re.findall(r"if \(N == (\d+)\)", parts[i + 1])}
    return out


def verify_rsa_hash_sizes() -> set[int]:
    """Hash sizes `verify_rsa` actually implements a padding block for.

    ⚠️ WHY THIS IS A SOUNDNESS CHECK. Every `assert(... "pkcs padding failure")` in `verify_rsa` sits
    INSIDE an `if (HASH_SIZE == n)` block. Reach it with an `n` it does not implement and the function
    computes `sig^e mod n` and then asserts NOTHING - so any signature passes. `3_512_3_3_336_264_NA`
    (SIG_TYPE 3, HASH_ALGO 64) shipped in exactly that state.
    """
    import re

    src = RSA.read_text()
    body = src[src.index("pub fn verify_rsa<"):]
    return {int(m.group(1)) for m in re.finditer(r"if \(HASH_SIZE == (\d+)\)", body)}


RSA_HASHES = verify_rsa_hash_sizes()
RSA_TAILS = verify_rsa_tails()


def name_fields(name: str) -> list[int] | None:
    """The profile name IS rarimo circom `RegisterIdentityBuilder`'s parameter list, in order:

        SIGNATURE_TYPE, DG_HASH_TYPE, DOCUMENT_TYPE, EC_BLOCK_NUMBER, EC_SHIFT,
        DG1_SHIFT, AA_SIGNATURE_ALGO, DG15_SHIFT, DG15_BLOCK_NUMBER, AA_SHIFT

    with a 7-field form ending in `NA` for profiles without Active Authentication, and every shift in
    BITS. Established from the upstream template signature, then VALIDATED before being relied on:
    8 of 9 positional identities hold 44/44 on the ten-field profiles, and 8 of 8 hold 38/38 on the
    NA form. Three profiles that had been written off as corrupt were only ever mis-decoded.
    """
    parts = name.split("_")
    if len(parts) == 7 and parts[6] == "NA":
        parts = parts[:6]
    elif len(parts) != 10:
        return None
    try:
        return [int(x) for x in parts]
    except ValueError:
        return None


def hash_block(dg_hash_type: int) -> tuple[int, int]:
    """(block bytes, padding bytes) for the digest a profile's block counts are expressed in."""
    return (64, 9) if dg_hash_type in (160, 224, 256) else (128, 17)


def check(name: str, g: dict, dg15_blocks: int | None = None) -> tuple[list[str], list[str]]:
    """Returns (errors, warnings). Errors mean the circuit is unsatisfiable OR unsound.

    `dg15_blocks` overrides the block count parsed from the name. Exactly one profile needs it, and
    the override is recorded in the manifest with its evidence rather than assumed here: a name field
    can be wrong, and DG15_BLOCK_NUMBER is the one field the Noir circuit never consumes - the
    generics carry DG15_LEN in bytes - so a wrong value there blocks nothing but this check.
    """
    errors, warnings = [], []

    # BLOCK BOUNDS. circom sizes `ec` and `dg15` as BLOCK_NUMBER * block, and the digest's own padding
    # (0x80 plus the 8- or 16-byte length) has to fit in that same span - so the usable data is
    # BLOCK_NUMBER*block - pad, not BLOCK_NUMBER*block. Both hold 45/45 across the corpus.
    # This is the cheap version of a 30-minute build failing at VK generation.
    f = name_fields(name)
    if f:
        block, pad = hash_block(f[1])
        if g["EC_LEN"] > f[3] * block - pad:
            errors.append(
                f"EC_LEN({g['EC_LEN']}) exceeds EC_BLOCK_NUMBER({f[3]}) * {block} - {pad} padding"
                f" = {f[3] * block - pad}"
            )
        if len(f) == 10 and g["DG15_LEN"] > 0:
            blocks = dg15_blocks if dg15_blocks is not None else f[8]
            if g["DG15_LEN"] > blocks * block - pad:
                errors.append(
                    f"DG15_LEN({g['DG15_LEN']}) exceeds DG15_BLOCK_NUMBER({blocks}) * {block}"
                    f" - {pad} padding = {blocks * block - pad}"
                )

    if g["SIG_TYPE"] not in IMPLEMENTED:
        errors.append(
            f"SIG_TYPE {g['SIG_TYPE']} has NO branch in verify_signature -"
            f" the document signature would never be checked (implemented: {sorted(IMPLEMENTED)})"
        )

    if g["SIG_TYPE"] in PKCS_SIG_TYPES and g["HASH_ALGO"] not in RSA_HASHES:
        errors.append(
            f"SIG_TYPE {g['SIG_TYPE']} reaches verify_rsa with HASH_ALGO {g['HASH_ALGO']}, which has"
            f" no padding block (implemented: {sorted(RSA_HASHES)}) - every pkcs assertion is inside"
            f" those blocks, so the signature would never be checked"
        )
    elif g["SIG_TYPE"] in PKCS_SIG_TYPES and g["N"] not in RSA_TAILS.get(g["HASH_ALGO"], set()):
        errors.append(
            f"verify_rsa's HASH_SIZE=={g['HASH_ALGO']} block has no N=={g['N']} tail"
            f" (has {sorted(RSA_TAILS.get(g['HASH_ALGO'], set()))}) - the top-limb padding"
            f" assertions would be skipped"
        )

    # A passport circuit that reads no MRZ cannot prove anything about a document.
    if g["DG1_LEN"] == 0:
        errors.append("DG1_LEN == 0: the circuit reads no MRZ")

    # `assert(dg1_hash[i] == ec[i + DG1_SHIFT])` for i in 0..DG_HASH_ALGO.
    end = g["DG1_SHIFT"] + g["DG_HASH_ALGO"]
    if end > g["EC_LEN"]:
        errors.append(
            f"DG1 hash runs past ec: DG1_SHIFT({g['DG1_SHIFT']}) + DG_HASH_ALGO({g['DG_HASH_ALGO']})"
            f" = {end} > EC_LEN({g['EC_LEN']})"
        )

    # Same shape for the DG15 hash, where the profile has one.
    if g["DG15_LEN"] > 0:
        end = g["DG15_SHIFT"] + g["DG_HASH_ALGO"]
        if end > g["EC_LEN"]:
            errors.append(
                f"DG15 hash runs past ec: DG15_SHIFT({g['DG15_SHIFT']}) +"
                f" DG_HASH_ALGO({g['DG_HASH_ALGO']}) = {end} > EC_LEN({g['EC_LEN']})"
            )

    # The eContent hash sits inside signedAttributes.
    end = g["EC_SHIFT"] + g["HASH_ALGO"]
    if end > g["SA_LEN"]:
        errors.append(
            f"ec hash runs past sa: EC_SHIFT({g['EC_SHIFT']}) + HASH_ALGO({g['HASH_ALGO']})"
            f" = {end} > SA_LEN({g['SA_LEN']})"
        )
    elif end != g["SA_LEN"]:
        # 76/78 sit flush against the end. Reported, never fatal.
        warnings.append(
            f"ec hash is not flush with sa: EC_SHIFT + HASH_ALGO = {end}, SA_LEN = {g['SA_LEN']}"
        )

    # Active Authentication, RSA case: `extract_dg15_pk_hash` reads FIVE fixed chunks out of dg15 -
    # four of 25 bytes and a last of 28 - so the highest index touched is AA_SHIFT + 27 + 4*25.
    # Nothing scales with the key size; the read is the same width for every RSA AA profile.
    # VALIDATED AS AN INVARIANT, not asserted: it holds for 37 of the 38 RSA-AA profiles, and the
    # single exception was a tuple DERIVED here rather than published - i.e. the check's only
    # disagreement with the corpus was with the thing that was actually wrong.
    aa = g["AA_SIG_TYPE"]
    if 0 < aa < 20:
        # Mirrors the selector in extract_dg15_pk_hash: a 1024-bit key if one physically fits at
        # AA_SHIFT, otherwise the 768-bit reader. Only 14_256_1_4... takes the second path.
        key_bytes = 128 if g["AA_SHIFT"] + 128 <= g["DG15_LEN"] else 96
        end = g["AA_SHIFT"] + key_bytes - 1
        if end > g["DG15_LEN"] - 1:
            errors.append(
                f"RSA AA key runs past dg15: max index {end} > DG15_LEN-1 ({g['DG15_LEN'] - 1});"
                f" AA_SHIFT({g['AA_SHIFT']}) with a {key_bytes}-byte modulus needs DG15_LEN >="
                f" {g['AA_SHIFT'] + key_bytes}"
            )

    # Active Authentication: an ECDSA public key is two coordinates read out of dg15.
    if aa >= 20:
        kb = aa_key_bytes(aa)

        # THE CHECK THAT WOULD HAVE CAUGHT AA_SIG_TYPE 24. A curve with no branch silently uses 32
        # bytes; if that is not the curve's real width, the extractor reads both coordinates from
        # the wrong offsets and the AA key hash commits to something that is not the key. It fails
        # SILENTLY - the circuit still builds and still proves - which is exactly the shape of defect
        # this file exists to reject.
        real = AA_CURVE_BYTES.get(aa)
        if real is not None and real != kb:
            errors.append(
                f"AA_SIG_TYPE {aa} coordinates are {real} bytes but extract_dg15_pk_hash uses {kb}"
                f" - both coordinates would be read from the wrong offsets"
            )

        hash_size = aa_hash_size(aa)
        x_y_shift = kb - hash_size
        if x_y_shift < 0:
            errors.append(f"AA_SIG_TYPE {aa}: key bytes({kb}) < hash size({hash_size}), shift underflows")
        else:
            end = g["AA_SHIFT"] + (hash_size - 1) + x_y_shift + kb
            if end > g["DG15_LEN"] - 1:
                errors.append(
                    f"AA key runs past dg15: max index {end} > DG15_LEN-1"
                    f" ({g['DG15_LEN'] - 1}) for AA_SIG_TYPE {aa} (key {kb} bytes)"
                )
        if aa not in AA_ECDSA_BYTES and real is None:
            # Only unknown curves are worth a warning now. A curve that HAS no branch but whose real
            # width is the 32-byte default is simply correct, and the mismatch case above is an
            # error, so the old blanket "no branch" warning fired on working profiles - a check that
            # cries wolf on correct input trains people to ignore it.
            warnings.append(
                f"AA_SIG_TYPE {aa} is not in the curve table; it falls through to"
                f" {AA_ECDSA_DEFAULT} bytes, which may be wrong for this curve"
            )

    return errors, warnings


def check_zk_types(live: dict) -> list[str]:
    """Every profile must carry a zkType, and it must be keccak256 of its label.

    WHY IT IS IN THE MANIFEST AT ALL. `Registration2.passportVerifiers[zkType]` is the only thing that
    binds a document to a verifier, and NOTHING in this repo populated it - no deploy script, no
    migration, no test; even `Registration2Mock.mockAddPassportVerifier` is never called. So the 89
    verifiers were correct, current, and bound to nothing, and `registerViaNoir` reverted with
    "passport verifier does not exist" for every document.

    The scheme is upstream's, not invented here: rarimo's `scripts/utils/types.ts` defines
    `Z_NOIR_PASSPORT_<profile> = keccak256(["string"], ["Z_NOIR_PASSPORT_<profile>"])` and
    `deploy/10_setup.migration.ts` registers each verifier under it.

    The keccak itself is only verified when `cast` is on PATH - the check degrades to structure and
    uniqueness rather than silently passing, and says which it did.
    """
    import shutil
    import subprocess

    errors = []
    seen = {}
    for name, e in sorted(live.items()):
        label, zk = e.get("zk_type_label"), e.get("zk_type")
        if not label or not zk:
            errors.append(f"{name}: no zk_type recorded - it cannot be bound to a verifier")
            continue
        if label != "Z_NOIR_PASSPORT_" + name:
            errors.append(f"{name}: zk_type_label is {label}, expected Z_NOIR_PASSPORT_{name}")
        if zk in seen:
            errors.append(f"{name}: zk_type collides with {seen[zk]} - one would shadow the other")
        seen[zk] = name

    if shutil.which("cast"):
        bad = 0
        for name, e in live.items():
            got = subprocess.run(
                ["cast", "keccak", e["zk_type_label"]], capture_output=True, text=True
            ).stdout.strip()
            if got != e["zk_type"]:
                errors.append(f"{name}: zk_type {e['zk_type']} != keccak(label) {got}")
                bad += 1
        print(f"zkTypes: {len(live)} checked against keccak(label), {bad} mismatched")
    else:
        print(f"zkTypes: {len(live)} checked for structure and uniqueness only (cast not on PATH)")
    return errors


def main() -> int:
    m = json.loads(MANIFEST.read_text())
    live = m["profiles"]
    # A quarantined profile need not have generics: `ID_Card_I` has no published artifact, so there is
    # no tuple to check. Those are reported, not skipped silently - an entry that this file cannot
    # examine is exactly the kind of thing that goes stale unnoticed.
    quarantined = {q["name"]: q["generics"] for q in m["quarantined"] if "generics" in q}
    no_generics = [q["name"] for q in m["quarantined"] if "generics" not in q]

    bad_live, warned = 0, 0
    for name, entry in sorted(live.items()):
        errors, warnings = check(name, entry["generics"], entry.get("dg15_block_number_corrected"))
        if errors:
            bad_live += 1
            print(f"ERROR {name}")
            for e in errors:
                print(f"        {e}")
        for w in warnings:
            warned += 1
            print(f"warn  {name}: {w}")

    zk_errors = check_zk_types(live)
    for e in zk_errors:
        print(f"ERROR {e}")
    bad_live += len(zk_errors)

    print(f"\nchecked {len(live)} live profiles: {bad_live} inconsistent, {warned} warnings")

    # The quarantined ones are the control: if they stop failing, either they were fixed upstream or
    # a check regressed. Either way somebody should look.
    print(f"\ncontrol - {len(quarantined)} quarantined profiles, each EXPECTED to fail:")
    surprises = 0
    for name, g in sorted(quarantined.items()):
        errors, _ = check(name, g)
        if errors:
            print(f"  refused as expected: {name}")
            for e in errors:
                print(f"        {e}")
        else:
            surprises += 1
            print(f"  ⚠️  NOW PASSES, investigate: {name}")

    for name in sorted(no_generics):
        print(f"  not checkable (no generics recorded): {name}")

    if bad_live:
        print(f"\nFAIL: {bad_live} live profile(s) are internally inconsistent.")
        return 1
    if surprises:
        print(f"\nFAIL: {surprises} quarantined profile(s) now pass; the quarantine may be stale.")
        return 1
    print("\nOK - every live profile is self-consistent, and every quarantined one is still refused.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
