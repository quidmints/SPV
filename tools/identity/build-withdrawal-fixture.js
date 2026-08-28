#!/usr/bin/env node
/*
 * Regenerates BOTH withdraw_identity Forge fixtures, deterministically.
 *
 * WHY THIS EXISTS. The original baseline fixture was weak on two counts, and both are the kind of
 * weakness that keeps a suite green while removing its meaning:
 *
 *  1. DEGENERATE TREES. It used size-1 state and ASP trees. With one leaf and all-zero siblings the
 *     LeanIMT carry-up rule makes the root EQUAL the leaf, so `state_tree_depth`/`asp_tree_depth`
 *     were 0 and NO sibling was ever hashed. The proof verified, but the Merkle path - the thing a
 *     withdrawal actually depends on - was never exercised at any depth.
 *  2. NOT REPRODUCIBLE. Its provenance comment said "regenerate: withdraw_identity/Prover.toml",
 *     but no Prover.toml was ever tracked. The fixture could not be rebuilt from the repo, so it
 *     could not be audited or regenerated after a circuit change.
 *
 * Both fixtures produced here use MULTI-LEVEL trees (state depth 3, ASP depth 2) over trees holding
 * unrelated filler leaves, so real sibling hashing is on the proven path in both.
 *
 * The two differ in the PROVENANCE of the spent note, deliberately - that is why both are kept:
 *   - baseline: the spent note is the hand vector (value 10, label 20, nullifier 30, secret 40) from
 *     pp/src/commitment.nr's differential test, whose commitment/nullifier_hash were cross-checked
 *     against poseidon-solidity. Independent of the wallet's derivation, so it still catches a
 *     wallet that is self-consistently wrong.
 *   - wallet: the spent note is derived through the wallet's own seed derivation. Proves the client
 *     can produce a withdrawal the chain accepts.
 *
 * USAGE (from the repo root):
 *   cd frontend/identity-wallet && npm run build:pp
 *   node tools/build-withdrawal-fixture.js --build frontend/identity-wallet/build
 *
 *   The compiler flags live in frontend/identity-wallet/tsconfig.fixtures.json, which is also why
 *   the output MUST stay INSIDE frontend/identity-wallet: the compiled modules resolve
 *   @iden3/js-crypto by walking UP from their own directory looking for node_modules, and
 *   tools/build has none above it.
 *
 * then, per fixture:
 *   cd backend/circuits/withdraw_identity
 *   cp Prover.baseline.toml Prover.toml && nargo execute witness
 *   bb prove --scheme ultra_honk --oracle_hash keccak -b target/withdraw_identity.json \
 *     -w target/witness.gz -k target/vk -o target
 *   cp target/proof ../../contracts/test/fixtures/withdraw_identity.proof
 *   # ...and again with Prover.wallet.toml -> withdraw_identity_wallet.proof
 *
 * bb MUST be 1.2.0 - there are several installs on the dev machine, and the wrong one silently
 * produces a proof that bb's own verifier rejects (see backend/circuits/codegen-verifiers.sh).
 */
const path = require('path');
const fs = require('fs');
const common = require('./lib/fixture-common');

const argIdx = process.argv.indexOf('--build');
const BUILD = argIdx > -1 ? path.resolve(process.argv[argIdx + 1]) : path.join(__dirname, 'build');
if (!fs.existsSync(BUILD)) {
  console.error(`No compiled wallet modules at ${BUILD}. Run the tsc step in this file's header first.`);
  process.exit(1);
}

const { masterKeysFromMnemonic, depositSecrets, commitment, nullifierHash, StateTree, buildWithdrawalWitness } =
  common.loadWallet(BUILD);
/*
 * The identity witness is READ FROM DISK, not built here.
 *
 * It is emitted by IdentityRegistry.t.sol::test_EmitIdentityWitnessFixture, which registers three
 * identities through the REAL registry and calls getProof. This script cannot build it: the
 * identity tree is a @solarity SparseMerkleTree and there is deliberately no JS reimplementation of
 * one (see frontend/identity-wallet/src/pp/identityProof.ts) - a second sparse trie would be a
 * permanent byte-compatibility liability, and a witness built here would only prove that two of our
 * own implementations agree. Regenerate it with:
 *
 *   forge test --match-test test_EmitIdentityWitnessFixture
 */
