#!/usr/bin/env python3
"""Build and run the recursion TREE that settles a batch of withdrawals on-chain.

  python3 build-recursion-tree.py [N]        # any N >= 2; padded to the next power of two

WHAT THIS IS FOR. The retired flat aggregator verified all N withdrawal proofs inside ONE circuit,
which was 12,720,801 gates and ~21.7 GB at N=16 - a batcher had to be a server. This builds the same
guarantee as a TREE of two-proof nodes instead. No node is ever large: a leaf is ~1.54M gates and an
internal node ~1.49M, so peak memory is ~2.1 GB no matter how big the batch is. The root is an
ordinary UltraHonk proof, so it gets a generated Solidity verifier exactly as the flat aggregator
does, and the settlement stays trustless.

WHY THE INTERNAL NODE IS NOT MORE EXPENSIVE THAN A LEAF, which is the part that sounds wrong. A
recursive UltraHonk proof is 458 fields WHATEVER circuit produced it - proof length is fixed by the
flavour, not by circuit size. So verifying an aggregation proof costs the same as verifying a
withdrawal proof, and the internal node is actually cheaper because it folds one public input per
child instead of seven.

WHY THE LEVELS ARE GENERATED RATHER THAN CHECKED IN. Every level pins the VK of the level below it,
so levels 2..k are the same source with a different constant. Committing k near-identical files would
be a set of twins that drift; generating them means the pin is derived from the artifact that was
actually built, and a level can never cite a key that no longer exists.

SELF-REFERENCE IS AVOIDED, DELIBERATELY. A single "merge" circuit that verified proofs of itself
would need its own VK pinned inside itself. The usual escape is to take the child VK as a WITNESS and
constrain its hash - but then the batch depth stops being structural, and a wrong-but-well-formed VK
becomes a thing the circuit must catch rather than a thing it cannot express. A fixed depth with one
circuit per level cannot express it at all.

TOOLCHAIN: bb 6.0.0-nightly, pinned in package.json and used by default - run `npm install` in
backend/circuits once. Set BB to override. 5.1.0 is no longer referenced anywhere in this tree.

THE TWO VERSIONS ARE NOT INTERCHANGEABLE AND YOU CANNOT TELL BY LOOKING AT THE KEYS. Measured:
`withdraw_identity`'s recursion VK is BYTE-IDENTICAL under 5.1.0 and 6.0 - same 115 fields, same
values - and its proofs are still mutually unverifiable, failing at `UltraVerifier: verification
failed at reduction step` in BOTH directions while each verifies fine against its own toolchain. So
the incompatibility lives in the proof transcript, not the key, and comparing pinned VKs would say
everything is fine. Every proof in a tree must come from one bb.

PREREQUISITE - the withdrawals themselves:
  cd frontend/identity-wallet && npm run build:pp
  node tools/build-fold-witnesses.js --build frontend/identity-wallet/build --count 16
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
WORK = pathlib.Path(os.environ.get("TREE_WORKDIR", HERE / ".tree"))
BB = os.environ.get("BB", str(HERE / "node_modules" / ".bin" / "bb"))

LEAF_CIRCUIT = "withdraw_identity"
WITNESS_SOURCE = "batch-witnesses"  # where build-fold-witnesses.js writes Prover.<i>.toml

# The only two things this writes OUTSIDE its work directory. Everything else is derived and
# disposable; these two are what the contracts compile and test against.
CONTRACTS = HERE / ".." / "contracts"


def verifier_name(n: int) -> str:
    """One deployed verifier PER DEPTH, named for the batch size it accepts.

    Not cosmetic. A depth-5 root proof is rejected by a depth-4 verifier with `SumcheckFailed()` -
    measured, after a tree-of-32 run silently overwrote the tree-of-16 verifier and broke its test.
    The fixture name already carried N; the verifier did not, so the two could disagree.

    It is also the shape the design wants: batch size is a DEPLOYMENT decision, so deploying 16, 32
    and 64 together lets a batch settle at the smallest tree that fits rather than waiting to fill a
    fixed one."""
    return f"TreeRoot{n}HonkVerifier"


def verifier_out(n: int) -> pathlib.Path:
    return CONTRACTS / "contracts" / "pool" / "verifiers" / f"{verifier_name(n)}.sol"


def fixture_out(n: int) -> pathlib.Path:
    """Named for the batch size it holds.

    A fixed name here is not a detail: a smoke run at N=4 silently overwrote the committed N=16
    fixture AND its verifier, and the test suite went on passing because a self-consistent N=4 pair
    verifies perfectly well. The batch size only survives in the file name, so it has to be in it."""
    return CONTRACTS / "test" / "fixtures" / f"recursion_tree_n{n}.json"

# `withdraw_identity`'s shape, measured rather than assumed. PROOF_LEN pairs with PROOF_TYPE: 458 is
# the ZK length and pairs with 6; the non-ZK pair is 410 with 0. Mixing them gives
# `ACIR proof size mismatch. Expected: 410`, which names the length and not the constant that is wrong.
PROOF_LEN = 458
PROOF_TYPE_HONK_ZK = 6
PUB_LEN = 8

FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617


def run(cmd, cwd=None, quiet=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def keccak_fold(payload: bytes) -> int:
    """keccak256 over `payload`, folded into a Field the way the circuits and the contract do.

    `cast` rather than a Python keccak: this value has to agree with Noir's keccak256 and with
    Solidity's, and reaching for whichever hash library happens to be installed is how three
    implementations of one hash end up in a system whose only job is for them to agree."""
    digest = run(["cast", "keccak", "0x" + payload.hex()]).strip()
    return int(digest, 16) % FIELD_MODULUS


def fields_of(path: pathlib.Path) -> list[int]:
    raw = path.read_bytes()
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def vk_literal(vk_path: pathlib.Path) -> str:
    f = fields_of(vk_path)
    return f"[Field; {len(f)}] = [\n    " + ",\n    ".join(f"0x{x:064x}" for x in f) + ",\n]"


# ── the two circuit templates ─────────────────────────────────────────────────────────────────
# One pins withdraw_identity and folds 2 x 8 signals; the other pins the level below and folds two
# commitments. Both expose exactly ONE public input, which is what keeps the generated Solidity
# verifier inside EIP-170 - the flat aggregator's own header records that a design exposing N x 7
# signals does not fit.

LEAF_SRC = """// GENERATED by build-recursion-tree.py - do not edit.
// Tree LEAF: verifies two `withdraw_identity` proofs and commits to their sixteen signals.
use keccak256::keccak256;

