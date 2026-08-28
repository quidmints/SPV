#!/usr/bin/env bash
# Regenerate the on-chain Honk verifier contracts from the Noir circuits.
#
# Everything this script emits is GENERATED - never hand-edit the .sol files it writes, re-run this
# instead. The only post-generation edit it makes is renaming the top-level `contract HonkVerifier`
# (bb emits that same name for every circuit) to a per-circuit name, so both verifiers can coexist
# in one Forge project.
#
# TWO ARGUMENTS ARE LOAD-BEARING AND BOTH ARE EASY TO OMIT SILENTLY: `--oracle_hash keccak`, and
# `-k <vk>` on `prove`. Omitting either produces a pipeline that still builds, still passes tests,
# and is still wrong.
#
# ZERO-KNOWLEDGE: on bb 1.x - which this script pins - ZK is the DEFAULT and the opt-OUT is
# `--disable_zk`, so this script passes NO zk flag and that is correct. On 0.82.2 it was opt-IN via
# `--zk`, and omitting it silently produced non-zero-knowledge proofs that leak the witness; upstream
# inverted the flag precisely because the old default was a footgun. Older notes in this repo that
# call `--zk` load-bearing are 0.82.2-era. Verify the property either way with:
#   bb prove --scheme ultra_honk --oracle_hash keccak -b ... -w ... -o /tmp/a
#   bb prove --scheme ultra_honk --oracle_hash keccak -b ... -w ... -o /tmp/b
#   cmp /tmp/a/proof /tmp/b/proof     # identical => NOT zk; differ => blinded
# `bb write_vk` takes no --zk (the key is shared); the flavour lives in the prover and the verifier.
#
# WHY THE `--oracle_hash keccak` FLAGS ARE NOT OPTIONAL: the default (Poseidon2) transcript is for
# proofs verified *inside another circuit*. Its proofs do NOT verify against the generated Solidity
# - they revert `SumcheckFailed()`. PP-NOIR-FUSION.md's P0 log found this empirically. Every
# standalone on-chain verifier in this fusion must use the keccak transcript on all three of
# prove / write_vk / write_solidity_verifier.
#
# ⚠️ bb 5.x CLI (migrated 2026-08-01). `--scheme` / `--oracle_hash` / `--honk_recursion` ARE GONE.
# The single flag `-t/--verifier_target` now selects hash AND zk-ness together:
#     -t evm                 keccak + ZK   <- every on-chain verifier here
#     -t evm-no-zk           keccak, NO zk (LEAKS THE WITNESS - never for our circuits)
#     -t noir-recursive      poseidon2 + ZK <- INNER proofs consumed by the recursion tree
#     -t noir-recursive-no-zk  poseidon2, no zk
# `-t evm` must be passed to write_vk, prove, verify AND write_solidity_verifier. Omitting it on the
# LAST of those silently emits a verifier that disagrees with the proofs - it cost a debugging cycle
# on 2026-08-01, and the failure surfaces only as a forge revert.
#
# ⚠️ EVERY FIXTURE, NOT ONE PER CIRCUIT. `withdraw_identity` alone backs THREE committed proofs
# (withdraw_identity, withdraw_identity_wallet, withdraw_e2e) from three different witnesses, and
# ragequit/title_holder each have a second. Regenerating only `<circuit>.proof` leaves the others
# stale, they keep their OLD byte length, and the resulting forge failures look like a toolchain bug.
# That is exactly what happened on 2026-08-01 and cost four wrong diagnoses. See FIXTURES below.
#
# TOOLCHAIN (pinned, do not drift). These MUST match REQUIRED_NARGO/REQUIRED_BB below - and THIS
# HEADER HAS NOW DRIFTED TWICE. It advertised beta.1 / 0.82.2 while the guard enforced beta.13 /
# 1.2.0; it then advertised beta.13 / 1.2.0 while the guard enforced beta.26 / 5.1.0 (corrected
# 2026-08-02). Both times, following the header got you rejected by the guard fifty lines later.
# **Read REQUIRED_NARGO/REQUIRED_BB, not prose** - the constants are what runs.
#   nargo 1.0.0-beta.26+quid-icefix1   locally patched; see the WHY PATCHED note below.
#   bb    6.0.0-nightly  an npm package, NOT bbup. `npm install` in this directory, then
#                        `export PATH="$PWD/node_modules/.bin:$PATH"` or the guard reports it missing.
#                        Pinned in package.json; 5.1.0 is gone from this tree entirely.
#                        Do NOT use bb < 0.82.0: bbup's own installer warns of a critical UltraHonk
#                        soundness vulnerability below that version, requiring verifier regeneration.
#                        Do NOT assume `bb` on PATH is the right one - several versions are commonly
#                        installed side by side, and the guard below exists because of that.
#
# NATIVE `bb` NEEDS AVX2/BMI2. It SIGILLs on CPUs without them (TODO.md §1 recorded this against an
# i3-U330). Check with `sysctl -n machdep.cpu.leaf7_features` (macOS) or `grep avx2 /proc/cpuinfo`.
# On a CPU that lacks them, substitute bb.js (WASM) for the `bb` calls - same subcommands.
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# TOOLCHAIN GUARD - do not remove. See TODO.md sec. 1 for the full compatibility map.
#
# EXACTLY ONE nargo/bb combination works for this repo. Every neighbouring version fails, and -
# critically - SOME OF THEM FAIL SILENTLY:
#
#   bb 1.2.0 + nargo beta.1  ->  `bb prove` REPORTS SUCCESS and writes a proof that bb's own
#                                `bb verify` then REJECTS ("Sumcheck failed!"). Anyone who
#                                evaluates a bump by "did prove succeed?" will ship a broken system.
#   bb <= 0.87.0             ->  `--zk` is SILENTLY IGNORED under `--honk_recursion`, producing
#                                non-zero-knowledge proofs that leak the witness.
#   nargo beta.22+           ->  compiler ICE ("all function ids should have metadata") on
#                                query_identity / register_identity, with zero regular errors. STILL
#                                UNFIXED UPSTREAM AT beta.26 - which is why the pinned nargo is a
#                                locally patched build and the source carries the BigNumParams
#                                accommodation, so stock beta.26 compiles too. (An earlier note here
#                                said "beta.4+ cannot compile our dependency tree" - that was true
#                                BEFORE the noir_dl_lib migration.)
#
# So this guard is not pedantry about versions - it is the only thing standing between a fresh
# clone and artifacts that look fine and are not.
# ---------------------------------------------------------------------------------------------
# nargo is a LOCALLY PATCHED beta.26, and the "+quid-icefix1" suffix is load-bearing.
#
# WHY PATCHED: released beta.26 ICEs (`ice: all function ids should have metadata`) on a generic
# operator-overload impl evaluated in a `global`, which blocked register_identity{,_td1,_light_td1},
# query_identity{,_td1} and escrow_envelope from compiling AT ALL. Fix is 3 hunks turning
# `function_meta` into `try_function_meta`; see noir-ice-repro/noir-fix.patch and NOIR-DL-PORT.md.
# Regression-tested against Noir's own suite: noirc_frontend 2223 passed, 0 failed.
#
# WHY THE SUFFIX: an unmarked patched build reports the IDENTICAL version string to the release and
# would slip past this guard unnoticed - the pin would silently stop meaning anything. The marker is
# added in tooling/nargo_cli/src/cli/mod.rs so that using a custom compiler is always an explicit,
# visible decision.
#
# TO REBUILD IT: clone noir at tag v1.0.0-beta.26, apply noir-ice-repro/noir-fix.patch plus the
# version marker, `cargo build --release -p nargo_cli`, copy target/release/nargo onto your PATH.
# TO GO BACK: the stock binary is saved at ~/.nargo/bin/nargo.beta26-release.bak, or reinstall with
# `noirup --version 1.0.0-beta.26`. The circuits still build on STOCK beta.26 too - the
# `BigNumParams::new` accommodation in noir_dl_lib was kept precisely so they do.
# WHEN THE FIX SHIPS UPSTREAM: drop the suffix, go back to the release, revert the accommodation.
REQUIRED_NARGO="1.0.0-beta.26+quid-icefix1"
# Two versions are accepted, and ONLY because they were proved equivalent rather than assumed to be.
# `bb write_vk -t evm` on `withdraw_identity` produces a BYTE-IDENTICAL key under both
# (sha256 366f53d7...), so the 89 verifiers already generated under 5.1.0 stay valid and nothing
# needs regenerating. 6.0.0-nightly is required for the IVC/chonk path only: 5.1.0 cannot build a
# circuit containing HN recursion constraints and fails with "not supported with UltraBuilder".
# It is installed as a node package, so it is NOT on PATH:
#   npm install @aztec/bb.js@6.0.0-nightly.20260804 && ./node_modules/.bin/bb --version
REQUIRED_BB="6.0.0-nightly.20260804"

