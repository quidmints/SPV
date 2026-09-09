// Run: node --test app/features/identity/chain/channelTruth.test.ts   (Node 24 strips types natively)
//
// 🔑 **THE TESTS THAT MATTER ARE THE THREE THAT PIN A *WRONG* IMPLEMENTATION, not the ones that
// show the right one working.** Each of §T9's rules names a specific plausible mistake — the amount
// as the recorded test, the concatenated key preimage, a latch that can be re-opened — and a suite
// that only exercises the happy path passes identically with any of them in place.
import test from 'node:test'
import assert from 'node:assert'
import { ethers } from 'ethers'

import { setRpcTransport } from './eth.ts'
import {
  ChannelTruthLatch, keysHash, onchainChannelId, readChannelRecord, sortFundingPubkeys,
  verifyChannelRecord, type ChannelRecord, type FundingScope,
} from './channelTruth.ts'

const BTC_CHANNELS = '0x00000000000000000000000000000000000000cc'
const CID = ethers.keccak256(ethers.toUtf8Bytes('quid-t9-fixture-cid'))

/// Deterministic 33-byte compressed pubkeys. Real points, so nothing here depends on a key being
/// well-formed by luck.
const pk = (i: number): string =>
  ethers.SigningKey.computePublicKey(ethers.keccak256(ethers.toUtf8Bytes(`t9-key-${i}`)), true)

const w = (v: string | bigint | number): string => {
  const h = typeof v === 'string' ? v.replace(/^0x/, '') : v.toString(16)
  return h.padStart(64, '0')
}

/// One `channels(bytes32)` return, as the seven static words the getter actually emits.
const row = (r: Partial<ChannelRecord> = {}): string =>
  '0x' + [
    w(r.amountSats ?? 0n), w(r.fundingTxId ?? ethers.ZeroHash),
    w((r.lpEth ?? ethers.ZeroAddress).replace(/^0x/, '')), w(r.fundingVout ?? 0),
    w(r.status ?? 0), w(r.keysHash ?? ethers.ZeroHash), w(r.lpToRemoteKey ?? ethers.ZeroHash),
  ].join('')

/// A transport that answers `eth_blockNumber` and serves a scripted `eth_call` result. `calls`
/// records the block tag so the burial depth can be asserted rather than assumed.
function fakeRpc(returns: string | (() => string), tip = 0x100) {
  const calls: { method: string; tag?: string }[] = []
  setRpcTransport({
    async send(method: string, params: unknown[]) {
      calls.push({ method, tag: method === 'eth_call' ? (params[1] as string) : undefined })
      if (method === 'eth_blockNumber') return `0x${tip.toString(16)}`
      if (method === 'eth_call') return typeof returns === 'function' ? returns() : returns
      throw new Error(`unexpected ${method}`)
    },
  })
  return calls
}

const scope = (a: number, b: number, sats: bigint, parent: string | null = null): FundingScope => ({
  lpPubkey: pk(a), hopPubkey: pk(b), fundingValueSat: sats, spliceParentFundingTxid: parent,
})

// ═══════════════════════════════════════════════════════════════════════════════════════
//   keysHash — the preimage, independently constructed
// ═══════════════════════════════════════════════════════════════════════════════════════

test('keysHash is abi.encode of two DYNAMIC bytes, not the concatenation of the keys', () => {
  const [k0, k1] = sortFundingPubkeys(pk(1), pk(2))
  // Built by hand from the ABI spec rather than by calling the encoder we are testing: two head
  // words of offsets, then each blob as <length><data right-padded to a 32-BYTE MULTIPLE>. A
  // 33-byte key therefore occupies 64 bytes, so each tail is 96 bytes and the second offset is
  // 0x40 + 0x60 = 0xa0. ⚠️ Getting either number wrong is how the concatenation answer sneaks back.
  const blob = (k: string) => w(33) + k.replace(/^0x/, '').padEnd(128, '0')
  const preimage = '0x' + w(0x40) + w(0xa0) + blob(k0) + blob(k1)
  assert.strictEqual(keysHash(pk(1), pk(2)), ethers.keccak256(preimage))

  // The plausible wrong answer the Rust side warns about, pinned as NOT equal.
  const concatenated = ethers.keccak256(ethers.concat([k0, k1]))
  assert.notStrictEqual(keysHash(pk(1), pk(2)), concatenated,
    'hashing the concatenation gives a plausible-looking wrong answer')
})

