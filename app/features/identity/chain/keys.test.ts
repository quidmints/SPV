// Run: node --test src/chain/keys.test.ts   (Node 24 strips types natively — no jest, no deps)
//
// THE ASSERTION THAT MATTERS is the round trip through x-only: what the CONTRACT can derive from
// the deposit address must equal what the WALLET calls its address. If that ever fails, §T2's
// deletion credits the wrong account with every other input correct — so this is the test that
// stands between a parameter deletion and a silent loss of funds.
import test from 'node:test'
import assert from 'node:assert'
import { ethers } from 'ethers'

import { normaliseKey, evmAddressFromXOnly, SECP256K1_N } from './keys.ts'

/// Deterministic keys, so a failure is reproducible rather than a one-in-N flake.
const key = (i: number) => ethers.keccak256(ethers.toUtf8Bytes(`quid-parity-fixture-${i}`))

test('the x-only key round-trips to the same EVM address the wallet uses', () => {
  for (let i = 0; i < 128; i++) {
    const k = normaliseKey(key(i))
    assert.strictEqual(
      evmAddressFromXOnly(k.xOnly),
      k.evmAddress,
      `key ${i}: the contract would credit a different address than the wallet owns`,
    )
  }
})

test('the fixture set actually exercises BOTH parities', () => {
  // ⚠️ WITHOUT THIS THE SUITE ABOVE COULD BE VACUOUS. If every fixture happened to be even-y,
  // the negation branch would never run and the tests would pass while the bug shipped. Roughly
  // half should negate; assert only that both branches are hit, not the exact split.
  const negated = Array.from({ length: 128 }, (_, i) => normaliseKey(key(i)).negated)
  assert.ok(negated.some(Boolean), 'no odd-y fixture — the negation branch is untested')
  assert.ok(negated.some((n) => !n), 'no even-y fixture — the identity branch is untested')
})

test('signing with the normalised key recovers the normalised address', () => {
  // The practical failure this prevents: a wallet that stores the RAW key, derives its address
  // from the normalised one, then signs with the raw one. Everything looks right until a
  // counterparty ecrecovers a different sender.
  for (let i = 0; i < 32; i++) {
    const k = normaliseKey(key(i))
    const w = new ethers.Wallet(k.privateKey)
    assert.strictEqual(w.address, k.evmAddress, `key ${i}: signer address != derived address`)
  }
})

test('an odd-y key negates and an even-y key does not', () => {
  for (let i = 0; i < 32; i++) {
    const raw = key(i)
    const k = normaliseKey(raw)
    const d0 = BigInt(raw)
    const expected = k.negated ? SECP256K1_N - d0 : d0
    assert.strictEqual(BigInt(k.privateKey), expected, `key ${i}: wrong normalisation`)

    // And the normalised key is itself already normal — idempotence, which is what lets a caller
    // apply the rule without tracking whether it has been applied before.
    const again = normaliseKey(k.privateKey)
    assert.strictEqual(again.negated, false)
    assert.strictEqual(again.evmAddress, k.evmAddress)
    assert.strictEqual(again.xOnly, k.xOnly)
  }
})

test('normalising the RAW key is not the same as using it — the bug this file prevents', () => {
  // Find an odd-y fixture and show the two addresses genuinely differ. If this ever stops being
  // true the parity rule is unnecessary, and that would be worth knowing loudly.
  const i = Array.from({ length: 128 }, (_, n) => n).find((n) => normaliseKey(key(n)).negated)
  assert.ok(i !== undefined, 'no odd-y fixture found')

  const k = normaliseKey(key(i!))
  const naive = new ethers.Wallet(key(i!)).address
  assert.notStrictEqual(
    naive,
    k.evmAddress,
    'raw and normalised addresses agree for an odd-y key — the whole rule would be moot',
  )
})

test('out-of-range keys are refused rather than clamped', () => {
  assert.throws(() => normaliseKey('0x' + '00'.repeat(32)), /out of range/)
  assert.throws(() => normaliseKey('0x' + 'ff'.repeat(32)), /out of range/)
})

test('a malformed x-only key is refused', () => {
  assert.throws(() => evmAddressFromXOnly('0xdeadbeef'), /32-byte/)
})