// holderRoot derivation comes from the ASSEMBLER ITSELF (holderRootFromSk), not a local copy and
// not the SDK. The ASP tree is keyed by this value, so the tree-builder and the circuit must agree
// exactly; exporting one function is what stops a second implementation drifting. It also keeps
// this script loadable in plain Node - the SDK is a React Native package whose Noir module pulls in
// expo, which cannot load outside RN.
const { holderRootFromSk } = require(path.join(BUILD, 'pp/withdrawWitness.js'));

const { MNEMONIC, REVOCATION_SECRET } = common;

// ── the blacklist predicate ───────────────────────────────────────────────────────────────────
// Shared with build-fold-witnesses.js via fixture-common - see the note there on why one
// definition is the only thing that keeps two generators proving against the same tree.
const { Poseidon } = require(path.join(BUILD, 'pp/withdrawWitness.js'));
const { DOMAIN_LABEL, DOMAIN_DOCUMENT, makeBlacklistKey, documentIds, loadBlacklistWitness } = common;
const blacklistKey = makeBlacklistKey(Poseidon);

const FIXTURES = path.join(__dirname, '..', 'backend', 'contracts', 'test', 'fixtures');
const QUERIES_PATH = path.join(FIXTURES, 'withdrawal_blacklist_queries.json');
const BL_WITNESS_PATH = path.join(FIXTURES, 'withdrawal_blacklist_witness.json');

/** Every profile here is identity 0 - the one `loadIdentityWitness()` defaults to. */
const DOCUMENT_ID = documentIds()[0];
const keys = masterKeysFromMnemonic(MNEMONIC);
const identity = common.loadIdentityWitness();

// Pinned to pp/src/identity_asp.nr's published vector. FIXED, never random - these witnesses become
// committed fixtures, so a random value would make them unreproducible.
const SK_IDENTITY = 1234n;
const HOLDER_ROOT = holderRootFromSk(SK_IDENTITY);



const CONTEXT = 42_424_242n;
const CIRCUIT_DIR = path.join(__dirname, '..', 'backend', 'circuits', 'withdraw_identity');

/** Trees that are NEVER degenerate: filler leaves before and after ours force real depth. */
function buildTrees(spentCommitment) {
  const stateTree = new StateTree();
  for (const filler of [111n, 222n, 333n]) stateTree.insert(filler);
  stateTree.insert(spentCommitment);
  const stateLeafIndex = BigInt(stateTree.leaves.length - 1);
  stateTree.insert(444n); // further activity after ours

  return { stateTree, stateLeafIndex };
}

function emit(name, note, withdrawnValue, profileIndex) {
  const { stateTree, stateLeafIndex } = buildTrees(note.commitment);

  const w = buildWithdrawalWitness({
    note, stateLeafIndex, stateTree,
    masterKeys: keys, identity, revocationSecret: REVOCATION_SECRET,
    withdrawnValue, context: CONTEXT, withdrawalIndex: 0n,
    documentId: DOCUMENT_ID,
    blacklist: {
      root: BL_ROOT,
      label: exclusionAt(profileIndex * 2),
      document: exclusionAt(profileIndex * 2 + 1),
    },
  });

  // Independent cross-checks - not "the assembler agrees with itself".
  const eq = (a, b, m) => { if (a !== b) throw new Error(`${name}: ${m}: ${a} != ${b}`); };
  eq(w.pubSignals[1], nullifierHash(note.nullifier), 'nullifier hash');
  eq(w.pubSignals[3], stateTree.root, 'state_root');
  eq(w.pubSignals[5], identity.identityRoot, 'identity_root');
  eq(w.pubSignals[0], commitment(note.value - withdrawnValue, note.label, w.changeNote), 'change note');
  eq(stateTree.leaves[Number(stateLeafIndex)], note.commitment, 'state leaf index');

  // The guard this whole file exists for. The identity side is checked at load (siblings all zero);
  // only the state tree's depth is a public signal now.
  if (w.pubSignals[4] === 0n) {
    throw new Error(`${name}: DEGENERATE - the state tree has depth 0, so no sibling is hashed. Add filler leaves.`);
  }

  // A BOOLEAN MUST NOT BE QUOTED - Noir reads `is_old0 = true` and rejects `is_old0 = "true"`
  // with a message naming the argument, so it reads as a missing field rather than a quoting bug.
  const toml = Object.entries(w.inputs).map(([k, v]) =>
    Array.isArray(v) ? `${k} = [${v.map(x => `"${x}"`).join(', ')}]`
      : typeof v === 'boolean' ? `${k} = ${v}` : `${k} = "${v}"`
  ).join('\n') + '\n';
  const out = path.join(CIRCUIT_DIR, `Prover.${name}.toml`);
  fs.writeFileSync(out, toml);

  console.log(`\n${name}:  state_depth=${w.pubSignals[4]}`);
  ['new_commitment', 'existing_nullifier_hash', 'withdrawn_value', 'state_root',
   'state_tree_depth', 'identity_root', 'context', 'blacklist_root']
    .forEach((n, i) => console.log(`  [${i}] ${n} = 0x${w.pubSignals[i].toString(16).padStart(64, '0')}`));
  console.log(`  -> ${path.relative(path.join(__dirname, '..'), out)}`);
  return w.pubSignals;
}

