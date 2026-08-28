#!/usr/bin/env node
/*
 * The END-TO-END withdrawal fixture: a witness proved against the pool's REAL deployed state.
 *
 * WHY THIS FILE DID NOT EXIST UNTIL NOW. WithdrawEndToEnd.t.sol has always named
 * `tools/build-e2e-fixture.js` as its fixture provenance, but the commit that introduced the test
 * (019b47d) never added the script - the witness was assembled ad hoc in that session. So
 * `Prover.e2e.toml` was not reproducible from anything committed, and the comment sent readers
 * looking for a file that was never there. Checked: it appears nowhere in this repo's history, and
 * it cannot exist upstream either - `withdraw_identity` is this fork's own Noir circuit, while
 * upstream Privacy Pools is Circom/Groth16 and has no Prover.toml at all.
 *
 * TWO PASSES, because the witness must commit to values that DO NOT EXIST until the contracts are
 * deployed and deposited into. SCOPE is derived from the pool's address and `label` from SCOPE, so
 * neither can be chosen in advance - and any change to deployment ORDER in setUp moves the pool's
 * address and invalidates everything downstream.
 *
 *   PASS 1  forge test --match-test test_LogFixtureInputs -vv
 *           node tools/build-e2e-fixture.js --scope <SCOPE> --precommitments
 *             -> paste the four precommitments into WithdrawEndToEnd.t.sol
 *
 *   PASS 2  forge test --match-test test_LogFixtureInputs -vv        (values now settled)
 *           node tools/build-e2e-fixture.js --build frontend/identity-wallet/build \
 *             --scope <SCOPE> --label <LABEL> --leaf-index <I> --state-root <R> \
 *             --state-depth <D> --identity-root <IR> --context <C> --value <V> --withdrawn <W>
 *           cd backend/circuits/withdraw_identity && cp Prover.e2e.toml Prover.toml
 *           nargo execute && bb prove ... -> test/fixtures/withdraw_e2e.proof
 *
 * The tsc step is the SAME as build-withdrawal-fixture.js's, including --rootDir src. See that
 * file's header for why omitting it silently produces a flat build this script cannot load.
 */
const path = require('path');
const fs = require('fs');
const common = require('./lib/fixture-common');

const argv = process.argv;
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i > -1 ? argv[i + 1] : dflt;
};
const need = (name) => {
  const v = arg(name);
  if (v === undefined) { console.error(`missing --${name}`); process.exit(1); }
  return BigInt(v);
};

const BUILD = path.resolve(arg('build', path.join(__dirname, '..', 'frontend', 'identity-wallet', 'build')));

const { masterKeysFromMnemonic, depositSecrets, commitment, precommitment, nullifierHash,
        StateTree, buildWithdrawalWitness } = common.loadWallet(BUILD);
const { solidityPackedKeccak256 } = require(path.join(
  __dirname, '..', 'frontend', 'identity-wallet', 'node_modules', 'ethers',
));

const keys = masterKeysFromMnemonic(common.MNEMONIC);

const REVOCATION_SECRET = common.REVOCATION_SECRET;

// ── the blacklist predicate ───────────────────────────────────────────────────────────────────
// Shared with the other two generators via fixture-common: all three prove against ONE tree, and a
// key built a second way is absent from it in the only sense that matters.
const { Poseidon } = require(path.join(BUILD, 'pp/withdrawWitness.js'));
const { DOMAIN_LABEL, DOMAIN_DOCUMENT, makeBlacklistKey, documentIds, loadBlacklistWitness } = common;
const blacklistKey = makeBlacklistKey(Poseidon);
const FIXTURES_DIR = path.join(__dirname, '..', 'backend', 'contracts', 'test', 'fixtures');
const E2E_QUERIES_PATH = path.join(FIXTURES_DIR, 'e2e_blacklist_queries.json');
const E2E_BL_WITNESS_PATH = path.join(FIXTURES_DIR, 'e2e_blacklist_witness.json');
const E2E_DOCUMENT_ID = documentIds()[0];

const SCOPE = need('scope');

