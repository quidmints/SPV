// Run: node --test src/identity/entropy.test.ts
//
// EVERY GUARD IS TESTED BY BREAKING THE THING IT GUARDS. A mixing scheme that is never fed a broken
// source is decorative - it would pass exactly the same tests whether or not the checks fire.
import test from 'node:test';
import assert from 'node:assert';
import { webcrypto } from 'node:crypto';

import {
  drawSeedEntropy,
  isDegenerate,
  webCryptoSource,
  InsecureEntropyError,
  SEED_BYTES,
  type EntropySource,
} from './entropy.ts';

/** A source that returns a fixed pattern - stands in for a generator that has stopped working. */
const stuck = (value: number): EntropySource => ({
  name: `stuck-${value}`,
  bytes: (n) => new Uint8Array(n).fill(value),
});

/** A working source, distinct from the platform one, for mixing tests. */
const counting = (start: number): EntropySource => ({
  name: `counting-${start}`,
  bytes: (n) => Uint8Array.from({ length: n }, (_, i) => (start + i) % 251),
});

const real: EntropySource = {
  name: 'node-webcrypto',
  bytes: (n) => webcrypto.getRandomValues(new Uint8Array(n)),
};

test('produces exactly 32 bytes - 256 bits, a 24-word phrase', () => {
  assert.strictEqual(drawSeedEntropy([real]).length, SEED_BYTES);
});

test('successive draws differ', () => {
  const a = Buffer.from(drawSeedEntropy([real])).toString('hex');
  const b = Buffer.from(drawSeedEntropy([real])).toString('hex');
  assert.notStrictEqual(a, b);
});

// ---- the degeneracy guard --------------------------------------------------------------------

test('all-zero output is rejected - the uninitialised-buffer case', () => {
  assert.throws(() => drawSeedEntropy([stuck(0x00)]), InsecureEntropyError);
});

test('all-0xFF output is rejected', () => {
  assert.throws(() => drawSeedEntropy([stuck(0xff)]), InsecureEntropyError);
});

test('any single repeated byte is rejected - the stuck-counter case', () => {
  assert.throws(() => drawSeedEntropy([stuck(0x42)]), /degenerate/);
});

test('isDegenerate does not reject ordinary values', () => {
  assert.strictEqual(isDegenerate(Uint8Array.from([1, 2, 3])), false);
  assert.strictEqual(isDegenerate(Uint8Array.from([7, 7, 7])), true);
  assert.strictEqual(isDegenerate(new Uint8Array(0)), true);
});

// ---- the mixing property ---------------------------------------------------------------------

/*
 * THE POINT OF MIXING: one broken source must not determine the output.
 *
 * A source stuck at a constant is caught by the degeneracy guard, so to test MIXING rather than the
 * guard, the "broken" source here is merely PREDICTABLE (a counter) - the shape of a source seeded
 * from a timestamp. Its contribution must not make the result predictable while a good source is
 * present.
 */
test('a predictable source does not determine the output when mixed with a good one', () => {
  const a = Buffer.from(drawSeedEntropy([counting(0), real])).toString('hex');
  const b = Buffer.from(drawSeedEntropy([counting(0), real])).toString('hex');
  assert.notStrictEqual(a, b, 'output was fixed by the predictable source');
});

test('changing ONLY the good source changes the output', () => {
  const fixed = counting(0);
  const first = Buffer.from(drawSeedEntropy([fixed, real])).toString('hex');
  const second = Buffer.from(drawSeedEntropy([fixed, real])).toString('hex');
  assert.notStrictEqual(first, second);
});

test('changing ONLY the second source changes the output - every source contributes', () => {
  const a = Buffer.from(drawSeedEntropy([counting(0), counting(1)])).toString('hex');
  const b = Buffer.from(drawSeedEntropy([counting(0), counting(2)])).toString('hex');
  assert.notStrictEqual(a, b, 'a source was ignored by the mix');
});

/*
 * DOMAIN SEPARATION: one source returning a long string must not be able to impersonate the mix of
 * two. Without hashing the source COUNT and NAMES, `a || b` from one source would be
 * indistinguishable from `a` and `b` from two.
 */
test('one source cannot impersonate two', () => {
  const one = Buffer.from(drawSeedEntropy([counting(0)])).toString('hex');
  const two = Buffer.from(drawSeedEntropy([counting(0), counting(0)])).toString('hex');
  assert.notStrictEqual(one, two);
});

// ---- failing loudly --------------------------------------------------------------------------

test('a throwing source aborts generation rather than being skipped', () => {
  const broken: EntropySource = {
    name: 'broken',
    bytes: () => {
      throw new Error('device RNG unavailable');
    },
  };
  // Silently degrading from two sources to one is how mixing becomes decorative, and the caller
  // could not tell from the result.
  assert.throws(() => drawSeedEntropy([broken, real]), /device RNG unavailable/);
});

test('a short read is rejected rather than padded', () => {
  const short: EntropySource = { name: 'short', bytes: (n) => new Uint8Array(n - 1).fill(3) };
  assert.throws(() => drawSeedEntropy([short]), /expected 32/);
});

test('an empty source list is refused', () => {
  assert.throws(() => drawSeedEntropy([]), /no entropy sources/);
});

/*
 * THE PLATFORM SOURCE MUST FAIL LOUDLY WHEN THE POLYFILL IS ABSENT.
 *
 * This is the exact condition that existed before sec. 2.18bd: `polyfills.ts` was never imported, so
 * `crypto.getRandomValues` was not installed. The requirement is that this throws - never that it
 * substitutes something weaker.
 */
test('webCryptoSource throws when getRandomValues is missing, and names the fix', () => {
  const saved = globalThis.crypto;
  try {
    // @ts-expect-error - deliberately simulating the un-polyfilled runtime
    delete globalThis.crypto;
    assert.throws(() => webCryptoSource.bytes(SEED_BYTES), /polyfills/);
  } finally {
    Object.defineProperty(globalThis, 'crypto', { value: saved, configurable: true });
  }
});
