// (§T9) THE LP'S HALF OF THE VALIDATING SIGNER — the refusal that is not the fleet's to make.
//
// 🔑 **WHY THIS FILE EXISTS AT ALL.** `BTCChannels` records arrive through `_onlyHop()`, so every
// row the fleet checks itself against is a row the fleet WROTE. That check is still worth having —
// it binds the fleet to its own published record — but it is not independent. The LP's is: the
// phone reads the same chain, was not consulted about what went into it, and can REFUSE. SPV's
// `quid-ln/quid-bridge/src/channel_truth.rs` is the fleet-side twin of everything below; this is
// the half that has no daemon, so it lives here.
//
// ⛔ **AND IT IS NOT "PROTECTION FOR AN OFFLINE LP".** §T9 bounds what the LP signs WHEN IT SIGNS.
// A phone that is off runs no check at all — the offline case is carried by the pre-signed exit
// ladder and the on-chain bounds, never by a runtime refusal. Do not let a UI string say otherwise.
//
// ⚠️ **FAIL CLOSED, EVERYWHERE.** Every read error THROWS rather than returning a permissive
// verdict. An unreadable chain is not permission to sign against an unchecked context, or a hostile
// endpoint disables the entire check by breaking its own RPC — the cheapest attack available to it.
// That is why nothing here goes through `eth.ts::readOne`, which swallows every failure into
// `null` for graceful UI degradation. Graceful degradation is exactly wrong for a refusal.

import { ethers } from 'ethers'

import { CONTRACTS } from './chains.ts'
import { rpc } from './eth.ts'

/// What the chain says about a channel. **THREE states, and the third is not padding.**
///
/// `openChannel` requires the funding transaction to be SPV-PROVEN, which happens strictly AFTER
/// the first commitments are signed. So a real, live, honest channel genuinely has NO on-chain
/// record for part of its life, and a two-state check would refuse to sign during exactly that
/// window — no channel could ever be opened. See `TruthVerdict` in
/// `quid-ln/quid-ln/src/validating_signer.rs`, which this mirrors state for state.
export type TruthVerdict = 'not-recorded' | 'match' | 'mismatch'

/// The `channels(bytes32)` row, as SEVEN static words.
///
/// ⚠️ **SEVEN, NOT SIX.** `Types.BTCChannel` gained `lpToRemoteKey` after `keysHash`
/// (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD). The Rust side still documents "SIX static words" and
/// requires only `6*32` bytes — permissive, so it keeps working, but the count is stale there and
/// this one is measured against `evm/src/imports/Types.sol:148-186`.
export interface ChannelRecord {
  amountSats: bigint
  fundingTxId: string
  lpEth: string
  fundingVout: number
  status: number
  keysHash: string
  lpToRemoteKey: string
}

const W_AMOUNT_SATS = 0
const W_FUNDING_TXID = 1
const W_LP_ETH = 2
const W_FUNDING_VOUT = 3
const W_STATUS = 4
const W_KEYS_HASH = 5
const W_LP_TO_REMOTE = 6
const CHANNELS_WORDS = 7

/// Blocks of burial for an AGREEMENT-classed read. Same 6 as
/// `quid-bridge/src/client.rs::AGREED_READ_DEPTH`, and the two must agree or the phone and the
/// fleet can be shown different rows at the same instant.
export const AGREED_READ_DEPTH = 6

const norm = (hex: string): string => {
  const h = (hex.startsWith('0x') ? hex.slice(2) : hex).toLowerCase()
  if (!/^[0-9a-f]*$/.test(h)) throw new Error('channelTruth: not hex')
  return h
}

/// One 33-byte compressed funding pubkey, as the 0x-hex the encoder wants.
const pubkey33 = (k: string, what: string): string => {
  const h = norm(k)
  if (h.length !== 66) throw new Error(`channelTruth: ${what} must be a 33-byte compressed pubkey`)
  return `0x${h}`
}

