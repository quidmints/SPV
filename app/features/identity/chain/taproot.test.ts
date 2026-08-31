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

import { taggedHash, tapLeafHash, scriptNum, refundLeafScript, termsCommitment, depositLeafScript, taprootOutputKey, verifyQuotedDepositAddress } from './taproot.ts'

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

/// (§QR-VERIFIER-UNASSEMBLED) THE JOIN, against the SAME fixture the Solidity suite pins.
///
/// ⚠️ **THESE CONSTANTS ARE `SwapInDeposit.t.sol`'s, NOT NEW ONES** — `INTERNAL`, `REFUND`, `CLTV`
/// and the four terms are that file's, and `EXPECTED_Q` is its pinned deposit key. So a pass here
/// means the wallet, the contract and (via `taproot_output_key_matches_the_wallet`) rust-bitcoin
/// all derive one address from one set of terms. Three implementations, one number.
///
/// ⚠️ **VERIFIED OUT-OF-BAND, BECAUSE THIS FILE CANNOT RUN YET** (`§APP-IS-CJS-BUT-SOURCES-ARE-ESM`
/// — `app/package.json` declares `"type": "commonjs"` while every source here is ESM). The
/// composition below was reproduced on 2026-08-31 by an independent pure-Python BIP-341
/// implementation, which returned exactly `EXPECTED_Q` and the pinned terms commitment; the
/// `bc1p…` string is that Q bech32m-encoded. **The assertions are pinned to values computed
/// elsewhere, never to this code's own output.**
const FIXTURE = {
  internalX: '0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798',
  userRefund: '0x2F8BDE4D1A07209355B4A7250A5C5128E88B84BDDC619AB7CBA8D569B240EFE4',
  cltvHeight: 800_001,
  seller: '0x00000000000000000000000000000000000000A1',
  token: '0x00000000000000000000000000000000000000B2',
  pricePerBtc: 50_000_000_000n,
  slippageBps: 100,
}
const QUOTED = 'bc1puars93mp4vakzey7akuxhdxc7hmaljzgw0jsj6rzk9l7prnfvsxsmgu464'

test('the honest quote verifies', () => {
  assert.ok(verifyQuotedDepositAddress({ ...FIXTURE, quotedAddress: QUOTED }))
})

/// ⭐ THE ONE THAT CARRIES THE SECURITY. Every committed term must move the address, or a hop could
/// restate the deal after the user accepted it and quote the same place.
test('any restated term is rejected', () => {
  const v = (o: Partial<typeof FIXTURE>) =>
    verifyQuotedDepositAddress({ ...FIXTURE, ...o, quotedAddress: QUOTED })
  assert.ok(!v({ pricePerBtc: 50_000_000_001n }), 'a restated price must not verify')
  assert.ok(!v({ slippageBps: 101 }), 'a restated slippage must not verify')
  assert.ok(!v({ cltvHeight: 800_002 }), 'a restated timelock must not verify')
  assert.ok(!v({ seller: '0x00000000000000000000000000000000000000A2' }), 'a substituted seller')
  assert.ok(!v({ token: '0x00000000000000000000000000000000000000B3' }), 'a substituted token')
  assert.ok(!v({ userRefund: '0x' + 'ab'.repeat(32) }), 'a substituted refund key')
})

/// A hop that quotes an address of the wrong SHAPE must fail before any key comparison —
/// P2WPKH, P2SH and junk are not addresses these terms can produce.
test('a non-P2TR or unparseable quote is refused', () => {
  const v = (a: string) => verifyQuotedDepositAddress({ ...FIXTURE, quotedAddress: a })
  assert.ok(!v('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4'), 'P2WPKH is not a taproot deposit')
  assert.ok(!v('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2'), 'P2PKH is not either')
  assert.ok(!v('not-an-address'), 'junk')
  assert.ok(!v(''), 'empty')
})