// ── PASS 1: the four precommitments this SCOPE implies ──────────────────────────────────────
if (argv.includes('--precommitments')) {
  // WRITTEN, NOT PRINTED FOR PASTING. These are a function of SCOPE, and SCOPE is a function of the
  // pool's address - so ANY constructor change moves them. Pinned in the test they went stale
  // silently and surfaced three steps downstream as `state_root disagrees with the chain`, which
  // points at the tree rather than at the deposits that built it.
  const values = [];
  for (let i = 0; i < 4; i++) values.push(precommitment(depositSecrets(keys, SCOPE, BigInt(i))));
  fs.writeFileSync(
    path.join(FIXTURES_DIR, 'e2e_precommitments.json'),
    JSON.stringify({
      scope: '0x' + SCOPE.toString(16).padStart(64, '0'),
      precommitments: values.map((v) => '0x' + v.toString(16).padStart(64, '0')),
    }, null, 2) + '\n',
  );
  console.log(`Wrote 4 precommitments for SCOPE ${SCOPE}`);
  process.exit(0);
}

// ── RAGEQUIT witness ────────────────────────────────────────────────────────────────────────
// Deposit index 0 - deliberately NOT the note the withdrawal spends (index 1), so the two
// end-to-end paths cannot mask each other. Its label, like every other, comes from the pool's own
// nonce rule, so it moves whenever SCOPE moves.
if (argv.includes('--ragequit')) {
  const FIELD_RQ = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
  const idx = BigInt(arg('rq-index', '0'));
  const value = BigInt(arg('value', String(10n ** 18n)));
  const s0 = depositSecrets(keys, SCOPE, idx);
  const label = BigInt(solidityPackedKeccak256(['uint256', 'uint256'], [SCOPE, idx + 1n])) % FIELD_RQ;
  const c = commitment(value, label, s0);
  const nh = nullifierHash(s0.nullifier);

  const toml = [
    `commitment_hash = "${c}"`, `nullifier_hash = "${nh}"`,
    `value = "${value}"`, `label = "${label}"`,
    `nullifier = "${s0.nullifier}"`, `secret = "${s0.secret}"`,
  ].join('\n') + '\n';
  fs.writeFileSync(
    path.join(__dirname, '..', 'backend', 'circuits', 'ragequit', 'Prover.e2e.toml'), toml);
  // WRITTEN, NOT PRINTED FOR PASTING - same reason as the precommitments above. All three are
  // functions of SCOPE, so a constructor change moves them, and pinned in the test they surface as
  // `OnlyOriginalDepositor` (the label no longer names a deposit this depositor made), which points
  // at authorisation rather than at a stale fixture.
  const hex = (v) => '0x' + v.toString(16).padStart(64, '0');
  fs.writeFileSync(
    path.join(FIXTURES_DIR, 'ragequit_e2e_pubsignals.json'),
    JSON.stringify({
      scope: hex(SCOPE),
      commitment: hex(c), nullifierHash: hex(nh), value: hex(value), label: hex(label),
    }, null, 2) + '\n',
  );
  console.log('ragequit witness written:');
  console.log(`  RQ_COMMITMENT     = ${c}`);
  console.log(`  RQ_NULLIFIER_HASH = ${nh}`);
  console.log(`  RQ_LABEL          = ${label}`);
  process.exit(0);
}

// ── PASS 2: the witness ─────────────────────────────────────────────────────────────────────
const LABEL = need('label');
const LEAF_INDEX = need('leaf-index');
const STATE_ROOT = need('state-root');
const STATE_DEPTH = need('state-depth');
const IDENTITY_ROOT = need('identity-root');
const CONTEXT = need('context');
const VALUE = need('value');
const WITHDRAWN = need('withdrawn');

const identity = common.loadIdentityWitness();

if (identity.identityRoot !== IDENTITY_ROOT) {
  throw new Error(
    `identity witness root ${identity.identityRoot} != the chain's ${IDENTITY_ROOT}. The emitter and ` +
    'WithdrawEndToEnd must register the SAME identities in the SAME order - re-run the emitter.',
  );
}

