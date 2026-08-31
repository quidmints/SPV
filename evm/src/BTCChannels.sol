// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBtc} from "./imports/Interfaces.sol";
import {Types, AlreadyOpen, BadSPV, ChannelKeysMismatch, InvalidParam} from "./imports/Types.sol";
import {ISPVGateway} from "./spv/interfaces/ISPVGateway.sol";
import {BitcoinTx} from "./imports/BitcoinTx.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// (E125-d) ERC-1271 + ECDSA in one call, so a SMART-WALLET LP can register. Tries ECDSA
// first, so the EOA path — the common one — keeps its cost.

// ═══════════════════════════════════════════════════════════════════════
//  BTCChannels — standard-LDK 2-of-2 channels for native BTC LP deposits,
//  bridged to the BTC pool position by SPV-proven funding/close ONLY.
//
//  Each LP locks native BTC in a 2-of-2 (key-path MuSig2 taproot) on Bitcoin
//  with the protocol's hop node. The LP self-custodies (LP holds one of the two
//  keys / one MuSig2 share); the hop can never spend alone. If the hop vanishes,
//  the LP unilaterally force-closes the LDK channel (its commitment tx, recovering
//  its balance after the to_self_delay CSV) — there is NO funding-script CLTV
//  refund branch (key-path taproot has no leaf). Hop failure loses the LP nothing.
//
//  ─── Standard LDK ────────────────────────────────────────────────────
//
//  The channel is a STANDARD LDK/BOLT Lightning channel. Its commitment
//  state, revocation, HTLC resolution, and penalty enforcement live entirely
//  on Bitcoin/BOLT (LDK justice txs + watchtowers); the EVM does NOT anchor
//  commitments or adjudicate fraud.
//
//  The EVM's only role is to BRIDGE the channel to the BTC AMM position:
//    • openChannel  — SPV-prove the key-path P2TR funding UTXO `0x5120||Q`
//                     exists at value `amountSats`, then credit the LP's BTC pool
//                     position (BtcVault.requestDeposit — NOT Quid; the BTC side
//                     was regrouped out of Quid + Aux, see the bridge interface
//                     below. Also note `requestDeposit` is NOT open-only: a GROW
//                     splice calls it again to add liquidity). The funding output is
//                     byte-matched against the lpAuth-committed Q + value against
//                     the proven tx, so an LP cannot fabricate a position. (Q's
//                     2-of-2 genuineness is off-chain — see Funding script below.)
//    • splice       — SPV-prove the funding UTXO was spent into a NEW 2-of-2
//                     (grow OR shrink) and re-anchor the live outpoint. A
//                     shrink (LP partial withdrawal) reads the LP's BTC payout
//                     straight from the splice tx; the removed remainder
//                     settles as QUID proceeds.
//    • recordClose  — SPV-prove the funding UTXO was spent, then retire the
//                     position (requestRedeem), paying the LP's accrued
//                     USD-leg claims + delivered proceeds as QUID. ONE
//                     entrypoint, branching on Bitcoin locktime (below). The
//                     remaining channel BTC is recovered natively by the
//                     close tx itself.
//
//  SWAP SETTLEMENT (USD↔BTC) is a separate bidirectional HTLC-preimage flow:
//  a Lightning payment's preimage settles the dollar leg on the EVM (no
//  per-swap SPV). See the swap-settlement module / the Aux swap path.
//
//  ─── Funding script ─────────────────────────────────────────────────
//
//  A key-path simple-taproot (BOLT #995) 2-of-2. The funding output is the 34-byte
//  `0x5120 || Q`, where Q is the 32-byte x-only MuSig2 aggregate
//  `Q = lift_x(KeyAgg(KeySort(lpPubkey, hopPubkey))) + H_TapTweak·G` of the two
//  33-byte funding keys (BitcoinTx.buildTaprootScriptPubKey). The contract does
//  ⚠️ CORRECTED (E129/E142): this said "NO secp256k1 EC … so it does NOT prove". BOTH halves
//  are now false. `BitcoinTx.isTwoOfTwoOutputKey` PROVES Q == TapTweak(KeyAgg(lp,hop)) at the
//  OPEN and at every SPLICE, and `lpAuth` is retired (see (B) below). Left as a marker because
//  three separate notes in this file described the pre-delegation, pre-EC world as current.
//
//  ⛔ ATTESTATION IS NOT A TRUST ANCHOR HERE, AND THIS COMMENT USED TO SAY IT WAS.
//  It read "SGX attestation IS wired as the trust anchor: `_requireAttested` calls
//  `AttestedHopRegistry.isAttested` on the hop money-paths". §E185 deleted every one of those
//  call sites (they were a no-op while the registry was unpinned), so the sentence described
//  code that no longer existed — and the direction is deliberate, not an accident of cleanup.
//
//  🔑 THE DESIGN POSITION (owner, 2026-08-13): "there should be no attestation gates of any
//  kind anywhere… there should be no malicious code attacks possible." An attestation gate
//  asserts that an address runs approved CODE, which (a) is only as strong as whoever controls
//  the measurement whitelist, and (b) buys nothing against the attacks that actually matter —
//  every one of them is available to a hop running perfectly attested code. The invariant to
//  build toward is therefore stronger and simpler: NO PATH MAY DEPEND ON THE HOP BEING HONEST.
//  Where that does not yet hold is enumerated in §M1, not papered over with a gate.
//  NOTE: this is the SAME
//  trust posture as the prior P2WSH path —
//  that path reconstructed the script SHAPE but likewise never proved the LP
//  controlled its key or that the parties were independent; a malicious hop is the
//  residual either way. A key-path spend carries only a 64-byte Schnorr sig (no
//  witnessScript). There is NO on-chain CLTV refund branch — an LP exit is a
//  cooperative close (or, if the hop is offline, an LDK unilateral close).
//
//  ─── Cooperative-close discriminator ────────────────────────────────
//
//  A cooperative close sets Bitcoin locktime == 0; a unilaterally broadcast
//  LDK commitment tx carries a non-zero locktime. recordClose handles BOTH:
//  locktime == 0 reads the LP's co-signed BTC payout from the tx (delivered =
//  funded − payout → QUID proceeds); non-zero retires the position with
//  delivered = 0 (a solvency reconciliation of a unilateral close).
// ═══════════════════════════════════════════════════════════════════════

/// @notice The bridge into the BTC pool position — now BtcVault (the BTC side
///         was regrouped out of Quid + Aux). requestDeposit / requestRedeem /
///         resize / creditSwapIn / creditSwapOut are ALL gated `onlyBTCChannels`
///         on `Vault` (msg.sender == its pinned btcChannels), so only this
///         contract can drive them.
/// §MODFOLD — THIS LINE NAMED TWO GATES AND THERE IS ONE. `onlyBtcChannels` and
///         `onlyBTCChannels` differed only in the spelling of BTC and in their revert data;
///         they were merged onto the custom-error form. The split spelling is what made a
///         reader believe the deposit legs and the credit legs answered to different rules.
/// ⛔ (M1) THE MRENCLAVE WHITELIST GATES NOTHING HERE — this doc described `isAttested(hop)` as
/// gating "who may become a shared-pool hop", and §E185 deleted every call site. The registry is
/// referenced by NO code in this contract. It is left described only so the next reader knows the
/// absence is DELIBERATE: an attestation gate asserts an address runs approved CODE, which is
/// only as strong as whoever controls the whitelist and buys nothing against the attacks that
/// matter — every one of them is available to a hop running perfectly attested code (§M1).

