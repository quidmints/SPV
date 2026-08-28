/*
 * Shared by tools/build-withdrawal-fixture.js and tools/build-e2e-fixture.js.
 *
 * WHY TWO ENTRY POINTS AND ONE LIBRARY. The e2e generator has to live at
 * `tools/build-e2e-fixture.js` specifically, because WithdrawEndToEnd.t.sol names that exact path as
 * its fixture provenance - folding it into the other script as a flag would leave that reference
 * pointing at nothing, which is the very defect that made it necessary to write. But the two
 * scripts were then carrying the same mnemonic, the same escrow secret, the same identity-witness
 * loader and the same TOML writer, so a change to any of them had to be made twice or silently
 * drift. The entry points stay separate; the logic does not.
 */
const path = require('path');
const fs = require('fs');
const { createRequire } = require('module');
const walletRequire = createRequire(
  path.join(__dirname, '..', '..', 'frontend', 'identity-wallet', 'package.json'),
);
const { poseidon } = walletRequire('@iden3/js-crypto');

/** Foundry's standard test mnemonic. Nothing here guards value; it must simply be FIXED. */
const MNEMONIC = 'test test test test test test test test test test test junk';

/**
 * Domain separator for the revocation secret: the big-endian bytes of "pp:revocation-secret:v1".
 *
 * MUST equal escrow_envelope's REVOCATION_SECRET_DOMAIN, which asserts itself against the same
 * string in `test_revocation_domain_is_the_string_it_claims_to_be`.
 */
const REVOCATION_SECRET_DOMAIN = BigInt(
  '0x' + Buffer.from('pp:revocation-secret:v1', 'ascii').toString('hex'),
);

/**
 * The identity's revocation secret. DERIVED, no longer chosen (TODO.md sec. 2.18a).
 *
 * While it was a free constant (`987654321n` lived here), a revoked user could escrow a FRESH
 * secret against the same passport, land a different commitment, and register clean - the blacklist
 * was evadable by exactly the people it was applied to. One identity now yields exactly one
 * commitment, which is what makes `IdentityRegistry.registered[commitment]` a per-holder guard.
 *
 * DEFINED HERE, NOT IN build-escrow-fixtures.js, because three generators need it and the wallet's
 * withdrawal witness must derive the SAME value - a second copy that drifts produces an inclusion
 * proof for someone else's leaf, which fails as `InvalidIdentityRoot` and names nothing useful.
 */
function deriveRevocationSecret(skIdentity) {
  return poseidon.hash([skIdentity, REVOCATION_SECRET_DOMAIN]);
}

/**
 * Identity 0's sk_identity - pp/src/identity_asp.nr's published vector, and escrow0's. Every
 * withdrawal fixture is for THIS identity's leaf.
 */
const SK_IDENTITY_0 =
  287325206580568373396753082727527032974277810276511506339905121597618812140n;

/** escrow0's revocation secret. Its Poseidon commitment IS the identity tree's key. */
const REVOCATION_SECRET = deriveRevocationSecret(SK_IDENTITY_0);

/**
 * The identity scalars behind the three registered escrow fixtures, in emitted order.
 *
 * LIVES HERE, next to SK_IDENTITY_0, because two generators need it: build-escrow-fixtures.js makes
 * the registrations and build-fold-witnesses.js spends against them, and the second must derive the
 * SAME revocation secret the first escrowed. A private copy in either would still produce a witness,
 * just one whose Poseidon commitment names a leaf that is not in the tree - which surfaces as an
 * unexplained inclusion failure rather than as the drift it is.
 *
 * The order is load-bearing: index i here is the identity whose witness is at index i in
 * identity_witness.json, because both come from escrow_envelope<i>.
 */
const PINNED_SK_IDENTITIES = [
  SK_IDENTITY_0,
  111222333444555666777888999n,
  999888777666555444333222111n,
];