// The note is OURS: deposit index LEAF_INDEX under this SCOPE, carrying the on-chain label.
const secrets = depositSecrets(keys, SCOPE, LEAF_INDEX);
const note = {
  scope: SCOPE, label: LABEL, index: Number(LEAF_INDEX), kind: 'deposit',
  nullifier: secrets.nullifier, secret: secrets.secret, value: VALUE,
  commitment: commitment(VALUE, LABEL, secrets), spent: false,
};

// Mirror the chain's state tree: four deposits, ours at LEAF_INDEX.
//
// EVERY leaf must be reconstructed, not just ours - a LeanIMT root depends on all of them. The pool
// derives each label from its own nonce, `keccak256(SCOPE, nonce) % FIELD` with nonce starting at
// 1, so all four are derivable here rather than needing to be read off the chain. An earlier draft
// inserted a placeholder for the other three; the state_root cross-check below caught it, which is
// exactly what that check is for.
const FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const stateTree = new StateTree();
for (let i = 0; i < 4; i++) {
  const s = depositSecrets(keys, SCOPE, BigInt(i));
  const lbl = BigInt(solidityPackedKeccak256(['uint256', 'uint256'], [SCOPE, BigInt(i + 1)])) % FIELD;
  stateTree.insert(commitment(VALUE, lbl, s));
}

// Phase 1: this generator's label arrives as --label, so the queries are emitted here rather than
// up front like the batch generator's.
if (argv.includes('--queries')) {
  const hex = (k) => '0x' + k.toString(16).padStart(64, '0');
  const queries = [
    blacklistKey(DOMAIN_LABEL, note.label),
    blacklistKey(DOMAIN_DOCUMENT, E2E_DOCUMENT_ID),
  ].map(hex);
  fs.writeFileSync(E2E_QUERIES_PATH, JSON.stringify(queries, null, 2) + '\n');
  console.log(`Wrote ${queries.length} queries to ${E2E_QUERIES_PATH}`);
  console.log('Next:  BLACKLIST_QUERIES=test/fixtures/e2e_blacklist_queries.json \\');
  console.log('       BLACKLIST_WITNESS=test/fixtures/e2e_blacklist_witness.json \\');
  console.log('       forge test --match-test test_EmitBlacklistWitnessFixture');
  process.exit(0);
}

const { root: E2E_BL_ROOT, exclusionAt: e2eExclusionAt } =
  loadBlacklistWitness(E2E_BL_WITNESS_PATH, 2);

const w = buildWithdrawalWitness({
  note, stateLeafIndex: LEAF_INDEX, stateTree,
  masterKeys: keys, identity, revocationSecret: REVOCATION_SECRET,
  withdrawnValue: WITHDRAWN, context: CONTEXT, withdrawalIndex: 0n,
  documentId: E2E_DOCUMENT_ID,
  blacklist: { root: E2E_BL_ROOT, label: e2eExclusionAt(0), document: e2eExclusionAt(1) },
});

const eq = (a, b, m) => { if (a !== b) throw new Error(`${m}: ${a} != ${b}`); };
eq(w.pubSignals[3], STATE_ROOT, 'state_root disagrees with the chain');
eq(w.pubSignals[4], STATE_DEPTH, 'state_tree_depth disagrees with the chain');
eq(w.pubSignals[5], IDENTITY_ROOT, 'identity_root disagrees with the chain');
eq(w.pubSignals[6], CONTEXT, 'context disagrees with the chain');
if (w.pubSignals[4] === 0n) throw new Error('DEGENERATE: state tree depth 0, no sibling hashed');

const out = path.join(__dirname, '..', 'backend', 'circuits', 'withdraw_identity', 'Prover.e2e.toml');
common.writeProverToml(out, w.inputs);

// The signals, beside the proof they belong to, for the same reason build-withdrawal-fixture.js
// writes its own: pinned in a test they go stale as `SumcheckFailed()`, which names nothing.
fs.writeFileSync(
  path.join(FIXTURES_DIR, 'withdraw_e2e_pubsignals.json'),
  JSON.stringify(w.pubSignals.map((v) => '0x' + v.toString(16).padStart(64, '0')), null, 2) + '\n',
);

console.log('e2e witness written. Public signals:');
common.logPublicSignals(w.pubSignals);