/// Order the 2-of-2's two funding pubkeys **the way the chain was given them**: ascending by
/// serialized bytes.
///
/// 🔴 **THIS IS THE ONE THING THE SPEC GOT WRONG, AND GETTING IT WRONG REFUSES HALF OF ALL HONEST
/// CHANNELS.** `docs/actionable/TODO.md` says to order the pair BY ROLE — *"the LP knows it is the
/// `lpPubkey` side, so it can order the pair correctly"* — and SPV's own signer does exactly that
/// (`validating_signer.rs`: `match role { Lp => (&ours, &theirs), Hop => (&theirs, &ours) }`).
/// **Measured against the code that actually submits the open, that is not what `keysHash` hashes.**
/// `quid-hop/src/evm_codec.rs::build_open_params` does
/// `let (k0, k1) = sort_funding_pubkeys(a, b); … lp_pubkey: k0, hop_pubkey: k1` — so the struct
/// fields NAMED `lpPubkey`/`hopPubkey` carry the BYTE-SORTED pair, not the role-assigned one, and
/// `keysHash = keccak256(abi.encode(lpPubkey, hopPubkey))` is therefore over the sorted pair. For
/// every channel where the LP's funding key sorts ABOVE the hop's — about half of them — a
/// role-ordered hash cannot match the chain, and a signer that fails closed on `Mismatch` refuses
/// to sign that channel at all.
///
/// ⛔ **THIS IS STILL ONE ORDER, NOT TWO — the spec's actual warning stands.** Trying both
/// orderings would pin only the SET, which is strictly weaker for no gain. Sorting is
/// deterministic: there is exactly one answer, it is computable from the pair alone, and it is the
/// same answer the chain computed. `channelId` is derived from the sorted pair for the same reason
/// (`node.rs::onchain_cid_from_monitor`), which is the corroborating evidence — two independent
/// derivations in the fleet sort, and only the signer's comparand does not.
export function sortFundingPubkeys(a: string, b: string): [string, string] {
  const [x, y] = [pubkey33(a, 'pubkey'), pubkey33(b, 'pubkey')]
  return x <= y ? [x, y] : [y, x]
}

/// `keysHash` — `keccak256(abi.encode(lpPubkey, hopPubkey))`, exactly as
/// `ChannelLib.openChannelBody` pins it and `BTCChannels._requireChannelKeys` compares it.
///
/// ⚠️ Both arguments are Solidity `bytes` (DYNAMIC), so the encoding is two offsets followed by two
/// length-prefixed, right-padded blobs — **NOT the concatenation of the two keys.** Hashing the
/// concatenation gives a plausible-looking wrong answer, which is the worst kind.
export function keysHash(a: string, b: string): string {
  const [k0, k1] = sortFundingPubkeys(a, b)
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(['bytes', 'bytes'], [k0, k1]),
  )
}

/// The on-chain `channelId`, **COMPUTED, never looked up.**
///
/// 🔑 **THERE IS NO REGISTRY TO ASK.** The `CidRegistry` was deleted precisely because this is a
/// deterministic function of four values the client already holds — a map would store only what can
/// be recomputed, and it would need a WRITER, which the phone does not run. A client wired to a map
/// nobody fills reports "not recorded" forever: permanently permissive while looking wired up.
///
/// 🔴 **BOTH INPUTS ARE THE *ORIGINAL* ONES.** A splice rotates the funding outpoint AND both
/// funding keys, while `BTCChannels` keys the channel on the pair and outpoint it was OPENED with.
/// Pairing the original outpoint with the LIVE pair yields a cid no channel on the EVM has — the
/// bug §SPLICE-ROTATES-BOTH-FUNDING-KEYS names, which every identity site in the fleet had at least
/// once. `fundingTxIdInternal` is the txid in INTERNAL byte order (the order the contract and the
/// merkle tree use), i.e. the REVERSE of the `bc1`-explorer display order.
export function onchainChannelId(
  originalPubkeyA: string,
  originalPubkeyB: string,
  fundingTxIdInternal: string,
  fundingVout: number,
): string {
  const [k0, k1] = sortFundingPubkeys(originalPubkeyA, originalPubkeyB)
  const txid = norm(fundingTxIdInternal)
  if (txid.length !== 64) throw new Error('onchainChannelId: fundingTxId must be 32 bytes')
  if (!Number.isInteger(fundingVout) || fundingVout < 0 || fundingVout > 0xffffffff) {
    throw new Error('onchainChannelId: vout must be a uint32')
  }
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes', 'bytes32', 'uint256'],
      [k0, k1, `0x${txid}`, BigInt(fundingVout)],
    ),
  )
}

/// `channels(bytes32)` — the selector, written out rather than resolved through `eth.ts`'s merged
/// `Interface`, so this read cannot be broken by an unrelated ABI edit elsewhere in the app.
const CHANNELS_SELECTOR = ethers.id('channels(bytes32)').slice(0, 10)

const word = (data: string, i: number): string => {
  const start = 2 + i * 64
  const w = data.slice(start, start + 64)
  if (w.length !== 64) throw new Error('channelTruth: short return from channels(bytes32)')
  return `0x${w}`
}

