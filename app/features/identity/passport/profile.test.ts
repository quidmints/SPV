// Run: node --test src/passport/profile.test.ts   (Node 24 strips types natively - no jest, no deps)
//
// THE TEST VECTORS ARE THE MANIFEST ITSELF, which is what makes this worth writing. Every profile
// must select itself from its own generics, and every zkType must survive re-derivation by keccak.
// A table generated from a source of truth is only trustworthy if something checks it; otherwise it
// is a copy, and this session watched two copies go stale — the checker's hand-written AA curve
// widths, and a contract header claiming 79 verifiers when there were 88.
import test from 'node:test';
import assert from 'node:assert';
import { keccak_256 } from '@noble/hashes/sha3.js';

import { PROFILES, PROFILE_FIELDS, selectProfile, selectZkType, NoMatchingProfileError } from './profile.ts';

const LABEL_PREFIX = 'Z_NOIR_PASSPORT_';

test('the generated table is not empty and is the size the manifest says', () => {
  // A floor rather than an exact count: adding or retiring a profile must not fail this for the
  // wrong reason. It exists to catch a generator that emitted nothing.
  assert.ok(PROFILES.length > 80, `only ${PROFILES.length} profiles - the table looks truncated`);
  assert.strictEqual(PROFILE_FIELDS.length, 14);
});

test('every profile selects ITSELF from its own generics', () => {
  for (const p of PROFILES) {
    const got = selectProfile(p.generics);
    assert.strictEqual(got.name, p.name, `${p.name} selected ${got.name}`);
  }
});

test('every zkType re-derives as keccak256 of its label', () => {
  // The generated value is never trusted. The wallet sends this selector on-chain, and a wrong one
  // does not fail loudly - it resolves to address(0) and reverts as "verifier not set", which reads
  // like a missing verifier rather than a wrong key.
  for (const p of PROFILES) {
    const expected =
      '0x' + Buffer.from(keccak_256(new TextEncoder().encode(LABEL_PREFIX + p.name))).toString('hex');
    assert.strictEqual(p.zkType, expected, `zkType mismatch for ${p.name}`);
  }
});

test('zkTypes are distinct - a collision would send one profile to another circuit', () => {
  const seen = new Map<string, string>();
  for (const p of PROFILES) {
    const prior = seen.get(p.zkType);
    assert.strictEqual(prior, undefined, `${p.name} collides with ${prior}`);
    seen.set(p.zkType, p.name);
  }
});

test('the DG15 fields are LOAD-BEARING for selection', () => {
  // Measured against the manifest: full tuples are unique, but ignoring DG15_LEN / DG15_SHIFT /
  // AA_SHIFT / EC_FIELD_SIZE collapses three pairs. This pins one of them, so a future "simplify the
  // selector" change cannot silently make the two indistinguishable.
  const a = PROFILES.find((p) => p.name === '1_256_3_4_336_248_1_1496_4_256');
  const b = PROFILES.find((p) => p.name === '1_256_3_4_336_248_1_560_4_256');
  assert.ok(a && b, 'the pinned near-collision pair is missing from the manifest');

  const dg15Shift = PROFILE_FIELDS.indexOf('DG15_SHIFT');
  assert.notStrictEqual(
    a.generics[dg15Shift],
    b.generics[dg15Shift],
    'these two differ ONLY in the DG15 layout - if that stops being true, selection is ambiguous',
  );
  assert.strictEqual(selectProfile(a.generics).name, a.name);
  assert.strictEqual(selectProfile(b.generics).name, b.name);
});

test('an unmatched document throws, and says what to record', () => {
  const unknown = new Array(14).fill(0);
  assert.throws(
    () => selectProfile(unknown),
    (err: unknown) => {
      assert.ok(err instanceof NoMatchingProfileError);
      // The message must carry the tuple - it is exactly what adding a profile needs.
      assert.match(err.message, /DG1_LEN=0/);
      assert.match(err.message, /do NOT substitute a near match/);
      return true;
    },
  );
});

test('a wrong-length tuple is rejected rather than compared positionally', () => {
  assert.throws(() => selectProfile([93, 0, 155]), /expected 14 generics/);
});

test('selectZkType returns the same key the profile carries', () => {
  const p = PROFILES[0];
  assert.strictEqual(selectZkType(p.generics), p.zkType);
});