global PROOF_LEN: u32 = {proof_len};
global PUB_LEN: u32 = {pub_len};
global PROOF_TYPE: u32 = {proof_type};

// PINNED, never an input. If the key were a witness a batcher could aggregate proofs of a circuit of
// their own choosing - one that mints withdrawals - and the root verifier would accept the batch,
// because it only checks the proof is valid for whatever key it was handed.
global CHILD_VK: {child_vk};

fn main(
    left_proof: [Field; PROOF_LEN],
    right_proof: [Field; PROOF_LEN],
    left_public: [Field; PUB_LEN],
    right_public: [Field; PUB_LEN],
    key_hash: Field,
    commitment: pub Field,
) {{
    std::verify_proof_with_type(CHILD_VK, left_proof, left_public, key_hash, PROOF_TYPE);
    std::verify_proof_with_type(CHILD_VK, right_proof, right_public, key_hash, PROOF_TYPE);

    let mut bytes: [u8; 2 * PUB_LEN * 32] = [0; 2 * PUB_LEN * 32];
    for j in 0..PUB_LEN {{
        let l: [u8; 32] = left_public[j].to_be_bytes();
        let r: [u8; 32] = right_public[j].to_be_bytes();
        for k in 0..32 {{
            bytes[j * 32 + k] = l[k];
            bytes[(PUB_LEN + j) * 32 + k] = r[k];
        }}
    }}
    let digest: [u8; 32] = keccak256(bytes, 2 * PUB_LEN * 32);
    let mut acc: Field = 0;
    for k in 0..32 {{
        acc = acc * 256 + digest[k] as Field;
    }}
    assert(acc == commitment, "leaf commitment mismatch");
}}
"""

NODE_SRC = """// GENERATED by build-recursion-tree.py - do not edit.
// Tree INTERNAL node, level {level}: verifies two level-{child_level} proofs.
use keccak256::keccak256;