/**
 * Identity `i`'s scalar. The first three are pinned to published vectors; beyond that they are
 * DERIVED, so the set can grow to any size without a hand-maintained list.
 *
 * ONE FUNCTION, NOT A LIST PLUS A FALLBACK. build-escrow-fixtures.js used to carry
 * `SK_IDENTITIES[i] ?? BigInt(1000 + i)` privately - so past index 2 the escrow generator invented
 * scalars the withdrawal generator knew nothing about, and a batch built on identity 3 would have
 * derived a revocation secret whose commitment is in nobody's tree. That fails as an inclusion error
 * naming neither generator.
 */
function skIdentity(i) {
  return PINNED_SK_IDENTITIES[i] ?? BigInt(1000 + i);
}

const IDENTITY_WITNESS_PATH = path.join(
  __dirname, '..', '..', 'backend', 'contracts', 'test', 'fixtures', 'identity_witness.json',
);

/**
 * Load the compiled wallet modules.
 *
 * The build MUST sit inside frontend/identity-wallet, or these cannot resolve @iden3/js-crypto -
 * node walks UP from a file's own directory looking for node_modules, and tools/ has none above it.
 */
function loadWallet(buildDir) {
  if (!fs.existsSync(buildDir)) {
    console.error(
      `No compiled wallet modules at ${buildDir}.\n` +
      'cd frontend/identity-wallet && npm run build:pp\n',
    );
    process.exit(1);
  }
  return {
    ...require(path.join(buildDir, 'pp/notes.js')),
    ...require(path.join(buildDir, 'pp/stateTree.js')),
    ...require(path.join(buildDir, 'pp/withdrawWitness.js')),
  };
}

/**
 * The identity inclusion witness for identity `index`, emitted by the REAL registry.
 *
 * Never rebuilt off-chain: the identity tree is a @solarity SparseMerkleTree and there is
 * deliberately no JS reimplementation of one (see frontend/identity-wallet/src/pp/identityProof.ts).
 * A witness built here would only prove that two of our own implementations agree.
 *
 * The fixture carries all three registered identities against ONE shared root, because a batch of
 * folded withdrawals is several different people against one registry state. `index` selects which;
 * it defaults to 0, which is the identity every older fixture was built for.
 */
function loadIdentityWitness(index = 0) {
  if (!fs.existsSync(IDENTITY_WITNESS_PATH)) {
    console.error(
      `No identity witness at ${IDENTITY_WITNESS_PATH}.\n` +
      'Run:  forge test --match-test test_EmitIdentityWitnessFixture',
    );
    process.exit(1);
  }
  const raw = JSON.parse(fs.readFileSync(IDENTITY_WITNESS_PATH, 'utf8'));
  const count = raw.commitments.length;
  if (index >= count) {
    throw new Error(`identity witness ${index} requested, but the fixture holds ${count}`);
  }
  const stride = raw.siblings.length / count;
  const witness = {
    identityRoot: BigInt(raw.root),
    commitment: BigInt(raw.commitments[index]),
    siblings: raw.siblings.slice(index * stride, (index + 1) * stride).map((x) => BigInt(x)),
  };
  // A tree with one leaf has an EMPTY path, so nothing would ever be hashed and the fixture would
  // prove nothing about the Merkle path it claims to walk.
  if (witness.siblings.every((x) => x === 0n)) {
    throw new Error(
      `identity witness ${index} is DEGENERATE - every sibling is zero. The emitter must register ` +
      'more than one identity.',
    );
  }
  return witness;
}

/** How many identities the emitted fixture holds. */
function identityWitnessCount() {
  return JSON.parse(fs.readFileSync(IDENTITY_WITNESS_PATH, 'utf8')).commitments.length;
}

/** Write a Noir Prover.toml from an inputs map. */
function writeProverToml(outPath, inputs) {
  const toml = Object.entries(inputs).map(([k, v]) =>
    // A BOOLEAN MUST NOT BE QUOTED. Noir reads `is_old0 = true`; `is_old0 = "true"` fails to
    // deserialize, and the message names the argument rather than the quoting, so it reads as a
    // missing field. Every other input is a decimal string by convention.
    Array.isArray(v)
      ? `${k} = [${v.map((x) => `"${x}"`).join(', ')}]`
      : typeof v === 'boolean' ? `${k} = ${v}` : `${k} = "${v}"`
  ).join('\n') + '\n';
  fs.writeFileSync(outPath, toml);
  return outPath;
}