test('keysHash sorts, so it is the same whichever side the caller thinks it is', () => {
  // ⚠️ This is NOT "try both orderings". There is exactly ONE ordering — ascending by serialized
  // bytes — and it is the one `evm_codec::build_open_params` submitted. Sorting inside the
  // derivation means a caller cannot get the order wrong, which a role argument would allow.
  for (let i = 0; i < 32; i++) {
    assert.strictEqual(keysHash(pk(i), pk(i + 100)), keysHash(pk(i + 100), pk(i)))
  }
})

test('the fixture set actually exercises BOTH sort orders', () => {
  // Without this the suite above could be vacuous — if every fixture pair happened to arrive
  // already sorted, a role-ordered implementation would pass every assertion here.
  let swapped = 0
  for (let i = 0; i < 32; i++) if (sortFundingPubkeys(pk(i), pk(i + 100))[0] !== pk(i)) swapped++
  assert.ok(swapped > 4 && swapped < 28, `expected a mix of orders, got ${swapped}/32 swapped`)
})

test('channelId sorts the pair the same way, and moves with the outpoint', () => {
  const txid = ethers.keccak256(ethers.toUtf8Bytes('funding'))
  assert.strictEqual(onchainChannelId(pk(1), pk(2), txid, 0), onchainChannelId(pk(2), pk(1), txid, 0))
  assert.notStrictEqual(onchainChannelId(pk(1), pk(2), txid, 0), onchainChannelId(pk(1), pk(2), txid, 1))
})

// ═══════════════════════════════════════════════════════════════════════════════════════
//   The recorded test — the one a downgrade attacks
// ═══════════════════════════════════════════════════════════════════════════════════════

test('an unwritten row is NOT RECORDED', () => {
  const rec: ChannelRecord = {
    amountSats: 0n, fundingTxId: ethers.ZeroHash, lpEth: ethers.ZeroAddress,
    fundingVout: 0, status: 0, keysHash: ethers.ZeroHash, lpToRemoteKey: ethers.ZeroHash,
  }
  assert.strictEqual(verifyChannelRecord(rec, scope(1, 2, 100_000n)), 'not-recorded')
})

test('🔴 a CLOSED channel is RECORDED, not absent — `amountSats != 0` must never be the test', () => {
  // A close zeroes `amountSats` and leaves `keysHash` pinned. An implementation that tested the
  // amount would answer `not-recorded` here — the ONE permissive verdict — which is exactly the
  // state a downgrade attack is trying to reach. This test fails loudly for that implementation
  // and passes for no other reason.
  const closed: ChannelRecord = {
    amountSats: 0n, fundingTxId: ethers.ZeroHash, lpEth: ethers.ZeroAddress, fundingVout: 0,
    status: 2, keysHash: keysHash(pk(1), pk(2)), lpToRemoteKey: ethers.ZeroHash,
  }
  assert.notStrictEqual(verifyChannelRecord(closed, scope(1, 2, 100_000n)), 'not-recorded')
  // And it is a MISMATCH against a live scope, because a closed channel funds nothing.
  assert.strictEqual(verifyChannelRecord(closed, scope(1, 2, 100_000n)), 'mismatch')
})

test('a matching pair with the wrong SIZE is a mismatch — the value is in the sighash', () => {
  const rec: ChannelRecord = {
    amountSats: 100_000n, fundingTxId: ethers.ZeroHash, lpEth: ethers.ZeroAddress, fundingVout: 0,
    status: 1, keysHash: keysHash(pk(1), pk(2)), lpToRemoteKey: ethers.ZeroHash,
  }
  assert.strictEqual(verifyChannelRecord(rec, scope(1, 2, 100_000n)), 'match')
  assert.strictEqual(verifyChannelRecord(rec, scope(1, 2, 100_001n)), 'mismatch')
  assert.strictEqual(verifyChannelRecord(rec, scope(1, 3, 100_000n)), 'mismatch')
})

// ═══════════════════════════════════════════════════════════════════════════════════════
//   The read: buried, and fail-closed
// ═══════════════════════════════════════════════════════════════════════════════════════

test('the read is pinned to a BURIED block, never `latest`', async () => {
  const calls = fakeRpc(row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 7n }), 0x100)
  await readChannelRecord(CID, BTC_CHANNELS)
  const call = calls.find(c => c.method === 'eth_call')
  assert.strictEqual(call?.tag, `0x${(0x100 - 6).toString(16)}`,
    'a `latest` read lets a hostile endpoint pick the view; a buried one only lets it lag')
})

