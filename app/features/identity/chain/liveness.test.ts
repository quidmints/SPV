/// §LP-LIVENESS conformance. Run: `node --test app/features/identity/chain/liveness.test.ts`
///
/// 🔑 **THE VECTOR BELOW IS HALF OF A CROSS-LANGUAGE PAIR.** The same constant is asserted in
/// `quid-ln/quid-hop/src/liveness.rs` (`digest_matches_the_typescript_vector`). Either side alone
/// proves nothing: a producer and a verifier that agree with themselves and not with each other is
/// exactly the drift this pair exists to catch, and the failure is SILENT — `/lp/heartbeat` answers
/// `{recorded: false}` for a bad signature, a wrong signer, a replayed sequence and an unknown
/// channel alike, so a mismatched digest looks identical to a replay.
import assert from 'node:assert/strict'
import test from 'node:test'

import { heartbeatDigest, shouldBeat, signHeartbeat, type BeatState } from './liveness.ts'

const CID = '0x' + '11'.repeat(32)
const PK = '0x' + '22'.repeat(32)

/// Pinned against `quid-hop/src/liveness.rs`. If this fails, ONE of the two implementations moved —
/// find out which before changing either constant.
const VECTOR = '0xcd6209ff93ad20fbe80520beed6dc32c0964b7cc3455cc0f16f588da5deb1443'

test('digest matches the Rust vector byte for byte', () => {
  assert.equal(heartbeatDigest(CID, 900_000, 7n), VECTOR)
})

test('every field is committed — no two heartbeats share a preimage', () => {
  const base = heartbeatDigest(CID, 900_000, 7n)
  assert.notEqual(heartbeatDigest('0x' + '12'.repeat(32), 900_000, 7n), base)
  assert.notEqual(heartbeatDigest(CID, 900_001, 7n), base)
  assert.notEqual(heartbeatDigest(CID, 900_000, 8n), base)
})

test('fields are FIXED WIDTH, so height and seq cannot alias each other', () => {
  // With variable-width encoding, (height=0x0100, seq=0x00) and (height=0x01, seq=0x0000) could
  // collide. Constant widths make that unconstructible rather than unlikely.
  assert.notEqual(heartbeatDigest(CID, 0x0100, 0n), heartbeatDigest(CID, 0x01, 0n))
})

test('the signature recovers to the LP address — i.e. it is NOT EIP-191 prefixed', async () => {
  const { ethers } = await import('ethers')
  const sig = signHeartbeat(PK, heartbeatDigest(CID, 900_000, 7n))
  assert.equal(ethers.dataLength(sig), 65)
  // `recoverAddress` over the RAW digest is what `recover_heartbeat` does. If someone switches the
  // producer to `signMessage`, this recovers a different address and the beat is silently rejected.
  assert.equal(
    ethers.recoverAddress(heartbeatDigest(CID, 900_000, 7n), sig),
    ethers.computeAddress(PK),
  )
})

test('shouldBeat refuses a defaulted threshold', () => {
  const s: BeatState = { seq: 0n, lastAcceptedHeight: 100 }
  assert.throws(() => shouldBeat(s, 200, 0), /derived, not defaulted/)
})

test('an LP that has never beaten beats immediately, then refreshes at half the window', () => {
  assert.equal(shouldBeat({ seq: 0n, lastAcceptedHeight: null }, 900_000, 144), true)
  assert.equal(shouldBeat({ seq: 1n, lastAcceptedHeight: 900_000 }, 900_071, 144), false)
  assert.equal(shouldBeat({ seq: 1n, lastAcceptedHeight: 900_000 }, 900_072, 144), true)
})

test('freshness is measured from the ACCEPTED beat, not the attempted one', () => {
  // A beat the hop rejected must not look like liveness. `lastAcceptedHeight` is only advanced on
  // `{recorded: true}` — this pins that the decision reads that field and nothing else.
  const rejected: BeatState = { seq: 9n, lastAcceptedHeight: 900_000 }
  assert.equal(shouldBeat(rejected, 900_200, 144), true)
})
