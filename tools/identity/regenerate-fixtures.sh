#!/usr/bin/env bash
#
# Rebuild every proof fixture the withdrawal path depends on, in dependency order.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# WHY THIS FILE EXISTS. Each chain below was reconstructed by hand at least once, and one of them
# (`withdraw_e2e.proof`) could not be reconstructed AT ALL: its generator takes nine arguments with
# no defaults, and nothing recorded the values used, so the fixture was rebuildable only by whoever
# still had the deployment that produced it. When the circuit changed under it there was no way
# back. The generator's own header makes that complaint about the fixture IT replaced, so it had
# already happened twice before anyone wrote the sequence down. This is the sequence.
#
# ⚠️ ORDER IS NOT COSMETIC. Identity leaves come from escrow PROOFS, so a change to the leaf
# construction invalidates every downstream witness, and rebuilding them out of order produces
# artifacts that verify individually and cannot settle together.
#
#     escrow proofs ──► identity_witness.json ──► batch/withdrawal/e2e witnesses ──► verifiers
#
# ⛔ A VERIFYING KEY'S EXISTENCE IS NOT ITS FRESHNESS. A vk from a previous version of a circuit is
# present, non-empty and wrong: `bb prove -k` uses it happily and the proof fails at the pairing
# check, which reads as a broken circuit rather than a stale key. Every stage here regenerates the
# key before it proves anything.
#
# Usage:  tools/regenerate-fixtures.sh [escrow|withdrawal|batch|e2e|trees|all]
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# bb is an npm package, NOT a PATH binary and NOT bbup - see codegen-verifiers.sh's REQUIRED_BB.
export PATH="$ROOT/backend/circuits/node_modules/.bin:$PATH"
BUILD=frontend/identity-wallet/build
STAGE="${1:-all}"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# The wallet's compiled modules are what every generator builds witnesses with.
step "compile the wallet's pp modules"
(cd frontend/identity-wallet && npm run build:pp >/dev/null)

# ── escrow: the head of the chain. Identity leaves are these proofs' public inputs ──────────────
if [[ "$STAGE" == "escrow" || "$STAGE" == "all" ]]; then
  step "escrow documents, registration witness, prover inputs"
  node tools/build-escrow-fixtures.js --documents 3
  (cd backend/contracts && forge test --match-test test_EmitRegistrationWitnessFixture >/dev/null)
  node tools/build-escrow-fixtures.js 3

  step "escrow: recompile, regenerate the vk, prove"
  (cd backend/circuits/escrow_envelope && nargo compile >/dev/null \
    && bb write_vk -t evm -b target/escrow_envelope.json -o target >/dev/null)
  bash tools/prove-escrow-fixtures.sh

  step "escrow: the solidity verifier"
  # bb emits `contract HonkVerifier`; every consumer imports it by its own name.
  (cd backend/circuits/escrow_envelope \
    && bb write_solidity_verifier -t evm -k target/vk \
         -o ../../contracts/contracts/registry/verifiers/EscrowEnvelopeHonkVerifier.sol >/dev/null)
  perl -pi -e 's/^contract HonkVerifier is/contract EscrowEnvelopeHonkVerifier is/' \
    backend/contracts/contracts/registry/verifiers/EscrowEnvelopeHonkVerifier.sol

  step "the identity tree, emitted by the REAL registry"
  (cd backend/contracts && forge test --match-test test_EmitIdentityWitnessFixture >/dev/null)
fi

# ── the withdrawal circuit's own key and verifier ───────────────────────────────────────────────
if [[ "$STAGE" == "withdrawal" || "$STAGE" == "batch" || "$STAGE" == "e2e" || "$STAGE" == "trees" || "$STAGE" == "all" ]]; then
  step "withdraw_identity: recompile, vk, solidity verifier, recursion leaf key"
  (cd backend/circuits/withdraw_identity \
    && nargo compile >/dev/null \
    && bb write_vk -t evm -b target/withdraw_identity.json -o target >/dev/null \
    && bb write_solidity_verifier -t evm -k target/vk \
         -o ../../contracts/contracts/pool/verifiers/WithdrawalHonkVerifier.sol >/dev/null)
  perl -pi -e 's/^contract HonkVerifier is/contract WithdrawalHonkVerifier is/' \
    backend/contracts/contracts/pool/verifiers/WithdrawalHonkVerifier.sol
  # `-t noir-recursive` is a DIFFERENT key from the `-t evm` one above; the trees fold with this.
  (cd backend/circuits && bb write_vk -t noir-recursive \
    -b withdraw_identity/target/withdraw_identity.json -o withdraw_identity/rec >/dev/null)
