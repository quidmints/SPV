// Run: node --test src/pp/notes.test.ts
//
// THE DERIVATION EVERYTHING ELSE RESTS ON, and until now untested — the module could be loaded, but
// nothing in `pp/` had tests because most of its siblings could not be (see deposit.test.ts).
//
// WHY THESE PROPERTIES. Every note the wallet will ever own comes from `masterKeysFromMnemonic`, and
// a fault here does not announce itself: wrong secrets still hash, still deposit, still produce a
// commitment. The money is simply unspendable, or spendable by the wrong derivation, and the user
// finds out when they try to withdraw. So what is pinned is:
//
//   1. DETERMINISM AND SEED-BINDING — the same mnemonic always gives the same keys, and a different
//      mnemonic never gives the same ones. This is what makes seed-phrase recovery work at all.
//   2. DOMAIN SEPARATION between the nullifier and secret halves, and across scope/label/index.
//      If two notes derive the same nullifier, the second is unspendable — the pool sees a spent
//      nullifier and rejects it.
//   3. EVERY INPUT IS BOUND into each hash, so no field is silently ignored.
//   4. FIELD DISCIPLINE — every derived value must be a valid BN254 element, or Poseidon rejects it
//      downstream and the failure surfaces far from its cause.
import test from "node:test";
import assert from "node:assert";
import {
  FIELD,
  commitment,
  depositSecrets,
  masterKeysFromMnemonic,
  nullifierHash,
  precommitment,
  withdrawalSecrets,
} from "./notes.ts";

/** REAL 24-word phrases with valid BIP39 checksums — ethers validates, so invented ones throw. */
const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";
const OTHER_PHRASE =
  "legal winner thank year wave sausage worth useful legal winner thank year " +
  "wave sausage worth useful legal winner thank year wave sausage worth title";

const KEYS = masterKeysFromMnemonic(PHRASE);
const SCOPE = 0x1234567890abcdefn;
const LABEL = 0xfedcba0987654321n;

const inField = (x: bigint) => x >= 0n && x < FIELD;

// ── 1. determinism and seed-binding ───────────────────────────────────────────────────────────

test("the same mnemonic always derives the same master keys", () => {
  const again = masterKeysFromMnemonic(PHRASE);
  assert.strictEqual(again.masterNullifier, KEYS.masterNullifier);
  assert.strictEqual(again.masterSecret, KEYS.masterSecret);
});

test("a different mnemonic derives entirely different master keys", () => {
  const theirs = masterKeysFromMnemonic(OTHER_PHRASE);
  assert.notStrictEqual(theirs.masterNullifier, KEYS.masterNullifier);
  assert.notStrictEqual(theirs.masterSecret, KEYS.masterSecret);
  // ...and no half of one seed's keys may equal the other half of another's.
  assert.notStrictEqual(theirs.masterNullifier, KEYS.masterSecret);
  assert.notStrictEqual(theirs.masterSecret, KEYS.masterNullifier);
});

// ── 2. domain separation ──────────────────────────────────────────────────────────────────────

test("the nullifier and secret halves are independent", () => {
  // They come from BIP44 accounts 0 and 1. If they ever coincided, knowing one would give the other,
  // and the precommitment would collapse to a single secret.
  assert.notStrictEqual(KEYS.masterNullifier, KEYS.masterSecret);
  const note = depositSecrets(KEYS, SCOPE, 0n);
  assert.notStrictEqual(note.nullifier, note.secret);
});

test("scope and index each separate notes", () => {
  const seen = new Set<bigint>();
  for (const scope of [SCOPE, SCOPE + 1n]) {
    for (let i = 0n; i < 8n; i++) {
      const { nullifier } = depositSecrets(KEYS, scope, i);
      assert.ok(!seen.has(nullifier), `nullifier repeated at scope ${scope} index ${i}`);
      seen.add(nullifier);
    }
  }
});