global PROOF_LEN: u32 = {proof_len};
global PROOF_TYPE: u32 = {proof_type};

// The level below's key, pinned. This is what makes the tree's SHAPE a constraint rather than a
// convention: a level-3 node cannot be handed a leaf proof, because it would not verify.
global CHILD_VK: {child_vk};

fn main(
    left_proof: [Field; PROOF_LEN],
    right_proof: [Field; PROOF_LEN],
    left_commitment: Field,
    right_commitment: Field,
    key_hash: Field,
    commitment: pub Field,
) {{
    std::verify_proof_with_type(CHILD_VK, left_proof, [left_commitment], key_hash, PROOF_TYPE);
    std::verify_proof_with_type(CHILD_VK, right_proof, [right_commitment], key_hash, PROOF_TYPE);

    let mut bytes: [u8; 64] = [0; 64];
    let l: [u8; 32] = left_commitment.to_be_bytes();
    let r: [u8; 32] = right_commitment.to_be_bytes();
    for k in 0..32 {{
        bytes[k] = l[k];
        bytes[32 + k] = r[k];
    }}
    let digest: [u8; 32] = keccak256(bytes, 64);
    let mut acc: Field = 0;
    for k in 0..32 {{
        acc = acc * 256 + digest[k] as Field;
    }}
    assert(acc == commitment, "node commitment mismatch");
}}
"""

NARGO_TOML = """[package]
name = "{name}"
type = "bin"
authors = [""]

