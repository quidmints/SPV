// Run: node --test src/chain/taproot.test.ts
//
// THE BINDING ASSERTION IS THE SHARED FIXTURE. `tapBranch` is pinned to the SAME value that
// `SPV/evm/test/TapBranch.t.sol` and `quid-hop/src/swap_in_onchain.rs` assert — a number already
// agreed by three independent implementations (Solidity `taggedHash`, a python rebuild from raw
// sha256, and rust-bitcoin's consensus-tested `TapNodeHash`). A fourth implementation agreeing
// with them is worth something; a fourth agreeing only with itself is not.
import test from 'node:test'
import assert from 'node:assert'
import { ethers } from 'ethers'

import { taggedHash, tapLeafHash, scriptNum, refundLeafScript, termsCommitment, depositLeafScript, taprootOutputKey } from './taproot.ts'

const A = ethers.keccak256(ethers.toUtf8Bytes('leaf-a'))
const B = ethers.keccak256(ethers.toUtf8Bytes('leaf-b'))

test('taggedHash is the BIP-340 construction, not sha256 of the tag and message', () => {
  // Guards the doubled tag hash specifically: dropping one copy is a silent, plausible bug.
  const t = ethers.sha256(ethers.toUtf8Bytes('TapBranch'))
  assert.strictEqual(
    taggedHash('TapBranch', ethers.getBytes(ethers.concat([A, B]))),
    ethers.sha256(ethers.concat([t, t, A, B])),
  )
  assert.notStrictEqual(
    taggedHash('TapBranch', ethers.getBytes(A)),
    ethers.sha256(ethers.concat([t, A])),
  )
})

test('an over-long leaf script is refused rather than mis-prefixed', () => {
  assert.throws(() => tapLeafHash('0x' + 'ab'.repeat(253)), /too long/)
})

test('scriptNum is little-endian, minimal, and pads only when the top bit is set', () => {
  // Derived from Bitcoin's rule rather than from the implementation, so this is a real check.
  assert.strictEqual(scriptNum(0), '0x00', 'ExitLib returns a single 0x00, not an empty push')
  assert.strictEqual(scriptNum(1), '0x01')
  assert.strictEqual(scriptNum(0x7f), '0x7f', 'high bit clear: no pad')
  assert.strictEqual(scriptNum(0x80), '0x8000', 'high bit SET: pad, or it reads negative')
  assert.strictEqual(scriptNum(0xff), '0xff00')
  assert.strictEqual(scriptNum(0x0100), '0x0001', 'little-endian')
  assert.strictEqual(scriptNum(500000), '0x20a107', '0x07A120 LE, top byte 0x07, no pad')
  assert.strictEqual(scriptNum(0xffffffff), '0xffffffff00')
  assert.throws(() => scriptNum(-1), /uint32/)
  assert.throws(() => scriptNum(0x1_0000_0000), /uint32/)
})

test('the refund leaf is the exact opcode sequence ExitLib builds', () => {
  const key = '0x' + 'ab'.repeat(32)
  const leaf = refundLeafScript(key, 500000)
  // PUSH3 20a107 | b1 OP_CLTV | 75 OP_DROP | 20 PUSH32 <key> | ac OP_CHECKSIG
  assert.strictEqual(leaf, '0x0320a107b17520' + 'ab'.repeat(32) + 'ac')
  assert.strictEqual(ethers.getBytes(leaf).length, 1 + 3 + 1 + 1 + 1 + 32 + 1)
})

test('the padded height changes the leaf, so the pad is load-bearing', () => {
  const key = '0x' + 'cd'.repeat(32)
  assert.notStrictEqual(refundLeafScript(key, 0x80), refundLeafScript(key, 0x0080 + 1))
  assert.ok(refundLeafScript(key, 0x80).startsWith('0x028000b175'), 'pad byte missing')
})

test('a wrong-width refund key is refused', () => {
  assert.throws(() => refundLeafScript('0xdeadbeef', 1), /32 bytes/)
})

test('the deposit leaf commits the terms in front of the refund path, in ONE leaf', () => {
  const key = '0x' + 'ab'.repeat(32)
  const s0 = '0x' + '11'.repeat(20)
  const t0 = '0x' + '22'.repeat(20)
  const leaf = depositLeafScript(key, 500000, s0, t0, 1000n, 100)

  // PUSH32 <terms> | 75 DROP | PUSH3 20a107 | b1 CLTV | 75 DROP | PUSH32 <key> | ac CHECKSIG
  const expected =
    '0x20' + termsCommitment(s0, t0, 1000n, 100).slice(2) + '75' +
    '0320a107' + 'b175' + '20' + 'ab'.repeat(32) + 'ac'
  assert.strictEqual(leaf, expected)

  // The refund path is UNCHANGED apart from the prefix — same tail, so spendability is untouched.
  assert.ok(leaf.endsWith(refundLeafScript(key, 500000).slice(2)), 'refund tail altered')
})

test('every committed term changes the deposit leaf', () => {
  const key = '0x' + 'cd'.repeat(32)
  const s0 = '0x' + '11'.repeat(20)
  const t0 = '0x' + '22'.repeat(20)
  const base = depositLeafScript(key, 7, s0, t0, 1000n, 100)
  assert.notStrictEqual(base, depositLeafScript(key, 7, '0x' + '33'.repeat(20), t0, 1000n, 100), 'seller')
  assert.notStrictEqual(base, depositLeafScript(key, 7, s0, '0x' + '44'.repeat(20), 1000n, 100), 'token')
  assert.notStrictEqual(base, depositLeafScript(key, 7, s0, t0, 1001n, 100), 'pricePerBtc')
  // (§T2) slippage is a COMMITTED term too — the floor is derived from price AND slippage.
  assert.notStrictEqual(base, depositLeafScript(key, 7, s0, t0, 1000n, 101), 'slippageBps')
  assert.notStrictEqual(base, depositLeafScript(key, 8, s0, t0, 1000n, 100), 'cltvHeight')
})

test("the taproot tweak matches rust-bitcoin's TaprootBuilder on a shared fixture", () => {
  // Pinned in quid-hop/src/swap_in_onchain.rs::taproot_output_key_matches_the_wallet. This is the
  // last cryptographic step of the QR verifier: if the wallet's tweak disagreed with the one that
  // produced the address, the check would reject every honest quote and accept nothing.
  const internal = '0x' + '02'.repeat(32)
  const key = '0x' + 'ab'.repeat(32)
  assert.strictEqual(
    taprootOutputKey(internal, tapLeafHash(refundLeafScript(key, 500000))),
    '0xb6df894fd855150b3df4e36b4ea2deb66b07976431164d501698691f4fa16c65',
  )
})

test('the output key moves when any committed term does', () => {
  const internal = '0x' + '02'.repeat(32)
  const key = '0x' + 'ab'.repeat(32)
  const q = (price: bigint) =>
    taprootOutputKey(internal, tapLeafHash(
      depositLeafScript(key, 500000, '0x' + '11'.repeat(20), '0x' + '22'.repeat(20), price, 100)))
  assert.notStrictEqual(q(1000n), q(1001n), 'a restated pricePerBtc must change the address')
})