actual_nargo="$(nargo --version 2>/dev/null | sed -n 's/^nargo version = //p' | head -1)"
actual_bb="$(bb --version 2>/dev/null | tail -1 | sed 's/^v//')"

if [ "${actual_nargo}" != "${REQUIRED_NARGO}" ] || [ "${actual_bb}" != "${REQUIRED_BB}" ]; then
  cat >&2 <<EOF
ERROR: wrong toolchain. Refusing to generate verifiers.

  nargo  required ${REQUIRED_NARGO}   found '${actual_nargo:-<not on PATH>}'
  bb     required ${REQUIRED_BB}  found '${actual_bb:-<not on PATH>}'

Install exactly these:
  noirup --version ${REQUIRED_NARGO}
  # bb: untar barretenberg-<arch>-darwin|linux.tar.gz from
  #     https://github.com/AztecProtocol/aztec-packages/releases/tag/v${REQUIRED_BB}
  #     (bbup also resolves it: it reads the installed nargo)

DO NOT "just use a newer version" - see TODO.md sec. 1. Several newer combinations produce
artifacts that appear valid and are not. If you are deliberately testing a bump, verify ALL THREE
before trusting it:
  1. native  'bb verify'  accepts the proof
  2. two prover runs on one witness produce DIFFERENT bytes  (confirms ZK; identical => NOT zk)
  3. the generated Solidity verifier accepts a real proof on-chain  (forge test)
