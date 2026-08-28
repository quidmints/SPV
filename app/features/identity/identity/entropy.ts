// Seed entropy, hardened against the failure that actually breaks wallets.
//
// WHAT BREAKS REAL WALLETS IS NOT BRUTE FORCE (sec. 2.18bd). A 24-word mnemonic carries 256 bits;
// searching that is not expensive, it is beyond physical possibility. Trust Wallet (2022) and the
// "Milk Sad" libbitcoin bug both lost funds because the RNG collapsed the search space to something
// enumerable - a weak PRNG in one case, a 32-bit time seed in the other. So the entropy SOURCE is
// the only part of seed generation worth defending, and it is defended here.
//
// THREE INDEPENDENT PROPERTIES, each of which can fail on its own:
//   1. the source is a real CSPRNG, and its absence is LOUD rather than silently substituted;
//   2. more than one source contributes, so a single broken one cannot determine the output;
//   3. the output is checked for the degenerate patterns a catastrophically broken RNG produces.
//
// WHAT THIS CANNOT DO, stated so nobody reads more into it: if EVERY available source is broken in
// the same way, mixing them cannot invent entropy. Mixing defends against ONE source failing, which
// is the realistic case (a polyfill regression, a platform bug, a bad backport) - not against a
// platform whose whole CSPRNG is compromised. And none of this defends the seed after generation:
// storage, backup handling and the supply chain are separate problems.
import { keccak_256 } from '@noble/hashes/sha3.js';

/** Bytes of seed entropy required. 32 = 256 bits = a 24-word BIP-39 phrase. */
export const SEED_BYTES = 32;

export class InsecureEntropyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InsecureEntropyError';
  }
}

/**
 * A source of raw randomness. Returns exactly `length` bytes or throws.
 *
 * Sources are injected rather than imported so this module is testable without a device - a broken
 * source can be simulated, which is the only way to check that the guards below actually fire.
 */
export type EntropySource = {
  readonly name: string;
  readonly bytes: (length: number) => Uint8Array;
};

/**
 * The platform CSPRNG. On React Native this is `react-native-get-random-values`, which bridges to
 * the OS generator - `SecRandomCopyBytes` on iOS, `/dev/urandom` on Android.
 *
 * ITS ABSENCE THROWS, and that is inherited rather than added: metro aliases `crypto` to
 * crypto-browserify, whose `randombytes` exports a throwing stub when `getRandomValues` is missing
 * instead of falling back to `Math.random`. This wrapper only makes the diagnosis nameable.
 */
export const webCryptoSource: EntropySource = {
  name: 'crypto.getRandomValues',
  bytes(length) {
    const g = globalThis.crypto;
    if (typeof g?.getRandomValues !== 'function') {
      throw new InsecureEntropyError(
        'crypto.getRandomValues is unavailable. index.ts must import "./polyfills" BEFORE anything ' +
          'else - it installs react-native-get-random-values. Refusing to generate a seed.',
      );
    }
    return g.getRandomValues(new Uint8Array(length));
  },
};

/**
 * Reject the outputs a catastrophically broken generator produces.
 *
 * THIS IS A SANITY CHECK, NOT A RANDOMNESS TEST, and the distinction matters: no test can certify
 * that 32 bytes are random, because every specific value is equally likely. What it CAN do is catch
 * a source that has plainly stopped working - all zeros (an uninitialised buffer), all 0xFF, or a
 * single byte repeated (a stuck counter or a misconfigured mock).
 *
 * THE FALSE-REJECT RISK IS NIL IN PRACTICE. A genuine CSPRNG produces an all-equal 32-byte string
 * with probability 256 / 2^256. A user will never see it; a broken source produces it constantly.
 */
export function isDegenerate(bytes: Uint8Array): boolean {
  if (bytes.length === 0) return true;
  const first = bytes[0];
  return bytes.every((b) => b === first);
}

/**
 * Draw `SEED_BYTES` of entropy by mixing every available source through keccak-256.
 *
 * WHY HASH RATHER THAN XOR. XOR is the textbook combiner and would be adequate, but it preserves
 * length-correlated structure: if two sources share a bias in the same byte positions, XOR can
 * preserve it, and a caller taking a prefix of the result inherits it. Hashing the concatenation is
 * a randomness EXTRACTOR - the output depends on every input bit, so any single source with full
 * entropy makes the digest unpredictable regardless of what the others did.
 *
 * WHY THE COUNT AND NAMES ARE HASHED IN. Domain separation: without it, one source returning
 * `a || b` would be indistinguishable from two sources returning `a` and `b`, so a compromised
 * source could impersonate the whole mix by controlling one long string.
 *
 * EVERY SOURCE MUST SUCCEED. A source that throws aborts generation rather than being skipped -
 * silently degrading from two sources to one is precisely how a mixing scheme becomes decorative,
 * and the caller cannot tell the difference from the result.
 */
export function drawSeedEntropy(sources: readonly EntropySource[] = [webCryptoSource]): Uint8Array {
  if (sources.length === 0) {
    throw new InsecureEntropyError('no entropy sources supplied');
  }

  const parts: Uint8Array[] = [];
  for (const source of sources) {
    const drawn = source.bytes(SEED_BYTES);

    if (drawn.length !== SEED_BYTES) {
      throw new InsecureEntropyError(
        `entropy source ${source.name} returned ${drawn.length} bytes, expected ${SEED_BYTES}`,
      );
    }
    if (isDegenerate(drawn)) {
      throw new InsecureEntropyError(
        `entropy source ${source.name} returned a degenerate value (every byte identical). ` +
          'This is what a broken or stubbed generator produces; refusing to derive a seed from it.',
      );
    }

    parts.push(new TextEncoder().encode(`${source.name}:`));
    parts.push(drawn);
  }

  const total = parts.reduce((n, p) => n + p.length, 0);
  const preimage = new Uint8Array(1 + total);
  preimage[0] = sources.length; // domain-separate the source COUNT, not just the contents
  let offset = 1;
  for (const part of parts) {
    preimage.set(part, offset);
    offset += part.length;
  }

  const mixed = keccak_256(preimage);

  // The extractor's own output is checked too. If this ever fires, something is wrong with the hash
  // itself rather than with a source - which is worth failing loudly on rather than shipping.
  if (isDegenerate(mixed)) {
    throw new InsecureEntropyError('mixed entropy is degenerate - the extractor is broken');
  }
  return mixed;
}