[dependencies]
keccak256 = {{ tag = "v0.1.3", git = "https://github.com/noir-lang/keccak256" }}
"""


def write_package(name: str, src: str) -> pathlib.Path:
    d = WORK / name
    (d / "src").mkdir(parents=True, exist_ok=True)
    (d / "Nargo.toml").write_text(NARGO_TOML.format(name=name))
    (d / "src" / "main.nr").write_text(src)
    return d


def compile_and_key(pkg: pathlib.Path, name: str, evm: bool) -> tuple[pathlib.Path, pathlib.Path]:
    run(["nargo", "compile"], cwd=pkg)
    artifact = pkg / "target" / f"{name}.json"
    keydir = WORK / f"vk_{name}"
    keydir.mkdir(parents=True, exist_ok=True)
    target = "evm" if evm else "noir-recursive"
    run([BB, "write_vk", "-t", target, "-b", str(artifact), "-o", str(keydir)])
    return artifact, keydir


def prove(pkg: pathlib.Path, artifact: pathlib.Path, keydir: pathlib.Path, tag: str, evm: bool):
    run(["nargo", "execute", tag], cwd=pkg)
    out = WORK / f"proof_{tag}"
    out.mkdir(parents=True, exist_ok=True)
    target = "evm" if evm else "noir-recursive"
    run([BB, "prove", "-t", target, "-b", str(artifact), "-w", str(pkg / "target" / f"{tag}.gz"),
         "-k", str(keydir / "vk"), "-o", str(out)])
    return out


def toml_array(name: str, values) -> str:
    return f"{name} = [" + ", ".join(f'"{v}"' for v in values) + "]"


def main() -> int:
    requested = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    if requested < 2:
        sys.exit(f"a tree settles at least two withdrawals, got {requested}")

    # PAD TO THE NEXT POWER OF TWO. A tree cannot hold an empty slot, so a batch of five is proved as
    # a tree of eight and the spare leaves are genuine zero-value withdrawals that the contract skips
    # (`withdrawn_value == 0`). That is what turns "wait until sixteen have queued" into "settle with
    # whoever is here" - verification costs the same either way, so a partial batch simply splits the
    # same gas among fewer people.
    n = 1 << (requested - 1).bit_length()
    if n != requested:
        print(f"padding {requested} withdrawals to a tree of {n}")
    if not pathlib.Path(BB).exists():
        sys.exit(f"no bb at {BB}. Run `npm install` in backend/circuits, or set BB.")

    WORK.mkdir(parents=True, exist_ok=True)
    started = time.time()

    # ── level 0: the withdrawals themselves ───────────────────────────────────────────────────
    leaf_pkg = HERE / LEAF_CIRCUIT
    leaf_vk = leaf_pkg / "rec" / "vk"
    leaf_artifact = leaf_pkg / "target" / f"{LEAF_CIRCUIT}.json"
    missing = [i for i in range(n) if not (HERE / WITNESS_SOURCE / f"Prover.{i}.toml").exists()]
    if missing:
        sys.exit(
            f"missing withdrawals {missing}. Run:\n"
            f"  cd frontend/identity-wallet && npm run build:pp\n"
            f"  node tools/build-fold-witnesses.js --build frontend/identity-wallet/build --count {n}"
        )

    # The witnesses are plain `withdraw_identity` inputs. They live in their own directory rather
    # than a circuit's, because they belong to the BATCH and not to any one circuit - they used to
    # sit inside the chonk app's package, which made them look like its property and broke the tree
    # when that package was retired.
    saved = (leaf_pkg / "Prover.toml").read_text()
    key_hash = int.from_bytes((leaf_pkg / "rec" / "vk_hash").read_bytes(), "big")
    level = []
    try:
        for i in range(n):
            (leaf_pkg / "Prover.toml").write_text((HERE / WITNESS_SOURCE / f"Prover.{i}.toml").read_text())
            run(["nargo", "execute", f"tree{i}"], cwd=leaf_pkg)
            out = WORK / f"proof_w{i}"
            out.mkdir(parents=True, exist_ok=True)
            run([BB, "prove", "-t", "noir-recursive", "-b", str(leaf_artifact),
                 "-w", str(leaf_pkg / "target" / f"tree{i}.gz"), "-k", str(leaf_vk), "-o", str(out)])
            pubs = fields_of(out / "public_inputs")
            if len(pubs) != PUB_LEN:
                sys.exit(f"withdrawal {i} exposed {len(pubs)} public inputs, expected {PUB_LEN}")
            level.append({"proof": fields_of(out / "proof"), "public": pubs})
            print(f"  withdrawal {i + 1:>3}/{n} proven")
    finally:
        (leaf_pkg / "Prover.toml").write_text(saved)

    # Kept because the fixture must carry them - `level` is rebound at every tree level.
    leaves = list(level)

    # Distinctness, checked here rather than trusted: two members with the same seven signals means
    # the batch has collapsed, and every downstream number would still look healthy.
    seen = {tuple(m["public"]) for m in level}
    if len(seen) != n:
        sys.exit(f"only {len(seen)} distinct withdrawals among {n} - not a real batch")

    # ── the tree ──────────────────────────────────────────────────────────────────────────────
    child_vk_path, child_hash = leaf_vk, key_hash
    depth = n.bit_length() - 1
    for lvl in range(1, depth + 1):
        is_root = lvl == depth
        name = f"tree_l{lvl}"
        src = (
            LEAF_SRC.format(proof_len=PROOF_LEN, pub_len=PUB_LEN, proof_type=PROOF_TYPE_HONK_ZK,
                            child_vk=vk_literal(child_vk_path))
            if lvl == 1 else
            NODE_SRC.format(level=lvl, child_level=lvl - 1, proof_len=PROOF_LEN,
                            proof_type=PROOF_TYPE_HONK_ZK, child_vk=vk_literal(child_vk_path))
        )
        pkg = write_package(name, src)
        # Only the ROOT faces the chain, so only the root is built for the EVM. Every other level is
        # verified inside its parent and must stay in the recursion flavour.
        artifact, keydir = compile_and_key(pkg, name, evm=is_root)

        nxt = []
        for pair in range(len(level) // 2):
            a, b = level[2 * pair], level[2 * pair + 1]
            if lvl == 1:
                payload = b"".join(v.to_bytes(32, "big") for v in a["public"] + b["public"])
                body = [toml_array("left_public", a["public"]), toml_array("right_public", b["public"])]
            else:
                payload = a["commitment"].to_bytes(32, "big") + b["commitment"].to_bytes(32, "big")
                body = [f'left_commitment = "{a["commitment"]}"',
                        f'right_commitment = "{b["commitment"]}"']
            commitment = keccak_fold(payload)

            toml = [toml_array("left_proof", a["proof"]), toml_array("right_proof", b["proof"])]
            toml += body + [f'key_hash = "{child_hash}"', f'commitment = "{commitment}"']
            (pkg / "Prover.toml").write_text("\n".join(toml) + "\n")

            tag = f"l{lvl}n{pair}"
            out = prove(pkg, artifact, keydir, tag, evm=is_root)
            got = fields_of(out / "public_inputs")
            if got != [commitment]:
                sys.exit(f"{tag}: proof exposes {got}, expected [{commitment}]")
            nxt.append({"proof": fields_of(out / "proof"), "commitment": commitment})
            print(f"  level {lvl} node {pair + 1:>2}/{len(level) // 2} proven  "
                  f"commitment=0x{commitment:064x}"[:78])

        level = nxt
        child_vk_path = keydir / "vk"
        child_hash = int.from_bytes((keydir / "vk_hash").read_bytes(), "big")

    assert len(level) == 1
    root = level[0]

    # ── what the chain needs ──────────────────────────────────────────────────────────────────
    # The root's Solidity verifier, renamed to the file it lives in. bb names the contract after the
    # artifact and emits `abstract contract BaseZKHonkVerifier` FIRST, so a regex for `\\w*HonkVerifier`
    # matches the BASE and renames the wrong one, leaving the child inheriting a name that no longer
    # exists. Target the concrete declaration, and refuse to write if it is not there exactly once.
    name = verifier_name(n)
    sol = WORK / f"{name}.sol"
    run([BB, "write_solidity_verifier", "-k", str(child_vk_path), "-o", str(sol)])
    text = sol.read_text()
    marker = "contract HonkVerifier is"
    if text.count(marker) != 1:
        sys.exit(f"expected exactly one '{marker}' in {sol}, found {text.count(marker)}")
    text = text.replace(marker, f"contract {name} is", 1)
    if "abstract contract BaseZKHonkVerifier is" not in text:
        sys.exit(f"{sol}: the base contract lost its name - refusing to write")
    out = verifier_out(n)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)

    # The fixture, in the shape the Forge test parses. The proof is the raw field bytes; the public
    # input is the tree ROOT, which is the only thing the chain sees of the whole batch.
    fixture = fixture_out(n)
    fixture.parent.mkdir(parents=True, exist_ok=True)
    # THE SIGNALS TRAVEL WITH THE PROOF. The contract has to RECOMPUTE the tree from the withdrawals
    # it is settling and check it equals the root - that recomputation is the only thing tying the
    # root back to individual withdrawals, exactly as the flat commitment was. A fixture holding the
    # root alone can only test the verifier, never the settlement.
    fixture.write_text(json.dumps({
        "proof": "0x" + b"".join(v.to_bytes(32, "big") for v in root["proof"]).hex(),
        "publicInputs": [f"0x{root['commitment']:064x}"],
        "batchSize": n,
        "realWithdrawals": requested,
        "signals": [[f"0x{v:064x}" for v in m["public"]] for m in leaves],
        "generator": "backend/circuits/build-recursion-tree.py",
    }, indent=2) + "\n")

    print(f"\nroot commitment 0x{root['commitment']:064x}")
    print(f"root proof      {len(root['proof'])} fields, 1 public input")
    print(f"verifier        {out} ({out.stat().st_size:,} bytes)")
    print(f"fixture         {fixture}")
    print(f"nodes           {n - 1} ({n // 2} leaves + {n // 2 - 1} internal), depth {depth}")
    print(f"elapsed         {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