EOF
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# bb_checked <expected-artifact> -- <bb args...>
#
# EVERY bb call goes through this. bb fails in two ways that a bare invocation does not catch, and
# both have already cost this project real time:
#
#   1. IT EXITS 0 AND WRITES NOTHING. `bb write_solidity_verifier` with a missing -k prints
#      "Unable to open file: target/vk" and returns 0. `set -e` cannot see that. Only checking that
#      the artifact exists catches it.
#   2. IT SIGSEGVS (exit 139) ON A WRONG IN-CIRCUIT VK LENGTH, after already printing
#      "Scheme is: ultra_honk" - so stdout looks like a normal run. The recursive
#      `verification_key` parameter is 128 FIELDS, not the 55 fields of the on-disk target/vk.
#      Passing 55 segfaults with no diagnostic. See TODO.md sec. 2.4pre.
#
# Checking the ARTIFACT rather than the exit code is the general defence: it holds for failure
# modes nobody has classified yet, which is the whole reason the self-checks further down exist.
bb_checked() {
  local artifact="$1"; shift
  [ "$1" = "--" ] && shift

  set +e
  "$@"
  local code=$?
  set -e

  if [ ${code} -eq 139 ]; then
    echo "ERROR: bb SEGFAULTED (exit 139) on: $*" >&2
    echo "       If this is a recursive circuit, the in-circuit verification_key is 128 FIELDS," >&2
    echo "       NOT the 55 fields of the on-disk target/vk. A wrong length segfaults bb with no" >&2
    echo "       diagnostic. See TODO.md sec. 2.4pre." >&2
    exit 1
  fi

  if [ ${code} -ne 0 ]; then
    echo "ERROR: bb exited ${code} on: $*" >&2
    exit 1
  fi

  # The load-bearing check: bb can exit 0 having produced nothing.
  if [ ! -s "${artifact}" ]; then
    echo "ERROR: bb reported success but produced no '${artifact}'." >&2
    echo "       Command: $*" >&2
    echo "       bb exits 0 on some failures (e.g. a missing -k on write_solidity_verifier)," >&2
    echo "       so exit status alone is not evidence the artifact was written." >&2
    exit 1
  fi
}