contract BTCChannels is Ownable {
    // ════════════════════════════════════════════════════════════════════════════════════════
    // §E347b-BTC — THE REENTRANCY GUARD IS DECLARED HERE, NOT INHERITED, AND `BTCChannels` IS NOW
    // THE CONTRACT THAT NEEDS IT MOST. Measured 2026-08-23 after the fleet's folds: `Quid` fell to
    // 21,856 (2,720 spare) and **`BTCChannels` became the tightest deployable contract at 23,413,
    // with 1,163 left** — the binding constraint moved, so the same trade lane A made on `Quid`
    // pays more here.
    //  solmate's `nonReentrant` is a MODIFIER, so its body — an SLOAD, a comparison, the
    //  `"REENTRANCY"` revert string and TWO SSTOREs — was copied into all THIRTEEN use sites. One
    //  routine each way and thirteen jumps instead.
    //
    //  WHY IT COULD NOT BE DONE BY OVERRIDING: solmate declares `uint256 private locked = 1`, so a
    //  derived contract cannot read it and cannot write the split modifier. The base had to go.
    //
    //  ⚠️ THE STORAGE SLOT IS UNCHANGED, AND IT IS A NO-OP HERE ONLY BECAUSE OF THE BASE ORDER.
    //  `is Ownable, ReentrancyGuard` put solmate's `locked` LAST among the bases, i.e. immediately
    //  after `Ownable._owner` and immediately before this contract's own state — so declaring it as
    //  the FIRST member of the body lands it on exactly that slot. Same slot, same name, same
    //  initial value, same 1/2 discipline (never 0/1 — a 0→1 SSTORE is 20k gas, which is why
    //  solmate uses 1 and 2), same `"REENTRANCY"` string, so no revert-data consumer moves.
    //  ⛔ THIS DOES NOT GENERALISE BY INSPECTION — CHECK THE BASE ORDER EVERY TIME. `Vault is
    //  Ownable, ReentrancyGuard, Shares` and `Basket is ReentrancyGuard, Ownable` both put `locked`
    //  BEFORE another base's state, so the identical edit there SHIFTS that base's slots. It is
    //  still safe if nothing reads them by raw slot, but it is NOT a no-op and must not be landed
    //  as one. VERIFIED for this contract by diffing `forge inspect BTCChannels storageLayout`
    //  against the pristine parent — identical, which is the only acceptable evidence.
    // ════════════════════════════════════════════════════════════════════════════════════════
    uint private locked = 1;
    function _lock()   private { require(locked == 1, "REENTRANCY"); locked = 2; }
    function _unlock() private { locked = 1; }
    modifier nonReentrant { _lock(); _; _unlock(); }

    // ─── Constants ────────────────────────────────────────────────────
    // SPV finality / reorg risk (ACCEPTED, by design): every tx this contract
    // consumes (openChannel / splice / recordClose) is gated on
    // MIN_CONFIRMATIONS and then consumed ONCE — it is never re-checked against the
    // mainchain. A Bitcoin reorg DEEPER than this could orphan a consumed tx, leaving
    // the EVM's view (a credited position, a retired channel, minted proceeds) diverged
    // from Bitcoin. This is NOT mitigated by an unwind: once consumed, the backing has
    // already FACILITATED swaps, so "going back" is meaningless — the only sound defense
    // is a maturation delay before backing counts, which is EXACTLY what these
    // confirmations are. So MIN_CONFIRMATIONS is the maturation depth. 6 is accepted
    // because a ≥6-deep reorg is a catastrophic, global, ~$1M+-hashpower event (not a
    // targeted attack), it is NOT a theft vector (channel funds are 2-of-2; the LP keeps
    // its BTC), and minting is hard-bounded by the clamp regardless. Raise this if
    // a more conservative maturation window is wanted (it only adds open/close latency).
    // MIN_CONFIRMATIONS + STATUS_OPEN/STATUS_CLOSED are defined ONCE in ChannelLib
    // (canonical) and referenced here as `ChannelLib.X` — no duplicated constants to
    // drift out of sync (this previously bit: STATUS_OPEN was 1 in ChannelLib vs 0 here).

    // ─── State ─────────────────────────────────────────────────────────
    ISPVGateway     public immutable spv;
    // BtcVault — the regrouped BTC side (LP register/close + swap credit), bound in the
    // constructor. (E150: the legacy `(_aux, _range)` pair and `_hopNode` are gone.)
    IBtc public immutable btc;
    // 🔑 AUTHORIZATION IS PER-OUTPOINT, NOT PER-HOP.
    //   • There is no `channel.hop`: a channel records no owning hop (§E164).
    //   • The gate is `_onlyHop()`: `msg.sender` must equal `MAIN_HOP` or `FALLBACK_HOP`, two
    //     IMMUTABLE addresses, at every hop entrypoint.
    //   • Open is NOT permissionless — `openChannel` calls `_onlyHop()` too (§E185).
    // 🔴 **THE CONSEQUENCE THAT MUST NOT BE MISREAD: THERE IS NO LONGER A PER-CHANNEL AUTHORITY
    // PARTITION.** Either hop address may act on ANY channel. §E163 did that DELIBERATELY — pinning
    // authority to the opener meant the fallback could open channels and operate none — so the
    // capability is the point, not an oversight. But it means **"two daemons owning disjoint
    // channels cannot collide on-chain by construction" IS NO LONGER TRUE**; that separation is now
    // an OFF-CHAIN discipline (each daemon managing only its own channels), enforced by nothing in
    // this contract. Anyone reasoning about multi-daemon or family-plan partitioning from the old
    // text will reach the wrong conclusion — which is exactly what happened before this rewrite.
    // ✅ WHAT BINDS THE SUBMITTER (§E183): not a signature — `_onlyHop()`. `msg.sender` must be one
    // of two IMMUTABLE addresses, so the replay-through-another-submitter attack is unreachable by
    // construction rather than by a digest that commits to the caller. The residual "self-deal" — a party citing a
    // funding UTXO it doesn't truly control — is the SAME unproven-Bitcoin-key-control
    // residual the design accepts everywhere (bounded by the no-over-mint clamp
    // + the outpoint-uniqueness guard below).
    //
    // ✅ (2026-08-14) THIS SENTENCE USED TO END "resolved by SGX attestation", AND THAT IS BOTH
    // DEAD AND AN UNDERSTATEMENT. Attestation gates nothing here (§M1/§E185) — but the residual
    // was closed by §E165 as a side effect, after this comment was written. `openChannel` REQUIRES
    // a non-empty exit ladder, and every rung is verified by `BitcoinTx.verifyDeadManExit` against
    // `Q` recomputed from the pinned pubkeys — a BIP-340 signature under a 2-of-2 aggregate.
    // ⇒ TO OPEN A CHANNEL YOU MUST PRODUCE A VALID SIGNATURE UNDER `KeyAgg(lpPubkey, hopPubkey)`
    // OVER A SPEND OF THE CITED FUNDING OUTPOINT. A party citing a UTXO it does not control
    // cannot do that, because it cannot produce that signature.
    // ⚠️ `_proveFundingKeys` alone does NOT close it — it checks only that `Q` EQUALS
    // `KeyAgg(lp, hop)`, an algebraic relation over supplied bytes that proves nothing about
    // control. The proof of control is the SIGNATURE the ladder demands, not the key equality.
    // ⇒ The no-over-mint clamp is therefore no longer load-bearing for self-deal (rule 17).
    // (There is likewise no global hop Bitcoin pubkey: the hop derives a per-channel
    // funding key that rotates on every splice, so there is nothing static to pin.)

    mapping(bytes32 => Types.BTCChannel) public channels;

    // OUTPOINT-UNIQUENESS (solvency-critical): each Bitcoin funding UTXO may back at
    // most ONE EVM channel, keyed by keccak(fundingTxId, vout). Without a single
    // trusted opener, two channels could otherwise cite the SAME confirmed funding
    // output with different pubkey metadata (⇒ different channelId, bypassing the
    // AlreadyOpen guard) and double-count one on-chain BTC as backing for two
    // positions — an under-collateralization bug. Set at open and on every splice /
    // delivery rotation (the new funding output is claimed too).
    mapping(bytes32 => bool) public fundingOutpointUsed;

    // MULTI-HOP: number of OPEN channels each hop currently owns (++ at open, -- at
    // close). ⚠️ It used to gate "swap-in attestation authority (`settleSwapIn`)" — that
    // entrypoint is DELETED (M1#1). The credit path that replaced it is now DELETED TOO — see
    // hop SPV-proved into custody, so the open-channel count no longer stands in for solvency.
    // What it still does is bind hop authority to having BTC locked, without a per-call
    // channelId — only a hop with locked BTC (an open channel) may credit the shared
    // USD pool, mirroring the trust the RETIRED single-`hopNode` model carried, now with
    // per-instance scope. (Tense matters: `:133` states there is NO single global `hopNode`
    // today — this line describes what the gate INHERITS, not what exists. E149.)

    uint public totalSatsLocked;     // sum across all open channels

    // ANTI-ROLLBACK: monotonic per-channel persistence-freshness counter.
    // The channel's hop (the node runner) commits the highest persisted channel-monitor
    // `update_id` here after each durable local write; on reboot its enclave reads it
    // back and REFUSES to load a monitor whose `update_id` is behind (crate::freshness).
    // The chain cannot be rolled back, so a host that serves stale sealed channel state —
    // to reuse a MuSig2 nonce or broadcast a revoked state — is caught. `commitFreshness`
    // enforces strict monotonicity, so replaying/rolling back an old value reverts.
    mapping(bytes32 => uint64) public freshnessSeq;

    // ANTI-ROLLBACK: monotonic per-HOP channel-MANAGER blob freshness. Unlike
    // a monitor, LDK's channel manager carries no in-blob update_id, so the enclave
    // stamps a monotonic seq INTO the AES-sealed manager blob and commits it here after
    // each durable write. On reboot it reads `managerFreshnessSeq` back and refuses a
    // manager blob whose embedded seq is behind (crate::freshness, key = the manager
    // sentinel). Keyed by `msg.sender` (the hop): only the hop can advance its OWN slot,
    // so a griefer can bump only their own counter — never the hop's. Strict monotonic.
    mapping(address => uint64) public managerFreshnessSeq;


    // MIGRATION-AUTH ANTI-REPLAY: a rollback-proof one-shot set for
    // an operator-signed MigrationAuth's `nonce`. The SGX seed-migration bundle (transfer
    // the enclave-sealed root seed to a successor enclave) was replayable forever — nothing
    // consumed it — so a captured bundle could re-export the seed. The migrating (OLD)
    // enclave now CONSUMES the nonce here BEFORE exporting; `markMigrationNonceUsed` reverts
    // if the nonce is already used (atomic compare-and-set), and the daemon agreement-confirms
    // the consume landed before it exports — so a replay reverts and a host can't roll the
    // consumption back (it's on-chain, not in the enclave's sealed state).
    mapping(bytes32 => bool) public migrationNonceUsed;

    // ─── BTC swap-out recipient registry ──────────────────────────────
    //
    // Per-user BTC recipient identifier (pubkey-hash) used to route a
    // swap's on-Bitcoin transfer. Set on channel open from the LP's committed
    // shutdown script (see openChannel); separately settable by users who only
    // swap (never open a channel). Aux reads this via IBTCChannels.btcRecipientOf.
    mapping(address => bytes32) public btcRecipientOf;

    // Once an address registers via a channel open, its btcRecipientOf is LOCKED:
    // recordClose attributes the LP's cooperative-close balance to
    // P2WPKH(btcRecipientOf), so if the LP could later setBtcRecipient(junk) it
    // would make _lpFinalBalance read 0 → delivered = funded → over-claim the
    // pool's swap-out proceeds. Locking it (and the open-time consistency guard)
    // keeps it pinned to the LP's actual, committed payout script for the life of
    // every channel. Non-channel swap users are never locked.
    mapping(address => bool) public btcRecipientLocked;

    // (B) LP DELEGATION — THE LP RUNS NOTHING, AND THE CONSENT IS PER-OPEN, NOT A STANDING GRANT.
    // The LP signs a BIP-340 proof-of-possession over `btcRecipientPoPDigest(lpEth)` — a Bitcoin
    // signature, not an EVM one — and the hop submits gaslessly under `_onlyHop()`. The open is
    // bound to exactly one funding outpoint by `_useOutpoint`, which spends it once, ever.
    // Security: the contract SPV-proves + taproot byte-matches (`0x5120||Q`) every funding/splice
    // tx, and every BTC payout pins to `btcRecipientOf`, so a compromised hop can only fund
    // positions credited to the LP with payouts to the LP — bounded, never theft.
    //
    // §SLOP — THIS BLOCK DESCRIBED THE RETIRED REGISTRATION MODEL AS CURRENT, then corrected itself
    // eleven lines later. Deleted from it: "signs ONE cold delegation (EIP-712) [...] names the
    // single `hop` allowed to open/splice/deliver", "`version` is monotonic: the LP revokes/rotates
    // by signing a higher one", and "delegatedHop==0 ⇒ no delegation ⇒ no open". All three named
    // deleted state — `delegatedHop`, `delegationVersion`, `delegatedAuthority` and
    // `registerDelegation` are at ZERO live-code references (verified by a comments-stripped sweep,
    // not a word grep). Leaving a stale description above its own correction means whichever half a
    // reader stops at decides what they believe.
    // ⚠️ THE AUTHENTICATION IS LIVE, and must not be mistaken for slop — only its WITNESS moved
    // (§E183). What stops an arbitrary caller pinning some other LP's `btcRecipient` — which close,
    // splice-out and the dead-man exit all key on — is now two things together: `_onlyHop()` bounds
    // WHO may submit, and `btcRecipientPoP` proves the payout key's holder consented, over a digest
    // committing to an `lpEth` the contract DERIVES rather than accepts.
    // (E157) The monotonic counter had nothing left to guard: a signature bound to a single-use
    // outpoint cannot be replayed, and `_useOutpoint` enforces that.
    // ⚠️ Afterwards `_onlyHop()` lets EITHER immutable hop address act, on any channel: the
    // authorization is per-OUTPOINT, not per-hop — see the `_onlyHop` note for why that is
    // deliberate and what it costs.
    // (E156) THE E122 LP-NAMED FALLBACK IS DELETED — `fallbackAuthority`, `registerFallback[For]`,
    // `fallbackDigest`, `lastHeartbeatBlock`, `FALLBACK_STALENESS_BLOCKS` and
    // `_authorizedHopForChannel` are all gone. It asked the LP to nominate a rescuer in advance,
    // and it could not deliver one: the fleet held BOTH funding halves at the time (`deadman_exit.rs`), so a
    // nominated hop has no key to sign an exit with — it could only RELAY bytes the original hop
    // had already signed. The rescue was always "those bytes exist and their CLTV matured", never
    // "a named party acted". Arming at open (`Types.ExitArming`) makes the bytes an invariant, so
    // the nomination protected nothing and its two clocks (`lastHeartbeatBlock` here, the CLTV
    // deadline on Bitcoin) measured the same fact — one of them enforced by consensus.

    // ONE OPEN CHANNEL PER lpEth. The BTC-LP position (autoManaged[lpEth]) is
    // keyed per-address; a SECOND open for an lpEth that already has one would let
    // the aggregate `pooled` span channels while close attributes per-channel —
    // mis-attributing the others' notional as delivered (over-mint) and wiping
    // their positions. Splice is the capacity knob (resize one channel in place),
    // so an LP never needs two channels; an entity wanting more positions uses
    // more addresses. Set on open, cleared on close (sequential reopen allowed).
    // This makes the aggregate-spanning-channels state UNREPRESENTABLE.
    mapping(address => bool) public hasOpenBtcChannel;

    // DEAD-MAN EXIT (#114) — non-custodial BTC-LP force-close backstop that needs
    // NOTHING from the LP (no keyfile, no sidecar tool).
    //
    // 🔴 §M1#2 LANDED AND THIS PARAGRAPH DESCRIBES THE WORLD BEFORE IT. "The fleet holds BOTH
    // MuSig2 key halves (Option B)" is now FALSE IN THE DEFAULT DEPLOYMENT:
    // `quid-bridge-daemon.rs` reads `QUID_FLEET_COHOSTS_VAULT` with DEFAULT FALSE, and the
    // `true` branch logs that "the multisig is nominal in this deployment (M1#2)".
    // `taproot_signer.rs` states the same: the fleet "is vault-less by default, so it holds ONE
    // half", the LP's pubnonce arriving from the LP's own host.
    // ⇒ Under the default topology the fleet CANNOT pre-sign an exit alone — the LP's half is
    // needed, which is exactly the property §M1#2 existed to create, and exactly what makes the
    // ladder's "signs once" bound meaningful rather than nominal. The both-halves description
    // below applies ONLY under `QUID_FLEET_COHOSTS_VAULT=true`, the single-custodian deployment.
    // Kept rather than rewritten because the mechanism it describes is unchanged; only WHO can
    // produce the second partial moved.
    //
    // Under `QUID_FLEET_COHOSTS_VAULT=true` the fleet holds BOTH MuSig2
    // key halves (Option B), so it pre-signs OFF-CHAIN a FULLY-signed unilateral-exit
    // tx paying the LP's checkpoint balance → its committed `btcRecipientOf` P2TR
    // script, CLTV-timelocked to a near-future dead-man deadline, and EMITS the raw
    // bytes on-chain via `emitDeadManExit` (the heartbeat). This field records the
    // CLTV deadline of the channel's CURRENT live exit so on-chain observers can see
    // liveness: an alive fleet keeps re-emitting with the deadline pushed forward, so
    // the CLTV is always future ⇒ the exit is NOT broadcastable (no griefing / no
    // premature close). Fleet vanishes ⇒ heartbeat stops ⇒ the last deadline MATURES
    // ⇒ the already-public raw bytes become broadcastable by ANYONE (keeper / watch-
    // tower / LP via a stateless page hitting a public mempool API) — no key, no
    // signing. Bitcoin's CLTV is the enforcement; the EVM is only the trustless
    // bulletin board. Each splice recreates the 2-of-2 Q (spends the funding UTXO) ⇒
    // any prior exit is invalid on-chain ⇒ ONE live exit per current funding UTXO.
    /// (E165) EVERY deadline this channel has a VERIFIED pre-signed exit for.
    ///
    /// 🔑 WHY A SET AND NOT ONE. With the LP holding a funding half, refreshing an exit costs LP
    /// PARTICIPATION — and the whole design is built on the LP running nothing. Pre-signing a
    /// LADDER at open makes the LP's involvement a ONE-TIME act: it signs once, goes offline
    /// forever, and the fleet can execute any armed shape and **nothing else**, because it cannot
    /// produce a signature for a shape that was never signed.
    ///
    /// 🔴 **THE "SIGNS ONCE, GOES OFFLINE FOREVER" PREMISE ABOVE IS REFUTED — see §E172, which RAN
    /// the check rather than reasoning about it.** The vault↔hop channel is a LIVE ROUTING channel:
    /// `quid-hop/src/rebalancer.rs:32-35` — "the LP can forward a swap-in only up to
    /// `next_outbound_htlc_limit_msat`" — so **every swap-in is a commitment update needing the
    /// LP-side funding signature**, not merely every splice. §E172's verdict: "an LP that signs an
    /// enumerable ladder once at open and goes offline is incompatible with this channel. Not a
    /// tuning problem — the channel's job is forwarding."
    ///
    /// ⚠️ Note what is NOT affected, because the two are easy to conflate. The splice behaviour
    /// three lines above (a splice spends the funding UTXO ⇒ prior exits are invalid ⇒ ONE live
    /// exit per current UTXO) is CORRECT and was always documented; re-arming after a splice is
    /// the accepted cost, which is why `emitDeadManExit` exists and why its own comment says using
    /// it "should be the exception, not the heartbeat". §E172 is the stronger statement: on a
    /// FORWARDING channel the LP signature is needed per HTLC, so "the exception" is unreachable.
    ///
    /// ⇒ The set/ladder mechanism is sound; the OFFLINE-LP premise it is justified by is not.
    /// Anything relying on "the LP signs once and never again" must resolve §E172 first — either
    /// the LP runs something that signs continuously, or this channel stops forwarding.
    ///
    /// 🔑 THAT IS WHAT BOUNDS A COMPROMISED FLEET. "Spend anywhere" needs a signature; the LP's
    /// half only ever signed these. So the failure mode inverts: an operation outside the set
    /// cannot happen, which is DEGRADED SERVICE (the channel cannot splice) rather than LOSS OF
    /// FUNDS (the exits are already signed and remain broadcastable).
    ///
    /// ⚠️ `deadManDeadline` was ONE `uint64` and is now this map. A zero value means NOT ARMED,
    /// which is why arming rejects a zero deadline — the two would otherwise be indistinguishable.
    ///
    /// 🔑 **KEYED ON THE FUNDING OUTPOINT, NOT ON `channelId` — a CORRECTNESS key, not a naming
    /// choice.** A rung is only ever valid against the ONE outpoint it was signed to spend; the
    /// note above already says so ("any prior exit is invalid on-chain ⇒ ONE live exit per current
    /// funding UTXO"). Keyed on `channelId` this map OUTLIVED its rungs: a splice rotates the
    /// funding outpoint, every armed shape becomes unspendable, and the map still read `true` for
    /// each of them. That is a security-relevant flag that is SILENTLY FALSE — and it is precisely
    /// the flag an observer reads to decide whether an LP has an escape at all, so the failure is
    /// the plausible-but-wrong kind a check is supposed to prevent.
    /// Keyed on the outpoint, rotation RETIRES the stale entries with zero writes: they become
    /// unreachable rather than wrong, and a spliced channel with no fresh ladder reads `false`,
    /// which is the truth. Observers read `channels[id].fundingTxId`/`fundingVout` and hash the
    /// pair exactly as `_outpointKey` does.
    /// ⚠️ RENAMED FROM `exitArmedAt` DELIBERATELY. The getter's ABI shape is unchanged
    /// (`(bytes32,uint64)`), so a caller still passing `channelId` would compile and silently read
    /// `false` for a live ladder. Renaming makes every stale call site a compile error instead.
    mapping(bytes32 => mapping(uint64 => bool)) public exitArmedOnOutpoint;

    /// (E165) There is NO per-deadline checkpoint map. One was added with the ladder and NOTHING
    /// EVER READ IT — the stale-close guard lives in `recordClose` (a cooperative close has no
    /// deadline) and `recordDeadManExit` finalises from the tx's own outputs. Dead state deleted
    /// rather than kept "in case" (rule 1).

    // (#114) The LP balance the fleet last ATTESTED in its pre-signed dead-man exit, and
    // everything legitimately paid OUT of the channel since that attestation. A cooperative
    // close paying less than `checkpointOf - paidOutSinceCheckpoint` is a STALE close: the
    // fleet co-signed a payout smaller than the balance it last vouched for, net of every
    // sat the LP actually received. ⚠️ BOTH sinks must be counted or the guard fires on an
    // honest close -- a swap-out delivery (_settleSwapOutSlice) AND an LP withdrawal splice
    // (_withdrawalPayout) each lower the balance for legitimate reasons.
    // Zero `checkpointOf` ⇒ no attestation was ever made ⇒ nothing to compare, guard skipped.
    mapping(bytes32 => uint) public checkpointOf;
    mapping(bytes32 => uint) public paidOutSinceCheckpoint;

    /// @notice (§LAZY-OPEN) Sats custodied by `openChannel` whose LP pool CLAIM has not been
    ///         registered yet. Non-zero ⇒ **custody is recorded and the EVM position is not**,
    ///         which is the only state this split introduces. Zeroed by `registerChannelClaim`.
    /// @dev **Why the claim is deferred at all, since the split is otherwise pure cost:** the
    ///      funding output is SPV-PROVEN, so the LP's sats are already locked in the 2-of-2 on
    ///      Bitcoin before this contract ever runs. The claim leg reverts on PROTOCOL-WIDE state
    ///      (`checkBacking`, `repack`, `ZeroTwap` in `BtcLib.requestDeposit`) — none of it about
    ///      this channel. Fused, that put a revertible step in front of `_armLadder`, so a stale
    ///      TWAP or an unhealthy basket left a FUNDED channel with NO ARMED EXIT. The open is
    ///      retryable (the merkle proof stays valid), so nothing stranded permanently — but the
    ///      window is open exactly during stress, which is when a hop is most likely to go dark,
    ///      and a hop that vanishes inside it makes the loss permanent because no ladder was armed.
    /// ⚠️ **CONSERVATIVE FOR THE BASKET, WHICH IS WHY THE ORDER IS THIS WAY ROUND AND NOT THE
    ///      OTHER:** custody-without-claim counts sats into `totalSatsLocked` with no shares
    ///      issued, so the basket is OVER-backed while this is non-zero. The mirror state
    ///      (shares without custody) would be under-backed, and is unconstructible here.
    mapping(bytes32 => uint) public pendingClaimSats;


    // Swap-in replay guard: the Lightning HTLC hashlock (payment hash) of each
    // settled BTC→USD swap-in, marked used so a buggy/compromised/double-
    // submitting hop can't credit the same swap-in twice (which would drain
    // POOLED_USD for the seller — the old per-call `BtcInflowCap` bound was
    mapping(bytes32 => bool) public swapInUsed;

    // Swap-OUT request guard: one swap-out per swapId, ever. Symmetric with
    // swapInUsed — keeps a replayed/duplicate request from confusing the hop's
    // off-chain watcher into a double delivery.
    mapping(bytes32 => bool) public swapOutUsed;

    // ON-CHAIN swap-out (USD→BTC to a Bitcoin address, for a user with no LN
    // wallet — the "delivery rail B" twin of the BOLT11 path). requestSwapOutOnchain
    // takes the swapper's USD on the curve (like the LN path) and records the
    // delivery obligation here; deliverSwapOutOnchain settles it when the hop's
    // SPV-proven splice-out pays the swapper's script. Keyed by a client swapId
    // (dedup, shares swapOutUsed). `sats` is the obligation; `swapperScriptHash`
    // = keccak(scriptPubKey) the delivery must pay; `swapper` is who gets the USD
    // back on a reversal. Cleared on delivery (or reversal).
    // `usd` (6-dec) = the swapper's recorded payment — paid EXACTLY to the
    // delivering LP at deliverSwapOutOnchain, or cleared from pendingSwapOutUsd on
    // reversal (settleSwapIn). swapper/sats pack into slot 1; scriptHash slot 2; usd slot 3.
    /// (§T1-d / M1#3) PACKED SO THE TOKEN FITS WITHOUT A FOURTH SLOT.
    /// slot0 = swapper(20) + sats(8) + requestBlock(4) = 32 · slot1 = hash · slot2 = usd(12) + token(20)
    ///
    /// `sats` is `uint64`, not `uint96`: 2^64 sats is ~184 billion BTC against a 21-million-BTC
    /// supply, so the narrowing loses no reachable value and frees the 4 bytes `requestBlock`
    /// needs in slot 0 — which is what lets `token` occupy slot 2 alongside `usd`.
    ///
    /// 🔑 WHY `token` IS HERE AT ALL: a reversal used to take the token as a PARAMETER, i.e. the
    /// hop chose which asset the swapper was refunded in. It is now read from what the swapper's
    /// OWN `requestSwapOutOnchain` recorded, so the hop can neither redirect a refund, resize it,
    /// nor re-denominate it. That closes the token half of T2 on this path (M1#3).
    struct PendingOnchainSwapOut {
        address swapper; uint64 sats; uint32 requestBlock; bytes32 swapperScriptHash;
        uint96 usd; address token;
    }
    mapping(bytes32 => PendingOnchainSwapOut) public pendingOnchainSwapOut;

    event BtcRecipientRegistered(address indexed owner, bytes32 pubkeyHash);
    error NotPubkeyHash();

    // ─── Errors / Events ─────────────────────────────────────────────
    error NotLP();
    error NotChannelHop();       // caller is not this channel's recorded hop
    error OutpointReused();      // this funding UTXO already backs a channel
    error SwapInReplay();
    error SwapInPartialRejected();   // an all-or-nothing credit the pool could only partially fill
    error NothingToClaim();    // (§LAZY-OPEN) no unregistered custody for this channel: never opened,
                               // already claimed, or closed before the claim was registered
    error ClaimNotRegistered(); // (§LAZY-OPEN-SHRINK) this channel's claim is still deferred, so the
                               // LP has no position to shrink — call registerChannelClaim first
    error WrongBtcRecipient(); // open's payout hash != the LP's already-registered one
    error OneChannelPerLp();   // lpEth already has an open channel (splice to resize)
    error BtcRecipientLockedErr(); // can't setBtcRecipient once a channel locked it
    error WrongStatus();
    error WrongPrevOutpoint();        // tx doesn't spend this channel's funding UTXO
    error SpliceUnchanged();          // a splice must change the funded amount (grow or shrink)
    error SpliceIsNotAClose();        // (E153) tx pays a continuing 2-of-2 ⇒ it is a splice
    error SpliceKeyNotTwoOfTwo();     // (E129) new funding Q is not KeyAgg(lpPubkey, hopPubkey)
    error FundingKeyNotTwoOfTwo();    // (E142) initial funding Q is not KeyAgg(lpPubkey, hopPubkey)
    error ForeignSpliceOutput();      // a withdrawal splice paid value somewhere other than the
                                      // new funding output or the LP's committed btcRecipientOf
    error FreshnessNotMonotonic();    // a freshness commit must strictly increase (rollback/replay guard)
    error FreshnessJumpTooLarge();    // §HOP-RCE-2: monotonic stops a rollback; this stops a brick
    error ManagerFreshnessNotMonotonic(); // a channel-manager freshness commit must strictly increase
    error MigrationNonceAlreadyUsed();    // a MigrationAuth nonce may be consumed at most once (anti-replay)
    error LadderTooShallow();             // (§SPRINT-B4) a ladder needs ≥2 rungs at ≥2 distinct
                                          // CLTV deadlines — one rung is one window, and vault-less
                                          // (B0) the ladder is the LP's only escape
    // §SLOP — `NotDelegatedHop` DELETED: zero reverts, and it named `registerDelegation`, itself
    // deleted by §E157. ⚠️ This said "the live open authenticates `auth.lpSig`" — it does NOT since
    // §E183 item 1 deleted that field; the open authenticates the BIP-340 payout PoP and derives
    // `lpEth` from `p.lpPubkey`. The conclusion is unchanged and now has a simpler reason: with no
    // delegated-hop concept at all, the error could not fire. `git log -S` first (this repo has twice deleted a symbol that was a
    // deliberate gap marker): it traces to E156/E157, the commits that REMOVED its check.

    event ChannelOpened(
        bytes32 indexed channelId,
        address indexed lpEth,
        address indexed hop,          // MULTI-HOP: the opening hop — watchers topic-filter their own channels
        uint    sats,
        bytes   lpPubkey,             // 33-byte compressed ECDSA
        bytes   hopPubkey,            // 33-byte compressed ECDSA (snapshot at open)
        bytes32 fundingTxId,          // Bitcoin internal byte order
        uint32  fundingVout,          // index of the 2-of-2 output in funding tx
        bytes32 fundingBlockHash,
        uint64  fundingBlockHeight
    );
    event ChannelClosed(bytes32 indexed channelId, uint satsReturned);
    event FreshnessCommitted(bytes32 indexed channelId, uint64 seq);
    event ManagerFreshnessCommitted(address indexed hop, uint64 seq);
    event MigrationNonceConsumed(bytes32 indexed nonce, address indexed hop);
    event ChannelSpliced(
        bytes32 indexed channelId,
        address indexed lpEth,
        bool    isGrow,           // true = grow (add liquidity); false = shrink (withdraw)
        uint    deltaSats,        // sats added (grow) or removed + settled (shrink)
        uint    newTotalSats,     // channel's funded total after the splice
        bytes32 newFundingTxId,   // splice tx (spends the prior funding UTXO)
        uint32  newFundingVout
    );
    // ON-CHAIN swap-out: the swapper committed USD for `sats` BTC to `swapperScript`
    // (a Bitcoin scriptPubKey). The hop watches this, drives a splice-out paying that
    // script, then settles via deliverSwapOutOnchain. Reverses via settleSwapIn on failure.
    event SwapOutRequestedOnchain(
        address indexed swapper, uint256 sats, address token, bytes32 indexed swapId, bytes swapperScript
    );
    // The on-chain swap-out `swapId` was delivered: the splice-out tx paid the swapper
    // and the LP that sourced the BTC (channelId/lpEth) claimed its swapUsdBtc proceeds.
    event SwapOutDeliveredOnchain(
        bytes32 indexed swapId, bytes32 indexed channelId, address indexed lpEth, uint256 sats,
        bytes32 newFundingTxId, uint32 newFundingVout
    );
    // A swap-IN settled: `consumedSats` of the seller's `sats` were converted to USD. On an inventory-bounded
    // partial (`consumedSats < sats`, the POOLED_USD USD reserve couldn't absorb the whole input) the hop
    // MUST refund the `sats − consumedSats` remainder to the seller (their BTC is held off-chain over the
    // deposit/HTLC — the contract can only signal, not move native BTC). `paymentHash` keys the swap-in.
    event SwapInSettled(
        address indexed seller, bytes32 indexed paymentHash, uint256 sats, uint256 consumedSats, address token
    );
    // DEAD-MAN EXIT (#114): the fleet emitted a FULLY-signed, CLTV-timelocked
    // unilateral-exit tx for `channelId` (LP `lpEth`). `cltvDeadline` is the absolute
    // Bitcoin locktime the pre-signed `signedExitTx` bytes can first be mined at;
    // `checkpointSats` is the LP balance the tx pays to its committed btcRecipientOf.
    // Re-emitted on the fleet heartbeat with `cltvDeadline` pushed forward (supersedes
    // the prior emission for this channel). Once `cltvDeadline` matures with no fresher
    // emission (fleet gone), ANYONE may broadcast `signedExitTx` to a public mempool —
    // no key, no signing. The raw bytes live in the log forever (retrievable, cheap).
    event DeadManExitEmitted(
        bytes32 indexed channelId,
        address indexed lpEth,
        uint64  cltvDeadline,
        uint    checkpointSats,
        bytes   signedExitTx
    );
    error SwapOutReplay();   // zeroed or reused swap-out swapId (distinct from SwapInReplay)
    error NotExpired();      // swap-out self-refund called before the timeout
    uint constant SWAPOUT_REFUND_BLOCKS = 7200; // ~1 day @ 12s — swapper self-refund timeout (≫ the ~1-2h honest SPV delivery window)
    error NoSuchSwapOut();   // deliverSwapOutOnchain for an unknown/already-settled swapId
    error SwapOutNotDelivered(); // splice tx doesn't pay the swapper's script ≥ sats
    error NotAShrink();      // an on-chain swap-out delivery must REDUCE the channel

    /// @dev (§E233-ladder) The live-channel gate. **A `private view`, NOT a modifier — standing rule 8c,
    ///      and here it is the reason the §E233-ladder ladder fits at all.** As `modifier whenOpen`
    ///      this check inlined at all EIGHT use sites; the same conversion measured **+968 bytes for
    ///      six uses** on `_onlyHop` below, against **138 bytes of margin** (snapshot, 2026-08-17).
    ///      ⚠️ CALL IT AS THE FIRST STATEMENT OF THE BODY. As a modifier it ran BEFORE everything
    ///      including `_onlyHop()`, so which revert a caller sees is part of the observed behaviour
    ///      (tests assert `WrongStatus` vs `NotChannelHop` on specific paths). Ordering it after any
    ///      other check silently swaps those, which is a behaviour change wearing a refactor's
    ///      clothes.
    function _whenOpen(bytes32 channelId) private view {
        if (channels[channelId].status != ChannelLib.STATUS_OPEN) revert WrongStatus();
    }

    /// @dev (§LAZY-OPEN-SHRINK) A PARTIAL shrink reduces the LP's pool position, and
    ///      `BtcLib.resize` does `LP.pooled -= shrinkSats` — so against a channel whose claim is
    ///      still deferred (`pendingClaimSats != 0`, i.e. the position was never opened) it
    ///      **underflows to panic `0x11`, which is undiagnosable in production.** This says what
    ///      the caller must actually do instead. ⚠️ A FULL close needs no such guard and must not
    ///      get one: there `sharesRemoved = LP.pooled`, so the subtraction self-cancels at zero.
    /// @dev **A `private view`, NOT a modifier, deliberately** (standing rule 8c): a modifier's body
    ///      is inlined at every use site, and `BTCChannels` is the tightest contract in the tree.
    ///      (This quoted "356 bytes of margin"; margins swing by thousands — run
    ///      `tools/check-contract-sizes.py` rather than trusting any figure written here.)
    /// ⛔ **DO NOT "FIX" THIS BY AUTO-CLAIMING INSIDE THE SHRINK.** That rebuilds the coupling
    ///      §LAZY-OPEN removed — a claim leg that reverts on protocol-wide state, back on a path
    ///      where the swapper's BTC has ALREADY moved. Anyone can call `registerChannelClaim`
    ///      first; this only has to say so.
    function _requireClaimRegistered(bytes32 channelId) private view {
        if (pendingClaimSats[channelId] != 0) revert ClaimNotRegistered();
    }

    // ─── Shared close helper ──────────────────────────────────────────
    // Every close proof SPV-confirms the tx is in mainchain AND it spends
    // THIS channel's funding UTXO. _verifyTxSpendsChannel collapses that
    // across recordClose / splice; _finalizeClose flips status,
    // decrements the global counter, and retires the BTC pool position.
    function _verifyTxSpendsChannel(
        bytes32 channelId,
        bytes calldata rawTx,
        bytes32 blockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) internal view returns (bytes32 txId) {
        Types.BTCChannel storage ch = channels[channelId];
        txId = BitcoinTx.txid(rawTx);
        if (!spv.checkTxInclusion(merkleProof, blockHash, txId, txIndex, ChannelLib.MIN_CONFIRMATIONS))
            revert BadSPV();
        // Scan ALL inputs for the one spending the channel's funding UTXO. A
        // cooperative close / commitment tx has a single input (the funding), so
        // this is index 0 there — but an interactive-tx SPLICE carries the shared
        // funding input PLUS the LP's contributed input(s), and BOLT serial-id
        // ordering does NOT guarantee the funding is input 0. Assuming index 0
        // would revert a splice whose funding input sorted later (a liveness bug).
        uint nIn = BitcoinTx.inputCount(rawTx);
        bool spends;
        for (uint i; i < nIn; i++) {
            (bytes32 prevHash, uint32 prevVout) =
                BitcoinTx.extractInputPrevOutpoint(rawTx, i);
            if (prevHash == ch.fundingTxId && prevVout == ch.fundingVout) {
                spends = true;
                break;
            }
        }
        if (!spends) revert WrongPrevOutpoint();
    }

    /// @dev Claim a funding UTXO for exactly one channel (open + every rotation).
    function _useOutpoint(bytes32 fundingTxId, uint32 vout) internal {
        bytes32 op = _outpointKey(fundingTxId, vout);
        if (fundingOutpointUsed[op]) revert OutpointReused();
        fundingOutpointUsed[op] = true;
    }

    /// @dev The ONE identity of a funding UTXO, used by both things keyed on one:
    ///      `fundingOutpointUsed` (claimed once, ever) and `exitArmedOnOutpoint` (which rungs are
    ///      valid right now). Two callers, one routine — a modifier or a second inline `keccak256`
    ///      would put the same preimage in two places, and a divergence between them is exactly the
    ///      silent kind: the arming would write a key the recording path never reads.
    ///      ⚠️ `abi.encode` (not `encodePacked`) so the 32-byte txid and the `uint32` vout are each
    ///      padded to a word; the packed form of a 32-byte value followed by 4 bytes is ambiguous
    ///      with other splits. `_useOutpoint` used `abi.encode`, so this preserves every key
    ///      already written to `fundingOutpointUsed` on a live deployment.
    function _outpointKey(bytes32 fundingTxId, uint32 vout) private pure returns (bytes32) {
        return keccak256(abi.encode(fundingTxId, vout));
    }

    /// @dev The current funding scope of `channelId` as an `exitArmedOnOutpoint` key. One reader
    ///      for the arming and the recording path so the two cannot drift apart.
    function _currentOutpointKey(bytes32 channelId) private view returns (bytes32) {
        Types.BTCChannel storage ch = channels[channelId];
        return _outpointKey(ch.fundingTxId, ch.fundingVout);
    }

    /// @param lpPayoutSats the BTC the LP took in the close tx — Quid uses
    ///        `delivered = funded − lpPayout` as the deferred swap-out USD claim.
    function _finalizeClose(bytes32 channelId, uint lpPayoutSats)
        internal returns (uint totalSats) {
        Types.BTCChannel storage ch = channels[channelId];
        totalSats = ch.amountSats;
        ch.status = ChannelLib.STATUS_CLOSED;
        hasOpenBtcChannel[ch.lpEth] = false; // free the LP to open a fresh channel
        totalSatsLocked -= totalSats;
        // Retire the LP's BTC pool position + close-time reconcile: pays USD-leg
        // fees + the deferred swap-out principal (funded − final) as QUID. The
        // LP's remaining BTC is recovered by the close tx itself, off this path.
        // (§LN-RESERVE-FUNDER) THE POOL-INVENTORY SUBTRACTION IS GONE BECAUSE POOL INVENTORY NO
        // LONGER ENTERS CHANNELS. It was `totalSats − poolOwnedSats[channelId]`, and the only
        // writer that ever raised that figure was `parkProvenSats` — deleted with the rail it
        // funded. The LP is entitled to the whole channel.
        // ⚠️ THE CLAMP ITSELF SURVIVES, AND IT IS NOT VESTIGIAL: `_lpFinalBalance` reads what the
        // close tx PAID `btcRecipientOf`, which other inputs could push above what this channel
        // held. The BTC has already moved, so this cannot claw it back — it makes the divergence
        // VISIBLE, which is the whole point: `requestRedeem` clamps in silence.
        if (lpPayoutSats > totalSats) {
            emit PayoutExceededChannel(channelId, ch.lpEth, lpPayoutSats - totalSats);
            lpPayoutSats = totalSats;
        }
        // (§LAZY-OPEN) A channel closed before its claim was registered has NO EVM position, so
        // there is nothing to retire and `requestRedeem` would be retiring one that was never
        // created. The LP's BTC is recovered by the close tx itself, off this path, exactly as for
        // a claimed channel — the deferred credit is the only thing it never received.
        // ⚠️ **THE CLEAR MUST HAPPEN ON EVERY CLOSE, NOT ONLY IN THAT BRANCH:** leaving it set
        // would let `registerChannelClaim` credit a position for custody that has already left.
        bool claimed = pendingClaimSats[channelId] == 0;
        delete pendingClaimSats[channelId];
        if (claimed) btc.requestRedeem(ch.lpEth, lpPayoutSats);
    }

    /// @notice The LP's remaining channel balance read from a cooperative-close
    ///         tx: the SUM of all outputs paying the LP's P2WPKH (their channel
    ///         pubkey-hash, recorded as btcRecipientOf at open). 0 if absent (a
    ///         fully-delivered LP has no payout output). The hop enforces this
    ///         payout-script convention when it co-signs the cooperative close.
    /// @dev Sums ALL matching outputs (not just the first) so a close tx can't
    ///      under-report the LP's balance by splitting the payout across several
    ///      outputs to the same pkh → inflated `delivered` → over-claim.
    ///      NOTE: the old shared-proceeds-pool solvency backstop (`deliveredSlice ≤
    ///      netDeliveredBtc`) is GONE -- swap-out proceeds are now pinned
    ///      per-obligation (Core.pendingSwapOutUsd), so there is no cross-channel pool
    ///      to clamp. This read IS the attribution; a coop close's honesty rests on the
    ///      hop's counterparty-output policy (btcRecipientOf is the LP's committed script).
    function _lpFinalBalance(address lpEth, bytes calldata rawCloseTx)
        internal view returns (uint) {
        // The LP's committed key-path P2TR payout (`btcRecipientOf` x-only shutdown key).
        return BitcoinTx.sumOutputValuesToScript(rawCloseTx, _lpPayoutScript(lpEth));
    }

    /// @dev LP withdrawal payout for a SHRINK splice, WITH the anti-redirection guard.
    ///      A pure LP-withdrawal splice (the `splice()` entrypoint — distinct from a
    ///      swap-out delivery, which pays the swapper) legitimately has exactly two kinds
    ///      of output: the new (smaller) funding 2-of-2 at `fundingVout`, and the LP's
    ///      payout to its committed `btcRecipientOf` P2WPKH. We REJECT any other output:
    ///      without this, a malicious LP could route its withdrawal to a script ≠
    ///      btcRecipientOf, making `_lpFinalBalance` read 0 → `delivered = shrinkSats` →
    ///      over-claim the SHARED swap-out proceeds pool (cross-LP theft). With foreign
    ///      outputs banned, the to-script sum IS the true payout, so `delivered =
    ///      shrink − payout` is ungameable ON-CHAIN — no hop cooperation required (the
    ///      cooperative-close path is separately pinned by LDK's upfront-shutdown
    ///      enforcement; the on-chain swap-out path pins delivered to the obligation).
    ///      Over-paying the withdrawal into miner fees is the LP's own loss, not a gain.
    function _withdrawalPayout(address lpEth, bytes calldata rawSpliceTx, uint32 fundingVout)
        private view returns (uint) {
        bytes memory p2tr = _lpPayoutScript(lpEth);
        if (BitcoinTx.sumOutputValuesExcept(rawSpliceTx, fundingVout, p2tr) != 0)
            revert ForeignSpliceOutput();
        return BitcoinTx.sumOutputValuesToScript(rawSpliceTx, p2tr);
    }

    /// @dev The LP's committed payout scriptPubKey — key-path P2TR `0x5120||key` over the
    ///      32-byte x-only key in `btcRecipientOf` (= the LP's upfront-shutdown key,
    ///      `keys_manager::get_shutdown_scriptpubkey`, now a witness-v1 P2TR). ONE source
    ///      of truth for both the cooperative-close attribution (`_lpFinalBalance`) and the
    ///      LP-withdrawal anti-redirection guard (`_withdrawalPayout`), so the two can never
    ///      diverge. Uniform with the funding output (`0x5120||Q`) — the whole system is
    ///      taproot, so there is no P2WPKH script handling left.
    function _lpPayoutScript(address lpEth) private view returns (bytes memory) {
        return abi.encodePacked(bytes1(0x51), bytes1(0x20), btcRecipientOf[lpEth]);
    }

    /// @param _btcVault the merged BtcVault — LP register/close + swap credit.
    /// @dev (E150) THIS TOOK FOUR PARAMS AND NEEDED TWO. Removed: `_hopNode`, read NOWHERE —
    ///      the body carried `_hopNode;` purely to silence the unused-param warning, a
    ///      statement whose only job was to hide a dead parameter — and the `_aux`/`_range`
    ///      PAIR, which both designated the SAME vault via
    ///      `_range != address(0) ? _range : _aux`, a shim for two calling conventions left
    ///      from when the BTC side was split. **All 18 construction sites passed a non-zero
    ///      `_range`, so the `_aux` fallback was never once exercised**, and the compatibility
    ///      it preserved was with callers we control — none external, none in `quid-ln`.
    constructor(address _spv, address _btcVault, address _mainHop, address _fallbackHop,
                bytes32 _btcDepositKey)
        Ownable(msg.sender)
    {
        if (_mainHop == address(0) || _fallbackHop == address(0) || _mainHop == _fallbackHop)
            revert InvalidParam();
        spv = ISPVGateway(_spv);
        btc = IBtc(_btcVault);
        MAIN_HOP = _mainHop;
        FALLBACK_HOP = _fallbackHop;
        BTC_DEPOSIT_KEY = _btcDepositKey;
    }

    /// (E164) THE ONLY TWO ADDRESSES THAT MAY OPERATE A CHANNEL, fixed at deploy.
    ///
    /// 🔑 WHY IMMUTABLE AND NOT GOVERNED: a Safe-governed hop set is a Safe that can grant itself
    /// channels, which is the lever a 4-of-7 compromise pulls. Pinning both at construction takes
    /// governance out of the access-control path entirely — it can still bless enclave IMAGES,
    /// but it can never add an operator.
    ///
    /// 🔑 WHY TWO AND NOT ONE: `MAIN_HOP` runs the fleet; `FALLBACK_HOP` exists so a dead main
    /// does not strand every channel. They are the SAME trust domain (same operator, same image),
    /// which is what makes this a bare address check — there is nothing to nominate and no reason
    /// to make the fallback wait, so E122's per-LP nomination, staleness clock and heartbeat are
    /// all unnecessary rather than merely deleted.
    address public immutable MAIN_HOP;
    address public immutable FALLBACK_HOP;

    /// (E159) The fleet's PINNED swap-in deposit internal key (x-only). Every on-chain swap-in
    /// deposit address is `TapTweak(this, cltvRefundLeaf(userRefund, cltvHeight))`, so the contract
    /// can RECOMPUTE where a deposit had to land instead of trusting a hop to name it.
    ///
    /// ⚠️ THIS REPLACES A DERIVATION THE CHAIN CANNOT DO. `swap_in_onchain.rs` derives the deposit
    /// key at `m/70'/swap_index'` — BOTH LEVELS HARDENED — and a hardened child cannot be derived
    /// from any xpub, only from the private key. So no pinned PUBLIC key could ever reproduce it,
    /// and "is this deposit ours?" was unanswerable on-chain. Pinning ONE internal key and taking
    /// per-swap uniqueness from the CLTV leaf makes it answerable.
    bytes32 public immutable BTC_DEPOSIT_KEY;


    /// (E164/E163) The one authority check. It replaces FOUR separate `msg.sender ==
    /// channels[channelId].hop` gates and TWO `openChannelsOf[msg.sender] != 0` gates (both deleted).
    ///
    /// 🔴 THE BUG IT DISSOLVES (§E163): pinning authority to the hop that OPENED a channel meant
    /// the fallback could open new channels and operate NONE — it could not splice, refresh a
    /// dead-man exit, commit freshness or deliver a swap-out on anything the main opened.
    /// §E156 removed the staleness-based handover and §E157 pinned everything to `channel.hop`;
    /// each was right about its own mechanism and together they removed the CAPABILITY. Here the
    /// fallback works everywhere by construction, so there is no handover to get wrong.
    /// ⚠️ A FUNCTION, NOT A MODIFIER, DELIBERATELY: a modifier's body is INLINED at every use
    /// site, so six uses meant six copies of the check. As a `private view` it is one routine and
    /// six JUMPs. Measured: the modifier form cost +968 bytes of `BTCChannels` bytecode, on a
    /// contract whose margin is the binding constraint.
    function _onlyHop() private view {
        if (msg.sender != MAIN_HOP && msg.sender != FALLBACK_HOP) revert NotChannelHop();
    }

    // ─── Attested-hop gate — DELETED. The next three lines are QUOTED HISTORY, not behaviour. ───
    // (Marked 2026-08-16: unmarked, they read as a live description for three lines before the
    //  reader reaches the deletion notice — and what they describe is an INSECURE-BY-DEFAULT gate,
    //  which is the worst thing to leave looking current. There is no such mode; see below.)
    //   > "The whitelist that decides who may become a shared-pool hop. UNSET (0) ⇒ the gate is OFF
    //   >  (the permissionless open behaviour, for testnet / pre-attestation bootstrap). Governance
    //   >  PINS it ONCE to the live registry to turn the gate on; PIN-ONCE (can never be un-set or
    //   >  repointed) so a later compromised owner cannot disable it."
    // ⛔ (E185) THE ATTESTED-HOP REGISTRY IS DELETED — the decision was taken during §E164 and
    // never executed, so a no-op guard sat on a size-constrained contract pretending to gate.
    //
    // `hopRegistry` defaulted to `address(0)` and `_requireAttested` did NOTHING until someone
    // pinned it, which nobody ever did. With §E164's single node plus a hardcoded fallback the
    // authorised set is the two-address constant `MAIN_HOP`/`FALLBACK_HOP`, so asking a registry
    // whether one of two IMMUTABLE addresses is "attested" answers a question that cannot vary.
    //
    // 🔴 AND IT WAS HIDING A REAL GAP. `_onlyHop()` guards seven entrypoints; `openChannel` was
    // NOT one of them — its only hop-side gate was `_requireAttested`, i.e. nothing. That was
    // invisible precisely because a no-op reads like a check. `openChannel` now calls `_onlyHop()`
    // like every other hop entrypoint, which is what §E166-3 assumes when the fleet RELAYS the
    // LP's consent.

    // ═════════════════════════════════════════════════════════════════
    //  OPEN — an AUTHORIZED HOP submits the raw funding tx + SPV proof.
    //
    //  §SLOP — "the LP's DELEGATED HOP" stood here and named a relationship this contract no
    //  longer has: `delegatedHop`, `delegationVersion`, `delegatedAuthority` and
    //  `registerDelegation` are all deleted (see the deleted-state note above, zero live
    //  references). The hop is authorized by `_onlyHop()` against the immutable
    //  `MAIN_HOP`/`FALLBACK_HOP` pair, not delegated to by an LP.
    //
    // ⛔ ALL FOUR PUBLIC DIGEST ACCESSORS ARE DELETED, AND WITH THEM EVERY DOMAIN TAG.
    //
    // `spliceDigest`, `swapOutDeliverDigest` (E182), `openChannelDigest` and `openAuthDigest`
    // (§E307) all encoded LP CONSENTS THAT NO LONGER EXIST — `splice` and `deliverSwapOutOnchain`
    // are `_onlyHop()`-gated and §E183 deleted the open's `lpSig`. Measured before removing: ZERO
    // callers in `evm/src`/`evm/test`, and the only client mentions are Rust DOC COMMENTS on
    // `evm_codec.rs`'s own local reimplementations, which never call these accessors.
    //
    // 🔑 **WHY THE DOMAIN TAGS COULD THEN GO** (owner: *"no tags"*): a tag separates messages that
    // would otherwise collide, and with FOUR digests in one namespace it did real work. TWO remain
    // — the payout PoP and `rekey` — separated three ways already: different HASH (sha256 vs
    // keccak256), FIELD COUNT (3 vs 5), and SCHEME (BIP-340 Schnorr vs ECDSA).
    // ⛔ **DO NOT RE-ADD A THIRD VERIFIED DIGEST WITHOUT RE-DERIVING THAT.** If a new one shares a
    // hash AND an arity with an existing one, the separation is gone and something must restore it.
    //
    // ⚠️ NOT THE `create_sweep_tx` CASE, and the distinction is why deleting these was right: that
    // symbol was restored twice because its "dead" warning MARKED A REAL GAP (a missing caller that
    // was a security feature). These consents were not deferred, they were DELIBERATELY RETIRED, by
    // commits that say so at the call sites. A digest for a signature nobody will ever check is not
    // a gap marker. ⛔ DO NOT RESTORE THEM ON A "KEPT — tests call it" READING: that sentence stood
    // here, and it was false.
    //
    // 🔴 AND THEY WERE ACTIVELY MISLEADING. A reader auditing whether splices are LP-authorized
    // finds a public `spliceDigest` on the contract and reasonably concludes they are. THEY ARE
    // NOT — the hop gate is the only authorization on that path. §E182's `rekey` is the first
    // caller of an LP-consent digest that the contract actually VERIFIES, and it keeps its own
    // preimage inline (domain tag `rekey.v1`) rather than reviving a public accessor.

    /// @notice (B) The digest an LP signs COLD (once) to delegate channel operation to an
    ///         `authority` — a concrete hop. ⚠️ This used to read "OR THE Safe-governed
    ///         `hopRegistry` for fleet mode": §E185 DELETED the registry and every
    ///         `_requireAttested` call, so no registry-shaped authority exists to name.
    ///         Binds chainId + this contract + authority + payout script + version, so it
    ///         can't be replayed to another deployment; a higher version supersedes.
    /// @notice (E157-b) What the LP signs so a hop may open its channel. ONE signature, made at
    ///         onboarding, presented by the daemon at open. No transaction, no counter, no
    ///         EOA/smart-wallet split — but still a signature, and this is why.
    ///
    /// 🔑 WHY CONSENT CANNOT BE DELETED BY secp256k1, THOUGH HALF OF §E125 DID LAND. E125's route
    ///    had two halves: (1) prove `Q == KeyAgg(lpPubkey, hopPubkey)` and (2) derive `lpEth` from
    ///    `lpPubkey`. **(1) IS LIVE** — `BitcoinTx.isTwoOfTwoOutputKey` in `openChannel` — and it
    ///    closed the hole where a hop opened with ANY Q. **(2) IS REFUTED TWICE**: §E125-r measured
    ///    that `lpPubkey` is the PER-CHANNEL funding key (folded into `channelId`), so deriving
    ///    yields a different EVM address per channel and FRAGMENTS the LP's position; §E125-d
    ///    (owner) ruled derivation out because a derived address IS an EOA address and forecloses
    ///    smart wallets. E125's own words on what is left: *"NOTHING on the Bitcoin side identifies
    ///    the LP to the EVM; `lpEth` can only be ASSERTED, and only an LP signature makes the
    ///    assertion trustworthy."*
    /// ⚠️ AND ITS PREMISE DID NOT HOLD FOR VAULT LPs — WHICH §M1#2 HAS SINCE CHANGED, AND THE
    ///    CONCLUSION SURVIVES ANYWAY. E125 argued the LP *"already co-signs the Bitcoin funding, so
    ///    that signature does double duty"*. When this was written the fleet held BOTH funding
    ///    halves, so a vault LP co-signed NOTHING on either chain. **That is no longer the default**
    ///    (`QUID_FLEET_COHOSTS_VAULT=false`; the LP half lives on the LP's own host), so a vault LP
    ///    DOES now co-sign on Bitcoin.
    /// ⇒ **The requirement stands regardless, for a different reason.** A Bitcoin co-signature
    ///    proves control of the funding half; it does not name an `lpEth`. Nothing on the Bitcoin
    ///    side identifies the LP to the EVM, so absent THIS signature a hop could still name any
    ///    `lpEth` and any `btcRecipient` and take the position outright. **Security, not ceremony.**
    ///
    /// 🔑 WHY IT BINDS NEITHER Q NOR `amountSats`, HAVING BRIEFLY BOUND BOTH. A per-channel digest
    ///    is tighter and was written first. It is UNSIGNABLE by the only party that may sign it:
    ///    `Q` comes from per-channel LDK keys generated AFTER the LP's deposit, so binding it
    ///    forces the LP ONLINE AT OPEN — and the vault flow is built the other way
    ///    (`channel_driver.rs:698`: *"there is NO lpAuth round-trip: the LP runs nothing"*).
    ///    Standing-ness is what lets consent PRECEDE the channel, and it is the one property of
    ///    `registerDelegation` that was load-bearing.
    /// ⚠️ THE TRADE, ACCEPTED NOT DISCOVERED: these bytes replay for the same (hop, btcRecipient).
    ///    That IS their meaning — "this hop may run my channels, paying me here" — and a replay
    ///    opens a channel FOR the LP, PAYING the LP, funded by someone else's sats, with
    ///    `OneChannelPerLp` allowing one at a time. What is genuinely lost is EOA revocation, which
    ///    `delegationVersion` provided; a smart-wallet LP still revokes by rotating owners.
    ///    §E125 flagged exactly this ("valid forever and cannot be revoked"), so it is a KNOWN cost.

    function openChannel(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        Types.OpenAuth calldata auth,
        Types.ExitArming[] calldata exits
    ) external nonReentrant returns (bytes32 channelId)
    {
        // (E157/E183) THE LP'S CONSENT ARRIVES WITH THE OPEN, and it is a BITCOIN signature, not an
        // EVM one: `auth.btcRecipientPoP` is a BIP-340 proof-of-possession over
        // `btcRecipientPoPDigest(lpEth)`, where `lpEth` is DERIVED here from `p.lpPubkey` rather
        // than supplied. The LP signs nothing on the EVM side, so there is no address to assert
        // beside a signature. Submission is gated by `_onlyHop()` — one of two immutable addresses —
        // and the later splice/deliver by the same gate. Two protections in one step:
        // `openChannelBody` SPV-proves + taproot byte-matches (0x5120||Q) the funding, and
        // `btcRecipient` is pinned here as the sole payout — so no hop can redirect funds.
        _onlyHop();   // (E185) a real gate; this line used to be a no-op registry check
        // (§E183 item 1) DERIVED FROM THE CHANNEL KEY, NOT SUPPLIED. Bitcoin and the EVM share
        // secp256k1, so `p.lpPubkey` already states the LP's address; taking it as a parameter was
        // accepting a fact the key proves. The KeyAgg gate below binds `p.lpPubkey` to the
        // SPV-proven funding output, so a hop can only ever be credited for sats it truly funded
        // under a key it controls. `address(0)` = malformed or off-curve key.
        address lpEth = ChannelLib.lpEthOf(p.lpPubkey);
        if (lpEth == address(0)) revert InvalidParam();
        // ONE OPEN CHANNEL PER lpEth (see hasOpenBtcChannel): a 2nd open for an LP
        // that already has one would form the aggregate position the per-channel
        // close mis-attributes. Splice resizes the existing channel; more positions
        // use more addresses. This makes the over-mint/wipe bug unrepresentable.
        if (hasOpenBtcChannel[lpEth]) revert OneChannelPerLp();

        // (E157) AUTHENTICATE THE LP FIRST — consent is checked BEFORE the SPV proof and the
        // ~631k gas of secp256k1. Same reasoning the KeyAgg check already gives for sitting after
        // the merkle proof: both must pass, and the order decides only what a FAILING open pays.
        // ⚠️ The line naming `SignatureChecker` as serving "BOTH LP kinds" is gone with the import:
        // §REKEY-FOLD removed the last `isValidSignatureNow` in the tree. The EOA/smart-wallet split
        // it justified was already gone with the standing registration that forced it.
        // ⛔ (§E183 item 1) THE LP'S ECDSA SIGNATURE IS DELETED — the LP now signs NOTHING on the
        // EVM, which is what item 1 asked for and §E157 did not deliver. It bound two things and
        // BOTH are carried elsewhere now: the SUBMITTER, by `_onlyHop()` above (§E185) — one of two
        // immutable addresses, so the replay-through-another-submitter attack is unreachable; and
        // the PAYOUT SCRIPT, by the BIP-340 proof-of-possession below, whose digest
        // `btcRecipientPoPDigest(lpEth)` ALREADY COMMITS TO `lpEth` (§E138). A hop therefore cannot
        // pair a recipient it controls with another LP's funding — the PoP names whose payout it is.
        // Pin + LOCK the payout — the sole destination recordClose/_withdrawalPayout will enforce.
        if (btcRecipientLocked[lpEth] && btcRecipientOf[lpEth] != auth.btcRecipient)
            revert WrongBtcRecipient();
        // (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) The SAME signature now also binds the payment
        // basepoint, so the hop cannot substitute one and silently disarm the force-close check.
        _requireRecipientPoP(lpEth, auth.btcRecipient, auth.btcRecipientPoP,
                             keccak256(auth.lpPaymentPoint));
        _registerBtcRecipient(lpEth, auth.btcRecipient);
        btcRecipientLocked[lpEth] = true;

        Types.BTCChannel memory channel;
        (channelId, channel) = ChannelLib.openChannelBody(
            p, rawFundingTx, fundingMerkleProof, lpEth, spv
        );
        // (E142) THE OTHER HALF OF E129. `openChannelBody` locates the funding output purely by
        // the caller-supplied `Q` — key-path taproot reveals no script on-chain — so the
        // (keys <-> Q) binding was an assertion. This proves the channel's INITIAL funding key
        // really is the 2-of-2 of the two named pubkeys.
        // ⚠️ ORDERED AFTER the SPV proof deliberately: a bad merkle proof is far cheaper to
        //    reject than 631k gas of secp256k1. Both must pass; this only decides what a
        //    failing open pays.
        // ⇒ With this, `p.lpPubkey` is PROVEN rather than asserted — the precondition E125
        //   names for deriving `lpEth` from it and deleting delegation outright.
        _proveFundingKeys(p);
        if (channels[channelId].amountSats != 0) revert AlreadyOpen();
        // MULTI-HOP: bind this channel to its opening hop + bump its open-channel count.
        // OUTPOINT-UNIQUENESS: this confirmed funding UTXO may back only ONE channel
        // (else the same on-chain BTC double-counts as backing under two channelIds).
        _useOutpoint(channel.fundingTxId, channel.fundingVout);

        // (B) The LP's BTC payout key (btcRecipientOf) is pinned + LOCKED at
        // registerDelegation time — it is the SAME committed key-path P2TR shutdown
        // script recordClose/_withdrawalPayout enforce, pinned by this call itself (E157). recordClose attributes the LP's cooperative-close
        // balance to outputs paying that script; a hop can never redirect the payout.
        // (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) PIN THE LP'S `to_remote` OUTPUT KEY. Derived from
        // the LP's Lightning payment basepoint, which is the ONLY LP-side key stable for the
        // channel's life — a splice rotates `lpPubkey`, but `compute_funding_key_tweak` is applied
        // to the funding key alone and no LN operation rotates a basepoint.
        // ⚠️ INLINE, in the custody half. This does NOT collide with §LAZY-OPEN: what that defers
        // is the POOL CLAIM below, not custody, and this is custody — a force close must be able to
        // find the LP's output whether or not the claim was ever registered.
        channel.lpToRemoteKey = ChannelLib.lpToRemoteOutputKey(auth.lpPaymentPoint);
        channels[channelId] = channel;
        hasOpenBtcChannel[channel.lpEth] = true; // one-per-lpEth (cleared on close)
        totalSatsLocked += channel.amountSats;
        // (E156) ARM THE ESCAPE BEFORE THE CHANNEL IS USABLE. Must follow the `channels[channelId]`
        // write — `_armDeadManExit` reads `lpEth` back for the event — and it rejects a zero
        // deadline, so no channel can exist without a live escape.
        _armLadder(channelId, p, exits);

        // (§LAZY-OPEN) Channel locks back the pool: the LP's BTC pool position is credited with
        // the locked sats. One channel per lpEth (the position aggregates per address; close
        // retires it in full). ⚠️ **BOOKED HERE, CREDITED IN `registerChannelClaim`** — this used
        // to be an inline `btc.requestDeposit`, which put a leg that reverts on PROTOCOL-WIDE
        // state (`checkBacking`/`repack`/`ZeroTwap`) in the same transaction as `_armLadder` above.
        // The consequence was the opposite of what the arming is for: an unhealthy basket meant a
        // channel whose funding is already final on Bitcoin could not record its escape.
        // ⇒ **CUSTODY AND THE LADDER NOW DEPEND ONLY ON FACTS ABOUT THIS CHANNEL** (the SPV proof),
        // which cannot fail for a reason elsewhere in the protocol.
        //
        // ⭐ **WHY THIS IS A `try`, NOT AN UNCONDITIONAL DEFERRAL — MEASURED, NOT REASONED.** The
        // first version booked the claim ALWAYS and made `registerChannelClaim` the only way to
        // credit it. Two arms of the full suite on an isolated worktree priced that: baseline
        // 433 passed / 86 failed, unconditional-deferral 419 / 97, with **13 tests failing on that
        // arm alone** — including `test_SpliceOut_ShrinksPositionAndChannel`, because a partial
        // shrink does `LP.pooled -= shrinkSats` and underflows against a position that was never
        // opened. ⇒ **If essentially every caller must claim in the next breath, the deferral is
        // friction in the normal path and a new hazard in the shrink path.** The defect was only
        // ever that an IRREVERSIBLE record (custody + ladder) was rolled back by a REVERTIBLE leg,
        // so the fix is to stop the rollback — not to restructure who credits whom.
        // ⚠️ **THIS IS NOT A SWALLOWED ERROR** (standing rule 4): the failure is recorded in public
        // state, announced by an event, and retryable by anyone. What it must never become is a
        // `catch` that lets the channel proceed as if credited — the whole point is that
        // `pendingClaimSats` stays non-zero until someone actually credits it.
        try btc.requestDeposit(channel.lpEth, channel.amountSats) {
            // Healthy basket: credited inline, byte-for-byte the behaviour that shipped before.
        } catch {
            pendingClaimSats[channelId] = channel.amountSats;
            emit ChannelClaimDeferred(channelId, channel.lpEth, channel.amountSats);
        }

        _emitOpened(channelId, channel, p);
    }

    /// @notice (§LAZY-OPEN) Credit the LP's BTC pool position for a channel whose custody this
    ///         contract has already recorded. Idempotent, and **PERMISSIONLESS BY DESIGN**.
    /// @dev 🔒 **THE PERMISSIONLESSNESS IS THE WHOLE SAFETY ARGUMENT, NOT A CONVENIENCE.** Deferring
    ///      the claim would otherwise hand the hop a power it does not have today — "custody
    ///      arrives, the claim arrives IF the enclave cooperates" — a griefing vector introduced BY
    ///      the split rather than found by it. Because ANYONE may call this (the LP, a watchtower,
    ///      any observer), withholding is not available to a compromised enclave at all, so the
    ///      split leaves it with strictly LESS influence than the fused version it replaces.
    /// ⚠️  **IT TAKES NO CALLER-SUPPLIED ECONOMIC INPUT**, which is what makes opening it up safe:
    ///      the amount comes from the custody record THIS contract wrote under an SPV proof, so an
    ///      untrusted caller chooses only the TIMING, never the number.
    /// @dev Normally called in the same block as the open (even by the same submitter), so the
    ///      deferral is a SAFETY VALVE, not a normal-path delay — which is why no back-dated fee
    ///      accrual is needed: the LP earns from the claim, and anyone can make claim = custody + 0
    ///      blocks whenever the protocol is healthy. ⛔ **DO NOT "IMPROVE" THIS BY BACK-DATING THE
    ///      CREDIT TO THE CUSTODY MOMENT** — joining a `feesPerShare` pool with a stale checkpoint
    ///      claims fees already distributed to the other LPs, moving the loss instead of removing it.
    /// @dev No status check: `_finalizeClose` clears `pendingClaimSats`, so a closed channel already
    ///      reverts through the zero branch and a redundant `_whenOpen` would only cost bytes.
    /// @dev ⚠️ **CREDITS WHAT IS STILL CUSTODIED, NOT WHAT WAS CUSTODIED AT OPEN — a correctness
    ///      rule, not a defensive clamp.** Custody can move between the open and the claim:
    ///      `deliverSwapOutOnchain` shrinks the channel without registering anything. Crediting
    ///      the open-time figure after a shrink would issue shares against sats that have LEFT —
    ///      silently under-backing the basket, which is exactly the failure standing rule 3 says a
    ///      check earns its place for. The entitlement is the channel's CURRENT `amountSats`.
    function registerChannelClaim(bytes32 channelId) external nonReentrant {
        uint sats = pendingClaimSats[channelId];
        if (sats == 0) revert NothingToClaim();
        // Clamp a stale `pendingClaimSats` against what the channel CURRENTLY holds: a
        // `deliverSwapOutOnchain` shrink writes `amountSats` without registering anything, so the
        // open-time figure would issue shares against sats that have LEFT.
        uint total = channels[channelId].amountSats;
        if (sats > total) sats = total;
        delete pendingClaimSats[channelId];
        if (sats == 0) revert NothingToClaim();   // shrunk to nothing: no position to open
        btc.requestDeposit(channels[channelId].lpEth, sats);
    }

    /// @dev The 9-field ChannelOpened emit in its own frame — keeps openChannel
    ///      within the legacy stack (no via_ir crutch).
    function _emitOpened(
        bytes32 channelId,
        Types.BTCChannel memory channel,
        Types.OpenParams calldata p
    ) private {
        emit ChannelOpened(
            channelId, channel.lpEth, msg.sender, channel.amountSats,
            p.lpPubkey, p.hopPubkey, channel.fundingTxId, channel.fundingVout,
            p.fundingBlockHash, p.fundingBlockHeight
        );
    }

    // ═════════════════════════════════════════════════════════════════
    //  SPLICE — resize an open channel in place (the sanctioned capacity knob
    //  given ONE-channel-per-LP). ONE entrypoint, both directions: the splice tx
    //  SPENDS the channel's funding UTXO (input 0) and pays a new key-path P2TR
    //  `0x5120||Q'` of value p.amountSats for the same channel. channelId is STABLE
    //  (keyed on the original outpoint) so close/attribution are unaffected — only
    //  the live funding outpoint + funded total rotate.
    //    • GROW  (p.amountSats > current): adds liquidity to the LP's BTC pool
    //      position (requestDeposit). A deposit — nothing to settle.
    //    • SHRINK (p.amountSats < current): partial withdrawal — removes liquidity
    //      AND settles the shrunk slice through the SAME path as a cooperative close
    //      (resize): the proportional delivered portion mints to the LP as QUI,
    //      the native portion leaves with the LP in the splice tx's payout output.
    // ═════════════════════════════════════════════════════════════════
    /// @param p           Updated params: `amountSats` is the NEW funded total;
    ///                    `fundingBlockHash`/`fundingTxIndex` locate the splice tx;
    ///                    pubkeys are the channel's 2-of-2 pair.
    /// @param rawSpliceTx The Bitcoin splice tx (input 0 spends the prior UTXO; on a
    ///                    SHRINK it also pays the LP's withdrawal output to btcRecipientOf).
    /// @param exits (§E233-ladder) THE FRESH LADDER FOR THE ROTATED OUTPOINT — mandatory, exactly as at
    ///        open. A splice spends the funding UTXO, so every rung armed before it is unspendable;
    ///        the header on `exitArmedOnOutpoint` documented that and left the re-arming to
    ///        `emitDeadManExit` "on the next heartbeat". **In the LP-HOSTED deployment there is no
    ///        heartbeat** — `run_deadman_exit_heartbeat`'s own docstring says it does not run when
    ///        the fleet has no vault seed, and that "a channel's exits come from the §E165 ladder
    ///        the LP pre-signed at open". So a single splice left that channel with NO escape at
    ///        all, permanently, and splice is the only capacity mechanism there is.
    ///        ⇒ Arming here makes the escape-less state UNCONSTRUCTIBLE rather than merely
    ///        detectable (standing rule 17): there is no block between the rotation and the arming.
    ///        🔑 **AND IT COSTS THE LP NOTHING NEW.** A splice SPENDS the 2-of-2, so it already
    ///        requires the LP's funding half to sign — the LP is in this signing session by
    ///        construction. The rungs spend the splice tx's own output, whose txid is fixed the
    ///        moment that tx is signed, so they are producible in the SAME session. This is the
    ///        one place where "re-arming costs LP participation" is free.
    function splice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof,
        Types.ExitArming[] calldata exits
    ) external nonReentrant {
        _whenOpen(channelId);
        _onlyHop();
        // (B) Authorization. ⚠️ UPDATED 2026-08-07 (E122), AGAIN 2026-08-10 (E156): this said
        // "`channel.hop` … so ONLY that hop can resize" — and (E157) that is TRUE AGAIN: both the
        // fallback and the delegation are gone, so the gate is `channel.hop`. Bounded as before:
        // every payout output pins
        // to `btcRecipientOf`, so a wider authority set cannot redirect funds. The
        // retired per-splice lpAuth was redundant on top of this: _verifySplice still
        // SPV-proves rawSpliceTx SPENDS this channel's funding UTXO and byte-matches the new
        // taproot output against the CALLER-SUPPLIED `p.fundingTaproot`.
        // ⚠️ CORRECTED 2026-08-07 (E129). This used to conclude "…so the hop can grow (credits
        // the LP) or shrink (pays the LP), NEVER REDIRECT FUNDS." That conclusion does NOT
        // follow and must not be relied on. Byte-matching proves only that the caller's 32
        // bytes appear in the output. ✅ (E129-c) CLOSED: the KeyAgg gate at the end of
        // `_verifySplice` now proves `p.lpPubkey` IS inside the new `Q`, so a grow can no
        // longer migrate custody. The rest of this note is kept as the record of WHY.
        // `btcRecipientOf` pins a SHRINK's WITHDRAWAL output
        // (_withdrawalPayout); the CONTINUING FUNDING output is unconstrained. ⇒ A GROW can
        // move the channel's BTC into a `Q` the hop solely controls. Self-hosted LPs must
        // co-sign the splice and would see it; IN FLEET MODE THE OPERATOR HOLDS BOTH HALVES
        // (E94) AND CAN DO IT ALONE. Closing this needs on-chain KeyAgg verification (E127).
        // (E156) The primary only. The fallback clause that stood here is deleted: a nominated
        // hop held no funding key (the fleet holds both halves), so it could never sign a splice
        // — it could only relay bytes the primary had already signed. Bounded as before: the
        // splice is SPV-proven and every payout output pins to `btcRecipientOf`.

        // ⛔ (§SPLICE-ROTATES-BOTH-FUNDING-KEYS, 2026-08-31) `_requireChannelKeys(channelId, p)`
        // STOOD HERE UNDER THE HEADING *"(E162) A SPLICE MAY RESIZE A CHANNEL — IT MAY NOT REKEY
        // ONE"*. IT IS DELETED, AND THE PIN IS RE-WRITTEN BELOW INSTEAD. Two reasons, and the
        // first is that the check was UNSATISFIABLE against our own Lightning stack:
        //
        // 1. **LDK ROTATES BOTH FUNDING PUBKEYS ON EVERY SPLICE.** `send_splice_init`
        //    (`channel.rs:13021`) and the `splice_ack` handler (`:13137`) each call
        //    `ChannelSigner::new_funding_pubkey(prev_funding_txid)` = `funding_key(Some(txid))`
        //    tweaked by `SHA256(prev_funding_txid ‖ base_funding_secret)` (`sign/mod.rs:1472`).
        //    So the pair the bridge reads back is the ROTATED one, and this equality check could
        //    only ever revert `ChannelKeysMismatch` — while supplying the ORIGINAL pair instead
        //    would fail `_verifySplice`'s KeyAgg gate against the on-chain output. **Both doors
        //    were locked, and every gate `_requireChannelKeys` guards — including the retirement
        //    paths via `_requireNotSplice` — would have been shut on any spliced channel.**
        //
        // 2. **IT WAS NEVER WHAT MADE A ROTATION SAFE.** E162's own record says the bug it fixed
        //    was the STALE PIN, not a theft: *"rotated the funding outpoint, and left `keysHash`
        //    stale — after which both retirement paths reverted and the position could never be
        //    closed."* 🔑 **What actually stops a compromised hop from rotating into a pair it
        //    solely controls is the chain, not this line:** `_verifySplice` → `_verifyTxSpendsChannel`
        //    SPV-proves that `rawSpliceTx` SPENDS this channel's funding outpoint, and that
        //    outpoint is `Q = TapTweak(KeyAgg(lpPubkey, hopPubkey))` — a key-path taproot 2-of-2
        //    whose spend REQUIRES THE LP'S MuSig2 PARTIAL. A hop holding one half cannot move the
        //    funds to ANY pair. And under BIP-341 `Prevouts::All` that partial commits to the
        //    transaction's OUTPUTS, hence to the exact new 2-of-2 being rotated into.
        //    ⇒ **An equality check over a PUBLIC value is subsumed by an UNFORGEABLE SIGNATURE
        //    over the destination.** Deleting it removes a clamp, not a guarantee.
        //
        // ⚠️ THE PRECONDITION, STATED PLAINLY: the "spend requires the LP" argument is VACUOUS
        // while the fleet holds both halves (§M1#2, PHASE 1). That is not a regression introduced
        // here — `_requireChannelKeys` is an equality check a both-halves fleet satisfies with keys
        // it already holds, so it bought nothing across that same gap. **This loses no security
        // that exists today and gains the real guarantee the moment §M1#2 lands.**
        // (§SPLICE-ROTATES-BOTH-FUNDING-KEYS) THE TWO "UNCHANGED" GUARDS, FOLDED. This was
        // `p.amountSats == ch.amountSats`, which refused a PURE ROTATION — the image-upgrade case
        // §E182 built `rekey` for. `rekey`'s own `RekeyUnchanged` was the mirror image, refusing a
        // rotation that rotated nothing. **One condition covers both: reject only a splice that
        // changes NOTHING — neither the size nor the pair.** A rotation at constant size now
        // reaches `_applySplice`'s same-size branch, which was written for exactly it.
        // ⚠️ A no-op is refused because it would rotate the outpoint for nothing, and rotating the
        // outpoint voids every pre-signed rung under BIP-341 `Prevouts::All`. It is not a DoS
        // vector either way — a splice requires spending the 2-of-2, so the hop cannot do it alone.
        if (p.amountSats == channels[channelId].amountSats
            && keccak256(abi.encode(p.lpPubkey, p.hopPubkey)) == channels[channelId].keysHash)
            revert SpliceUnchanged();
        // Verify + rotate + (grow|shrink) in its own frame (legacy stack, no via_ir); returns the grow delta.
        uint grewBy = _applySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        // 🔴 RE-PIN THE PAIR — THE ROOT FIX FOR WHAT E162 ACTUALLY FOUND, and the same line
        // `_finishRekey` has always carried (`:1304`). `keysHash` is PER-SCOPE data, not the
        // channel's identity: `ChannelLib.sol:617` binds `channelId` to the ORIGINAL pair and the
        // ORIGINAL outpoint, so the id is stable across every rotation and nothing downstream
        // re-keys. Written AFTER `_applySplice`, which is where `_verifySplice` has just proven
        // `Q == TapTweak(KeyAgg(p.lpPubkey, p.hopPubkey))` against the on-chain output — so the
        // value pinned here is the pair the chain itself just attested to.
        channels[channelId].keysHash = keccak256(abi.encode(p.lpPubkey, p.hopPubkey));
        // (§E233-ladder) RE-ARM AGAINST THE ROTATED OUTPOINT — after `_applySplice` (which is what rotates
        // it) and BEFORE the external `registerBtcLp`, so a ladder that does not verify reverts the
        // whole splice with no accounting moved.
        // ⚠️ THE `paidOutSinceCheckpoint` RESET IS INTENTIONAL AND ORDER-DEPENDENT. `_shrinkSplice`
        // has just ADDED this splice's withdrawal to that tally; `_armDeadManExit` then zeroes it.
        // That is correct and is the arming rule already written there — "the tally restarts because
        // the new attestation already reflects every payout before it". The fresh rungs attest the
        // POST-shrink balance, so carrying the pre-shrink tally forward would double-count the
        // withdrawal against the stale-close guard and reject legitimate closes.
        _armLadder(channelId, p, exits);
        // (T1-f) THE CLAIM, decided here rather than inside the splice: an ordinary grow is
        // funded BY this LP, so it is a deposit and earns the LP its shares. The swap-in path
        // deliberately does NOT do this — see `settleSwapInSpliced`.
        if (grewBy != 0) btc.requestDeposit(channels[channelId].lpEth, grewBy);
        // FEE-INTO-CHANNEL: the hop may mark up to `grewBy` of this grow as BTC-leg fees it is FUNDING in —
        // they compound into the LP's position (requestDeposit already grew pooled by the full delta, so `delivered`
        // stays invariant); the bigger pooled share grows the LP's coop-close payout. (An earlier version of this
        // line added "and the hop keysends the same sats onto the LP's LN balance off-chain" — that leg is
        // OBSOLETE under delegation, where the LP runs no LN node.) `<= grewBy` ⇒ it
        // can only settle fees it actually spliced in (no theft); the Vault clamps to the real owed (no over-settle).
        // ⛔ (E191) `feeSettleSats` IS DELETED. It was accepted-and-ignored since §E145, kept
        // only for ABI stability with the Rust driver — and the note here said the removal
        // "must land in one commit with the Rust side", which this is.
        //
        // 🔴 IT WAS WORSE THAN DEAD WEIGHT: `channel_driver.rs` computed it by RPC-reading
        // `Vault.btcFeesOwedSats(address)` on EVERY splice — a function §E145 DELETED
        // (it stood at `Vault.sol:210` WHEN IT WAS DELETED; that line now holds an unrelated
        // live guard, so do not follow the coordinate — grep the NAME, which is zero-hit).
        // So each splice made a round-trip to a nonexistent selector,
        // swallowed the revert with `.unwrap_or(0)`, and passed the zero to a parameter the
        // contract discarded. A dead read feeding a dead argument, invisible because both
        // halves failed quietly.
    }

    // ⛔ (§SPLICE-ROTATES-BOTH-FUNDING-KEYS, 2026-08-31) `rekey`, `_authorizeRekey`, `_finishRekey`
    // AND `ChannelRekeyed` STOOD HERE. **THE CAPABILITY IS NOT GONE — IT FOLDED INTO `splice`**,
    // which now re-pins `keysHash` itself, and whose no-op guard admits a rotation at constant
    // size. §E182 built `rekey` so the Safe could whitelist a new MRENCLAVE and the hop half could
    // rotate to that image's key WITHOUT CLOSING THE CHANNEL; that is a `splice` with
    // `amountSats` unchanged and a new `hopPubkey`, and `_applySplice`'s same-size branch was
    // already written for it.
    //
    // 🔑 WHY THE SEPARATE ENTRYPOINT WAS NOT BUYING THE SAFETY IT CLAIMED. `rekeyAuthBody` pinned
    // the LP half by comparing `keccak256(abi.encode(p.lpPubkey, oldHopPubkey))` to `keysHash` —
    // an equality check over PUBLIC values. What actually stops a compromised hop rotating into a
    // pair it solely controls is that `_verifySplice` SPV-proves the transaction SPENDS the
    // channel's funding outpoint, and that outpoint is a key-path taproot 2-of-2 whose spend
    // REQUIRES THE LP'S MuSig2 PARTIAL — which, under `Prevouts::All`, commits to the outputs and
    // therefore to the exact new 2-of-2. **The signature subsumes the equality check.**
    //
    // ⚠️ AND THE PIN WAS UNSATISFIABLE AGAINST OUR OWN LN STACK: LDK rotates BOTH funding pubkeys
    // on every splice (`new_funding_pubkey(prev_funding_txid)`), so `p.lpPubkey` moves too and no
    // rotation LDK produces could ever have passed `rekeyAuthBody`. ⇒ **`rekey` had no caller
    // anywhere in the Rust stack** (grep is doc-references only), which is the symptom the fold
    // cures: the image upgrade is now reachable through the entrypoint the bridge already calls.
    //
    // ⛔ DO NOT RE-ADD A SEPARATE ROTATION ENTRYPOINT. Two paths that both rotate the outpoint and
    // re-pin the pair are two places to get the ordering wrong, and §E153's *unretirable forever*
    // regression was exactly a rotation that forgot to re-pin.


    // ⛔ (T1-f-root) `settleSwapInSpliced` IS DELETED — M1#1 superseded it and it was one of the
    // two ways POOL-OWNED SATS ENTERED AN LP'S CHANNEL.
    //
    // It spliced and credited in ONE call, which meant the sats it proved into custody landed in
    // whatever channel the hop chose — commingling pool inventory with an LP's own balance in one
    // UTXO. Every payout path then had to SUBTRACT to work out who owned what, and a clamp at
    // every exit is the tell that the STATE is wrong rather than the exits.
    //
    // (§FLEET-FRONTS-THE-WINDOW) and there is no buffered credit at all any more: the pool only
    // into a provable half and an instant half. Pool sats no longer enter channels AT ALL, so
    // commingling is not bounded — it is unconstructible.
    // It had no caller in quid-ln, the SPA or the scripts when it was removed.


    /// (§T1-f-general) Sats sitting in a channel that the LP has NO claim to — inventory the
    /// POOL owns, parked or bought there.
    ///
    /// 🔴 **THIS EXISTS BECAUSE THE CONDITION IT MEASURES IS OTHERWISE INVISIBLE.** §T1-f stopped
    /// a swap-in grow from minting the LP shares (right: the pool bought those sats) and M1#1's
    /// park does the same — so a channel's `amountSats` can exceed its LP's registered position.
    /// A close then pays the LP the WHOLE channel, and `requestRedeem` **clamps** the oversized
    /// settle rather than reverting, so the pool absorbs the difference in silence: no revert, no
    /// unusual event, nothing to notice. A leak, not a brick.
    ///
    /// ⚠️ Not a full fix on its own — the Bitcoin payout has already happened by the time a close
    /// is recorded, so this cannot claw anything back. What it does is make the divergence
    /// COMPUTABLE and EMITTED, which is the precondition for both the off-chain refusal that
    /// prevents it and the §INVARIANTS.md §1 conservation check that would catch it.







    /// A close paid the LP more than its entitlement — `over` sats of pool inventory left with it.
    /// A close or withdrawal paid `btcRecipientOf` MORE than the channel held. The BTC has
    /// already moved, so the clamp records the divergence rather than preventing it.
    event PayoutExceededChannel(bytes32 indexed channelId, address indexed lpEth, uint over);

    /// @notice (§LAZY-OPEN) The channel is custodied and its ladder armed, but the LP's pool claim
    ///         could not be credited because the CLAIM leg reverted on protocol-wide state
    ///         (`checkBacking`/`repack`/`ZeroTwap`). Anyone may complete it via
    ///         `registerChannelClaim`. ⚠️ **THIS IS THE ONLY ANNOUNCEMENT OF A STATE THAT WOULD
    ///         OTHERWISE BE SILENT** — the open succeeded, so nothing else about the transaction
    ///         says the LP is not yet earning. Alert on it.
    event ChannelClaimDeferred(bytes32 indexed channelId, address indexed lpEth, uint sats);



    /// (M1#1) Prove a grow-splice into custody WITHOUT crediting anyone — bank it for later.
    ///
    /// This is half of the answer to "provability or atomicity", and the half that makes the
    /// other half free. A Lightning HTLC produces no transaction to prove, so the LN rail could
    /// only be made provable by claiming the seller's BTC BEFORE knowing the pool could pay for
    /// it. Sats are fungible, so they need not be the SAME sats: the hop proves its own BTC into
    /// custody AHEAD of demand here, and a credit later draws that balance down.
    ///
    /// ⚠️ Credits NO LP position — §T1-f. The parked sats are not a deposit anyone owns; they are
    /// inventory awaiting a credit that will move them into `POOLED`.
    /// @param exits (§E233-ladder) THE FRESH LADDER FOR THE ROTATED OUTPOINT — mandatory, exactly as
    ///        on `splice`/`rekey`/`openChannel`. This grow rotates the funding outpoint like any
    ///        other, so the rungs armed before it spend a spent output and are dead the moment it
    ///        confirms. Arming here is what makes an escape-less channel UNCONSTRUCTIBLE at THIS
    ///        site too, rather than merely visible (the outpoint-keyed map reports the absence
    ///        honestly, which is not the same as there being an escape).
    ///        ⚠️ WHAT THE RUNGS MUST PAY IS THE LP'S ENTITLEMENT, NOT `amountSats`. A park grows the
    ///        channel with POOL inventory that credits no LP position (§T1-f), so a rung paying the
    ///        whole funding output hands the LP sats the pool owns. `_finalizeClose` clamps the
    ///        ACCOUNTING to what the channel held and emits `PayoutExceededChannel`, but the BTC has already
    ///        moved — the clamp cannot claw it back. The signer chooses the amount, and
    ///        `checkpointSats` is where it is recorded.


    /// @dev CUSTODY ONLY — this rotates the funding outpoint and moves `amountSats`; it does
    ///      NOT decide who owns the grown slice. **(§T1-f) The claim is the CALLER's decision**,
    ///      because the two callers differ on it: an ordinary `splice` grow is funded BY the LP
    ///      and so is a deposit that earns shares, while a swap-in's grow is BOUGHT BY THE POOL,
    ///      which also pays the seller USD — registering shares there paid twice for one set of
    ///      sats, once as a position and once in dollars, to a party that funded neither.
    ///      Custody grows either way, because the sats really did arrive.
    ///      (Lifting `requestDeposit` out to the caller also relieved this frame's stack — a
    ///      `bool` parameter here compiled to Stack-too-deep, and `via_ir` is off deliberately.)
    function _applySplice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof
    ) private returns (uint grewBy) {   // grow delta (0 on a shrink) so the caller can settle fees ≤ it
        Types.BTCChannel storage ch = channels[channelId];
        uint old = ch.amountSats;
        (bytes32 newTxId, uint32 newVout) =
            _verifySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        ch.fundingTxId = newTxId;
        ch.fundingVout = newVout;
        ch.amountSats  = p.amountSats;
        _useOutpoint(newTxId, newVout); // the rotated funding UTXO is now this channel's, claimed once
        if (p.amountSats > old) {
            uint delta = p.amountSats - old;
            totalSatsLocked += delta;
            grewBy = delta;                          // caller settles ≤ this as funded BTC-leg fees
            emit ChannelSpliced(channelId, ch.lpEth, true, delta, p.amountSats, newTxId, newVout);
        } else if (p.amountSats < old) {
            _shrinkSplice(channelId, p, rawSpliceTx, newTxId, newVout, old); // own frame (legacy stack)
        } else {
            // (§E182) SAME SIZE — a PURE REKEY: the outpoint rotated but no value moved.
            // ⚠️ This branch is unreachable from `splice`, which rejects an unchanged amount with
            // `SpliceUnchanged` before it gets here; `rekey` is what reaches it. Without it, a
            // rekey that keeps its size would fall into `_shrinkSplice` and be asked to find a
            // ZERO-value withdrawal output in the tx — a payout that does not exist, so the
            // rotation would revert for a reason that has nothing to do with what it is doing.
            emit ChannelSpliced(channelId, ch.lpEth, false, 0, p.amountSats, newTxId, newVout);
        }
    }

    /// @dev Shrink (withdrawal) branch of a splice, in its own frame: settle the removed
    ///      slice like a close. The LP's native payout is read from the splice tx (output
    ///      to btcRecipientOf), the remainder delivered as clamped QUI. resize
    ///      reads LP.pooled (still the OLD funded) and decrements it, so LP.pooled ==
    ///      ch.amountSats after. `_withdrawalPayout` ENFORCES the payout lands on
    ///      btcRecipientOf (rejects any foreign output), so the LP cannot route its
    ///      withdrawal away to drive the payout → 0 and inflate `delivered` (over-claim the
    ///      shared proceeds pool). All native (exactUsd=0): a withdrawal carries no proceeds
    ///      slice (lpPayout == shrink ⇒ deliveredRaw 0).
    function _shrinkSplice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32 newTxId,
        uint32 newVout,
        uint old
    ) private {
        address lpEth = channels[channelId].lpEth;
        uint shrinkSats = old - p.amountSats;
        totalSatsLocked -= shrinkSats;
        uint lpPayoutSats = _withdrawalPayout(lpEth, rawSpliceTx, newVout);
        // (§T1-f-general) THE SAME BOUND AS `_finalizeClose`, ON THE PATH AN LP WOULD REACH FIRST.
        // A withdrawal shrink pays whatever the splice tx sent to `btcRecipientOf`, and other
        // inputs to that same transaction could push the figure above what this channel held.
        //
        // ⚠️ CLAMP, NOT REVERT, AND THE REASON IS NOT SQUEAMISHNESS: the splice is already
        // broadcast and SPV-proven by the time this runs, so reverting cannot recall the sats —
        // it would only leave the EVM believing the channel is bigger than it is, which is the
        // "unretirable forever" hazard §E162 exists to prevent. Recording the truth beats
        // refusing to record it.
        if (lpPayoutSats > old) {
            emit PayoutExceededChannel(channelId, lpEth, lpPayoutSats - old);
            lpPayoutSats = old;
        }
        paidOutSinceCheckpoint[channelId] += lpPayoutSats;   // legitimate balance fall
        _requireClaimRegistered(channelId);   // (§LAZY-OPEN-SHRINK) else `LP.pooled -=` panics
        btc.resize(lpEth, shrinkSats, lpPayoutSats, 0);
        emit ChannelSpliced(channelId, lpEth, false, shrinkSats, p.amountSats, newTxId, newVout);
    }

    /// @notice (#114 DEAD-MAN EXIT) Emit / refresh the fleet's pre-signed, CLTV-
    ///         timelocked unilateral-exit tx for a channel — the heartbeat. The fleet
    ///         holds both MuSig2 key halves (Option B) and signs OFF-CHAIN a tx that
    ///         pays the LP's `checkpointSats` balance → its committed `btcRecipientOf`
    ///         P2TR shutdown script, with an absolute CLTV = `cltvDeadline`. On-chain we
    ///         ONLY record the deadline (liveness) and re-publish the raw bytes as an
    ///         event: the EVM is a trustless bulletin board, Bitcoin's CLTV is the
    ///         enforcement. Alive fleet ⇒ re-emitted with the deadline pushed forward ⇒
    ///         CLTV always future ⇒ the exit is NOT broadcastable (no griefing). Fleet
    ///         vanishes ⇒ heartbeat stops ⇒ the last deadline matures ⇒ anyone broadcasts
    ///         the already-public bytes (no key, no signing). A splice recreates the
    ///         funding UTXO / 2-of-2 Q, so the fleet re-signs against the new UTXO on its
    ///         next heartbeat (a stale exit spends a spent UTXO ⇒ invalid) — ONE live
    ///         exit per current funding UTXO.
    ///
    ///         AUTHORITY: identical (B) gate to `openChannel` — `_onlyHop()` (a two-address
    ///         check against `MAIN_HOP`/`FALLBACK_HOP`) + `channel.hop`, so only the hop that
    ///         opened this channel may emit (E157). ⚠️ This named `_requireAttested` until
    ///         §E185 deleted it; the gate is the per-channel `channel.hop` binding, NOT an
    ///         attestation. The payout is pinned to
    ///         `btcRecipientOf` INSIDE the signed bytes, so this can only publish a
    ///         backstop that pays the LP — it can never redirect funds. Emit-only (no
    ///         external call, no fund movement) ⇒ no reentrancy surface.
    function emitDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.ExitArming calldata exit
    ) external {
        _whenOpen(channelId);
        _onlyHop();
        // (E128) `p` is needed to recompute `Q`; `_requireChannelKeys` is what stops a hop naming
        // a key pair whose aggregate it controls and verifying the exit against THAT.
        _requireChannelKeys(channelId, p);
        // (E165) Refreshing arms ONE more shape; the LADDER is armed at open. This path still
        // exists because a long-lived channel may outrun its pre-signed set — but with the LP
        // holding a funding half it costs LP participation, which is exactly what the ladder is
        // for. Using it should be the exception, not the heartbeat.
        // 🔴 §HOP-RCE-1 — A REFRESH MAY NOT LOWER THE ATTESTATION, BECAUSE NOTHING HERE BINDS IT
        //    TO *NOW*. `_armDeadManExit` proves the bytes are structurally sound, correctly signed
        //    against `Q`, and pay at least what they attest — none of which expires. So EVERY
        //    arming this channel was ever given re-verifies forever, and this path used to write
        //    the attestation UNCONDITIONALLY: a hop replaying the oldest one it holds ratcheted
        //    `checkpointOf` down to the channel's opening balance, and the stale-close guard at
        //    `_recordClose` then permitted exactly the closes it exists to reject.
        //
        // ⚠️ THE OLD JUSTIFICATION — *"the balance may have DROPPED, and keeping a stale higher
        //    attestation would reject legitimate closes"* — IS COVERED TWICE OVER BY THE OTHER
        //    TERM, AND THAT IS WHY THIS IS SAFE TO REFUSE. A fall is recorded by crediting
        //    `paidOutSinceCheckpoint` (`:1568` cooperative payout, *"legitimate balance fall"*;
        //    `:2446` splice-out), and the guard subtracts precisely that term. Lowering the
        //    checkpoint was a SECOND way to say the same thing — redundant with the mechanism
        //    that is driven by proven on-chain events, and unlike it, drivable at will by the hop.
        //
        // ⇒ The ladder is deliberately NOT gated the same way: each of its arms rides a REAL
        //   proven splice or open, so a lower attestation there is tied to a custody change the
        //   chain witnessed. This entrypoint carries no such event — it is the pure refresh, and
        //   the pure refresh is the one an attacker gets for free.
        if (exit.checkpointSats < checkpointOf[channelId]) revert CheckpointRegression();
        _armDeadManExit(channelId, p, exit);
        checkpointOf[channelId] = exit.checkpointSats;
    }

    /// @dev (E142/E129) The (keys ↔ Q) proof, in its own frame — `openChannel` gained a calldata
    ///      ARRAY for the exit ladder (two more stack slots) and went over the legacy limit.
    ///      Frame, never `via_ir`.
    function _proveFundingKeys(Types.OpenParams calldata p) private view {
        if (!BitcoinTx.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert FundingKeyNotTwoOfTwo();
    }

    /// @dev (E165) ARM THE WHOLE LADDER, in its own frame — `openChannel` is already at the legacy
    ///      stack limit, and the house fix is a frame, never `via_ir`. Each shape is verified
    ///      (structure, sighash, signature), so the LP's ONE-TIME participation buys every exit it
    ///      will ever need. (§SPRINT-B4) At least TWO are required, at distinct deadlines: a
    ///      channel with no armed escape is precisely the window §E156 closed, and a channel with
    ///      ONE window is that same channel after one missed deadline.
    function _armLadder(
        bytes32 channelId, Types.OpenParams calldata p, Types.ExitArming[] calldata exits
    ) private {
        // (§SPRINT-B4) DEPTH IS LOAD-BEARING, NOT A NICETY. Since B0 (`99fda5e9`) the fleet is
        // vault-less by default, the heartbeat does not run, and this ladder is the LP's ONLY
        // escape — a single rung is a single CLTV window, and one missed window would leave the
        // channel permanently escape-less. Two rungs at the SAME deadline are still one window
        // (the deadline is committed inside the signed bytes via the BIP-341 sighash, so a
        // distinct deadline is necessarily a distinct, independently usable exit). The chain
        // enforces only "more than one window"; HOW deep and how spaced stays the signer's
        // policy. Extra same-deadline rungs (fee variants) remain legal beyond the first two.
        if (exits.length < 2) revert LadderTooShallow();
        // ⚠️ THE LADDER IS ONE ATTESTATION SET, so its rungs must not overwrite each other's
        // checkpoint — arming N of them used to write `checkpointOf` N times and keep whichever
        // came LAST, i.e. an arbitrary rung. Take the HIGHEST: the stale-close guard rejects a
        // cooperative close paying less than the attested balance, so the highest attestation is
        // the most protective of the LP.
        uint hi;
        bool distinct;
        uint64 first = exits[0].cltvDeadline;
        for (uint i; i < exits.length; ++i) {
            _armDeadManExit(channelId, p, exits[i]);
            if (exits[i].cltvDeadline != first) distinct = true;
            if (exits[i].checkpointSats > hi) hi = exits[i].checkpointSats;
        }
        if (!distinct) revert LadderTooShallow();
        checkpointOf[channelId] = hi;
    }

    /// @dev (E156) Record a pre-signed exit against a channel. ONE body, TWO callers: `openChannel`
    ///      arms the first one (mandatory — see `Types.ExitArming`) and `emitDeadManExit` refreshes
    ///      it. Keeping them separate is what let the open path ship with no exit at all.
    ///      The tally restarts because the new attestation already reflects every payout before it.
    function _armDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.ExitArming calldata exit
    ) private {
        // A ZERO DEADLINE IS DISARMING, NOT ARMING. `recordDeadManExit` cannot tell "deadline 0"
        // from "never armed", so allowing it would hand any authorized hop a way to strip the
        // LP's escape with one call. Rejected for BOTH callers, which is why it lives here.
        if (exit.cltvDeadline == 0) revert InvalidParam();

        // (E128) VERIFY THE BYTES. Until now this only EMITTED them: the LP's sole
        // fleet-independent escape was whatever the hop chose to hand over, and a hop could arm
        // every channel with garbage while the chain recorded it as protection. Structure,
        // BIP-341 sighash and BIP-340 signature are all checked against the funding key `Q`
        // recomputed from the pubkeys pinned at open.
        // (E165-b) THE RETURNED AMOUNT IS NOT DECORATION. `verifyDeadManExit` returns what the
        // exit actually pays the LP, and it used to be DISCARDED — so a hop could arm a
        // structurally perfect, correctly-signed exit paying ONE SATOSHI and every check passed.
        // The escape would exist, verify, and be worthless. Requiring it to honour the arming's
        // own `checkpointSats` ties the two numbers together: claim more than you pay and the
        // arming reverts; claim less and the stale-close guard you fed is the one that suffers.
        uint paid = BitcoinTx.verifyDeadManExit(
            exit.signedExitTx,
            BitcoinTx.ExitCheck({
                fundingTxId: channels[channelId].fundingTxId,
                fundingVout: channels[channelId].fundingVout,
                fundingSats: channels[channelId].amountSats,
                q:           BitcoinTx.computeOutputKey(p.lpPubkey, p.hopPubkey),
                cltvDeadline: exit.cltvDeadline
            }),
            _lpPayoutScript(channels[channelId].lpEth),
            exit.prevValues, exit.prevScripts
        );
        if (paid < exit.checkpointSats) revert ExitUnderpaysCheckpoint();

        // Armed against the channel's CURRENT funding scope — the same outpoint
        // `BitcoinTx.verifyDeadManExit` just proved these bytes spend. A later rotation makes this
        // entry unreachable rather than stale (see `exitArmedOnOutpoint`).
        exitArmedOnOutpoint[_currentOutpointKey(channelId)][exit.cltvDeadline] = true;
        paidOutSinceCheckpoint[channelId] = 0;
        emit DeadManExitEmitted(channelId, channels[channelId].lpEth,
            exit.cltvDeadline, exit.checkpointSats, exit.signedExitTx);
    }

    /// @dev SPV-verify the splice tx spends the channel's current funding UTXO,
    ///      then locate the new 2-of-2 output (value == p.amountSats). Own frame
    ///      to keep splice within the legacy stack.
    function _verifySplice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof
    ) private view returns (bytes32 newTxId, uint32 newVout) {
        newTxId = _verifyTxSpendsChannel(
            channelId, rawSpliceTx, p.fundingBlockHash, spliceMerkleProof, p.fundingTxIndex);
        newVout = ChannelLib.locateChannelOutput(
            rawSpliceTx, p.lpPubkey, p.hopPubkey, p.fundingTaproot, p.amountSats);
        // (E129) THE KeyAgg GATE — the line the whole secp256k1 exercise exists for.
        // `locateChannelOutput` above proves only that the caller's 32 bytes appear in the new
        // funding output; it cannot tell the LP's channel from a `Q` the hop alone controls.
        // This proves `Q == TapTweak(KeyAgg(KeySort(lpPubkey, hopPubkey)))`, true only if BOTH
        // named keys are inside it, so a GROW can no longer migrate custody. In fleet mode,
        // where the operator holds both halves (E94), it is the only thing between a splice
        // and a redirect.
        //
        // ⚠️ THIS WAS LANDED, REVERTED, AND RE-LANDED — read E147 before touching it. The
        //    revert was correct at the time: the repo's one real-Bitcoin fixture recorded a
        //    `fundingTaproot` that was NOT the aggregate of its own pubkeys (the generator
        //    asked bitcoind for an unrelated address), so this gate would have REJECTED EVERY
        //    REAL SPLICE — a liveness failure worse than the custody hole it closes. The
        //    fixture is regenerated (0/19 → 19/19 satisfy the property), its integrity is
        //    asserted in its own test, and `test_splice_realRegtestShrink` now drives this
        //    path from real data. Do not re-enable a gate like this without all three.
        //
        // ⚠️ 631,432 gas on the accepting path — MEASURED, not estimated. Splices are rare and
        //    operator-initiated, so it is affordable here as it would not be per-swap.
        if (!BitcoinTx.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert SpliceKeyNotTwoOfTwo();
    }

    /// @notice ANTI-ROLLBACK: the channel's hop records the highest persisted
    ///         channel-monitor `update_id` for `channelId`, monotonically. On reboot the
    ///         hop's enclave reads `freshnessSeq[channelId]` and refuses a locally-loaded
    ///         monitor whose `update_id` is behind — catching a host that serves stale
    ///         sealed channel state (MuSig2 nonce-reuse / revoked-state broadcast). Gated
    ///         to the channel's hop (a foreign caller can't bump the counter to lock the
    ///         enclave out) and STRICTLY monotonic (a replay/rollback of an old value reverts).
    /// 🔴 §HOP-RCE-2 — MONOTONIC IS NOT ENOUGH; THE RATCHET ALSO NEEDS A CEILING. Strictly
    ///    increasing stops a ROLLBACK, which is what this counter was built for, and does nothing
    ///    about a JUMP. A hop that writes `type(uint64).max` once makes the enclave refuse every
    ///    monitor it will ever hold — the counter's whole purpose is that a lower `update_id` is
    ///    treated as stale — and the channel is unloadable from that block onward.
    /// ⛔ **AND IT IS NOT SELF-INFLICTED, WHICH IS WHY IT IS WORTH A CONSTANT.** Migration carries
    ///    the seed, not a way to lower this, so a compromise lasting a single transaction bricks
    ///    the channel for every SUCCESSOR enclave too. There is no reset by design (a reset is a
    ///    rollback, which is the attack this defends against), so the bound has to be on the STEP.
    /// ⇒ `MAX_FRESHNESS_JUMP` is far above any real gap between commits — an LDK `update_id`
    ///   advances once per monitor update — while leaving the counter ~1.8e13 calls short of
    ///   saturation, so the brick is unreachable and honest operation never notices.
    uint64 private constant MAX_FRESHNESS_JUMP = 1_000_000;

    function commitFreshness(bytes32 channelId, uint64 seq) external {
        _onlyHop();
        // (E122) Primary, or the LP's fallback after the staleness window — see `splice`.

        if (seq <= freshnessSeq[channelId]) revert FreshnessNotMonotonic();
        if (seq - freshnessSeq[channelId] > MAX_FRESHNESS_JUMP) revert FreshnessJumpTooLarge();
        freshnessSeq[channelId] = seq;
        emit FreshnessCommitted(channelId, seq);
    }

    /// @notice Commit the hop's monotonic channel-MANAGER blob freshness seq. The
    ///         channel manager has no per-channel id and no in-blob update_id, so its
    ///         anti-rollback counter is keyed on the hop (`msg.sender`): only the hop
    ///         advances its OWN slot. On reboot the hop's enclave reads
    ///         `managerFreshnessSeq[hop]` and refuses a manager blob whose embedded seq
    ///         is behind. Strictly monotonic ⇒ a rolled-back/replayed seq reverts.
    function commitManagerFreshness(uint64 seq) external {
        if (seq <= managerFreshnessSeq[msg.sender]) revert ManagerFreshnessNotMonotonic();
        // §HOP-RCE-2 — same ceiling, same reason. Self-scoped by `msg.sender` (correctly: only a
        // hop advances its OWN slot), so the brick this bounds is one a compromised hop lands on
        // ITSELF and on every enclave that succeeds it.
        if (seq - managerFreshnessSeq[msg.sender] > MAX_FRESHNESS_JUMP) revert FreshnessJumpTooLarge();
        managerFreshnessSeq[msg.sender] = seq;
        emit ManagerFreshnessCommitted(msg.sender, seq);
    }


    /// @notice Consume an operator-signed MigrationAuth `nonce` — a
    ///         rollback-proof, ONE-SHOT anti-replay guard for the enclave seed-migration
    ///         bundle. The migrating (OLD) enclave calls this BEFORE exporting its sealed
    ///         seed; a REVERT (nonce already used) tells the daemon the bundle is a replay
    ///         and it must NOT export. Atomic compare-and-set (revert-if-used) so two racing
    ///         migrations can't both proceed. Gated to an active hop (the migrating enclave
    ///         holds live channels) so a non-hop can't bloat storage; the nonce itself is
    ///         secret (in the signed bundle) until first use, so it can't be pre-consumed.
    function markMigrationNonceUsed(bytes32 nonce) external {
        _onlyHop();
        if (migrationNonceUsed[nonce]) revert MigrationNonceAlreadyUsed();
        migrationNonceUsed[nonce] = true;
        emit MigrationNonceConsumed(nonce, msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════
    //  CLOSE — cooperative close, both parties signed on Bitcoin.
    //  Permissionless once Bitcoin confirms; the EVM accounting only
    //  reflects what's already final on Bitcoin. locktime == 0 discriminates
    //  a cooperative close from a unilateral commitment broadcast.
    // ═════════════════════════════════════════════════════════════════
    /// @notice Record a channel close that has CONFIRMED on Bitcoin, retiring its
    ///         EVM position. ONE SPV-gated recorder for BOTH close types — the close
    ///         tx's locktime selects the branch (no separate "force-close" instruction;
    ///         the non-coop handling is internal). Permissionless: the EVM can't watch
    ///         Bitcoin, so anyone may submit the SPV proof of a confirmed close.
    ///
    ///         • COOPERATIVE (locktime == 0): co-signed by LP + hop. Read the LP's
    ///           payout output → the BtcVault (via requestRedeem) reconciles delivered =
    ///           funded − final and mints the LP's swap-out USD proceeds as QUI (the regrouped
    ///           BTC-LP close mints, previously V4's — Basket auth note). The LP's payout output script is
    ///           NOT LP-choosable: `commit_upfront_shutdown_pubkey` pins it at open and
    ///           LDK rejects any cooperative close paying the LP anywhere but that
    ///           committed script (= btcRecipientOf), so `_lpFinalBalance` reads the TRUE
    ///           payout — a malicious LP cannot route its payout away to under-report
    ///           final and inflate delivered (the redirection attack closed on the swap-out
    ///           and withdrawal-splice paths has no foothold here either). On recency:
    ///           locktime==0 proves co-signed but not current-vs-stale, so finalBalance
    ///           recency rests on the hop co-signing the CURRENT state (same hop-trust as
    ///           settleSwapIn) — and the hop is TRUSTED infrastructure, not the adversarial
    ///           party (the threat model is a malicious LP).
    ///
    ///           PROCEEDS ARE PINNED PER-OBLIGATION, NOT POOLED (corrected 2026-08-01 — this
    ///           block used to describe netDeliveredBtc/swapUsdBtc as a SHARED cross-channel
    ///           pool an exit claims a delivered-SHARE of, and to cite
    ///           `deliveredSlice <= netDeliveredBtc` as the over-mint backstop. That machinery
    ///           and its clamp are GONE — see `_lpFinalBalance`'s note at the top of this file
    ///           and Core.sol's `_handleSwap`. The swapper's actual USD is recorded per
    ///           obligation (Core.pendingSwapOutUsd) at request and paid to the delivering LP
    ///           at deliverSwapOutOnchain, so there is NO shared pool to race over and no
    ///           cross-channel share to inflate.)
    ///
    ///           What still holds is the per-entrypoint honesty of `delivered`: swap-out
    ///           delivery pins it to the swapper obligation (_settleSwapOutSlice), a
    ///           withdrawal splice bans foreign outputs (_withdrawalPayout), and a cooperative
    ///           close pins the payout script via LDK upfront-shutdown (above). The residual
    ///           mis-attribution is hop misbehaviour (recency), which is trusted.
    ///
    ///         • NON-COOPERATIVE (locktime != 0): an LDK commitment/force-close
    ///           broadcast on Bitcoin. SOLVENCY RECONCILIATION, not a payout — the BTC
    ///           has left the 2-of-2, so the position MUST be retired or the EVM keeps
    ///           counting gone-BTC as backing (QUI mintable against BTC that's gone →
    ///           under-collateralized). A commitment tx can't attribute the delivered
    ///           split (CSV / per-commitment-key outputs), so finalBalance = funded ⇒
    ///           delivered = 0 ⇒ NO proceeds minted. The LP recovered its BTC on
    ///           Bitcoin; the forfeited proceeds are exactly why an LP always prefers
    ///           cooperative close — and with the trusted-operator hop ~always online,
    ///           this branch is a backstop that should ~never fire.
    /// @dev (E153) The key-binding + splice discriminator, in its OWN FRAME — an extra
    ///      calldata param pushes `recordClose` over the legacy stack, and the house fix is a
    ///      separate frame, never `via_ir`.
    ///      ① The supplied keys must match `keysHash`, pinned at open, so they cannot be
    ///         forged. **NOT a re-derivation of `channelId`: that folds in the ORIGINAL
    ///         funding outpoint, which `_verifySplice` rotates — an earlier attempt bound the
    ///         keys that way and failed for every SPLICED channel (E153).**
    ///      ② If the tx pays a continuing 2-of-2 of those keys, it is a SPLICE, not a close.
    /// @dev Does `rawTx` END this channel, or CONTINUE it? A splice recreates the 2-of-2 and the
    ///      channel lives on; a close/dead-man exit leaves no such output. Both retirement paths
    ///      (`recordClose`, `recordDeadManExit`) need this, and neither can tell without the two
    ///      pubkeys — which is why they take `p` and why `keysHash` is pinned at open.
    ///      ⚠️ THE KEYS CHECK IS NOT CEREMONY: without it a caller could pass ANY key pair, and the
    ///      derived 2-of-2 script would match nothing in the tx, so the splice test would pass
    ///      vacuously and a continuation would retire the position. The check is what makes the
    ///      absence of that output MEAN something.
    function _requireNotSplice(
        bytes32 channelId, Types.OpenParams calldata p, bytes calldata rawTx
    ) private view {
        _requireChannelKeys(channelId, p);
        if (BitcoinTx.sumOutputValuesToScript(rawTx,
                abi.encodePacked(hex"5120",
                    BitcoinTx.computeOutputKey(p.lpPubkey, p.hopPubkey))) > 0)
            revert SpliceIsNotAClose();
    }

    /// @dev (E162) The supplied pair IS this channel's pair. Shared by the retirement paths and
    ///      by `splice`, because `keysHash` is an INVARIANT and every path taking `p` must
    ///      preserve it — not only the paths that read it.
    ///      🔴 WHY SPLICE NEEDS THIS, AND WHY ITS ABSENCE WAS A LIVE DEFECT (my §E153 regression):
    ///      `_verifySplice` proves KeyAgg over the CALLER-SUPPLIED pair, so a splice carrying a
    ///      DIFFERENT pair passed, rotated the funding outpoint, and left `keysHash` at the
    ///      original pair. `recordClose` and `recordDeadManExit` then both reverted
    ///      `ChannelKeysMismatch` — **the channel was unretirable FOREVER**: BTC alive in a live
    ///      2-of-2, the EVM position stuck open, backing over-counted indefinitely. That is the
    ///      hazard §E155 removed the LP-only gate to prevent, arriving through a different door.
    ///      ⛔ THIS BLOCK USED TO END: *"THIS DELIBERATELY FORBIDS KEY ROTATION … Until that gating
    ///      is settled, rejecting the change is the safe half."* **THAT GATING IS NOW SETTLED AND
    ///      THE SENTENCE IS FALSE** (§SPLICE-ROTATES-BOTH-FUNDING-KEYS, 2026-08-31). `splice` no
    ///      longer calls this; it RE-PINS `keysHash` after `_verifySplice` has proven the new pair
    ///      is inside the new `Q`, which is the ROOT fix for the §E153 hazard described above —
    ///      forbidding rotation was a clamp on the symptom, and it was UNSATISFIABLE against our
    ///      own LN stack, which rotates BOTH funding pubkeys on every splice.
    ///      🔑 WHAT GATES A ROTATION NOW: `_verifySplice` SPV-proves the transaction SPENDS the
    ///      channel's funding outpoint, and that outpoint is a key-path taproot 2-of-2 whose spend
    ///      REQUIRES THE LP'S MuSig2 PARTIAL — which, under BIP-341 `Prevouts::All`, commits to the
    ///      outputs and therefore to the exact new pair. An unforgeable signature over the
    ///      destination, in place of an equality check over public keys.
    ///      ⚠️ **AND THE HONEST RESIDUAL, BECAUSE THIS IS A RELOCATION AND NOT A PURE GAIN:** the
    ///      old check held even if the LP BLIND-SIGNED; the new one requires the LP's signer to
    ///      VALIDATE what it signs. That validation is §T9 (PHASE 2, not landed). A blind-signing
    ///      LP loses funds through far more direct routes than key rotation, so §T9 is required
    ///      regardless — but do not describe the fold as free.
    ///      ⛔ **AND DO NOT READ *"the LP must sign"* AS *"the LP must be ONLINE"* — I wrote it that
    ///      way once and it is wrong** (owner, 2026-08-31: *"there was something about an allowlist
    ///      or allowed shape that gets set on evm so that everything can work even when the lp is
    ///      offline?"*). **There is, and it is `ExitArming`.** `signedExitTx` is a FULLY-SIGNED CLTV
    ///      exit paying `btcRecipientOf`, pre-signed by the LP and ARMED ON THE EVM with its
    ///      `cltvDeadline` and `checkpointSats` — **anyone may broadcast it once mature, with no LP
    ///      participation at all** (§E188: *"funds = no key (ladder)"*). ⇒ Value leaves the 2-of-2
    ///      by exactly two routes: a LIVE MuSig2 partial (splice / cooperative close), or a
    ///      PRE-COMMITTED rung whose SHAPE the EVM pinned in advance — destination, amount and
    ///      earliest height. **The signature is never optional; its LIVENESS is.** The fold touches
    ///      only the first route, which is why an offline LP is unaffected by it.
    ///      📌 THIS FUNCTION IS STILL LIVE for the RETIREMENT paths, `emitDeadManExit` and
    ///      `deliverSwapOutOnchain`, where it now reads the CURRENT pin — correct for a spliced
    ///      channel, which it was not before.
    function _requireChannelKeys(bytes32 channelId, Types.OpenParams calldata p) private view {
        if (keccak256(abi.encode(p.lpPubkey, p.hopPubkey)) != channels[channelId].keysHash)
            revert ChannelKeysMismatch();
    }

    error ExitUnderpaysCheckpoint();   // the armed exit pays less than it attests
    error CheckpointRegression();      // a bare refresh may not lower the attested balance


    /// @param p this channel's `OpenParams` — only `lpPubkey`/`hopPubkey` are read, and both
    ///        are checked against the `keysHash` pinned at open.
    function recordClose(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawCloseTx,
        bytes32 closeBlockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) external nonReentrant {
        _whenOpen(channelId);
        // (E153) THE SPLICE-VS-CLOSE DISCRIMINATOR, REPLACING THE PARTICIPANT GATE.
        // This used to read: "recordClose has no on-chain splice-vs-close discriminator (it
        // can't reconstruct the rotated 2-of-2 keys of the splice's CONTINUING output)" — and
        // therefore restricted recording to the hop or the LP, because a third party could
        // otherwise replay the hop's confirmed SPLICE tx here to force-retire an OPEN channel
        // (delivered=0, splice()/deliver() bricked on whenOpen, an in-flight swap-out stranded).
        // `BitcoinTx` reconstructs exactly those keys (E129/E142), so the ambiguity is gone:
        // a SPLICE leaves a continuing 2-of-2 output; a CLOSE does not.
        // ⇒ Attacking the cause means the gate no longer trusts WHO calls, so recording is
        //   PERMISSIONLESS — a channel can be retired once Bitcoin confirms the close, with no
        //   dependence on hop OR LP liveness. Same shape as every other liveness fix here:
        //   remove the named party, keep the cryptographic bound.
        _requireNotSplice(channelId, p, rawCloseTx);
        _verifyTxSpendsChannel(channelId, rawCloseTx,
            closeBlockHash, merkleProof, txIndex);
        // Cooperative → the LP's co-signed BTC payout; non-cooperative → funded
        // (lpPayout=funded ⇒ delivered=0: a non-coop close realizes no swap proceeds).
        bool coop = BitcoinTx.extractLocktime(rawCloseTx) == 0;
        // A non-coop close MUST be a genuine BOLT#3 commitment tx. Discriminating on
        // locktime ALONE let a participant feed an in-flight splice / swap-out-delivery
        // tx (also nonzero-locktime, also spends the funding UTXO) as a "force close" —
        // bricking the channel mid-splice (orphaning the new 2-of-2), corrupting the
        // swap-out settlement, and setting up a reversal double-pay. isCommitmentTx is
        // the symmetric discriminator the permissionless path already uses: a splice /
        // coop / delivery tx all fail it.
        if (!coop && !BitcoinTx.isCommitmentTx(rawCloseTx)) revert NotForceClose();
        uint lpPayoutSats = coop
            ? _lpFinalBalance(channels[channelId].lpEth, rawCloseTx)
            : channels[channelId].amountSats;
        // STALE-CLOSE GUARD, cooperative branch only. A force close is a solvency
        // reconciliation against a tx the fleet did not co-sign, so it has nothing to be
        // stale ABOUT. This earns its place under the guard rule: absent it, a fleet that
        // co-signs an out-of-date balance produces a close that is plausible on its face
        // and silently short-pays the LP, with no on-chain trace that anything was wrong.
        // ⚠️ HOP-SUBMITTED CLOSES ONLY. `emitDeadManExit` is callable by ANY attested hop in
        // fleet mode, so a guard that bound the LP too would hand a compromised hop a way to
        // block every cooperative close by attesting an absurd checkpoint -- forcing LPs into
        // punitive force-closes. (First version did exactly that; it was reverted for it.)
        // Gating on the submitter removes it: the LP is the party the guard protects, and it
        // can always waive by submitting the close itself. That is not coercion -- the LP's
        // alternative is a force close, which needs no counterparty cooperation at all.
        uint ckpt = checkpointOf[channelId];
        if (msg.sender != channels[channelId].lpEth
            && coop && ckpt != 0 && lpPayoutSats + paidOutSinceCheckpoint[channelId] < ckpt)
            revert StaleClose();
        uint total = _finalizeClose(channelId, lpPayoutSats);
        emit ChannelClosed(channelId, total);
    }

    error NotForceClose();
    error StaleClose();   // coop close pays less than the last attested checkpoint, net of payouts

    /// @notice (#114) Retire a channel ended by the pre-signed DEAD-MAN EXIT. Without this the
    ///         exit is UNRECORDABLE and the position never retires: `recordClose` routes a
    ///         nonzero-locktime tx to the force branch, and BOTH that branch (`:1014`) and
    ///         `recordForceClosePermissionless` (`:1054`) demand `isCommitmentTx` — BOLT#3
    ///         encoding, nLockTime top byte 0x20 + nSequence top byte 0x80. The exit tx is
    ///         built (`quid-ln/quid-ln/src/deadman_exit.rs`) with nLockTime = the ABSOLUTE CLTV
    ///         deadline (a block height, top byte 0x00) and nSequence = ENABLE_LOCKTIME_NO_RBF
    ///         (top byte 0xFF), so it fails BOTH bytes and can never pass. The LP would recover
    ///         its BTC on Bitcoin while the EVM kept counting gone-BTC as backing — QUI mintable
    ///         against BTC that has left the 2-of-2, the exact hazard the force-close path exists
    ///         to prevent, arriving through the ONE path that is meant to protect the LP.
    ///
    ///         DISCRIMINATOR: the tx's locktime must EQUAL the `deadManDeadline` this contract
    ///         itself recorded. A coop close is locktime 0; a BOLT#3 commitment carries the
    ///         obscured 0x20-prefixed locktime; neither can equal a real deadline. MATURITY needs
    ///         no check — Bitcoin consensus will not confirm a CLTV tx before its locktime, so an
    ///         SPV-proven confirmation IS the proof it matured.
    ///
    ///         AUTHORITY: PERMISSIONLESS (E155). It was LP-only, on the stated grounds that this is
    ///         "the same reasoning `recordClose` gives for participant-gating" — and **E153 deleted
    ///         that reasoning**: the gate there was a PROXY for a missing splice-vs-close
    ///         discriminator, and once the discriminator exists the identity of the submitter adds
    ///         nothing. The payout is pinned to `btcRecipientOf` inside the signed bytes, so no
    ///         submitter can redirect a satoshi.
    ///         🔑 AND THE GATE WAS WORSE THAN REDUNDANT — IT CREATED THE HAZARD THIS FUNCTION EXISTS
    ///         TO PREVENT. Once the exit confirms, the BTC has LEFT the 2-of-2. If the EVM does not
    ///         follow, it keeps counting gone-BTC as backing (`:1368`). Gating on the LP meant an LP
    ///         who lost its key, or simply never came back, left the position permanently
    ///         un-retirable — QU!D mintable against BTC that is provably gone, reachable by
    ///         ABSENCE rather than by attack. A reconciliation that MUST happen cannot be gated on
    ///         one party choosing to show up.
    ///         ⚠️ THE SPLICE REJECTION IS NOW REAL. The comment here USED to claim this "deliberately
    ///         does NOT accept a splice tx that happened to share the deadline's locktime" — nothing
    ///         enforced it. `_verifyTxSpendsChannel` deliberately ACCOMMODATES splices (it scans all
    ///         inputs precisely because a splice carries extra ones), and locktime equality was the
    ///         only test. A hop chooses BOTH the `cltvDeadline` it records here AND its splice's
    ///         nLockTime, so it could make them equal and retire a live channel — wiping the LP's
    ///         position while its sats stayed in a 2-of-2 the hop co-controls. `_requireNotSplice`
    ///         now enforces what the comment promised.
    function recordDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawExitTx,
        bytes32 exitBlockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) external nonReentrant {
        _whenOpen(channelId);
        address lpEth = channels[channelId].lpEth;
        // (E156/E165) NO `deadline == 0` CHECK: `exitArmedAt` is false for an unarmed deadline,
        // and zero is rejected at arming — so a zero locktime simply fails the membership test
        // below. The state a separate check defended against is unrepresentable.
        uint64 deadline = BitcoinTx.extractLocktime(rawExitTx);
        // (E165) ANY armed deadline retires the channel — the LP pre-signed a ladder at open, so
        // there is no single "current" one. An unarmed locktime is not a dead-man exit at all.
        // (E165) Membership is checked against the channel's CURRENT funding scope, so a rung armed
        // against a PRE-SPLICE outpoint fails HERE — with `NotDeadManExit`, naming the real reason
        // — instead of passing this test and dying four frames later inside `_verifyTxSpendsChannel`
        // on a mismatched prevout, which reads as a malformed proof rather than a retired rung.
        if (!exitArmedOnOutpoint[_currentOutpointKey(channelId)][deadline]) revert NotDeadManExit();
        _requireNotSplice(channelId, p, rawExitTx);
        _verifyTxSpendsChannel(channelId, rawExitTx, exitBlockHash, merkleProof, txIndex);
        // (E165) NO second locktime comparison: `deadline` IS `extractLocktime(rawExitTx)`, so the
        // old check compared a value to itself. It read as a guard and asserted nothing.
        // Same attribution as a cooperative close: sum every output paying the LP's committed
        // P2TR. The exit pays `btcRecipientOf` by construction, pinned inside the signed bytes.
        uint total = _finalizeClose(channelId, _lpFinalBalance(lpEth, rawExitTx));
        emit ChannelClosed(channelId, total);
    }

    error NotDeadManExit();  // the tx's locktime is not an ARMED deadline for this channel

    /// @notice PERMISSIONLESS reconciliation of a FORCE-CLOSE. Anyone (a keeper, a
    ///         QUI holder, a watchtower) may retire a channel whose funding UTXO is
    ///         provably spent by a BOLT #3 COMMITMENT transaction — removing the
    ///         dead-hop/adversary-LP veto over the decrement.
    ///
    ///  WHY THIS IS SAFE TO BE PERMISSIONLESS (unlike `recordClose`): `recordClose`
    ///  is participant-gated because a SPLICE / swap-out-delivery / coop-close tx
    ///  spends the SAME funding UTXO and the contract can't reconstruct the rotated
    ///  splice keys, so an open tx could be replayed to force-retire a LIVE channel.
    ///  Here we additionally require the spending tx to be a genuine commitment tx
    ///  (`isCommitmentTx`: nLockTime top byte 0x20 + input nSequence top byte 0x80,
    ///  BOLT #3). A splice (locktime = block height), a coop close (locktime 0), and
    ///  a swap-out delivery all FAIL that check, so none can be used here. A force-
    ///  close commitment tx is unambiguous and public on-chain once broadcast.
    ///
    ///  WHY IT MATTERS: a force-close is exactly when the hop is dead/offline (else
    ///  it would coop-close), and the LP — having recovered its BTC on-chain — is
    ///  adversarially incentivized to LEAVE its position open (it keeps counting as
    ///  QUI backing and earning V4 fees; the force branch settles delivered=0 so the
    ///  LP has no reason to call `recordClose`). Permissionless retire lets the
    ///  harmed party (QUI holders) or any keeper restore honest backing. delivered=0
    ///  (lpPayout=funded) is non-gameable — it only retires the position to its
    ///  on-chain reality, minting nothing.
    function recordForceClosePermissionless(
        bytes32 channelId,
        bytes calldata rawCloseTx,
        bytes32 closeBlockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) external nonReentrant {
        _whenOpen(channelId);
        if (!BitcoinTx.isCommitmentTx(rawCloseTx)) revert NotForceClose();
        _verifyTxSpendsChannel(channelId, rawCloseTx, closeBlockHash, merkleProof, txIndex);
        // (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) MEASURE WHAT THE COMMITMENT ACTUALLY PAID THE LP,
        // BEFORE retiring — the retirement below deletes nothing this reads, but measuring first
        // keeps the emitted numbers describing the channel as it stood at the close.
        _emitForceCloseLpOutput(channelId, rawCloseTx);
        // delivered=0: lpPayout := the full funded amount (a force close realizes no
        // swap proceeds), retiring the position to on-chain reality. Mints nothing.
        // ⛔ DO NOT REPLACE `amountSats` WITH THE MEASURED PAYOUT ABOVE. It is the obvious change
        // and it is a HOLE-TRADE. `_finalizeClose` → `requestRedeem` → `Vault._resize(full)`, whose
        // contract is *"`shrinkSats − lpPayout` is the DOLLAR (delivered) slice"* — so a smaller
        // payout MINTS the LP the difference in dollars, against sats an attacker now holds. That
        // does not recover the loss; it MOVES it from the LP onto QUI holders, on the word of a
        // transaction the attacker chose. The measurement is EVIDENCE, not a valuation.
        uint total = _finalizeClose(channelId, channels[channelId].amountSats);
        emit ChannelClosed(channelId, total);
    }


    /// @notice What a force-close commitment paid the LP, beside what the fleet's own attestation
    ///         said it owed. **ALWAYS emitted on a force close**, breach or not.
    /// @param lpPaidSats sats paid to the LP's `to_remote` output (0 if that output is absent)
    /// @param checkpointSats the LP balance the fleet last attested (`checkpointOf`; 0 = never)
    /// @param paidOutSats legitimate outflows since that attestation (`paidOutSinceCheckpoint`)
    event ForceCloseLpOutput(
        bytes32 indexed channelId, address indexed lpEth,
        uint lpPaidSats, uint checkpointSats, uint paidOutSats
    );

    /// @dev (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) The whole fix, and it is a MEASUREMENT, not a gate.
    ///
    /// 🔴 WHAT WAS WRONG: `recordForceClosePermissionless` verified the tx was a commitment that
    /// spends this channel, then retired the position as though the LP had recovered the ENTIRE
    /// channel — whatever the commitment actually paid. `recordClose` has the corresponding check
    /// (`lpPayoutSats + paidOutSinceCheckpoint < ckpt ⇒ StaleClose`) but scopes it `&& coop`, so
    /// **the only path a breach can take was the one path with no check at all.** Nothing anywhere
    /// emitted that the commitment and the contract's own attestation disagreed.
    ///
    /// ⚠️ WHY IT EMITS RATHER THAN REVERTS, AND WHY THAT IS THE MAXIMAL SAFE ACTION:
    /// - **Reverting is worse than doing nothing.** The channel would stay `STATUS_OPEN` with its
    ///   BTC already gone, so `totalSatsLocked` keeps counting backing that does not exist — which
    ///   is the exact condition the permissionless retire exists to end.
    /// - **Re-valuing moves the loss onto QUI holders** (see the caller's note).
    /// - The BTC cannot be clawed back by anything this contract does. What the fix buys is that a
    ///   breach becomes PROVABLE and ATTRIBUTABLE on-chain from the fleet's OWN signed attestation,
    ///   which is the precondition for every response that lives outside this contract.
    ///
    /// ⚠️ THE CONTRACT DELIBERATELY DOES NOT ITSELF DECLARE A BREACH, because a ZERO reading is
    /// AMBIGUOUS: `to_remote` pays the NON-broadcaster, so an absent LP output means either the
    /// LP's balance was zero in the replayed state, or **the LP broadcast its own commitment** and
    /// its funds are in the CSV-delayed `to_local` — which is the honest case. `to_local` needs the
    /// per-commitment point and is not derivable here. ⇒ Emit the three numbers and let the
    /// observer judge; a shortfall is `checkpointSats − (lpPaidSats + paidOutSats)` when positive.
    /// ⛔ Do not "improve" this into a revert on `lpPaidSats == 0`: that would punish an LP for
    /// force-closing its own channel, which is the escape the whole design is built around.
    ///
    /// 📌 REACHABILITY, RECORDED SO THIS IS NOT MIS-SOLD: no replayable older state exists TODAY —
    /// the LP runs no LN node, so its channel carries no HTLCs and the commitment balance never
    /// moves within a funding scope, while an older SCOPE's commitment cannot confirm (its outpoint
    /// is spent). **This makes the invariant EXACT rather than heuristic** — an honest force close
    /// has no reason to pay the LP less than it is owed — and it converts a property that is
    /// currently EMERGENT ("we happen not to route over LP channels") into an ENFORCED one.
    function _emitForceCloseLpOutput(bytes32 channelId, bytes calldata rawCloseTx) private {
        Types.BTCChannel storage ch = channels[channelId];
        uint paid;
        // Zero only for a channel opened before this key was pinned; scanning for `0x5120||0` would
        // match nothing anyway, but skipping says so deliberately rather than by accident.
        if (ch.lpToRemoteKey != bytes32(0))
            paid = BitcoinTx.sumOutputValuesToScript(
                rawCloseTx, abi.encodePacked(hex"5120", ch.lpToRemoteKey));
        emit ForceCloseLpOutput(
            channelId, ch.lpEth, paid, checkpointOf[channelId], paidOutSinceCheckpoint[channelId]);
    }

    // ═════════════════════════════════════════════════════════════════
    //  SWAP-IN (BTC→USD) — the hop confirms native-BTC receipt over Lightning
    //  and settles the seller in dollars. Bounded by the pool's USD leg
    //  (creditSwapIn's inflow-capacity gate), which caps the hop's exposure to
    //  net-BTC-bought. The seller's BTC refills a drained LP's channel; that
    //  LP's position reconciles at its own close. `usdAmount` is valued at the
    //  WBTC TWAP. The seller picks their payout: QUID, or a specific stable on
    //  the strict (fee-bearing) redemption path.
    //
    //  Hop-attested (not preimage-proven): for a swap-IN the protocol is the
    //  Lightning RECEIVER, so it generates the preimage itself — a preimage
    //  proves nothing to the EVM here (unlike swap-OUT, where the swapper
    //  generates it). The capacity gate is the bound on a dishonest hop.
    // ═════════════════════════════════════════════════════════════════
    error SwapInDepositReplay();   // this deposit outpoint has already been credited

    /// @notice (E159) Credit an on-chain swap-in against a PROVEN Bitcoin deposit.
    ///
    /// 🔴 WHAT IT REPLACES: `settleSwapIn` credits the SHARED pool on the hop's WORD — no proof any
    ///    BTC arrived. A compromised hop can attest swap-ins for sats that never existed and drain
    ///    `POOLED_USD` to its liquidity limit. That reaches QU!D holders and other LPs who
    ///    never opted into enclave trust, which is why it is worse IN KIND than a hop stealing its
    ///    own channels' BTC. Here the credit cannot exceed what a Bitcoin block says arrived.
    ///
    /// 🔑 THE ADDRESS IS DERIVED, NOT NAMED. `BTC_DEPOSIT_KEY` is pinned at construction and the
    ///    swap's own CLTV refund leaf supplies per-swap uniqueness, so a hop cannot SPV-prove a
    ///    genuine payment to a script IT controls and collect USD for BTC that never entered
    ///    protocol custody — the proof would be real and worthless.
    ///
    /// ⚠️ DEDUP IS ON THE DEPOSIT OUTPOINT, NOT A HOP-CHOSEN HASH. The old rail keyed replay
    ///    protection on `paymentHash`, a value the hop invents; a txid is a fact.
    ///
    /// ✅ (§T2) THE TERMS ARE COMMITTED, NOT TRUSTED: the deposit
    ///    address's leaf carries `PUSH32 sha256(abi.encode(seller, token, pricePerBtc, slippageBps))
    ///    OP_DROP`, so a hop that settles under different terms derives an address the deposit never
    ///    paid and `verifySwapInDeposit` reverts. **And `minDeliveredUsd` is gone entirely** — the
    ///    floor is DERIVED here from the committed rate and the proven sats (`settleFloorUsd`),
    ///    because it scales with the deposit and so could never have been committed in an address
    ///    that must exist before the deposit. ⇒ What is proven is now BOTH: that the sats exist and
    ///    landed at an address only this protocol controls, AND that they landed under these terms.
    function settleSwapInProven(
        Types.Terms calldata terms,
        Types.DepositProof calldata proof,
        bytes calldata rawDepositTx
    ) external nonReentrant {
        _onlyHop();
        (bytes32 txid, uint sats) = _provenDeposit(terms, proof, rawDepositTx);

        // Partials are accepted on this rail: the seller's remainder is refundable trustlessly via
        // the deposit's own CLTV leaf, which is exactly why the on-chain rail can take them and the
        // all-or-nothing LN rail cannot.
        // (§T2) The floor is DERIVED from the committed rate and the proven sats — never supplied.
        uint consumed = btc.creditSwapIn(
            terms.seller, sats, terms.token, BitcoinTx.settleFloorUsd(terms, sats));
        emit SwapInSettled(terms.seller, txid, sats, consumed, terms.token);
    }

    /// @dev Own frame: dedup, SPV inclusion, and the derived-address check. Returns the deposit
    ///      txid (the replay key) and the sats it actually paid this protocol.
    /// @dev The half BOTH provers share: one transaction, proven once. Extracted when
    ///      the (now deleted) reserve prover reproduced these six lines verbatim — that put
    ///      `BTCChannels` 386 bytes OVER EIP-170, so sharing it is what makes the funder fit.
    /// 🔑 THE DEDUP IS THE LOAD-BEARING PART, and it is why the two provers must share ONE map.
    ///      `swapInUsed` is keyed by txid across BOTH, so the same transaction cannot be claimed
    ///      once as a swap-in deposit and again as a reserve top-up. Dedup on the OUTPOINT, not a
    ///      hop-chosen hash: the old rail keyed replay protection on `paymentHash`, a value the hop
    ///      invents; a txid is a fact. Marking BEFORE the SPV check is safe — a failed check reverts
    ///      and unwinds the write, so no txid is ever consumed for free.
    function _provenTxid(
        bytes32 blockHash, uint txIndex, bytes32[] calldata merkleProof, bytes calldata rawTx
    ) private returns (bytes32 txid) {
        txid = BitcoinTx.txid(rawTx);
        if (swapInUsed[txid]) revert SwapInDepositReplay();
        swapInUsed[txid] = true;
        if (!spv.checkTxInclusion(merkleProof, blockHash, txid, txIndex,
                                  ChannelLib.MIN_CONFIRMATIONS)) revert BadSPV();
    }

    function _provenDeposit(
        Types.Terms calldata terms, Types.DepositProof calldata proof, bytes calldata rawDepositTx
    )
        private returns (bytes32 txid, uint sats)
    {
        txid = _provenTxid(proof.blockHash, proof.txIndex, proof.merkleProof, rawDepositTx);
        sats = BitcoinTx.verifySwapInDeposit(
            BTC_DEPOSIT_KEY, terms, proof.userRefund, proof.cltvHeight, rawDepositTx);
    }

    /// @notice (T1) REVERSE a failed on-chain swap-out — refund the swapper's own USD.
    ///
    /// 🔑 EXTRACTED FROM `settleSwapIn` SO THAT ENTRYPOINT CAN BE DELETED. `settleSwapIn` had
    ///    TWO jobs: crediting a swap-in on the hop's WORD (`#1`, the phantom — now provable via
    ///    `settleSwapInSpliced`), and this reversal. **They are not the same kind of thing.** A
    ///    swap-in credit asserts BTC arrived and must be PROVEN; a reversal returns dollars the
    ///    swapper ALREADY PAID IN, so nothing arrives and there is nothing to prove. Deleting
    ///    the unproven credit must not take the reversal with it.
    ///
    /// ⚠️ THE PAYEE AND AMOUNT ARE PINNED TO RECORDED STATE, never hop-supplied: `so.swapper`
    ///    and `so.sats` come from `pendingOnchainSwapOut[swapId]`, so a malicious hop can
    ///    neither redirect the refund nor short it. That property is why this needs no proof.
    ///
    /// ⚠️ ORDER IS LOAD-BEARING: the obligation is cleared and `pendingSwapOutUsd` reduced
    ///    BEFORE the credit, so the solvency gate sees the freed reserve and a reversal is never
    ///    blocked by its own obligation. CEI — state deleted before the external call.
    /// (§T1-d / M1#3) NO `token` PARAMETER: payee, amount AND asset now all come from the record
    /// the swapper's own request wrote. A reversal is the one credit path where the contract can
    /// know all three without trusting anyone, so it does.
    function reverseSwapOut(bytes32 swapId, uint minDeliveredUsd, bool requireFull)
        external nonReentrant returns (uint consumed)
    {
        _onlyHop();
        if (swapId == bytes32(0) || swapInUsed[swapId]) revert SwapInReplay();
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        if (so.sats == 0) revert NotAReversal();
        swapInUsed[swapId] = true;
        delete pendingOnchainSwapOut[swapId];
        btc.subPendingSwapOut(so.usd);
        consumed = btc.creditSwapIn(so.swapper, so.sats, so.token, minDeliveredUsd);
        // All-or-nothing: a partial refund strands the remainder, because the swapper has no
        // deposit or HTLC to reclaim it from on this path.
        if (requireFull && consumed < so.sats) revert SwapInPartialRejected();
        emit SwapInSettled(so.swapper, swapId, so.sats, consumed, so.token);
    }

    error NotAReversal();   // no pending swap-out for this id — nothing to refund

    // ⛔ (M1#1) `settleSwapIn` IS DELETED — the phantom swap-in is gone from the contract.
    //
    // It credited the shared POOLED_USD on the hop's WORD, so a malicious hop asserted sats
    // that never arrived and the loss reached QU!D holders who opted into no enclave trust. It
    // survived this long only because the LN rail had no provable form.
    //
    // REPLACED, not merely removed: `settleSwapInProven` is the only credit path now. Its OTHER
    // role already lives under its own name — `reverseSwapOut` (T1-b/T1-d).

    /// @notice A swapper recovers their committed USD if the hop never delivers
    ///         the on-chain swap-out (or never reverses it). Permissionless of the HOP —
    ///         only the recorded swapper can call, and the refund is pinned to that
    ///         swapper, so no hop cooperation is needed and no one can misdirect it.
    ///         Callable once the request has aged past `SWAPOUT_REFUND_BLOCKS` (well
    ///         beyond the ~1-2h honest SPV-proven delivery window). The `swapInUsed`
    ///         mark makes a refund and a later (stale) delivery mutually exclusive,
    ///         exactly like the hop reversal path.
    function refundExpiredSwapOut(bytes32 swapId, address token, uint minDeliveredUsd)
        external nonReentrant {
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        if (so.sats == 0) revert SwapOutReplay();                 // nothing pending
        if (msg.sender != so.swapper) revert NotLP();             // only the swapper recovers their own principal
        if (block.number < uint(so.requestBlock) + SWAPOUT_REFUND_BLOCKS) revert NotExpired();
        if (swapInUsed[swapId]) revert SwapInReplay();            // already delivered/reversed
        swapInUsed[swapId] = true;
        delete pendingOnchainSwapOut[swapId];
        btc.subPendingSwapOut(so.usd);
        btc.creditSwapIn(so.swapper, so.sats, token, minDeliveredUsd);   // pinned to the recorded swapper
    }

    // ═════════════════════════════════════════════════════════════════
    //  SWAP-OUT (USD→BTC) — the on-curve mirror of swap-IN. The swapper commits
    //  USD on the curve (recording the delivery obligation via netDeliveredBtc)
    //  and the hop delivers native BTC. The only rail today is the ON-CHAIN one
    //  (`requestSwapOutOnchain` → `deliverSwapOutOnchain`), which settles each
    //  delivery's proceeds on-chain. A failed delivery IS a swap-IN: the hop
    //  reverses it via the existing `settleSwapIn`/`creditSwapIn` (BTC back to
    //  the pool, USD back to the swapper, netDeliveredBtc decrements on the
    //  symmetric curve delta). The swapper approves Aux for the USD pull.
    // ═════════════════════════════════════════════════════════════════

    /// @notice ON-CHAIN swap-out (delivery rail B): USD→BTC delivered to a Bitcoin
    ///         address for a user with NO Lightning wallet. Identical USD intake to
    ///         the BOLT11 path (`creditSwapOut` runs the curve buy + records
    ///         netDeliveredBtc/swapUsdBtc); the delivery obligation is recorded here
    ///         and settled by `deliverSwapOutOnchain` once the hop's SPV-proven
    ///         splice-out pays `swapperScript`. `swapId` is a client-unique dedup key
    ///         (shares `swapOutUsed`). A failed delivery reverses via `settleSwapIn`
    ///         (USD back to the swapper) — the SAME unhappy path as the LN rail.
    /// ⚠️ (E184) THE DESTINATION IS NOT A PARAMETER ANY MORE — it is `btcRecipientOf[msg.sender]`.
    ///
    /// 🔴 THE HALF-FAILURE THIS CLOSES. §E131 proved the supplied script's 32 bytes were ON the
    /// curve; **nothing proved the swapper CONTROLLED them** — the identical half of the failure
    /// §E138 fixed for the LP. A typo landing on a valid x-coordinate (≈HALF of all typos, since
    /// ~half of arbitrary 32-byte values are valid points) sent the swapper's BTC to a key someone
    /// else may hold, and the system recorded a successful delivery.
    ///
    /// 🔑 THE FIX REMOVES CODE RATHER THAN ADDING A CHECK. `setBtcRecipient` ALREADY demands a
    /// BIP-340 proof-of-possession (§E138) and already rejects an off-curve key (§E130). Deriving
    /// the destination from that registration inherits BOTH proofs for free, so the prefix test and
    /// the `isValidXOnlyKey` call here are not merely redundant — they were the WEAKER half of a
    /// guarantee that now holds in full. Adding a second PoP parameter instead would have been the
    /// clamp standing rule 3 warns about: more surface, same hole.
    ///
    /// ⇒ Uniform with the LP payout (`_lpPayoutScript`), so a swapper and an LP are protected by
    /// the same one mechanism, and a swapper who wants a different destination re-registers — WITH
    /// a proof — rather than naming an unproven key per swap.
    function requestSwapOutOnchain(
        address token, uint usdAmount, uint minSats, bytes32 swapId
    ) external nonReentrant returns (uint sats) {
        if (swapId == bytes32(0) || swapOutUsed[swapId]) revert SwapOutReplay();
        // Symmetric dedup: a swapId that collides with an already-used swap-IN key
        // (swapInUsed is set by settleSwapIn AND by a delivered swap-out) would be BOTH
        // undeliverable (deliverSwapOutOnchain reverts on swapInUsed) AND unreversible
        // (settleSwapIn reverts on swapInUsed) → the swapper's USD would strand with no
        // recovery. Reject it up front, BEFORE creditSwapOut pulls the USD.
        if (swapInUsed[swapId]) revert SwapOutReplay();
        // (E184) The destination is the swapper's REGISTERED payout key, which `setBtcRecipient`
        // already proved is on the curve (§E130) AND under their control (§E138). Building it here
        // means the P2TR shape is true by construction — there is no supplied blob to prefix-check.
        if (btcRecipientOf[msg.sender] == bytes32(0)) revert NotPubkeyHash();
        bytes memory swapperScript = _lpPayoutScript(msg.sender);
        swapOutUsed[swapId] = true;
        uint usd6;
        (sats, usd6) = btc.creditSwapOut(msg.sender, token, usdAmount, minSats);
        if (sats == 0) revert SwapOutReplay(); // zero/dust fill → unwind the used-mark
        // uint96 packing self-evidently safe (BTC supply ≪ 2^96; 6-dec usd ≪ 2^96/1e6).
        if (sats > type(uint96).max || usd6 > type(uint96).max) revert InvalidParam();
        pendingOnchainSwapOut[swapId] = PendingOnchainSwapOut({
            swapper:           msg.sender,
            sats:              uint64(sats),
            requestBlock:      uint32(block.number),  // starts the self-refund timeout
            swapperScriptHash: keccak256(swapperScript),
            usd:               uint96(usd6),
            token:             token                  // (T1-d) the swapper's OWN choice, pinned
        });
        // pendingSwapOutUsd += usd6 (proceeds owed to the LP that delivers). creditSwapOut
        // grew POOLED_USD by the same usd6, so the swap-in FREE reserve
        // (POOLED − pending) is UNCHANGED → spamming requests can't grief the gate.
        // Matched -= on delivery (_settleDelivered) or reversal (settleSwapIn).
        btc.addPendingSwapOut(usd6);
        emit SwapOutRequestedOnchain(msg.sender, sats, token, swapId, swapperScript);
    }

    /// @notice Settle an on-chain swap-out: the hop submits the SPV-proven splice-out
    ///         tx that paid the swapper. HOP-GATED ONLY.
    ///         ⚠️ THIS SAID "lpAuth-consented like `splice` (the LP signs THIS exact tx via
    ///         `swapOutDeliverDigest`)". **NO SIGNATURE IS VERIFIED HERE — this function takes
    ///         no signature parameter at all** (E148). Under the delegation model the fleet
    ///         splices as the channel's hop and produces no per-call lpAuth
    ///         (`quid-bridge/swap_out_onchain.rs:221-223`).
    ///         ⚠️ **THIS ALSO SAID `swapOutDeliverDigest` "REMAINS as an off-chain-signing helper".
    ///         IT DOES NOT — §E182 deleted it (record: the "ALL FOUR PUBLIC DIGEST ACCESSORS ARE
    ///         DELETED" block above; this cited `:828` and it drifted), and its Rust twin
    ///         `swap_out_deliver_digest` went with it on 2026-08-22 once the reason for keeping the
    ///         pair was re-tested and found expired.** The keep-reason was "the natural message for
    ///         an LP-consent gate that does not exist yet"; that gate arrived as §E182 `rekey` and
    ///         deliberately did NOT reuse it, keeping its own preimage under tag `rekey.v1`.
    ///         What actually bounds this call: the hop gate, the SPV proof, and the KeyAgg
    ///         gate on the new funding key (E129). Verifies the tx
    ///         pays `swapperScript` ≥ the obligation, then shrinks the LP's channel and
    ///         settles the slice with delivered PINNED to the obligation: the swap-out's
    ///         `so.sats` (proven paid to the swapper) is the delivered BTC, and the LP
    ///         claims its `swapUsdBtc` proceeds for exactly that — clamped. Unlike a
    ///         close / LP-withdrawal splice, the delivered amount is NOT inferred from the
    ///         tx outputs, so it cannot be inflated by routing the LP's change away from
    ///         btcRecipientOf (see `_deliverSwapOut`).
    function deliverSwapOutOnchain(
        bytes32 swapId,
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof,
        bytes calldata swapperScript,
        // (§E233-ladder) The fresh ladder for the rotated outpoint — see the note at the arming
        // call below for why this parameter lives on the OUTER frame and not on `_deliverSwapOut`.
        Types.ExitArming[] calldata exits
    ) external nonReentrant {
        _whenOpen(channelId);
        _onlyHop();
        // 🔴 §AUDIT-DELIVER-KEYS — THE PIN EVERY OTHER KEY-ROTATING PATH HAD AND THIS ONE DID NOT.
        // `_deliverSwapOut` rotates the funding outpoint (it assigns `fundingTxId`/`fundingVout`
        // and calls `_useOutpoint`), and it proves the rotation with `_verifySplice`, which
        // "proves KeyAgg over WHATEVER PAIR IT IS GIVEN" (`splice:1123`). So without this line the
        // hop supplies `p.lpPubkey`/`p.hopPubkey` of its OWN choosing, the aggregate verifies
        // against those, and custody moves to a 2-of-2 the LP is not half of — the exact attack
        // `_requireChannelKeys`'s own docblock (:1832) describes: *"a compromised hop splices to
        // keys it solely controls and CUTS THE LP OUT of its own 2-of-2."*
        // ⚠️ AND THE SECOND HALF IS AS BAD AS THE FIRST: `keysHash` would be left STALE against a
        // rotated outpoint, which is §E153's *unretirable forever* regression verbatim (:1258) —
        // both retirement paths then revert and the position can never be closed.
        // The siblings that already do this: `splice`, `emitDeadManExit`, and
        // `_requireNotSplice` (the recordClose/retire path). ⚠️ `parkProvenSats` was a FOURTH and
        // is gone — the reserve funder replacing it does not touch a channel, so rotation sites
        // are one fewer. This was the last unpinned one — found the same way §T1-f-general
        // was: by diffing the writers of the funding outpoint against the sites that gate it.
        // ⚠️ IT SITS IN THE **OUTER** FRAME, WITH THE `_armLadder` CALL AND FOR THE SAME REASON.
        // `_deliverSwapOut`'s note is explicit that its calldata params must go DEAD before the
        // settlement tail or the legacy stack (no via_ir) overflows — a prior attempt to extend
        // one live range in there reverted four tests. `p` is ALREADY live out here (it is passed
        // on to both `_deliverSwapOut` and `_armLadder`), so reading it here extends nothing.
        // ⚠️ THIS DOES NOT REKEY: rotating to a NEW pair is `rekey` (§E182), which updates
        // `keysHash` under its own gate. A delivery must keep the pair it opened with.
        _requireChannelKeys(channelId, p);
        // (B) Authorization = the channel's HOP GATE (channel.hop was fixed at open to a
        // delegated hop). The retired per-delivery lpAuth was redundant: the swapper's BTC
        // payment is SPV-proven below, the shrink pins the delivered slice to the on-chain
        // obligation, and any withdrawal output still pins to btcRecipientOf.
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        if (so.sats == 0) revert NoSuchSwapOut();
        // Anti-double-spend: if this swap-out was already REVERSED (its USD returned
        // via settleSwapIn, which marks swapInUsed[swapId]), refuse to also deliver
        // the BTC — else the swapper gets both. The hop's driver checks this off-chain
        // too, but this is the on-chain backstop against a racing/replayed delivery.
        if (swapInUsed[swapId]) revert SwapOutReplay();
        if (keccak256(swapperScript) != so.swapperScriptHash) revert InvalidParam();
        // The splice tx must actually pay the swapper their BTC (≥ the obligation).
        if (BitcoinTx.sumOutputValuesToScript(rawSpliceTx, swapperScript) < so.sats)
            revert SwapOutNotDelivered();
        // Gate + SPV-verify + settle in its own frame (legacy stack, no via_ir).
        _deliverSwapOut(swapId, channelId, p, rawSpliceTx, spliceMerkleProof);
        // (§E233-ladder) THE FIFTH AND LAST ROTATION SITE. A delivery shrink rotates the funding
        // outpoint (`_deliverSwapOut` assigns `fundingTxId`/`fundingVout` and calls `_useOutpoint`),
        // so every rung armed before it is dead, exactly as on `splice`.
        //
        // ⚠️ **IT ARMS HERE, IN THE OUTER FRAME — AND I FIRST CONCLUDED IT COULD NOT.** The note in
        // `_deliverSwapOut` says its calldata params must go DEAD before the settlement tail or the
        // legacy stack overflows, and that a prior attempt to extend one live range there reverted
        // four tests. That is TRUE OF THE INNER FRAME and I over-read it as "this path cannot take a
        // ladder at all", which is what left this site open. The rotation is COMPLETE when
        // `_deliverSwapOut` returns, so the arming needs nothing from the inner frame: it runs
        // afterwards, out here, and `_armLadder` reads the ALREADY-ROTATED outpoint from storage.
        // The inner constraint is untouched.
        _armLadder(channelId, p, exits);
    }

    /// @dev Delivery body in its own frame: same lpAuth + SPV-spend authentication as
    ///      `splice` (the LP signs THIS exact tx; the splice provably spends the channel's
    ///      current 2-of-2 — no static key pin, since LDK rotates funding keys per splice),
    ///      SPV-verify the splice-out, shrink the channel, and settle the slice as
    ///      DELIVERED (lpPayout=0 → LP claims QUI).
    function _deliverSwapOut(
        bytes32 swapId,
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof
    ) private {
        Types.BTCChannel storage ch = channels[channelId];
        if (p.amountSats >= ch.amountSats) revert NotAShrink(); // delivery must shrink
        (bytes32 newTxId, uint32 newVout) = _verifySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        uint shrinkSats = ch.amountSats - p.amountSats;
        ch.fundingTxId = newTxId;
        ch.fundingVout = newVout;
        ch.amountSats  = p.amountSats;
        _useOutpoint(newTxId, newVout); // rotated funding UTXO claimed once
        totalSatsLocked -= shrinkSats;
        // Settle in a fresh frame: the calldata params (p / rawSpliceTx / proof)
        // — ⚠️ this used to list `lpAuth`, which is NOT a parameter of this function (E148).
        // are dead from here, so the settlement tail gets a clean legacy stack (no via_ir).
        _settleSwapOutSlice(swapId, channelId, ch.lpEth, shrinkSats, newTxId, newVout);
    }

    /// @dev Settlement tail for an on-chain swap-out, in its own frame.
    ///      DELIVERED IS THE OBLIGATION, not inferred from the tx. For an on-chain
    ///      swap-out the delivered BTC is EXACTLY `so.sats` — the amount recorded at
    ///      requestSwapOutOnchain and already PROVEN paid to the swapper by the caller
    ///      (sumOutputValuesToScript(rawSpliceTx, swapperScript) ≥ so.sats). Passing
    ///      lpPayout = shrinkSats − so.sats makes the Vault derive deliveredRaw = so.sats,
    ///      so a malicious LP CANNOT inflate its delivered slice by routing the splice's
    ///      non-swapper (change/withdrawal) output to a script ≠ btcRecipientOf — the old
    ///      `_lpFinalBalance` attribution was gameable exactly that way (route payout away
    ///      → reads 0 → delivered = shrinkSats → over-claim the shared proceeds pool). The
    ///      delivered amount is now pinned to the swapper's on-chain-proven obligation and
    ///      does not depend on the LP's payout script at all; the LP's own change/fee
    ///      (shrinkSats − so.sats) settles as native, as it must. (Close and LP-withdrawal
    ///      splice have NO such obligation to pin against — they stay tx-derived via
    ///      `_lpFinalBalance` and are made honest by the hop's counterparty-output policy.)
    function _settleSwapOutSlice(
        bytes32 swapId,
        bytes32 channelId,
        address lpEth,
        uint shrinkSats,
        bytes32 newTxId,
        uint32 newVout
    ) private {
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[swapId];
        uint sats = so.sats;
        // The OTHER legitimate sink (see checkpointOf). ⚠️ COUNT `shrinkSats`, NOT `so.sats`.
        // The channel falls by the FULL shrink: `so.sats` goes to the swapper and the
        // remainder is the LP's own change, which this function's docblock calls out --
        // "the LP's own change/fee (shrinkSats - so.sats) settles as native, as it must".
        // Both halves leave the channel, so counting only the swapper's slice under-counts
        // the payout and makes an HONEST close trip the guard. (First version did exactly
        // that; it was reverted for it.)
        paidOutSinceCheckpoint[channelId] += shrinkSats;
        // Pay the delivering LP EXACTLY the swapper's recorded USD (so.usd) as
        // proceeds: lpPayout = shrink − sats is the LP's native change; exactUsd =
        // so.usd is its dollar leg. _settleDelivered draws POOLED_USD + clears
        // pendingSwapOutUsd by so.usd (the matched -= for the request's +=).
        _requireClaimRegistered(channelId);   // (§LAZY-OPEN-SHRINK) else `LP.pooled -=` panics
        btc.resize(lpEth, shrinkSats, shrinkSats > sats ? shrinkSats - sats : 0, so.usd);
        // Mark the swapId consumed on the swap-IN side too: delivery and reversal are now
        // MUTUALLY EXCLUSIVE in BOTH directions. The deliver entry already blocks
        // reverse→deliver (swapInUsed check at the top); this blocks deliver→reverse, so a
        // later settleSwapIn(paymentHash=swapId) can't also refund a swapper who already
        // received BTC.
        swapInUsed[swapId] = true;
        delete pendingOnchainSwapOut[swapId];
        emit SwapOutDeliveredOnchain(swapId, channelId, lpEth, uint96(sats), newTxId, newVout);
    }

    // ═════════════════════════════════════════════════════════════════
    //  BTC recipient registration (swap destination)
    // ═════════════════════════════════════════════════════════════════
    /// @notice Setter for users who haven't opened a channel. They register
    /// their P2WPKH destination as the low 20 bytes of bytes32.
    function setBtcRecipient(bytes32 xOnlyKey, bytes calldata pop) external {
        // A channel LP's payout is pinned by its channels (see btcRecipientLocked);
        // only non-channel swap users may set/update it freely. `xOnlyKey` = the LP's
        // 32-byte x-only taproot key (key-path P2TR payout, `0x5120||xOnlyKey`).
        if (btcRecipientLocked[msg.sender]) revert BtcRecipientLockedErr();
        // (E138) SAME PROOF AS THE OPEN PATH. Requiring possession only at `openChannel` would
        // leave this entrypoint as a bypass — a swap user could still pin an unspendable or
        // someone else's key — and a guard with a hole around it is worse than no guard, because
        // it reads as covered.
        // `bindHash == 0`: a non-channel swap user pins only a payout key, with no channel and
        // therefore no payment basepoint to bind. The zero is what keeps the two PoPs
        // non-interchangeable.
        _requireRecipientPoP(msg.sender, xOnlyKey, pop, bytes32(0));
        _registerBtcRecipient(msg.sender, xOnlyKey);
    }

    /// Shared by `setBtcRecipient` (non-channel Aux users) and `openChannel` (channel LPs,
    /// set from the committed P2TR upfront-shutdown script). `xOnlyKey` is the LP's 32-byte
    /// x-only taproot key; the payout is key-path P2TR `0x5120||xOnlyKey`. A malformed key
    /// makes only the LP's OWN payout unspendable (its loss), so on-chain we require only
    /// nonzero (all 32 bytes are the key — no high-bytes-zero mask).
    /// @notice (E138) The message a payout key signs to prove possession. Public so the LP's
    ///         wallet signs EXACTLY what the contract checks rather than a reconstruction.
    /// @param bindHash EXTRA MATERIAL THIS PoP COMMITS TO, or `0` for none.
    ///        (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) `openChannel` passes
    ///        `keccak256(auth.lpPaymentPoint)`; `setBtcRecipient` passes `0`.
    ///
    /// 🔴 WHY THE OPEN PATH BINDS THE PAYMENT POINT, AND WHY IT IS NOT OPTIONAL. The hop submits
    /// `OpenAuth`, so without this a compromised hop could supply ANY 33-byte point: the pinned
    /// `lpToRemoteKey` would then match no output in any commitment transaction, every force close
    /// would measure `lpPaidSats = 0`, and — because a zero reading is deliberately treated as
    /// AMBIGUOUS rather than as a breach — the check would be SILENTLY DISARMED while still
    /// appearing to run. **A guard that looks armed is the failure this whole row is about**, so
    /// re-introducing it inside the fix would be the exact hole-trade the design forbids.
    /// ✅ IT COSTS THE LP NOTHING NEW: the LP already signs this one BIP-340 PoP at open, and this
    /// only widens what that same signature commits to.
    /// ⭐ IT ALSO DOMAIN-SEPARATES THE TWO CALLERS FOR FREE: a PoP signed for `setBtcRecipient`
    /// (`bindHash == 0`) can no longer be replayed into an `openChannel`, or the reverse.
    function btcRecipientPoPDigest(address lpEth, bytes32 bindHash) public view returns (bytes32) {
        // (2026-08-22) NO DOMAIN TAG. Separated from the only other verified digest (`rekey`) by
        // hash function, field count and signature scheme — see the block above `openChannel`.
        // ⚠️ `rekey` and its digest are GONE (§SPLICE-ROTATES-BOTH-FUNDING-KEYS folded it into
        // `splice`), so this is now the contract's ONLY verified digest. The separation argument
        // above is therefore vacuously satisfied — but keep the reasoning, because it is the test
        // any FUTURE digest must pass before it is added beside this one.
        return sha256(abi.encode(block.chainid, address(this), lpEth, bindHash));
    }

    /// @dev (E138) Own frame — `openChannel` is at the legacy stack limit.
    function _requireRecipientPoP(address lpEth, bytes32 xOnlyKey, bytes calldata sig, bytes32 bindHash)
        private view {
        if (sig.length != 64) revert NotPubkeyHash();
        bytes32 r; bytes32 s_;
        assembly { r := calldataload(sig.offset) s_ := calldataload(add(sig.offset, 32)) }
        if (!BitcoinTx.schnorrVerify(xOnlyKey, r, s_, btcRecipientPoPDigest(lpEth, bindHash)))
            revert NotPubkeyHash();
    }

    function _registerBtcRecipient(address who, bytes32 xOnlyKey) internal {
        if (xOnlyKey == bytes32(0)) revert NotPubkeyHash();
        // (E130) It must be a REAL x-only key, or `0x5120||xOnlyKey` is UNSPENDABLE and every
        // payout pinned to it — cooperative close, withdrawal splice, dead-man exit — burns the
        // LP's balance irrecoverably. ~HALF of arbitrary 32-byte values fail this, and nothing
        // else detects it until a payout is attempted and already on-chain.
        if (!BitcoinTx.isValidXOnlyKey(xOnlyKey)) revert NotPubkeyHash();
        btcRecipientOf[who] = xOnlyKey;
        emit BtcRecipientRegistered(who, xOnlyKey);
    }
}