/** The eight public signals, named, for logging a generated witness. */
const PUBLIC_SIGNAL_NAMES = [
  'new_commitment', 'existing_nullifier_hash', 'withdrawn_value', 'state_root',
  'state_tree_depth', 'identity_root', 'context', 'blacklist_root',
];

function logPublicSignals(pubSignals) {
  PUBLIC_SIGNAL_NAMES.forEach((n, i) => console.log(`  [${i}] ${n} = ${pubSignals[i]}`));
}

/* ────────────────────────────────────────────────────────────────────────────────────────────
 * THE BLACKLIST PREDICATE, SHARED BY BOTH WITNESS GENERATORS.
 *
 * Here rather than in either caller because they must agree EXACTLY: the batch generator and the
 * standalone withdrawal generator prove against ONE root, and a key built two ways is absent from
 * the tree in the only sense that matters - every exclusion proof would pass, for the wrong reason,
 * forever. One definition is the only way that stays true.
 * ──────────────────────────────────────────────────────────────────────────────────────────── */

/** Domains from backend/circuits/pp/src/blacklist.nr. A label and a passport number are both
 *  Fields; without separation a sanctioned document could collide with an innocent label. */
const DOMAIN_LABEL = 1n;
const DOMAIN_ADDRESS = 2n;
const DOMAIN_DOCUMENT = 3n;

/** `blacklist_key(domain, identifier)`. Poseidon comes from the caller's compiled wallet build. */
const makeBlacklistKey = (Poseidon) => (domain, identifier) => Poseidon.hash([domain, identifier]);

/** documentId per identity index, from the fixture that owns the DG1. */
function documentIds() {
  const p = path.join(__dirname, '..', '..', 'backend', 'contracts', 'test', 'fixtures',
    'escrow_documents.json');
  return JSON.parse(fs.readFileSync(p, 'utf8')).documents.map((d) => BigInt(d.documentId));
}

/**
 * Read an emitted witness file and index it positionally.
 *
 * `expected` is asserted because a STALE file is the failure mode here: it exists, parses, and
 * describes a different set of queries. The proof then fails in-circuit with an exclusion error
 * that says nothing about which side is wrong.
 */
function loadBlacklistWitness(witnessPath, expected) {
  if (!fs.existsSync(witnessPath)) {
    console.error(`No blacklist witness at ${witnessPath}.\nRun the --queries phase, then` +
      ' forge test --match-test test_EmitBlacklistWitnessFixture\n');
    process.exit(1);
  }
  const raw = JSON.parse(fs.readFileSync(witnessPath, 'utf8'));
  if (raw.oldKey.length !== expected) {
    console.error(`${witnessPath} holds ${raw.oldKey.length} witnesses, need ${expected}. ` +
      'Re-run the --queries phase and the emitter.\n');
    process.exit(1);
  }
  const depth = raw.siblings.length / raw.oldKey.length;
  return {
    root: BigInt(raw.root),
    exclusionAt: (k) => ({
      siblings: raw.siblings.slice(k * depth, (k + 1) * depth).map(BigInt),
      oldKey: BigInt(raw.oldKey[k]),
      oldValue: BigInt(raw.oldValue[k]),
      isOld0: BigInt(raw.isOld0[k]) !== 0n,
    }),
  };
}

module.exports = {
  MNEMONIC, REVOCATION_SECRET, REVOCATION_SECRET_DOMAIN, SK_IDENTITY_0, skIdentity,
  deriveRevocationSecret, IDENTITY_WITNESS_PATH,
  loadWallet, loadIdentityWitness, identityWitnessCount, writeProverToml, PUBLIC_SIGNAL_NAMES,
  DOMAIN_LABEL, DOMAIN_ADDRESS, DOMAIN_DOCUMENT, makeBlacklistKey, documentIds,
  loadBlacklistWitness,
  logPublicSignals,
};