# execute_witness <prover-file> <witness-name> - solve a witness WITHOUT destroying a committed input.
#
# THIS IS THE WHOLE OF TASK 30's UNEXPLAINED `SumcheckFailed()` (root-caused 2026-08-02). Both loops
# below used to `cp "${witness}" Prover.toml` before `nargo execute`, because nargo reads Prover.toml
# by default. But `Prover.toml` IS A COMMITTED INPUT for every circuit whose baseline witness is not
# named `Prover.baseline.toml` - title_holder is one - so that copy PERMANENTLY REPLACED the circuit's
# baseline witness with a fixture's, and the replacement was itself committed (db1df14). Every later
# run then proved the baseline fixture from the WRONG witness.
#
# WHY EVERY SIGNAL SAID "FINE". `bb prove` succeeded. `bb verify` ACCEPTED the proof - it is a
# perfectly valid proof, of a different statement. The vk was unchanged and the verifier bytecode was
# byte-identical. Only the Solidity test rejected it, because its public inputs are hardcoded and
# belong to the real baseline. A proof of the wrong statement is indistinguishable from a proof of the
# right one until something pins the statement.
#
# WHY NOT `nargo execute -p <name>`, WHICH LOOKS LIKE THE OBVIOUS FIX: nargo splits the extension at
# the FIRST dot, so `-p Prover.titleid1` resolves to `Prover.toml` and the argument is DISCARDED
# SILENTLY - `-p Prover.doesnotexist` exits 0 and cheerfully solves Prover.toml. It works only for
# dotless names, and this pipeline's witnesses are `Prover.<what>.toml` across six files including two
# generators. So the flag would have swapped one silent substitution for a subtler one; the guard
# below refuses a dotted `-p`-style name for exactly that reason.
#
# Restore happens on failure too, and is VERIFIED - a restore that silently did not happen is the
# same bug wearing a hat.
execute_witness() {
  local prover_file="$1" witness_name="$2" saved="" rc=0

  if [ ! -f "${prover_file}" ]; then
    echo "ERROR: witness ${prover_file} not found in $(pwd)" >&2
    return 1
  fi

  if [ "${prover_file}" != "Prover.toml" ]; then
    if [ -f Prover.toml ]; then
      saved="$(mktemp)"
      cp Prover.toml "${saved}"
    fi
    cp "${prover_file}" Prover.toml
  fi

  nargo execute "${witness_name}" >/dev/null || rc=$?

  if [ -n "${saved}" ]; then
    cp "${saved}" Prover.toml
    if ! cmp -s "${saved}" Prover.toml; then
      echo "ERROR: failed to restore Prover.toml in $(pwd) - it now holds ${prover_file}." >&2
      echo "       Recover it from git before proving anything: git checkout -- Prover.toml" >&2
      rm -f "${saved}"
      return 1
    fi
    rm -f "${saved}"
  elif [ "${prover_file}" != "Prover.toml" ]; then
    rm -f Prover.toml   # there was none before us; leave none behind
  fi

  return "${rc}"
}

CIRCUITS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="${CIRCUITS_DIR}/../contracts/contracts"