test("labels and indices each separate withdrawal notes", () => {
  const seen = new Set<bigint>();
  for (const label of [LABEL, LABEL + 1n]) {
    for (let i = 0n; i < 8n; i++) {
      const { nullifier } = withdrawalSecrets(KEYS, label, i);
      assert.ok(!seen.has(nullifier), `nullifier repeated at label ${label} index ${i}`);
      seen.add(nullifier);
    }
  }
});

test("deposit and withdrawal derivation are THE SAME FUNCTION, separated only by their inputs", () => {
  // Pinned deliberately, because it is the module's one unguarded assumption: both compute
  // Poseidon(masterNullifier, x, index), so a deposit note and a withdrawal note COLLIDE whenever a
  // label numerically equals a scope. Nothing in the derivation prevents that — it is prevented only
  // by scope and label being outputs of different hashes, which makes a collision a ~2^-254 event
  // rather than an impossibility.
  //
  // The reason to assert it rather than leave it implicit: if a future change ever makes labels
  // derive FROM scopes (an obvious-looking simplification), this stops being astronomically
  // unlikely and becomes reachable — and the symptom would be a note that silently cannot be spent,
  // because the pool already saw its nullifier.
  const shared = 0xabcdefn;
  assert.deepStrictEqual(
    depositSecrets(KEYS, shared, 3n),
    withdrawalSecrets(KEYS, shared, 3n),
    "the two derivations have diverged — one of them changed without the other",
  );
});

// ── 3. every input is bound ───────────────────────────────────────────────────────────────────

test("the commitment binds value, label and the precommitment", () => {
  const note = depositSecrets(KEYS, SCOPE, 0n);
  const baseline = commitment(10n ** 18n, LABEL, note);
  assert.notStrictEqual(commitment(10n ** 18n + 1n, LABEL, note), baseline, "value is not bound");
  assert.notStrictEqual(commitment(10n ** 18n, LABEL + 1n, note), baseline, "label is not bound");
  assert.notStrictEqual(
    commitment(10n ** 18n, LABEL, depositSecrets(KEYS, SCOPE, 1n)),
    baseline,
    "the note secrets are not bound",
  );
});

test("the precommitment binds both halves of the note", () => {
  const note = depositSecrets(KEYS, SCOPE, 0n);
  const baseline = precommitment(note);
  assert.notStrictEqual(precommitment({ ...note, nullifier: note.nullifier + 1n }), baseline);
  assert.notStrictEqual(precommitment({ ...note, secret: note.secret + 1n }), baseline);
  // Swapping the halves must not produce the same precommitment, or the pair is unordered and two
  // distinct notes could present one precommitment.
  assert.notStrictEqual(
    precommitment({ nullifier: note.secret, secret: note.nullifier }),
    baseline,
    "the precommitment is symmetric in its inputs",
  );
});

test("the public nullifier hash does not reveal, and is bound to, the nullifier", () => {
  const note = depositSecrets(KEYS, SCOPE, 0n);
  const h = nullifierHash(note.nullifier);
  assert.notStrictEqual(h, note.nullifier, "the published hash equals the secret nullifier");
  assert.notStrictEqual(nullifierHash(note.nullifier + 1n), h);
});

// ── 4. field discipline ───────────────────────────────────────────────────────────────────────

test("every derived value is a valid BN254 element", () => {
  // A value at or above the field is not merely wrong: Poseidon REFUSES it, so the failure would
  // surface wherever it is next hashed rather than where it was produced.
  assert.ok(inField(KEYS.masterNullifier) && inField(KEYS.masterSecret), "master keys out of field");
  for (let i = 0n; i < 8n; i++) {
    const d = depositSecrets(KEYS, SCOPE, i);
    const w = withdrawalSecrets(KEYS, LABEL, i);
    for (const [name, v] of [
      ["deposit nullifier", d.nullifier],
      ["deposit secret", d.secret],
      ["withdrawal nullifier", w.nullifier],
      ["withdrawal secret", w.secret],
      ["precommitment", precommitment(d)],
      ["commitment", commitment(10n ** 18n, LABEL, d)],
      ["nullifier hash", nullifierHash(d.nullifier)],
    ] as const) {
      assert.ok(inField(v), `${name} at index ${i} is outside the field`);
    }
  }
});
