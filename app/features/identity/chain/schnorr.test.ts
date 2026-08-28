// Run: node --test src/chain/schnorr.test.ts
import test from 'node:test'
import assert from 'node:assert'
import { ethers } from 'ethers'

import { xOnlyPublicKey, signRefund, verifyRefund, signRefundWithNormalisedKey } from './schnorr.ts'
import { normaliseKey } from './keys.ts'

const key = (i: number) => ethers.keccak256(ethers.toUtf8Bytes(`schnorr-fixture-${i}`))
const MSG = ethers.keccak256(ethers.toUtf8Bytes('a refund sighash'))

test('🔑 noble\'s BIP-340 x-only key equals the one normaliseKey derives — an INDEPENDENT check', () => {
  // keys.ts normalises to even-y by hand; noble does BIP-340's own thing. If these ever diverge,
  // the wallet commits to a refund key it cannot sign for and the deposit is unreclaimable with
  // everything else correct. This is the assertion that rules that out.
  for (let i = 0; i < 64; i++) {
    const k = normaliseKey(key(i))
    assert.strictEqual(xOnlyPublicKey(k.privateKey), k.xOnly, `key ${i}`)
  }
})

test('the fixture set exercises both parities, so the check above is not vacuous', () => {
  const negated = Array.from({ length: 64 }, (_, i) => normaliseKey(key(i)).negated)
  assert.ok(negated.some(Boolean) && negated.some((n) => !n))
})

test('sign then verify, under the x-only key OP_CHECKSIG would use', () => {
  for (let i = 0; i < 16; i++) {
    const { signature, xOnly } = signRefundWithNormalisedKey(key(i), MSG)
    assert.strictEqual(ethers.getBytes(signature).length, 64)
    assert.ok(verifyRefund(signature, MSG, xOnly), `key ${i} failed to verify`)
  }
})

test('⚠️ PARITY MATTERS FOR THE ADDRESS, NOT FOR THE SIGNATURE — pinned so neither gets "fixed"', () => {
  // BIP-340 negates internally, so signing with the RAW key produces a signature valid under the
  // SAME x-only key. That is why the parity rule is about the EVM address, not about signing --
  // and why someone could "simplify" keys.ts away without any signature test noticing.
  const raw = key(3)
  const k = normaliseKey(raw)
  assert.strictEqual(xOnlyPublicKey(raw), k.xOnly, 'raw and normalised share an x-only key')
  assert.ok(verifyRefund(signRefund(raw, MSG), MSG, k.xOnly))
  assert.ok(verifyRefund(signRefund(k.privateKey, MSG), MSG, k.xOnly))
})

test('a wrong sighash or a wrong key does not verify', () => {
  const { signature, xOnly } = signRefundWithNormalisedKey(key(1), MSG)
  assert.ok(!verifyRefund(signature, ethers.keccak256(ethers.toUtf8Bytes('other')), xOnly))
  assert.ok(!verifyRefund(signature, MSG, normaliseKey(key(2)).xOnly))
})

test('signatures are deterministic by default, so a retry reproduces the witness', () => {
  assert.strictEqual(signRefund(key(5), MSG), signRefund(key(5), MSG))
})

test('a non-32-byte sighash is refused', () => {
  assert.throws(() => signRefund(key(1), '0xdeadbeef'), /32 bytes/)
})