# circuit_dir : destination .sol : generated contract name : number of public inputs
TARGETS=(
  # 8 public signals: seven, plus the TAINT ROOT carrying non-association (sec. 2.18gz-unify).
  # Miscounting here does not fail loudly at generation - it produces a fixture the verifier
  # rejects for the wrong reason, which is what the length assertion below exists to catch.
  "withdraw_identity:${CONTRACTS_DIR}/pool/verifiers/WithdrawalHonkVerifier.sol:WithdrawalHonkVerifier:8"
  "title_holder:${CONTRACTS_DIR}/title/TitleHolderHonkVerifier.sol:TitleHolderHonkVerifier:2"
  "ragequit:${CONTRACTS_DIR}/pool/verifiers/RagequitHonkVerifier.sol:RagequitHonkVerifier:4"
  # 11 public inputs: controller_x/y, commitment, registration_root, c1_x/y, sealed[5].
  # Miscounting here silently produces a fixture the verifier rejects for the wrong reason.
  # WAS 12: `holder_root` and `dg1_hash` were dropped in TODO.md sec. 2.18 - both were per-person
  # identifiers that linked every user's identity to their pool handle in registration calldata.
  "escrow_envelope:${CONTRACTS_DIR}/registry/verifiers/EscrowEnvelopeHonkVerifier.sol:EscrowEnvelopeHonkVerifier:11"
  # 2 public inputs: notary_root, action_context. Anonymous notary authorisation (sec. 2.18am),
  # replacing `address notary_` plus an ECDSA signature - which named the acting notary on-chain.
  "notary_action:${CONTRACTS_DIR}/title/NotaryActionHonkVerifier.sol:NotaryActionHonkVerifier:2"
  # ⚠️ `register_identity_light_td1` IS NO LONGER A TARGET HERE, and re-adding it would resurrect a
  # DELETED file. It was one until 20617b2 replaced the single `RegisterIdentityLightHonkVerifier`
  # with ten `RegisterIdentityLight{,ID}{160,224,256,384,512}` variants, which
  # `codegen-light-verifiers.sh` now generates as a template loop over (DG1_LEN, DG_HASH_ALGO). The
  # entry was left behind pointing at a path that no longer exists, so running this script would
  # have emitted a second copy of a circuit that already has a TESTED verifier - which is exactly
  # how a duplicate `ID_Card_I` came to be built (sec. 2.18gz).
  #
  # THE TD1 FULL REGISTRATION CIRCUIT - what the permissionless ICAO path actually consumes.
  # `registerDocumentViaIcao` needs a TD1 (95-byte DG1) verifier: pointed at the 93-byte TD3 circuit
  # it produces `registrationSmt` leaves `escrow_envelope` can never reproduce, so documents register
  # and are then permanently inert (`HolderRegistration.sol:100-110`).
  # 7 public outputs: `register_identity`'s four, plus `icao_root`, `dg1_hash` and the EXPIRY
  # (sec. 2.18gz-nocontroller - a document's own expiry needs no authority to attest it).
  # ⚠️ EMITTED BUT NOT PROVEN, and that asymmetry is deliberate. The light circuit has a committed
  # witness; this one cannot, because it needs a real TD1 document and this repo does not fabricate
  # an ICAO chain to pretend otherwise (task 6). Its SOD layout constants are inherited from profile
  # 3_160_3_3_336_200_NA - a real card may need a different variant, which is a parameter change and
  # not a redesign.
  "register_identity_td1:${CONTRACTS_DIR}/passport/verifiers/RegisterIdentityTd1HonkVerifier.sol:RegisterIdentityTd1HonkVerifier:7"
  # DELIBERATELY ABSENT: the recursion tree's own circuits. They are GENERATED per level by
  # build-recursion-tree.py, which pins each level's child VK from the artifact it just built, so
  # they cannot be listed as fixed targets here. That script emits the root's Solidity verifier
  # itself - one per batch size, `TreeRoot<N>HonkVerifier` - and the depths are not interchangeable.
)

