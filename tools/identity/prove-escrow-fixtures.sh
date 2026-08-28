#!/usr/bin/env bash
# Prove EVERY committed escrow witness and write the numbered fixtures the registry suite loads.
#
# WHY THIS EXISTS. codegen-verifiers.sh proves exactly ONE witness per circuit (`Prover.toml`), but
# IdentityRegistry.t.sol needs THREE genuine escrow proofs - a single-leaf identity SMT has an empty
# inclusion path, so the withdrawal fixture built on it would hash no siblings and prove nothing
# about the Merkle path. Those three proofs were previously produced BY HAND and committed, with
# nothing in the repo recording the commands. That is the same defect as a test header naming a
# generator that does not exist: the fixtures could drift from the circuit with no way to tell, and
# no way to reproduce them.
#
#   tools/prove-escrow-fixtures.sh          # all Prover.escrow*.toml
#
# RUN IT AFTER codegen-verifiers.sh, never instead of it: the verifying key these proofs are made
# against is the one that script writes, and `bb prove -k` silently produces a proof against a
# DIFFERENT key if the key is stale - a proof the on-chain verifier then rejects with
# `SumcheckFailed()`, pointing nowhere near the cause.
#
# THE FULL PIPELINE, because every step consumes the previous one's output:
#   1. node tools/build-escrow-fixtures.js --documents 3          -> escrow_documents.json
#   2. forge test --match-test test_EmitRegistrationWitnessFixture -> registration_witness.json
#   3. node tools/build-escrow-fixtures.js 3                      -> Prover.escrow<i>.toml
#   4. backend/circuits/codegen-verifiers.sh                      -> verifier + vk
#   5. tools/prove-escrow-fixtures.sh                             -> escrow_envelope<i>.proof/.public
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CIRCUIT="${ROOT}/backend/circuits/escrow_envelope"
FIXTURES="${ROOT}/backend/contracts/test/fixtures"

command -v bb >/dev/null 2>&1 || {
  echo "ERROR: bb is not on PATH. export PATH=\"\$HOME/.bb-v12:\$PATH\"" >&2; exit 1;
}
# ⚠️ EXISTENCE IS NOT FRESHNESS. A vk left over from a PREVIOUS version of the circuit is present,
# non-empty, and wrong: `bb prove -k` uses it happily and the proof fails at the pairing check, which
# reads as a broken circuit rather than a stale key. If the circuit source changed, regenerate it -
#   nargo compile && bb write_vk -t evm -b target/<circuit>.json -o target
# before trusting anything here.
[ -s "${CIRCUIT}/target/vk" ] || {
  echo "ERROR: no verifying key at ${CIRCUIT}/target/vk - run backend/circuits/codegen-verifiers.sh first." >&2
  exit 1
}

cd "${CIRCUIT}"

# ⚠️ THE WITNESS LIST COMES FROM THE DOCUMENTS FIXTURE, NOT FROM A GLOB, AND THAT IS A ROOT FIX.
#
# It used to be `Prover.escrow*.toml`. A glob picks up witnesses for documents that NO LONGER EXIST:
# an earlier 16-identity run left `Prover.escrow3..15.toml` tracked in the repo while the fixture
# carries three documents, so the glob fed the prover a witness with no document behind it. Those
# files cannot be regenerated either - there is no document 10 to prove against - so they were
# orphaned BY CONSTRUCTION and every future run would have tripped over them again.
#
# It surfaced as a Noir type error about `sealed` having length 5 when the circuit wanted 2, three
# steps into a regeneration, naming neither the stale file nor the count that produced it.
DOC_COUNT=$(node -e "console.log(require('${ROOT}/backend/contracts/test/fixtures/escrow_documents.json').documents.length)")
witnesses=()
for ((i = 0; i < DOC_COUNT; i++)); do
  w="Prover.escrow${i}.toml"
  [ -s "${w}" ] || {
    echo "ERROR: ${w} is missing but escrow_documents.json declares ${DOC_COUNT} documents." >&2
    echo "       Run: node tools/build-escrow-fixtures.js ${DOC_COUNT}" >&2
    exit 1
  }
  witnesses+=("${w}")
done
[ ${#witnesses[@]} -gt 1 ] || {
  echo "ERROR: found ${#witnesses[@]} witness(es); the identity tree needs more than one leaf." >&2
  echo "       Run: node tools/build-escrow-fixtures.js 3" >&2
  exit 1
}

for w in "${witnesses[@]}"; do
  i="${w#Prover.escrow}"; i="${i%.toml}"
  echo "==> escrow${i}"
  cp "${w}" Prover.toml
  nargo execute "escrow${i}" >/dev/null

  rm -rf "target/_e${i}"; mkdir -p "target/_e${i}"
  # `-t evm` REPLACED `--scheme ultra_honk --oracle_hash keccak` in the bb 5.x CLI, and this script
  # was left on the old spelling. bb accepted the dead flags, printed a plausible `Scheme is:
  # ultra_honk` banner, and produced a proof against the DEFAULT (Poseidon2) transcript - which its
  # own `-t evm` verifier then rejected at the pairing check. Exit codes and banners both looked
  # right; only verification disagreed. See codegen-verifiers.sh's header, which already says -t evm
  # must be passed to write_vk, prove, verify AND write_solidity_verifier.
  bb prove -t evm \
    -b target/escrow_envelope.json -w "target/escrow${i}.gz" -k target/vk -o "target/_e${i}" >/dev/null

  # bb EXITS 0 ON SOME FAILURES, so the artifact's existence is the real check - the same trap
  # codegen-verifiers.sh's `bb_checked` exists for.
  [ -s "target/_e${i}/proof" ] || { echo "ERROR: bb wrote no proof for escrow${i}" >&2; exit 1; }

  # A proof its own verifier rejects has shipped from this toolchain before (bb 1.2.0 + nargo
  # beta.1). `bb prove`'s exit code does not catch it; only verifying does.
  bb verify -t evm \
    -k target/vk -p "target/_e${i}/proof" -i "target/_e${i}/public_inputs" >/dev/null 2>&1 || {
    echo "ERROR: escrow${i}: bb generated a proof its OWN verifier rejects. Do not use it." >&2
    exit 1
  }

  cp "target/_e${i}/proof" "${FIXTURES}/escrow_envelope${i}.proof"
  cp "target/_e${i}/public_inputs" "${FIXTURES}/escrow_envelope${i}.public"
  rm -rf "target/_e${i}"
  echo "    $(wc -c <"${FIXTURES}/escrow_envelope${i}.proof" | tr -d ' ') bytes proof, \
$(( $(wc -c <"${FIXTURES}/escrow_envelope${i}.public" | tr -d ' ') / 32 )) public inputs"
done

# The UNNUMBERED fixture is what EscrowEnvelopeHonkVerifier.t.sol loads. It is escrow0 by
# definition, so alias rather than re-prove: two independent provings of the same witness give
# different bytes (they are zero-knowledge), and a suite asserting on one while another asserts on
# the other is a difference nobody would think to look for.
cp "${FIXTURES}/escrow_envelope0.proof" "${FIXTURES}/escrow_envelope.proof"
cp "${FIXTURES}/escrow_envelope0.public" "${FIXTURES}/escrow_envelope.public"
cp Prover.escrow0.toml Prover.toml

echo
echo "==> Done. ${#witnesses[@]} proofs; escrow_envelope.proof/.public aliased to escrow0."
echo "    Verify with: cd backend/contracts && forge test --match-path 'test/registry/*'"