fi

# ── the two standalone withdrawal profiles ──────────────────────────────────────────────────────
if [[ "$STAGE" == "withdrawal" || "$STAGE" == "all" ]]; then
  step "withdrawal profiles: blacklist queries -> witnesses -> prover inputs"
  node tools/build-withdrawal-fixture.js --queries --build "$BUILD"
  (cd backend/contracts && BLACKLIST_QUERIES=test/fixtures/withdrawal_blacklist_queries.json \
     BLACKLIST_WITNESS=test/fixtures/withdrawal_blacklist_witness.json \
     forge test --match-test test_EmitBlacklistWitnessFixture >/dev/null)
  node tools/build-withdrawal-fixture.js --build "$BUILD"

  step "withdrawal profiles: prove"
  (cd backend/circuits/withdraw_identity
   for pair in "baseline:withdraw_identity" "wallet:withdraw_identity_wallet"; do
     n="${pair%%:*}"; out="${pair##*:}"
     cp "Prover.${n}.toml" Prover.toml
     nargo execute "w_${n}" >/dev/null
     bb prove -t evm -b target/withdraw_identity.json -w "target/w_${n}.gz" -k target/vk -o "target/_p${n}" >/dev/null
     # bb EXITS 0 ON SOME FAILURES, so verify rather than trusting the exit code.
     bb verify -t evm -k target/vk -p "target/_p${n}/proof" -i "target/_p${n}/public_inputs" >/dev/null
     cp "target/_p${n}/proof" "../../contracts/test/fixtures/${out}.proof"
     echo "  ${out}.proof verified"
   done)
fi