for target in "${TARGETS[@]}"; do
  IFS=':' read -r circuit dest contract_name npub <<<"${target}"
  echo "==> ${circuit}"
  pushd "${CIRCUITS_DIR}/${circuit}" >/dev/null

  nargo compile
  # THE ARTIFACT IS NAMED AFTER THE PACKAGE, NOT THE DIRECTORY, and for register_identity_light_td1
  # those differ (the package is `register_identity_light`). Deriving it from Nargo.toml keeps every
  # target working whether or not the two happen to coincide.
  artifact="target/$(sed -n 's/^name *= *"\(.*\)"/\1/p' Nargo.toml | head -1).json"
  [ -f "${artifact}" ] || { echo "ERROR: ${circuit} produced no ${artifact}" >&2; exit 1; }
  bb_checked target/vk -- bb write_vk -t evm -b "${artifact}" -o target
  # ZERO KNOWLEDGE IS NON-NEGOTIABLE HERE, and on bb 1.x it is the DEFAULT - so no flag is passed
  # and NOTHING must ever add `--disable_zk`. (On 0.82.2 this needed an explicit `--zk`; an earlier
  # revision of this comment said "--zk IS NOT OPTIONAL" while the command below already, correctly,
  # passed no zk flag at all.) A non-ZK pair is SOUND BUT LEAKS: proving one witness twice yields
  # BYTE-IDENTICAL proofs, which a zero-knowledge system cannot do, because blinding needs
  # randomness. withdraw_identity's witness holds `nullifier`, `secret`, `label`, `value` and
  # `sk_identity`; title_holder's holds `sk_identity`. Shipping non-ZK proofs over those destroys
  # exactly the unlinkability both circuits exist to provide. ZK costs ~+51% verify gas and +51
  # field elements of proof - that is the price of the property, not overhead to trim. The
  # determinism self-check below is what actually enforces this. See TODO.md sec. 2.17.
  bb_checked "${dest}" -- bb write_solidity_verifier -t evm -k target/vk -o "${dest}"

  # bb names every generated contract `HonkVerifier`; give each a distinct name so a single Forge
  # project can hold both. Only the top-level contract is renamed - the file-scoped libraries keep
  # their generated names and are harmless, since Forge keys artifacts by source path.
  # bb emits the ZK verifier as ` contract HonkVerifier is IVerifier {` (note the leading space)
  # and the non-ZK one as `contract HonkVerifier is BaseHonkVerifier`. Match both so this keeps
  # working if the flavour is ever changed, rather than silently leaving the name unrenamed.
  sed -i.bak -E "s/^[[:space:]]*contract HonkVerifier is /contract ${contract_name} is /" "${dest}"
  rm -f "${dest}.bak"
  grep -q "^contract ${contract_name} is " "${dest}" || {
    echo "ERROR: failed to rename generated contract in ${dest}" >&2; exit 1;
  }

  # Regenerate the committed proof fixture from a COMMITTED witness, so the fixture can never drift
  # from the verifier it is tested against - and so a fixture proved WITHOUT --zk cannot linger
  # unnoticed (it would be 51 field elements shorter and the ZK verifier would reject it).
  #
  # `Prover.baseline.toml` takes precedence over `Prover.toml`. withdraw_identity has TWO committed
  # witnesses (baseline + wallet, both emitted by tools/build-withdrawal-fixture.js) and only the
  # baseline corresponds to test/fixtures/<circuit>.proof; the wallet one is regenerated by that
  # tool, not here. This branch previously keyed on `Prover.toml` alone while NO Prover.toml was ever
  # committed for withdraw_identity - so it silently skipped, and the "cannot drift" guarantee in the
  # old version of this comment did not actually hold for that circuit.
  _prover=""
  if   [ -f Prover.baseline.toml ]; then _prover="Prover.baseline.toml"
  elif [ -f Prover.toml ];          then _prover="Prover.toml"
  fi
  if [ -n "${_prover}" ]; then
    echo "  witness: ${_prover}"
    execute_witness "${_prover}" witness
    # -k IS MANDATORY ON bb 1.x AND WAS NOT ON 0.82.2. Omitting it does not error - bb exits 0 and
    # writes a proof against a DIFFERENT key, which its own verifier then rejects with
    # `SumcheckFailed()`. That single missing flag masqueraded as a bb-version incompatibility for a
    # long time. The self-checks below would catch it, but pass it explicitly.
    bb_checked target/proof -- bb prove -t evm -b "${artifact}" -w target/witness.gz -k target/vk -o target

    # ----- SELF-VALIDATION: never emit an artifact we have not checked -----
    # A version guard alone is a proxy. These two checks test the ARTIFACT, so they hold even for a
    # toolchain nobody has classified yet.

    # (1) NATIVE VERIFY. bb 1.2.0 + nargo beta.1 reports proving success and emits a proof that bb's
    #     OWN verifier rejects. Only this check catches that; `bb prove`'s exit code does not.
    if ! bb verify -t evm -k target/vk -p target/proof -i target/public_inputs >/dev/null 2>&1; then
      echo "ERROR: ${circuit}: bb generated a proof its own verifier REJECTS." >&2
      echo "       The prover/VK pair is incompatible with this circuit. Do NOT use these" >&2
      echo "       artifacts. See TODO.md sec. 1." >&2
      exit 1
    fi

    # (2) ZERO-KNOWLEDGE. Prove the SAME witness twice: a ZK prover must produce different bytes,
    #     because blinding requires randomness. Identical output is conclusive proof that ZK is OFF
    #     - which is how `--zk` being silently ignored under `--honk_recursion` was found, and how
    #     the original missing-`--zk` bug was found. Output dirs are cleared first: comparing stale
    #     files once produced a false negative here.
    rm -rf target/_zkcheck_a target/_zkcheck_b
    mkdir -p target/_zkcheck_a target/_zkcheck_b
    for _d in a b; do
      bb_checked "target/_zkcheck_${_d}/proof" -- bb prove -t evm -b "${artifact}" -w target/witness.gz -k target/vk \
        -o "target/_zkcheck_${_d}" >/dev/null 2>&1
    done
    if cmp -s target/_zkcheck_a/proof target/_zkcheck_b/proof; then
      echo "ERROR: ${circuit}: proving the same witness twice produced IDENTICAL bytes." >&2
      echo "       A deterministic prover cannot be zero-knowledge. These proofs would leak the" >&2
      echo "       witness (sk_identity, nullifier, secret). Do NOT use them. TODO.md sec. 2.17." >&2
      exit 1
    fi
    rm -rf target/_zkcheck_a target/_zkcheck_b
    echo "  self-check ok: native verify passed, prover is non-deterministic (ZK)"
    python3 - "${circuit}" "${CONTRACTS_DIR}/../test/fixtures" "${npub}" <<'PYEOF'