/// Read the channel's row at a BURIED block.
///
/// 🔑 **WHY NOT `latest`.** The RPC is not ours. Pinned to `tip − AGREED_READ_DEPTH` an untrusted
/// endpoint can only DEFLATE the tip and serve an OLDER view; it cannot forge the value at the
/// block it names. An older view is safe here because `keysHash` and `amountSats` are pinned per
/// funding scope and do not drift within one — and the one place they DO move, a splice, is exactly
/// what `ChannelTruthLatch`'s predecessor arm is for.
///
/// Throws on anything that is not a complete, well-formed row: no transport, RPC failure, empty
/// return, short return. **Never returns a permissive value on failure.**
export async function readChannelRecord(
  channelId: string,
  btcChannels: string = CONTRACTS.btcChannels,
): Promise<ChannelRecord> {
  const cid = norm(channelId)
  if (cid.length !== 64) throw new Error('readChannelRecord: channelId must be 32 bytes')
  if (!/^0x[0-9a-fA-F]{40}$/.test(btcChannels) || /^0x0{40}$/.test(btcChannels)) {
    // A zero address reads as "not deployed" everywhere else in this layer and renders an empty
    // screen. Here it would read as "no record", i.e. permissive — so it is a throw.
    throw new Error('readChannelRecord: BTCChannels address is not configured')
  }
  const tip = Number(BigInt(await rpc('eth_blockNumber', [])))
  const at = Math.max(0, tip - AGREED_READ_DEPTH)
  const data = await rpc('eth_call', [
    { to: btcChannels, data: `${CHANNELS_SELECTOR}${cid}` },
    `0x${at.toString(16)}`,
  ])
  if (typeof data !== 'string' || data.length < 2 + CHANNELS_WORDS * 64) {
    throw new Error('readChannelRecord: channels(bytes32) returned fewer than seven words')
  }
  return {
    amountSats: BigInt(word(data, W_AMOUNT_SATS)),
    fundingTxId: word(data, W_FUNDING_TXID),
    lpEth: ethers.getAddress(`0x${word(data, W_LP_ETH).slice(-40)}`),
    fundingVout: Number(BigInt(word(data, W_FUNDING_VOUT))),
    status: Number(BigInt(word(data, W_STATUS))),
    keysHash: word(data, W_KEYS_HASH),
    lpToRemoteKey: word(data, W_LP_TO_REMOTE),
  }
}

/// The funding scope a signature would be made under: the pair and the size IN FORCE RIGHT NOW.
///
/// ⚠️ **CURRENT, NOT BASE.** `splice` RE-PINS `keysHash` to the rotated pair, so supplying the pair
/// from open for a channel that has been spliced yields a mismatch and refuses a legitimate splice.
/// That exact bug existed on the SPV side and was fixed there.
export interface FundingScope {
  /// The two CURRENT 33-byte compressed funding pubkeys. Order does not matter — `keysHash` sorts.
  lpPubkey: string
  hopPubkey: string
  /// The funded size. **Not a nicety**: the value is committed in the BIP-341 key-path sighash, so
  /// it is part of the identity being signed over.
  fundingValueSat: bigint
  /// The funding txid this scope descends from — `null` for the original scope. Used ONLY to prove
  /// that a claimed splice really did advance the scope; see `ChannelTruthLatch.check`.
  spliceParentFundingTxid: string | null
}

/// Compare one scope against one row. Pure — no I/O, so it is the part a test can pin exhaustively.
export function verifyChannelRecord(rec: ChannelRecord, scope: FundingScope): TruthVerdict {
  // ⚠️ `keysHash == 0` IS THE "no record" TEST, NOT `amountSats == 0`.
  // `keysHash` is pinned at open and NEVER cleared; `amountSats` legitimately reaches 0 on a CLOSED
  // channel. Testing the amount reports a closed channel as never-recorded — **which is precisely
  // the state a downgrade attack wants to reach**, because "never recorded" is the one verdict that
  // is permissive. An unwritten mapping entry reads as all-zero words, so a zero `keysHash` is the
  // honest absence and nothing else produces it.
  if (/^0x0{64}$/.test(rec.keysHash)) return 'not-recorded'

  if (rec.keysHash.toLowerCase() !== keysHash(scope.lpPubkey, scope.hopPubkey).toLowerCase()) {
    return 'mismatch'
  }
  if (rec.amountSats !== scope.fundingValueSat) return 'mismatch'
  return 'match'
}