// baseline: independent hand vector from pp/src/commitment.nr's differential test
const HAND = { value: 10n, label: 20n, nullifier: 30n, secret: 40n };
// ── the profiles, as data, so phase 1 can read their labels without emitting anything ────────
const scope = 12345n, label = 67890n;
const note0 = depositSecrets(keys, scope, 0n);
const walletValue = 10n ** 18n;

const PROFILES = [
  {
    name: 'baseline',
    note: {
      scope: 0n, label: HAND.label, index: 0, kind: 'deposit',
      nullifier: HAND.nullifier, secret: HAND.secret, value: HAND.value,
      commitment: commitment(HAND.value, HAND.label, { nullifier: HAND.nullifier, secret: HAND.secret }),
      spent: false,
    },
    withdrawnValue: 4n,
  },
  {
    // wallet: the client's own seed derivation
    name: 'wallet',
    note: {
      scope, label, index: 0, kind: 'deposit',
      nullifier: note0.nullifier, secret: note0.secret, value: walletValue,
      commitment: commitment(walletValue, label, note0), spent: false,
    },
    withdrawnValue: 3n * 10n ** 17n,
  },
];

// ── phase 1: hand the emitter this file's keys ───────────────────────────────────────────────
//
// SEPARATE FILES FROM THE BATCH GENERATOR'S, BUT THE SAME TREE. Two generators need exclusion
// proofs for different keys, and they must be proven against ONE root - a withdrawal proven against
// a different blacklist root than the pool holds cannot settle, whichever root is "right".
if (process.argv.includes('--queries')) {
  const hex = (k) => '0x' + k.toString(16).padStart(64, '0');
  const queries = PROFILES.flatMap((p) => [
    blacklistKey(DOMAIN_LABEL, p.note.label),
    blacklistKey(DOMAIN_DOCUMENT, DOCUMENT_ID),
  ]).map(hex);
  fs.writeFileSync(QUERIES_PATH, JSON.stringify(queries, null, 2) + '\n');
  console.log(`Wrote ${queries.length} queries to ${QUERIES_PATH}`);
  console.log('Next:  BLACKLIST_QUERIES=test/fixtures/withdrawal_blacklist_queries.json \\');
  console.log('       BLACKLIST_WITNESS=test/fixtures/withdrawal_blacklist_witness.json \\');
  console.log('       forge test --match-test test_EmitBlacklistWitnessFixture');
  process.exit(0);
}

// ── phase 2 ───────────────────────────────────────────────────────────────────────────────────
const { root: BL_ROOT, exclusionAt } = loadBlacklistWitness(BL_WITNESS_PATH, PROFILES.length * 2);

const EMITTED = {};
PROFILES.forEach((p, i) => { EMITTED[p.name] = emit(p.name, p.note, p.withdrawnValue, i); });

// ── the public signals, written where a test can read them ───────────────────────────────────
//
// PINNED CONSTANTS IN A TEST GO STALE SILENTLY AND FAIL AS `SumcheckFailed`, which names nothing.
// That is what a stale public input looks like on-chain: not "this number moved" but "the proof is
// invalid", so the search starts at the circuit and the verifier. Emitting them lets the suite
// assert its own constants against the fixture and say which number moved instead.
fs.writeFileSync(
  path.join(FIXTURES, 'withdraw_identity_pubsignals.json'),
  // HEX, because forge's parseJson reads a 0x string into a uint256 unambiguously while a decimal
  // string of 77 digits is a coin toss between a number and a string.
  JSON.stringify(EMITTED, (_k, v) => (typeof v === 'bigint' ? '0x' + v.toString(16).padStart(64, '0') : v), 2) + '\n',
);
console.log('\nWrote public signals for', Object.keys(EMITTED).join(', '));