import sys, pathlib
circuit, fixtures, npub = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
proof = (pathlib.Path("target") / "proof").read_bytes()
pub = (pathlib.Path("target") / "public_inputs").read_bytes()

# bb 1.x proof format, DIFFERENT from 0.82.2:
#   - no 4-byte big-endian field-count prefix
#   - public inputs are written to their OWN file, not prepended to the proof
#   - the proof carries a 16-field pairing-point accumulator, which the generated Solidity reads
#     from the proof itself (it takes `publicInputsSize - PAIRING_POINTS_SIZE` from calldata)
# So the fixture is the proof VERBATIM, and the calldata public-input count is unchanged.
assert len(proof) % 32 == 0, len(proof)
assert len(pub) == npub * 32, (len(pub), npub * 32)
fixtures.mkdir(parents=True, exist_ok=True)
(fixtures / f"{circuit}.proof").write_bytes(proof)
print(f"  fixture {circuit}.proof: {len(proof)//32} proof fields, {npub} public inputs (separate)")
PYEOF
  fi

  popd >/dev/null
done


# ─── FIXTURES: every committed proof, not one per circuit ──────────────────────────────────────
# circuit : witness file : fixture name.  A circuit appears MULTIPLE times when several committed
# proofs come from it under different witnesses. Regenerating only the first leaves the rest stale.
EXTRA_FIXTURES=(
  "withdraw_identity:Prover.wallet.toml:withdraw_identity_wallet"
  "withdraw_identity:Prover.e2e.toml:withdraw_e2e"
  "ragequit:Prover.e2e.toml:ragequit_e2e"
  "title_holder:Prover.titleid1.toml:title_holder_id1"
)

