/// §LP-LIVENESS — the phone's heartbeat producer.
///
/// `quid-hop`'s `RoutingGate` drops a channel from BOLT11 route hints unless a recent signed
/// heartbeat exists, and it **FAILS CLOSED**: an unbound channel is unroutable. It therefore ships
/// OFF (`gate = None`), because turning it on before the phone posts anything would strand every
/// swap-in. ⇒ **this file is the hard dependency for enabling the gate**, not a nice-to-have.
///
/// ⭐ **NO MuSig2, NO BIP-327, NO `@scure/btc-signer`.** The heartbeat is signed by the SAME
/// secp256k1 channel key the contract derives `lpEth` from, in the shape `ethers` already produces.
/// That is why this can ship well ahead of the exit ladder, which is the only piece genuinely
/// blocked on BIP-327.
///
/// **Why it exists** (and it is not fee protection): BIP-341 `Prevouts::All` binds every pre-signed
/// exit to the funding outpoint, so a rotation invalidates them. A channel taking traffic while its
/// LP is unreachable accrues rotations nobody can re-arm. The gate blocks the traffic at the
/// narrowest point, reversibly — the heartbeat is what lets it distinguish "unreachable" from
/// "idle".
import { ethers } from 'ethers'

import { postLpHeartbeat } from './hop.ts'

/// Domain tag. Must match `quid-hop/src/liveness.rs`'s `HEARTBEAT_TAG` byte for byte.
const HEARTBEAT_TAG = 'QUID-REALM::lp-liveness.v1'

/// The digest the LP signs: `keccak256(tag ‖ channel_id[32] ‖ height(u32 BE) ‖ seq(u64 BE))`.
///
/// ⚠️ **EVERY FIELD IS A CONSTANT WIDTH ON PURPOSE** — that is what makes two distinct heartbeats
/// unable to share a preimage. Do not "simplify" this to `solidityPacked` with loose types, and do
/// not reorder: the Rust side writes tag, id, height, seq in exactly this order and compares bytes.
export function heartbeatDigest(channelId: string, height: number, seq: bigint): string {
  if (!/^0x[0-9a-fA-F]{64}$/.test(channelId)) throw new Error('channel_id must be 32 bytes')
  if (!Number.isInteger(height) || height < 0 || height > 0xffffffff) throw new Error('height is u32')
  if (seq < 0n || seq > 0xffffffffffffffffn) throw new Error('seq is u64')

  const tag = ethers.toUtf8Bytes(HEARTBEAT_TAG)
  const id = ethers.getBytes(channelId)
  const h = ethers.getBytes(ethers.zeroPadValue(ethers.toBeHex(height), 4))
  const s = ethers.getBytes(ethers.zeroPadValue(ethers.toBeHex(seq), 8))
  return ethers.keccak256(ethers.concat([tag, id, h, s]))
}

/// Sign a heartbeat digest as a 65-byte recoverable ECDSA signature.
///
/// 🔴 **THIS SIGNS THE RAW DIGEST. DO NOT USE `signMessage`.** The verifier is
/// `Message::from_digest(hb.digest().0)` — it hashes nothing further, so an EIP-191
/// (`"\x19Ethereum Signed Message:\n32"`) prefix would make recovery yield a DIFFERENT address and
/// the beat would be rejected as "wrong signer". That failure is silent: `/lp/heartbeat` answers
/// `{recorded: false}` for a bad signature, a wrong signer, a replayed sequence and an unknown
/// channel alike, deliberately, so an unauthenticated caller cannot probe which channels a hop
/// serves. **You would see a rejection and not know why.**
export function signHeartbeat(privateKey: string, digest: string): string {
  const sig = new ethers.SigningKey(privateKey).sign(digest)
  return ethers.concat([sig.r, sig.s, new Uint8Array([sig.yParity])])
}

/// What the caller must persist between beats. `seq` is the whole anti-replay story: the hop's book
/// accepts only a STRICTLY greater one, so a captured heartbeat is useless later.
export interface BeatState {
  /// Strictly-increasing per channel. Persist it; restarting at 0 makes every beat a replay and the
  /// channel silently unroutable until it exceeds the highest value the hop has already seen.
  seq: bigint
  /// The height of the last beat the hop ACCEPTED (`recorded: true`), not the last one attempted.
  lastAcceptedHeight: number | null
}

/// Should we beat at `tip`?
///
/// ⚠️ **`maxAgeBlocks` IS REQUIRED AND HAS NO DEFAULT — THE SAME RULE AS `RoutingGate::new`.** It
/// must be DERIVED from the slowest co-sign an LP must complete, and that measurement has not been
/// taken (`§BITCOIN-CLOSEOUT#6`). **Do not invent one here.** A guessed value is worse than no gate:
/// too low unroutes live LPs, too high defeats the point.
///
/// We refresh at `maxAgeBlocks / 2` so a single missed beat does not immediately unroute a channel
/// that is otherwise healthy — the gate is meant to catch "unreachable", not "one flaky request".
export function shouldBeat(state: BeatState, tip: number, maxAgeBlocks: number): boolean {
  if (maxAgeBlocks <= 0) throw new Error('maxAgeBlocks must be derived, not defaulted')
  if (state.lastAcceptedHeight === null) return true
  return tip - state.lastAcceptedHeight >= Math.floor(maxAgeBlocks / 2)
}

export type BeatOutcome =
  | { beat: false; reason: 'fresh' }
  | { beat: true; recorded: true; state: BeatState }
  | { beat: true; recorded: false; reason: 'rejected' | 'gate-disabled' | 'unreachable'; state: BeatState }

/// One tick. Pure except for the POST, so it is testable without timers — which is why this is a
/// module and not a React hook. The caller owns scheduling and persistence.
///
/// 📌 **`seq` ADVANCES EVEN ON A REJECTED BEAT.** A rejection we cannot attribute (the endpoint
/// answers one way for four causes) may well be "replayed sequence", and retrying the same `seq`
/// forever is the one failure mode that never recovers. Burning a sequence number costs nothing.
export async function heartbeatTick(args: {
  channelId: string
  privateKey: string
  tip: number
  maxAgeBlocks: number
  state: BeatState
}): Promise<BeatOutcome> {
  const { channelId, privateKey, tip, maxAgeBlocks, state } = args
  if (!shouldBeat(state, tip, maxAgeBlocks)) return { beat: false, reason: 'fresh' }

  const seq = state.seq + 1n
  const sig = signHeartbeat(privateKey, heartbeatDigest(channelId, tip, seq))
  const res = await postLpHeartbeat({ channel_id: channelId, height: tip, seq: Number(seq), sig })

  if (res === null) {
    return { beat: true, recorded: false, reason: 'unreachable', state: { ...state, seq } }
  }
  if (res.recorded) {
    return { beat: true, recorded: true, state: { seq, lastAcceptedHeight: tip } }
  }
  // `{recorded: false, gate: "disabled"}` is worth surfacing rather than retrying: the deployment
  // does not gate routing, so the beats are pointless and the user should be told instead of
  // believing they landed.
  return {
    beat: true,
    recorded: false,
    reason: res.gate === 'disabled' ? 'gate-disabled' : 'rejected',
    state: { ...state, seq },
  }
}