# ── the end-to-end fixture, against a live deterministic deployment ─────────────────────────────
if [[ "$STAGE" == "e2e" || "$STAGE" == "all" ]]; then
  step "e2e: read the deployment's own parameters"
  (cd backend/contracts && forge test --match-test test_EmitE2EFixtureParams >/dev/null)
  P=backend/contracts/test/fixtures/e2e_params.json
  get() { node -e "console.log(require('./$P').$1)"; }
  ARGS="--build $BUILD --scope $(get scope) --label $(get label) --leaf-index $(get leafIndex)
        --state-root $(get stateRoot) --state-depth $(get stateTreeDepth)
        --identity-root $(get identityRoot) --context $(get context)
        --value $(get value) --withdrawn $(get withdrawn)"

  # ⚠️ TWO PASSES, AND THE FIRST ONE IS EXPECTED TO BE WRONG. The four deposits are wallet-derived
  # from SCOPE, and SCOPE is a function of the pool's ADDRESS - so the scope cannot be known until
  # the pool exists, and the pool's deposits cannot be right until the scope is known. Pass one
  # deposits placeholders and learns the scope; pass two deposits the real ones and the state root
  # the generator cross-checks against finally matches.
  step "e2e: derive this scope's precommitments, then re-read the parameters"
  node tools/build-e2e-fixture.js --build "$BUILD" --scope "$(get scope)" --precommitments
  (cd backend/contracts && forge test --match-test test_EmitE2EFixtureParams >/dev/null)
  ARGS="--build $BUILD --scope $(get scope) --label $(get label) --leaf-index $(get leafIndex)
        --state-root $(get stateRoot) --state-depth $(get stateTreeDepth)
        --identity-root $(get identityRoot) --context $(get context)
        --value $(get value) --withdrawn $(get withdrawn)"

  step "e2e: blacklist queries -> witnesses -> prover inputs"
  # shellcheck disable=SC2086
  node tools/build-e2e-fixture.js $ARGS --queries
  (cd backend/contracts && BLACKLIST_QUERIES=test/fixtures/e2e_blacklist_queries.json \
     BLACKLIST_WITNESS=test/fixtures/e2e_blacklist_witness.json \
     forge test --match-test test_EmitBlacklistWitnessFixture >/dev/null)
  # shellcheck disable=SC2086
  node tools/build-e2e-fixture.js $ARGS

  step "e2e: prove"
  (cd backend/circuits/withdraw_identity
   cp Prover.e2e.toml Prover.toml
   nargo execute w_e2e >/dev/null
   bb prove -t evm -b target/withdraw_identity.json -w target/w_e2e.gz -k target/vk -o target/_e2e >/dev/null
   bb verify -t evm -k target/vk -p target/_e2e/proof -i target/_e2e/public_inputs >/dev/null
   cp target/_e2e/proof ../../contracts/test/fixtures/withdraw_e2e.proof
   echo "  withdraw_e2e.proof verified")

  # ⚠️ RAGEQUIT IS PART OF THIS STAGE, NOT A SEPARATE CONCERN. Its commitment, nullifier hash and
  # label are all derived from the SAME scope, so it goes stale with exactly the same changes - and
  # it fails as `OnlyOriginalDepositor`, which points at authorisation rather than at a fixture. It
  # was missing from this script until the anchor change moved SCOPE and three ragequit tests broke.
  step "ragequit: witness, prove, install"
  node tools/build-e2e-fixture.js --build "$BUILD" --scope "$(get scope)" --ragequit
  (cd backend/circuits/ragequit
   nargo compile >/dev/null
   bb write_vk -t evm -b target/ragequit.json -o target >/dev/null
   bb write_solidity_verifier -t evm -k target/vk \
     -o ../../contracts/contracts/pool/verifiers/RagequitHonkVerifier.sol >/dev/null
   perl -pi -e 's/^contract HonkVerifier is/contract RagequitHonkVerifier is/' \
     ../../contracts/contracts/pool/verifiers/RagequitHonkVerifier.sol
   cp Prover.e2e.toml Prover.toml
   nargo execute rq_e2e >/dev/null
   bb prove -t evm -b target/ragequit.json -w target/rq_e2e.gz -k target/vk -o target/_rq >/dev/null
   bb verify -t evm -k target/vk -p target/_rq/proof -i target/_rq/public_inputs >/dev/null
   cp target/_rq/proof ../../contracts/test/fixtures/ragequit_e2e.proof
   echo "  ragequit_e2e.proof verified")
fi

# ── the recursion trees ─────────────────────────────────────────────────────────────────────────
#
# ⚠️ EACH TREE NEEDS A WITNESS SET GENERATED AT ITS OWN COUNT, and this is the least obvious thing
# in the file. Padding lives in the WITNESSES, not in the tree script: `--count 5` pads to 8 with
# three zero-value members, while `--count 32` is 32 real ones. Build n8 from a --count 32 set and
# its first eight members are all real, so `test_APaddedBatchReproducesItsRoot` finds no padding.
# The witness directory therefore cannot simultaneously reproduce all three trees - it is left
# holding the 32-member set, which is what the repo tracks.
if [[ "$STAGE" == "batch" || "$STAGE" == "trees" || "$STAGE" == "all" ]]; then
  for spec in "5:8" "16:16" "32:32"; do
    n="${spec%%:*}"
    step "tree n${spec##*:}: witnesses at --count ${n}, then fold (this is the slow part)"
    node tools/build-fold-witnesses.js --queries --count "$n" --build "$BUILD"
    (cd backend/contracts && forge test --match-test test_EmitBlacklistWitnessFixture >/dev/null)
    node tools/build-fold-witnesses.js --count "$n" --build "$BUILD"
    (cd backend/circuits && python3 build-recursion-tree.py "$n")
  done
fi

step "done - now run the gates"
echo "  cd backend/contracts && forge test"
echo "  cd backend/circuits/pp && nargo test"
echo "  cd frontend/identity-wallet && node --test 'src/pp/*.test.ts'"