echo
echo "==> Extra fixtures (same circuits, different witnesses)"
for entry in "${EXTRA_FIXTURES[@]}"; do
  IFS=':' read -r circuit witness fixture <<<"${entry}"
  pushd "${CIRCUITS_DIR}/${circuit}" >/dev/null
  artifact="target/$(sed -n 's/^name *= *"\(.*\)"/\1/p' Nargo.toml | head -1).json"
  if [ ! -f "${witness}" ]; then
    echo "ERROR: ${circuit}/${witness} missing - ${fixture}.proof cannot be regenerated." >&2
    exit 1
  fi
  execute_witness "${witness}" "w_${fixture}"
  rm -rf "pf_${fixture}"; mkdir -p "pf_${fixture}"
  bb_checked "pf_${fixture}/proof" -- bb prove -t evm \
    -b "${artifact}" -w "target/w_${fixture}.gz" -k target/vk -o "pf_${fixture}"
  # Same non-negotiable check as the primary fixtures: bb's own verifier must accept it.
  if ! bb verify -t evm -k target/vk -p "pf_${fixture}/proof" -i "pf_${fixture}/public_inputs" >/dev/null 2>&1; then
    echo "ERROR: ${fixture}: bb generated a proof its own verifier REJECTS." >&2
    exit 1
  fi
  cp "pf_${fixture}/proof" "${CONTRACTS_DIR}/../test/fixtures/${fixture}.proof"
  echo "  ${fixture}.proof  ($(( $(wc -c <"pf_${fixture}/proof") / 32 )) fields)"
  popd >/dev/null
done

# GUARD: no committed fixture may be left at a stale length. Every .proof under test/fixtures must
# have been written by THIS run, except the passport ones, which are still built on the old
# toolchain (see TODO.md sec. 2.4a) and are deliberately excluded.
echo
echo "==> Fixture staleness check"
_stale=0
for f in "${CONTRACTS_DIR}/../test/fixtures"/*.proof; do
  # Fixtures this script does not own. `escrow_envelope`'s come from tools/prove-escrow-fixtures.sh,
  # and `register_identity_light*`'s from codegen-light-verifiers.sh since 20617b2 moved that whole
  # family there. Without this exclusion the check flags them on every run that edits THIS file -
  # the comparison is against this script's own mtime - and the only way to silence it would be to
  # re-add a target that emits a duplicate of an already-tested verifier.
  case "$(basename "$f")" in escrow_envelope*|register_identity_light*) continue;; esac
  if [ "$f" -ot "${CIRCUITS_DIR}/codegen-verifiers.sh" ]; then
    echo "  STALE: $(basename "$f") was not regenerated by this run" >&2; _stale=1
  fi
done
[ ${_stale} -eq 0 ] || { echo "ERROR: stale fixtures above would fail forge with a misleading length error." >&2; exit 1; }
echo "  all fixtures fresh"

# Refresh the circuits BUNDLED INTO THE WALLET. These are the same ACIR artifacts the prover runs
# on-device, and they are published nowhere, so the app ships them (see the wallet's
# metro.config.js). Copying them here is what stops the bundled bytecode drifting from the circuit
# this script just generated a verifier for - a drift that would produce proofs the on-chain
# verifier rejects, with nothing pointing at the stale asset as the cause.
WALLET_CIRCUITS="${CIRCUITS_DIR}/../../frontend/identity-wallet/assets/circuits"
if [ -d "${WALLET_CIRCUITS}" ]; then
  echo
  echo "==> Refreshing wallet-bundled circuits"
  for target in "${TARGETS[@]}"; do
    IFS=':' read -r circuit _rest <<<"${target}"
    src="${CIRCUITS_DIR}/${circuit}/target/$(sed -n 's/^name *= *"\(.*\)"/\1/p' "${CIRCUITS_DIR}/${circuit}/Nargo.toml" | head -1).json"
    if [ -f "${src}" ]; then
      cp "${src}" "${WALLET_CIRCUITS}/${circuit}.circuit"
      echo "  ${circuit}.circuit  ($(wc -c <"${src}" | tr -d ' ') bytes)"
    fi
  done
fi

echo
echo "==> Done. Verify with:"
echo "    cd ${CONTRACTS_DIR}/.. && forge build --sizes && forge test"
echo
echo "    Every verifier must stay under the EIP-170 24,576-byte runtime limit, and the failure"
echo "    appears only at deploy time - so check --sizes after every run."
echo "    MEASURED 2026-08-24: WithdrawalHonkVerifier 17,183 (margin 7,393); TreeRoot8/16/32 all"
echo "    17,744 (margin 6,832). ~7KB of headroom, NOT the ~85 bytes this note used to claim -"
echo "    that figure read the MARGIN column of an unrelated \`Address\` row and scared people off"
echo "    changes that fit easily. Re-measure rather than trusting either number."