/// (§T9) The stateful half: **a one-way latch around the three-state check.**
///
/// 🔑 **THE LATCH IS WHAT CLOSES THE DOWNGRADE, AND WITHOUT IT THE REST IS DECORATION.** Without
/// it a hostile counterparty holds the client in `not-recorded` forever — naming an outpoint that
/// resolves to no channel, or simply relaying a stale row — and so keeps the on-chain comparand
/// permanently out of play while every function above still runs and still returns. With it,
/// `not-recorded` AFTER a record has been seen is a regression and refuses: the pre-record window
/// becomes strictly one-way, entered once and never re-entered.
///
/// ⚠️ **THE LATCH IS PER CHANNEL AND IN MEMORY, so a process restart clears it** — the same
/// weakness SPV measures on its own side (`nonce_binding_does_not_survive_a_restart`). On a phone
/// that is a bigger hole than in a daemon, because an app is killed constantly and restarting one
/// is not an attack anybody notices. `snapshot()`/`restore()` exist so the caller can persist it
/// beside the channel; **a caller that skips that has a latch which any backgrounding resets.**
export class ChannelTruthLatch {
  private recorded = false

  /// @param channelId the STABLE on-chain id, from `onchainChannelId(original pair, original
  ///        outpoint)`. Computed once at construction because it never moves; the SCOPE moves.
  /// ⚠️ `btcChannels` is RESOLVED PER READ, not captured here. `bootChain` installs addresses after
  /// the UI has already constructed objects, and a default evaluated at construction time would pin
  /// the zero address for the app's whole session — which `readChannelRecord` refuses, so the
  /// failure would at least be loud, but it would be loud forever and for the wrong reason.
  constructor(readonly channelId: string, private readonly btcChannels?: string) {}

  /// Whether the chain has ever answered for this channel. Persist this.
  snapshot(): boolean { return this.recorded }

  /// Re-arm a latch persisted from an earlier session. **One-way here too**: a restored `true` can
  /// never be un-set, because an API that could clear the latch would be the downgrade it prevents.
  restore(recorded: boolean): void { if (recorded) this.recorded = true }

  /// Read the chain and classify `scope`. Throws on an unreadable chain.
  async verify(scope: FundingScope): Promise<TruthVerdict> {
    const at = this.btcChannels ?? CONTRACTS.btcChannels
    return verifyChannelRecord(await readChannelRecord(this.channelId, at), scope)
  }

  /// **THE GATE. Call this before producing ANY MuSig2 partial over a spend of the 2-of-2.**
  /// Returns normally when signing is permitted; THROWS when it is not. There is no boolean return
  /// on purpose — a `false` gets ignored at a call site, an exception does not.
  ///
  /// @param scope the pair + size in force for the signature about to be made.
  /// @param prev  the scope this one REPLACES, or `undefined` for the first. It exists ONLY for the
  ///              splice window below, and it must be a scope THIS client already had in force —
  ///              never one a counterparty supplies, which is what makes the step un-forgeable.
  async check(scope: FundingScope, prev?: FundingScope): Promise<void> {
    switch (await this.verify(scope)) {
      case 'match':
        this.recorded = true
        return

      // 🔴 THE SPLICE WINDOW. Without this arm, wiring the check makes every splice unsignable —
      // and silently: a correct-looking refusal that kills the rail. A splice is negotiated BEFORE
      // the EVM mirrors it, because the mirror is SPV-proven, so at the instant of signing the
      // context carries the NEW pair and NEW value while `BTCChannels` still holds the OLD ones.
      // The honest state during every splice is therefore exactly `mismatch`.
      //
      // ⭐ THE RULE, and it is the same one-way shape the `not-recorded` arm uses: accept iff the
      // chain shows THIS scope, or the ONE it replaces. A splice advances exactly one scope, so the
      // window is one step wide and closes the moment the mirror lands. It is NOT "trust the peer
      // when it says it is ahead" — the client must name a predecessor the CHAIN confirms.
      case 'mismatch': {
        if (!prev) throw new Error('T9: chain contradicts the funding scope')
        // Only a SPLICE may look ahead. If the scope did not rotate, a mismatch contradicts the
        // context in force, which is a rebind and is refused outright.
        if (prev.spliceParentFundingTxid === scope.spliceParentFundingTxid) {
          throw new Error('T9: chain contradicts the funding scope (no scope rotation)')
        }
        if (await this.verify(prev) !== 'match') {
          throw new Error('T9: neither this scope nor the one it replaces is what the chain holds')
        }
        // The chain is one scope behind: the splice is real and unmirrored. Accept — and DO latch,
        // because a record HAS been seen, so a later `not-recorded` is a downgrade exactly as it
        // would have been before.
        this.recorded = true
        return
      }

      // The one-way window. Legitimate BEFORE the record exists; a DOWNGRADE ATTEMPT after one has
      // been seen, which is the only form the downgrade can take.
      case 'not-recorded':
        if (this.recorded) {
          throw new Error('T9: the chain has answered for this channel before and now claims none')
        }
        return
    }
  }
}