test('a SHORT return is refused, never indexed into', async () => {
  fakeRpc('0x' + '00'.repeat(32 * 6)) // six words — the stale count the Rust side still documents
  await assert.rejects(() => readChannelRecord(CID, BTC_CHANNELS), /fewer than seven words/)
})

test('an unreadable chain FAILS CLOSED — it is not permission to sign', async () => {
  setRpcTransport({ async send() { throw new Error('rpc down') } })
  const latch = new ChannelTruthLatch(CID, BTC_CHANNELS)
  await assert.rejects(() => latch.check(scope(1, 2, 100_000n)),
    'a broken endpoint must not wave the signature through — that is the cheapest attack there is')
})

test('an unconfigured BTCChannels address is a throw, not an absence', async () => {
  fakeRpc(row())
  await assert.rejects(() => readChannelRecord(CID, ethers.ZeroAddress), /not configured/)
})

// ═══════════════════════════════════════════════════════════════════════════════════════
//   The latch — one-way, which is the whole point
// ═══════════════════════════════════════════════════════════════════════════════════════

test('unknown is permissive BEFORE a record exists (or no channel could ever be opened)', async () => {
  fakeRpc(row())
  await new ChannelTruthLatch(CID, BTC_CHANNELS).check(scope(1, 2, 100_000n))
})

test('🔴 unknown AFTER a record is a DOWNGRADE and is refused', async () => {
  let recorded = true
  fakeRpc(() => recorded ? row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 100_000n }) : row())
  const latch = new ChannelTruthLatch(CID, BTC_CHANNELS)
  await latch.check(scope(1, 2, 100_000n))
  assert.strictEqual(latch.snapshot(), true)
  // The counterparty now withholds the answer — the only shape the downgrade can take.
  recorded = false
  await assert.rejects(() => latch.check(scope(1, 2, 100_000n)), /claims none/)
})

test('the latch cannot be re-opened, including through restore()', async () => {
  fakeRpc(row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 100_000n }))
  const latch = new ChannelTruthLatch(CID, BTC_CHANNELS)
  await latch.check(scope(1, 2, 100_000n))
  latch.restore(false) // an API that could clear it would BE the downgrade it prevents
  assert.strictEqual(latch.snapshot(), true)
})

test('a restored latch is live immediately — a restart must not reset the check', async () => {
  fakeRpc(row())
  const latch = new ChannelTruthLatch(CID, BTC_CHANNELS)
  latch.restore(true)
  await assert.rejects(() => latch.check(scope(1, 2, 100_000n)), /claims none/)
})

// ═══════════════════════════════════════════════════════════════════════════════════════
//   The splice window — one step wide, and the step must be chain-confirmed
// ═══════════════════════════════════════════════════════════════════════════════════════

test('a splice signs while the EVM still shows the scope it replaces', async () => {
  fakeRpc(row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 100_000n }))
  const prev = scope(1, 2, 100_000n, null)
  const next = scope(3, 4, 150_000n, ethers.keccak256(ethers.toUtf8Bytes('parent')))
  const latch = new ChannelTruthLatch(CID, BTC_CHANNELS)
  await latch.check(next, prev)
  assert.strictEqual(latch.snapshot(), true, 'a record WAS seen, so the latch must arm')
})

test('a mismatch with no predecessor is refused', async () => {
  fakeRpc(row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 100_000n }))
  await assert.rejects(() => new ChannelTruthLatch(CID, BTC_CHANNELS).check(scope(5, 6, 100_000n)),
    /contradicts the funding scope/)
})

test('a mismatch WITHOUT a scope rotation is a rebind, not a splice, and is refused', async () => {
  fakeRpc(row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 100_000n }))
  const parent = ethers.keccak256(ethers.toUtf8Bytes('same'))
  await assert.rejects(
    () => new ChannelTruthLatch(CID, BTC_CHANNELS)
      .check(scope(5, 6, 100_000n, parent), scope(7, 8, 100_000n, parent)),
    /no scope rotation/)
})

test('a predecessor the chain does NOT confirm buys nothing', async () => {
  // The window is "the chain shows this scope or the one it replaces" — not "trust the peer when
  // it says it is ahead". A node two scopes out, or somewhere else entirely, is refused.
  fakeRpc(row({ keysHash: keysHash(pk(1), pk(2)), amountSats: 100_000n }))
  await assert.rejects(
    () => new ChannelTruthLatch(CID, BTC_CHANNELS)
      .check(scope(5, 6, 150_000n, ethers.keccak256(ethers.toUtf8Bytes('p'))), scope(7, 8, 100_000n, null)),
    /neither this scope nor the one it replaces/)
})
