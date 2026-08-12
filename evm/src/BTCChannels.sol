// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBtcVaultBridge} from "./imports/Interfaces.sol";
import {Types} from "./imports/Types.sol";
import {ISPVGateway} from "./spv/interfaces/ISPVGateway.sol";
import {BitcoinTx} from "./imports/BitcoinTx.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";
import {ExitLib} from "./imports/ExitLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MuSig2Agg} from "./imports/MuSig2Agg.sol";
// (E125-d) ERC-1271 + ECDSA in one call, so a SMART-WALLET LP can register. Tries ECDSA
// first, so the EOA path — the common one — keeps its cost.
import {SignatureChecker} from "@openzeppelin-submodule/utils/cryptography/SignatureChecker.sol";

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
//                     position (BtcVault.registerBtcLp — NOT Vogue; the BTC side
//                     was regrouped out of Vogue + Aux, see the bridge interface
//                     below. Also note `registerBtcLp` is NOT open-only: a GROW
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
//                     position (unregisterBtcLp), paying the LP's accrued
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
//  are now false. `MuSig2Agg.isTwoOfTwoOutputKey` PROVES Q == TapTweak(KeyAgg(lp,hop)) at the
//  OPEN and at every SPLICE, and `lpAuth` is retired (see (B) below). Left as a marker because
//  three separate notes in this file described the pre-delegation, pre-EC world as current.
//  The historical text, for the record: it byte-matched the lpAuth-committed Q, so it did not prove
//  on-chain that Q == KeyAgg(lp, hop). That 2-of-2 genuineness rests on the
//  off-chain MuSig2 keygen (the LP recomputes Q from its own + the hop's key
//  before signing lpAuth) + the hop-only msg.sender gate. SGX attestation IS wired
//  as the trust anchor: `_requireAttested` calls
//  `AttestedHopRegistry.isAttested` on the hop money-paths (openChannel, settleSwapIn,
//  emitDeadManExit). It is GOVERNANCE-ARMED — a no-op until `setHopRegistry` pins the
//  live registry, so any deployment/regtest that never pins it falls back to the
//  two-address hop check (E164). Pinning the
//  registry requires the born-in-enclave DCAP identity-quote flow (SGX hardware) so
//  prod hops can actually attest; regtest has no real quote, hence the armed fallback.
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
///         was regrouped out of Vogue + Aux). registerBtcLp / unregisterBtcLp /
///         resizeBtcLp are gated `onlyBtcChannels` and creditSwapIn /
///         creditSwapOut `onlyBTCChannels` on BtcVault (msg.sender == its pinned
///         btcChannels), so only this contract can drive them.
/// The Safe-governed MRENCLAVE whitelist — `isAttested(hop)` is true only for an EVM address whose SGX
/// quote the registry's governance has verified (Automata DCAP). Gates who may become a shared-pool hop.

contract BTCChannels is Ownable, ReentrancyGuard {
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
    // constructor. (E150: the legacy `(_aux, _vogue)` pair and `_hopNode` are gone.)
    IBtcVaultBridge public immutable btcVault;
    // MULTI-HOP: there is NO single global `hopNode`. Each channel records the hop
    // (EVM address) that opened it (`channel.hop`). ⚠️ UPDATED 2026-08-07 (E122): that hop is
    // ⚠️ UPDATED AGAIN 2026-08-10 (E157): it IS the sole authority once more — splice and
    // swap-out delivery gate on `channel.hop` directly, now that delegation is folded into the
    // open. ⚠️ PREVIOUSLY 2026-08-10
    // (E156): the "and, after staleness, its named fallback" clause is GONE with the fallback
    // itself. The partition still holds (one delegation per LP). Historically this said SOLE authority
    // for that channel's splice / swap-out delivery / swap-in attestation / cooperative
    // close. This lets independent SGX instances — the hosted fleet, a person self-
    // hosting for themselves, or a family-plan group — run against the SAME contracts
    // without one being able to touch another's channels. Open is PERMISSIONLESS
    // across hops: the LP's ECDSA `lpAuth` signs the SUBMITTER (msg.sender) into the
    // open digest, so only the hop the LP designated can open the LP's channel — the
    // hop-relay model (fleet/family) works, and a genuine LP's authorization cannot be
    // REPLAYED through a different submitter (the original front-run). Whoever
    // opens becomes this channel's hop. The residual "self-deal" — a party citing a
    // funding UTXO it doesn't truly control — is the SAME unproven-Bitcoin-key-control
    // residual the design accepts everywhere (bounded by the no-over-mint clamp
    // + the outpoint-uniqueness guard below), resolved by SGX attestation.
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
    // close). Gates swap-in attestation authority (`settleSwapIn`) without a per-call
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

    // The LP-FEE IDEMPOTENCY set (`lpFeePaid`) + `markLpFeePaid` were REMOVED: the
    // BTC-leg fee is no longer paid OFF-chain by a settler (whose double-pay-on-rollback risk
    // this F4 guard existed for). It now compounds into LP.pooled via the fee-splice, and any
    // exit residual is forgone to the pool (dust) — see Vault.BtcLpFeesForgone. With no native
    // off-chain payout there is nothing to dedup on-chain.

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

    // (B) LP DELEGATION — the LP runs NOTHING. Instead of signing an lpAuth per
    // open/splice/deliver over a live LN round-trip (the retired responder), the LP
    // signs ONE cold delegation (EIP-712, submitted gaslessly by the operator): it
    // names the single `hop` allowed to open/splice/deliver channels owned by the
    // LP's `lpEth`, and the `btcRecipientOf` payout script every payout pins to.
    // Security is UNCHANGED vs the responder: the contract still SPV-proves + taproot
    // byte-matches (`0x5120||Q`) every funding/splice tx, and every BTC payout still
    // pins to `btcRecipientOf`, so a compromised hop can only fund positions credited
    // to the LP with payouts to the LP — bounded, never theft. `version` is monotonic:
    // the LP revokes/rotates by signing a higher one (guards replay of an old
    // delegation over a newer). delegatedHop==0 ⇒ no delegation ⇒ no open.
    // (E157) `delegationVersion` / `delegatedAuthority` ARE DELETED with the standing grant they
    // described. Authorization is now per-channel: the LP signs for THIS funding outpoint
    // (`openAuthDigest`), and afterwards only `channel.hop` — the hop that opened it — may act.
    // The monotonic counter had nothing left to guard: a signature bound to a single-use outpoint
    // cannot be replayed, and `_useOutpoint` is what enforces that.
    // (E156) THE E122 LP-NAMED FALLBACK IS DELETED — `fallbackAuthority`, `registerFallback[For]`,
    // `fallbackDigest`, `lastHeartbeatBlock`, `FALLBACK_STALENESS_BLOCKS` and
    // `_authorizedHopForChannel` are all gone. It asked the LP to nominate a rescuer in advance,
    // and it could not deliver one: the fleet holds BOTH funding halves (`deadman_exit.rs`), so a
    // nominated hop has no key to sign an exit with — it could only RELAY bytes the original hop
    // had already signed. The rescue was always "those bytes exist and their CLTV matured", never
    // "a named party acted". Arming at open (`Types.ExitArming`) makes the bytes an invariant, so
    // the nomination protected nothing and its two clocks (`lastHeartbeatBlock` here, the CLTV
    // deadline on Bitcoin) measured the same fact — one of them enforced by consensus.

    // ONE OPEN CHANNEL PER lpEth. The BTC-LP position (autoManagedBTC[lpEth]) is
    // keyed per-address; a SECOND open for an lpEth that already has one would let
    // the aggregate `pooled` span channels while close attributes per-channel —
    // mis-attributing the others' notional as delivered (over-mint) and wiping
    // their positions. Splice is the capacity knob (resize one channel in place),
    // so an LP never needs two channels; an entity wanting more positions uses
    // more addresses. Set on open, cleared on close (sequential reopen allowed).
    // This makes the aggregate-spanning-channels state UNREPRESENTABLE.
    mapping(address => bool) public hasOpenBtcChannel;

    // DEAD-MAN EXIT (#114) — non-custodial BTC-LP force-close backstop that needs
    // NOTHING from the LP (no keyfile, no sidecar tool). The fleet holds BOTH MuSig2
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
    /// 🔑 THAT IS WHAT BOUNDS A COMPROMISED FLEET. "Spend anywhere" needs a signature; the LP's
    /// half only ever signed these. So the failure mode inverts: an operation outside the set
    /// cannot happen, which is DEGRADED SERVICE (the channel cannot splice) rather than LOSS OF
    /// FUNDS (the exits are already signed and remain broadcastable).
    ///
    /// ⚠️ `deadManDeadline` was ONE `uint64` and is now this map. A zero value means NOT ARMED,
    /// which is why arming rejects a zero deadline — the two would otherwise be indistinguishable.
    mapping(bytes32 => mapping(uint64 => bool)) public exitArmedAt;

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


    // Swap-in replay guard: the Lightning HTLC hashlock (payment hash) of each
    // settled BTC→USD swap-in, marked used so a buggy/compromised/double-
    // submitting hop can't credit the same swap-in twice (which would drain
    // POOLED_USD_BTC for the seller — the old per-call `BtcInflowCap` bound was
    // REMOVED (SwapLib:701-702), so this replay guard + the soft-backing check
    // are the protection; the residual hop-trust drain is tracked as §A #22).
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
    struct PendingOnchainSwapOut { address swapper; uint96 sats; bytes32 swapperScriptHash; uint96 usd; uint32 requestBlock; }
    mapping(bytes32 => PendingOnchainSwapOut) public pendingOnchainSwapOut;

    event BtcRecipientRegistered(address indexed owner, bytes32 pubkeyHash);
    error NotPubkeyHash();

    // ─── Errors / Events ─────────────────────────────────────────────
    error NotLP();
    error NotChannelHop();       // caller is not this channel's recorded hop
    error OutpointReused();      // this funding UTXO already backs a channel
    error SwapInReplay();
    error SwapInPartialRejected();   // requireFull swap-in (LN rail) that the pool could only partially fill
    error BadSPV();
    error AlreadyOpen();
    error WrongBtcRecipient(); // open's payout hash != the LP's already-registered one
    error OneChannelPerLp();   // lpEth already has an open channel (splice to resize)
    error BtcRecipientLockedErr(); // can't setBtcRecipient once a channel locked it
    error WrongStatus();
    error WrongPrevOutpoint();        // tx doesn't spend this channel's funding UTXO
    error InvalidParam();             // bad lpAuth recovery
    error SpliceUnchanged();          // a splice must change the funded amount (grow or shrink)
    error SpliceIsNotAClose();        // (E153) tx pays a continuing 2-of-2 ⇒ it is a splice
    error SpliceKeyNotTwoOfTwo();     // (E129) new funding Q is not KeyAgg(lpPubkey, hopPubkey)
    error FundingKeyNotTwoOfTwo();    // (E142) initial funding Q is not KeyAgg(lpPubkey, hopPubkey)
    error ForeignSpliceOutput();      // a withdrawal splice paid value somewhere other than the
                                      // new funding output or the LP's committed btcRecipientOf
    error FreshnessNotMonotonic();    // a freshness commit must strictly increase (rollback/replay guard)
    error ManagerFreshnessNotMonotonic(); // a channel-manager freshness commit must strictly increase
    error MigrationNonceAlreadyUsed();    // a MigrationAuth nonce may be consumed at most once (anti-replay)
    error NotDelegatedHop();          // (B) caller is not the LP's delegated hop (open) — see registerDelegation

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
    // partial (`consumedSats < sats`, the POOLED_USD_BTC USD reserve couldn't absorb the whole input) the hop
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

    // ─── Modifiers ────────────────────────────────────────────────────
    modifier whenOpen(bytes32 channelId) {
        if (channels[channelId].status != ChannelLib.STATUS_OPEN) revert WrongStatus();
        _;
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
        bytes32 op = keccak256(abi.encode(fundingTxId, vout));
        if (fundingOutpointUsed[op]) revert OutpointReused();
        fundingOutpointUsed[op] = true;
    }

    /// @param lpPayoutSats the BTC the LP took in the close tx — Vogue uses
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
        btcVault.unregisterBtcLp(ch.lpEth, lpPayoutSats);
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
    ///      statement whose only job was to hide a dead parameter — and the `_aux`/`_vogue`
    ///      PAIR, which both designated the SAME vault via
    ///      `_vogue != address(0) ? _vogue : _aux`, a shim for two calling conventions left
    ///      from when the BTC side was split. **All 18 construction sites passed a non-zero
    ///      `_vogue`, so the `_aux` fallback was never once exercised**, and the compatibility
    ///      it preserved was with callers we control — none external, none in `quid-ln`.
    constructor(address _spv, address _btcVault, address _mainHop, address _fallbackHop,
                bytes32 _btcDepositKey)
        Ownable(msg.sender)
    {
        if (_mainHop == address(0) || _fallbackHop == address(0) || _mainHop == _fallbackHop)
            revert InvalidParam();
        spv = ISPVGateway(_spv);
        btcVault = IBtcVaultBridge(_btcVault);
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

    // ─── Attested-hop gate ──────────────────────────────────────
    // The whitelist that decides who may become a shared-pool hop. UNSET (0) ⇒ the gate is OFF (the permissionless
    // open behaviour, for testnet / pre-attestation bootstrap). Governance PINS it ONCE to the live registry to turn
    // the gate on; PIN-ONCE (can never be un-set or repointed) so a later compromised owner cannot disable it.
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
    //  OPEN — the LP's DELEGATED HOP submits the raw funding tx + SPV proof.
    //
    //  ⚠️ THIS SAID "anyone submits … + lpAuth" and "ch.lpEth = the recovered signer of
    //  lpAuth". BOTH DESCRIBE THE RETIRED MODEL (E149): `lpAuth` is not a parameter
    //  anywhere. (E157) The open now carries `auth.lpSig`, authenticated against this channel's
    //  funding outpoint — so `lpEth` is passed EXPLICITLY and PROVEN, which is what stops a
    //  relayer redirecting the credit.
    //
    //  AIRTIGHT FUNDING CHECK (in ChannelLib.openChannelBody):
    //   1. SPV: funding tx confirmed in mainchain with MIN_CONFIRMATIONS.
    //   2. txid integrity: recomputed from raw bytes.
    //   3. Script match: byte-match the key-path P2TR funding output `0x5120||Q`
    //      (Q = p.fundingTaproot) against the SPV-proven tx.
    //   4. (E142) KeyAgg: `MuSig2Agg.isTwoOfTwoOutputKey` PROVES
    //      Q == TapTweak(KeyAgg(KeySort(lpPubkey, hopPubkey))) — see openChannel.
    //      ⚠️ THIS LINE USED TO SAY THE OPPOSITE ("the contract does NO secp256k1 EC, so it
    //      does NOT prove Q == KeyAgg"). True until 2026-08-08, false now. It is the third
    //      correction to this same block; the check it describes is what finally makes the
    //      funding output SELF-IDENTIFYING rather than asserted.
    //      ⚠️ CORRECTED 2026-08-07. This used to read: "the LP's lpAuth signs over the
    //      WHOLE OpenParams (incl. Q), so Q is anchored to what the LP consented to."
    //      THAT ANCHOR NO LONGER EXISTS — `lpAuth` was retired when `openChannel` moved
    //      to `(…, address lpEth)` gated on `_authorizedHop`. Under delegation the LP
    //      consents to a HOP, not to a funding output, so a delegated hop may open with
    //      ANY `Q` and ANY `amountSats` credited to that LP. The 2-of-2 genuineness now
    //      rests ENTIRELY on the off-chain MuSig2 keygen + the delegated-hop gate. This is
    //      the SAME trust posture as the old P2WSH path: that path reconstructed
    //      the script SHAPE but likewise never proved the LP controlled its key or
    //      that the parties were independent. A malicious hop is the residual trust
    //      either way.
    //   4. Amount match: that output's value == p.amountSats.
    //  Without (3)+(4) an LP could submit any tx and credit a fabricated
    //  position.
    // ═════════════════════════════════════════════════════════════════
    /// @notice EIP-191-free authorization digest the LP signs with the EVM key
    ///         that should own the channel + pool position. Binds chain + this
    ///         contract + the exact funding tx + every OpenParams field.
    /// @param hop the EVM address the LP authorizes to SUBMIT this open (== the hop
    ///        that will own the channel). Binding it into the digest lets the LP
    ///        designate its hop (fleet/self/family) and stops a genuine lpAuth from
    ///        being replayed through any other submitter. (v2: hop added to the digest.)
    ///
    /// ═══ THE DIGEST FAMILY SPLITS IN TWO, AND NOTHING SAID SO UNTIL NOW (E149) ═══
    /// **VERIFIED ON-CHAIN** — a signature over these is recovered/checked in this contract:
    ///     `openAuthDigest`    (openChannel — the LP's per-channel consent)
    /// **OFF-CHAIN-SIGNING HELPERS** — `public view` so the off-chain side can compute the
    /// EXACT bytes this contract would, but NO on-chain consumer verifies a signature:
    ///     `openChannelDigest` · `spliceDigest` · `swapOutDeliverDigest`
    /// ⚠️ **HAVING NO ON-CHAIN CONSUMER IS THE NORMAL, INTENDED STATE FOR THE SECOND GROUP —
    ///    IT IS NOT EVIDENCE OF DEAD CODE.** Under the delegation model the fleet acts as the
    ///    channel's hop and produces no per-call signature, so these are currently unsigned;
    ///    the helpers were kept deliberately. **E148 nearly deleted `swapOutDeliverDigest` on
    ///    exactly that misreading — the criterion "no `src` consumer" would equally condemn
    ///    `openChannelDigest`, which has 9 test and 7 Rust callers.** Count the SIBLINGS
    ///    before concluding any member of this family is dead.
    function openChannelDigest(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        address hop
    ) public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("BTCChannels.openChannel.v2"),
            block.chainid,
            address(this),
            keccak256(rawFundingTx),
            keccak256(abi.encode(p)),
            hop
        ));
    }

    /// @notice Digest the LP signs to authorize a SPLICE (grow). Binds the
    ///         channelId + the new params (incl. the new total amountSats) + the
    ///         splice tx, so consent is specific to this resize of this channel
    ///         and can't be replayed onto another channel or amount.
    /// @notice LP-consent digest for a splice (resize, either direction). Binds the
    ///         channelId + new params + splice tx — no separate balance field: a SHRINK
    ///         reads the LP's BTC payout straight from the splice tx (trustless), so
    ///         there's nothing for the hop to attest.
    function spliceDigest(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx
    ) public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("BTCChannels.splice.v1"),
            block.chainid,
            address(this),
            channelId,
            keccak256(rawSpliceTx),
            keccak256(abi.encode(p))
        ));
    }

    /// @notice LP-consent digest for an ON-CHAIN swap-out DELIVERY splice. Distinct
    ///         domain tag from `spliceDigest` + binds `swapId`, so a delivery lpAuth
    ///         can ONLY be used through `deliverSwapOutOnchain` (never replayed as a
    ///         plain `splice`, which would leave the swapId unfulfilled → a possible
    ///         later double-refund). The LP thus consents to delivering THIS swap-out.
    function swapOutDeliverDigest(
        bytes32 swapId,
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx
    ) public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("BTCChannels.swapOutDeliver.v1"),
            block.chainid,
            address(this),
            swapId,
            channelId,
            keccak256(rawSpliceTx),
            keccak256(abi.encode(p))
        ));
    }

    /// @notice (B) The digest an LP signs COLD (once) to delegate channel operation to an
    ///         `authority` (a concrete hop, OR THE Safe-governed hopRegistry for fleet mode).
    ///         Binds chainId + this contract + authority + payout script + version, so it
    ///         can't be replayed to another deployment; a higher version supersedes.
    /// @notice (E157-b) What the LP signs so a hop may open its channel. ONE signature, made at
    ///         onboarding, presented by the daemon at open. No transaction, no counter, no
    ///         EOA/smart-wallet split — but still a signature, and this is why.
    ///
    /// 🔑 WHY CONSENT CANNOT BE DELETED BY secp256k1, THOUGH HALF OF §E125 DID LAND. E125's route
    ///    had two halves: (1) prove `Q == KeyAgg(lpPubkey, hopPubkey)` and (2) derive `lpEth` from
    ///    `lpPubkey`. **(1) IS LIVE** — `MuSig2Agg.isTwoOfTwoOutputKey` in `openChannel` — and it
    ///    closed the hole where a hop opened with ANY Q. **(2) IS REFUTED TWICE**: §E125-r measured
    ///    that `lpPubkey` is the PER-CHANNEL funding key (folded into `channelId`), so deriving
    ///    yields a different EVM address per channel and FRAGMENTS the LP's position; §E125-d
    ///    (owner) ruled derivation out because a derived address IS an EOA address and forecloses
    ///    smart wallets. E125's own words on what is left: *"NOTHING on the Bitcoin side identifies
    ///    the LP to the EVM; `lpEth` can only be ASSERTED, and only an LP signature makes the
    ///    assertion trustworthy."*
    /// ⚠️ AND ITS PREMISE DOES NOT HOLD FOR VAULT LPs. E125 argued the LP *"already co-signs the
    ///    Bitcoin funding, so that signature does double duty"* — but the fleet holds BOTH funding
    ///    halves (`quid-bridge/src/deadman_exit.rs`), so a vault LP co-signs NOTHING on either
    ///    chain. Absent this signature a hop could name any `lpEth` and any `btcRecipient` and take
    ///    the position outright. **Security, not ceremony.**
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
    function openAuthDigest(address hop, bytes32 btcRecipient) public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("BTCChannels.open.v1"),
            block.chainid,
            address(this),
            hop,
            btcRecipient
        ));
    }

    function openChannel(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        Types.OpenAuth calldata auth,
        Types.ExitArming[] calldata exits
    ) external nonReentrant returns (bytes32 channelId)
    {
        // (E157) THE LP'S CONSENT ARRIVES WITH THE OPEN. This was a standing grant established by
        // a prior `registerDelegation` tx; it is now `auth.lpSig`, authenticated below against the
        // funding outpoint this very call proves. `channel.hop = msg.sender` owns the later
        // splice/deliver. Same two protections as before, in one step instead of two:
        // `openChannelBody` SPV-proves + taproot byte-matches (0x5120||Q) the funding, and
        // `btcRecipient` is pinned here as the sole payout — so no hop can redirect funds.
        _onlyHop();   // (E185) a real gate; this line used to be a no-op registry check
        address lpEth = auth.lpEth;
        if (lpEth == address(0)) revert InvalidParam();
        // ONE OPEN CHANNEL PER lpEth (see hasOpenBtcChannel): a 2nd open for an LP
        // that already has one would form the aggregate position the per-channel
        // close mis-attributes. Splice resizes the existing channel; more positions
        // use more addresses. This makes the over-mint/wipe bug unrepresentable.
        if (hasOpenBtcChannel[lpEth]) revert OneChannelPerLp();

        // (E157) AUTHENTICATE THE LP FIRST. The digest reads only `p`, so consent can be checked
        // BEFORE the SPV proof and the ~631k gas of secp256k1 — same reasoning the KeyAgg check
        // already gives for sitting after the merkle proof: both must pass, and the order decides
        // only what a FAILING open pays. `SignatureChecker` serves BOTH LP kinds, so the
        // EOA/smart-wallet entrypoint split is gone with the standing registration that forced it.
        if (!SignatureChecker.isValidSignatureNow(lpEth,
                openAuthDigest(msg.sender, auth.btcRecipient),
                auth.lpSig))
            revert InvalidParam();
        // Pin + LOCK the payout — the sole destination recordClose/_withdrawalPayout will enforce.
        if (btcRecipientLocked[lpEth] && btcRecipientOf[lpEth] != auth.btcRecipient)
            revert WrongBtcRecipient();
        _requireRecipientPoP(lpEth, auth.btcRecipient, auth.btcRecipientPoP);
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
        channels[channelId] = channel;
        hasOpenBtcChannel[channel.lpEth] = true; // one-per-lpEth (cleared on close)
        totalSatsLocked += channel.amountSats;
        // (E156) ARM THE ESCAPE BEFORE THE CHANNEL IS USABLE. Must follow the `channels[channelId]`
        // write — `_armDeadManExit` reads `lpEth` back for the event — and it rejects a zero
        // deadline, so no channel can exist without a live escape.
        _armLadder(channelId, p, exits);

        // Channel locks back the pool: credit the LP's BTC pool position with
        // the locked sats. One channel per lpEth (the position aggregates per
        // address; close retires it in full).
        btcVault.registerBtcLp(channel.lpEth, channel.amountSats);

        _emitOpened(channelId, channel, p);
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
    //      position (registerBtcLp). A deposit — nothing to settle.
    //    • SHRINK (p.amountSats < current): partial withdrawal — removes liquidity
    //      AND settles the shrunk slice through the SAME path as a cooperative close
    //      (resizeBtcLp): the proportional delivered portion mints to the LP as QUI,
    //      the native portion leaves with the LP in the splice tx's payout output.
    // ═════════════════════════════════════════════════════════════════
    /// @param p           Updated params: `amountSats` is the NEW funded total;
    ///                    `fundingBlockHash`/`fundingTxIndex` locate the splice tx;
    ///                    pubkeys are the channel's 2-of-2 pair.
    /// @param rawSpliceTx The Bitcoin splice tx (input 0 spends the prior UTXO; on a
    ///                    SHRINK it also pays the LP's withdrawal output to btcRecipientOf).
    function splice(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawSpliceTx,
        bytes32[] calldata spliceMerkleProof,
        uint feeSettleSats            // BTC-leg fees the hop is FUNDING into this grow-splice (compounds into the LP)
    ) external nonReentrant whenOpen(channelId) {
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

        // (E162) A SPLICE MAY RESIZE A CHANNEL — IT MAY NOT REKEY ONE. Without this, a splice
        // carrying a different pair passed (`_verifySplice` proves KeyAgg over whatever pair it
        // is given), rotated the funding outpoint, and left `keysHash` stale — after which both
        // retirement paths reverted and the position could never be closed.
        _requireChannelKeys(channelId, p);
        if (p.amountSats == channels[channelId].amountSats) revert SpliceUnchanged();
        // Verify + rotate + (grow|shrink) in its own frame (legacy stack, no via_ir); returns the grow delta.
        uint grewBy = _applySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        // FEE-INTO-CHANNEL: the hop may mark up to `grewBy` of this grow as BTC-leg fees it is FUNDING in —
        // they compound into the LP's position (registerBtcLp already grew pooled by the full delta, so `delivered`
        // stays invariant); the bigger pooled share grows the LP's coop-close payout. (An earlier version of this
        // line added "and the hop keysends the same sats onto the LP's LN balance off-chain" — that leg is
        // OBSOLETE under delegation, where the LP runs no LN node.) `<= grewBy` ⇒ it
        // can only settle fees it actually spliced in (no theft); the Vault clamps to the real owed (no over-settle).
        // (E145) `feeSettleSats` IS NOW A NO-OP AND THE CALL BEHIND IT IS GONE.
        // The BTC-leg fee compounds into `LP.pooled` in sats as it is earned, so there is no
        // owed ledger for a hop to settle — `Vault.settleBtcFeesOwed` was deleted with it.
        // ⚠️ THE PARAMETER IS RETAINED DELIBERATELY: `quid-bridge/channel_driver.rs:847` builds
        //    splice calldata carrying `fee_settle_sats`, so removing it is a CROSS-REPO change
        //    and must land in one commit with the Rust side. Accepting-and-ignoring keeps the
        //    ABI stable meanwhile.
        // ⚠️ THIS WAS A LIVE DEFECT FOR ONE COMMIT: the call survived my deletion because
        //    `btcVault` is typed as an INTERFACE that still declared the function, so it
        //    compiled clean and would have reverted at RUNTIME on any splice with
        //    `feeSettleSats > 0`. A deleted implementation does not break a call routed
        //    through an interface — the compiler cannot see the gap.
        feeSettleSats;   // accepted, ignored (see above)
    }

    /// @dev Splice body in its own frame: SPV-verify the splice tx (spends THIS
    ///      channel's funding UTXO + the new 2-of-2 == p.amountSats, larger OR smaller
    ///      is fine), rotate the live outpoint, then grow or shrink the LP's position.
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
            btcVault.registerBtcLp(ch.lpEth, delta); // deposit: add liquidity, no settle
            grewBy = delta;                          // caller settles ≤ this as funded BTC-leg fees
            emit ChannelSpliced(channelId, ch.lpEth, true, delta, p.amountSats, newTxId, newVout);
        } else {
            _shrinkSplice(channelId, p, rawSpliceTx, newTxId, newVout, old); // own frame (legacy stack)
        }
    }

    /// @dev Shrink (withdrawal) branch of a splice, in its own frame: settle the removed
    ///      slice like a close. The LP's native payout is read from the splice tx (output
    ///      to btcRecipientOf), the remainder delivered as clamped QUI. resizeBtcLp
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
        paidOutSinceCheckpoint[channelId] += lpPayoutSats;   // legitimate balance fall
        btcVault.resizeBtcLp(lpEth, shrinkSats, lpPayoutSats, 0);
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
    ///         AUTHORITY: identical (B) gate to `openChannel` — `_requireAttested` +
    ///         `channel.hop`, so only the hop that opened this channel may emit (E157). The payout is pinned to
    ///         `btcRecipientOf` INSIDE the signed bytes, so this can only publish a
    ///         backstop that pays the LP — it can never redirect funds. Emit-only (no
    ///         external call, no fund movement) ⇒ no reentrancy surface.
    function emitDeadManExit(
        bytes32 channelId,
        Types.OpenParams calldata p,
        Types.ExitArming calldata exit
    ) external whenOpen(channelId) {
        _onlyHop();
        // (E128) `p` is needed to recompute `Q`; `_requireChannelKeys` is what stops a hop naming
        // a key pair whose aggregate it controls and verifying the exit against THAT.
        _requireChannelKeys(channelId, p);
        // (E165) Refreshing arms ONE more shape; the LADDER is armed at open. This path still
        // exists because a long-lived channel may outrun its pre-signed set — but with the LP
        // holding a funding half it costs LP participation, which is exactly what the ladder is
        // for. Using it should be the exception, not the heartbeat.
        _armDeadManExit(channelId, p, exit);
        // A REFRESH SUPERSEDES rather than accumulating: the balance may have DROPPED, and keeping
        // a stale higher attestation would reject legitimate closes. That is why the ladder takes
        // a max and this does not — they mean different things by "attested".
        checkpointOf[channelId] = exit.checkpointSats;
    }

    /// @dev (E142/E129) The (keys ↔ Q) proof, in its own frame — `openChannel` gained a calldata
    ///      ARRAY for the exit ladder (two more stack slots) and went over the legacy limit.
    ///      Frame, never `via_ir`.
    function _proveFundingKeys(Types.OpenParams calldata p) private view {
        if (!MuSig2Agg.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert FundingKeyNotTwoOfTwo();
    }

    /// @dev (E165) ARM THE WHOLE LADDER, in its own frame — `openChannel` is already at the legacy
    ///      stack limit, and the house fix is a frame, never `via_ir`. Each shape is verified
    ///      (structure, sighash, signature), so the LP's ONE-TIME participation buys every exit it
    ///      will ever need. At least one is required: a channel with no armed escape is precisely
    ///      the window §E156 closed.
    function _armLadder(
        bytes32 channelId, Types.OpenParams calldata p, Types.ExitArming[] calldata exits
    ) private {
        if (exits.length == 0) revert InvalidParam();
        // ⚠️ THE LADDER IS ONE ATTESTATION SET, so its rungs must not overwrite each other's
        // checkpoint — arming N of them used to write `checkpointOf` N times and keep whichever
        // came LAST, i.e. an arbitrary rung. Take the HIGHEST: the stale-close guard rejects a
        // cooperative close paying less than the attested balance, so the highest attestation is
        // the most protective of the LP.
        uint hi;
        for (uint i; i < exits.length; ++i) {
            _armDeadManExit(channelId, p, exits[i]);
            if (exits[i].checkpointSats > hi) hi = exits[i].checkpointSats;
        }
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
        uint paid = ExitLib.verifyDeadManExit(
            exit.signedExitTx,
            ExitLib.ExitCheck({
                fundingTxId: channels[channelId].fundingTxId,
                fundingVout: channels[channelId].fundingVout,
                fundingSats: channels[channelId].amountSats,
                q:           MuSig2Agg.computeOutputKey(p.lpPubkey, p.hopPubkey),
                cltvDeadline: exit.cltvDeadline
            }),
            _lpPayoutScript(channels[channelId].lpEth),
            exit.prevValues, exit.prevScripts
        );
        if (paid < exit.checkpointSats) revert ExitUnderpaysCheckpoint();

        exitArmedAt[channelId][exit.cltvDeadline] = true;
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
        if (!MuSig2Agg.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert SpliceKeyNotTwoOfTwo();
    }

    /// @notice ANTI-ROLLBACK: the channel's hop records the highest persisted
    ///         channel-monitor `update_id` for `channelId`, monotonically. On reboot the
    ///         hop's enclave reads `freshnessSeq[channelId]` and refuses a locally-loaded
    ///         monitor whose `update_id` is behind — catching a host that serves stale
    ///         sealed channel state (MuSig2 nonce-reuse / revoked-state broadcast). Gated
    ///         to the channel's hop (a foreign caller can't bump the counter to lock the
    ///         enclave out) and STRICTLY monotonic (a replay/rollback of an old value reverts).
    function commitFreshness(bytes32 channelId, uint64 seq) external {
        _onlyHop();
        // (E122) Primary, or the LP's fallback after the staleness window — see `splice`.

        if (seq <= freshnessSeq[channelId]) revert FreshnessNotMonotonic();
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
        managerFreshnessSeq[msg.sender] = seq;
        emit ManagerFreshnessCommitted(msg.sender, seq);
    }

    // markLpFeePaid REMOVED — see the lpFeePaid note above. The BTC-leg fee compounds
    // in-channel (no off-chain native payout ⇒ no double-pay-on-rollback risk ⇒ nothing to mark).

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
    ///           payout output → the BtcVault (via unregisterBtcLp) reconciles delivered =
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
                    MuSig2Agg.computeOutputKey(p.lpPubkey, p.hopPubkey))) > 0)
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
    ///      ⚠️ THIS DELIBERATELY FORBIDS KEY ROTATION. Rotating custody to a new image's keys
    ///      without closing the channel (§E162-rekey-splice) is a REAL and wanted capability, but
    ///      it must UPDATE `keysHash` and must be gated on who may rotate and to what — otherwise
    ///      a compromised hop splices to keys it solely controls and cuts the LP out of its own
    ///      2-of-2. Until that gating is settled, rejecting the change is the safe half.
    function _requireChannelKeys(bytes32 channelId, Types.OpenParams calldata p) private view {
        if (keccak256(abi.encode(p.lpPubkey, p.hopPubkey)) != channels[channelId].keysHash)
            revert ChannelKeysMismatch();
    }

    error ExitUnderpaysCheckpoint();   // the armed exit pays less than it attests

    error ChannelKeysMismatch();   // p.lpPubkey/p.hopPubkey != the keysHash pinned at open

    /// @param p this channel's `OpenParams` — only `lpPubkey`/`hopPubkey` are read, and both
    ///        are checked against the `keysHash` pinned at open.
    function recordClose(
        bytes32 channelId,
        Types.OpenParams calldata p,
        bytes calldata rawCloseTx,
        bytes32 closeBlockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) external nonReentrant whenOpen(channelId) {
        // (E153) THE SPLICE-VS-CLOSE DISCRIMINATOR, REPLACING THE PARTICIPANT GATE.
        // This used to read: "recordClose has no on-chain splice-vs-close discriminator (it
        // can't reconstruct the rotated 2-of-2 keys of the splice's CONTINUING output)" — and
        // therefore restricted recording to the hop or the LP, because a third party could
        // otherwise replay the hop's confirmed SPLICE tx here to force-retire an OPEN channel
        // (delivered=0, splice()/deliver() bricked on whenOpen, an in-flight swap-out stranded).
        // `MuSig2Agg` reconstructs exactly those keys (E129/E142), so the ambiguity is gone:
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
    ) external nonReentrant whenOpen(channelId) {
        address lpEth = channels[channelId].lpEth;
        // (E156/E165) NO `deadline == 0` CHECK: `exitArmedAt` is false for an unarmed deadline,
        // and zero is rejected at arming — so a zero locktime simply fails the membership test
        // below. The state a separate check defended against is unrepresentable.
        uint64 deadline = BitcoinTx.extractLocktime(rawExitTx);
        // (E165) ANY armed deadline retires the channel — the LP pre-signed a ladder at open, so
        // there is no single "current" one. An unarmed locktime is not a dead-man exit at all.
        if (!exitArmedAt[channelId][deadline]) revert NotDeadManExit();
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
    ) external nonReentrant whenOpen(channelId) {
        if (!BitcoinTx.isCommitmentTx(rawCloseTx)) revert NotForceClose();
        _verifyTxSpendsChannel(channelId, rawCloseTx, closeBlockHash, merkleProof, txIndex);
        // delivered=0: lpPayout := the full funded amount (a force close realizes no
        // swap proceeds), retiring the position to on-chain reality. Mints nothing.
        uint total = _finalizeClose(channelId, channels[channelId].amountSats);
        emit ChannelClosed(channelId, total);
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
    ///    `POOLED_USD_BTC` to its liquidity limit. That reaches QU!D holders and other LPs who
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
    /// ⚠️ STILL TRUSTED, AND NAMED SO IT IS NOT MISTAKEN FOR PROVEN: `seller`, `token` and
    ///    `minDeliveredUsd` remain the hop's assertions. What is proven is that the SATS EXIST and
    ///    landed at an address only this protocol controls.
    function settleSwapInProven(
        address seller, address token, uint minDeliveredUsd,
        Types.DepositProof calldata proof,
        bytes calldata rawDepositTx
    ) external nonReentrant {
        _onlyHop();
        (bytes32 txid, uint sats) = _provenDeposit(proof, rawDepositTx);

        // Partials are accepted on this rail: the seller's remainder is refundable trustlessly via
        // the deposit's own CLTV leaf, which is exactly why the on-chain rail can take them and the
        // all-or-nothing LN rail cannot.
        uint consumed = btcVault.creditSwapIn(seller, sats, token, minDeliveredUsd);
        emit SwapInSettled(seller, txid, sats, consumed, token);
    }

    /// @dev Own frame: dedup, SPV inclusion, and the derived-address check. Returns the deposit
    ///      txid (the replay key) and the sats it actually paid this protocol.
    function _provenDeposit(Types.DepositProof calldata proof, bytes calldata rawDepositTx)
        private returns (bytes32 txid, uint sats)
    {
        txid = BitcoinTx.txid(rawDepositTx);
        // Dedup on the deposit OUTPOINT, not a hop-chosen hash: the old rail keyed replay
        // protection on `paymentHash`, a value the hop invents; a txid is a fact.
        if (swapInUsed[txid]) revert SwapInDepositReplay();
        swapInUsed[txid] = true;
        if (!spv.checkTxInclusion(proof.merkleProof, proof.blockHash, txid, proof.txIndex,
                                  ChannelLib.MIN_CONFIRMATIONS)) revert BadSPV();
        sats = ExitLib.verifySwapInDeposit(
            BTC_DEPOSIT_KEY, proof.userRefund, proof.cltvHeight, rawDepositTx);
    }

    function settleSwapIn(address seller, uint sats, address token,
        bytes32 paymentHash, uint minDeliveredUsd, bool requireFull) external nonReentrant {
        _onlyHop();
        // MULTI-HOP attestation authority: a swap-in credit draws the shared
        // POOLED_USD_BTC, so only a GENUINE hop — one that currently owns at least one
        // OPEN channel (i.e. has BTC locked) — may attest, exactly as only the single
        // trusted `hopNode` could before. `openChannelsOf` is the per-hop open-channel
        // count (++ at open, -- at close). Per-hop bounding of pool drainage vs a hop's
        // OWN locked sats is a tracked refinement; the has-an-open-channel gate is the
        // essential authority binding that keeps a random address from crediting.
        // Dedup on the LN HTLC hashlock — one credit per swap-in, ever.
        if (paymentHash == bytes32(0) || swapInUsed[paymentHash])
            revert SwapInReplay();
        swapInUsed[paymentHash] = true;
        // REVERSAL of an on-chain swap-out (paymentHash == its swapId): clear the
        // obligation and free its owed proceeds (pendingSwapOutUsd -= so.usd) BEFORE
        // the credit. This (a) honors the matched -= for the request's += and (b)
        // lets the swap-in solvency gate see the freed reserve, so a reversal is
        // never blocked by its own obligation. CEI: delete state before the call.
        PendingOnchainSwapOut memory so = pendingOnchainSwapOut[paymentHash];
        if (so.sats != 0) {
            // REVERSAL: the refund payee + amount are PINNED to the recorded
            // swap-out (so.swapper / so.sats), NOT the hop-supplied `seller`/`sats`, so
            // a malicious hop can't redirect or short the swapper's refunded principal.
            delete pendingOnchainSwapOut[paymentHash];
            btcVault.subPendingSwapOut(so.usd);
            uint consumedRev = btcVault.creditSwapIn(so.swapper, so.sats, token, minDeliveredUsd);
            // A reversal returns the swapper's OWN principal — all-or-nothing: a partial refund would strand the
            // remainder (the swapper has no deposit/HTLC to reclaim from on this path). requireFull reverts it so
            // the whole reversal rolls back and is retried once the pool can fully honor it (the caller passes true).
            if (requireFull && consumedRev < so.sats) revert SwapInPartialRejected();
            emit SwapInSettled(so.swapper, paymentHash, so.sats, consumedRev, token);
            return;
        }
        // minDeliveredUsd is the hop's attestation of the seller's
        // expected USD; creditSwapIn reverts (rolling back the swapInUsed mark
        // above) if a thin POOLED_USD_BTC can't deliver it — symmetric to the
        // swap-OUT minSats floor, so the seller never eats a short fill BELOW its floor.
        // ABOVE the floor a thin POOLED_USD_BTC can still convert only PART of the input
        // (inventory-bounded); creditSwapIn returns the sats actually converted so the
        // hop refunds the `sats − consumedSats` remainder to the seller (its BTC is held
        // off-chain over the deposit/HTLC — see SwapInSettled).
        uint consumedSats = btcVault.creditSwapIn(seller, sats, token, minDeliveredUsd);
        // ATOMIC full-fill (the LN rail): if the pool converted only PART of `sats` (inventory-bounded), revert
        // the WHOLE settle — the draw + USD delivery roll back, so the hop delivers no USD and FAILS the HTLC,
        // and the seller keeps 100% of their BTC. LN HTLCs are all-or-nothing and the fleet has NO seller LN
        // node to refund a remainder to, so a partial can never be settled on this rail (the seller retries once
        // the reservoir refills). The on-chain rail passes requireFull=false: it accepts partials and refunds the
        // `sats − consumedSats` remainder trustlessly via the deposit's CLTV leaf (SwapInSettled → claim-tx output).
        if (requireFull && consumedSats < sats) revert SwapInPartialRejected();
        emit SwapInSettled(seller, paymentHash, sats, consumedSats, token);
    }

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
        btcVault.subPendingSwapOut(so.usd);
        btcVault.creditSwapIn(so.swapper, so.sats, token, minDeliveredUsd);   // pinned to the recorded swapper
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
        (sats, usd6) = btcVault.creditSwapOut(msg.sender, token, usdAmount, minSats);
        if (sats == 0) revert SwapOutReplay(); // zero/dust fill → unwind the used-mark
        // uint96 packing self-evidently safe (BTC supply ≪ 2^96; 6-dec usd ≪ 2^96/1e6).
        if (sats > type(uint96).max || usd6 > type(uint96).max) revert InvalidParam();
        pendingOnchainSwapOut[swapId] = PendingOnchainSwapOut({
            swapper:           msg.sender,
            sats:              uint96(sats),
            swapperScriptHash: keccak256(swapperScript),
            usd:               uint96(usd6),
            requestBlock:      uint32(block.number)   // starts the self-refund timeout
        });
        // pendingSwapOutUsd += usd6 (proceeds owed to the LP that delivers). creditSwapOut
        // grew POOLED_USD_BTC by the same usd6, so the swap-in FREE reserve
        // (POOLED − pending) is UNCHANGED → spamming requests can't grief the gate.
        // Matched -= on delivery (_settleDelivered) or reversal (settleSwapIn).
        btcVault.addPendingSwapOut(usd6);
        emit SwapOutRequestedOnchain(msg.sender, sats, token, swapId, swapperScript);
    }

    /// @notice Settle an on-chain swap-out: the hop submits the SPV-proven splice-out
    ///         tx that paid the swapper. HOP-GATED ONLY.
    ///         ⚠️ THIS SAID "lpAuth-consented like `splice` (the LP signs THIS exact tx via
    ///         `swapOutDeliverDigest`)". **NO SIGNATURE IS VERIFIED HERE — this function takes
    ///         no signature parameter at all** (E148). Under the delegation model the fleet
    ///         splices as the channel's hop and produces no per-call lpAuth
    ///         (`quid-bridge/swap_out_onchain.rs:221-223`). `swapOutDeliverDigest` REMAINS as
    ///         an off-chain-signing helper — the same status as `openChannelDigest`, which
    ///         also has no on-chain consumer (E148-c) — but nothing signs it today.
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
        bytes calldata swapperScript
    ) external nonReentrant whenOpen(channelId) {
        _onlyHop();
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
        // so.usd is its dollar leg. _settleDelivered draws POOLED_USD_BTC + clears
        // pendingSwapOutUsd by so.usd (the matched -= for the request's +=).
        btcVault.resizeBtcLp(lpEth, shrinkSats, shrinkSats > sats ? shrinkSats - sats : 0, so.usd);
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
        _requireRecipientPoP(msg.sender, xOnlyKey, pop);
        _registerBtcRecipient(msg.sender, xOnlyKey);
    }

    /// Shared by `setBtcRecipient` (non-channel Aux users) and `openChannel` (channel LPs,
    /// set from the committed P2TR upfront-shutdown script). `xOnlyKey` is the LP's 32-byte
    /// x-only taproot key; the payout is key-path P2TR `0x5120||xOnlyKey`. A malformed key
    /// makes only the LP's OWN payout unspendable (its loss), so on-chain we require only
    /// nonzero (all 32 bytes are the key — no high-bytes-zero mask).
    /// @notice (E138) The message a payout key signs to prove possession. Public so the LP's
    ///         wallet signs EXACTLY what the contract checks rather than a reconstruction.
    function btcRecipientPoPDigest(address lpEth) public view returns (bytes32) {
        return sha256(abi.encode(
            keccak256("BTCChannels.btcRecipient.pop.v1"), block.chainid, address(this), lpEth));
    }

    /// @dev (E138) Own frame — `openChannel` is at the legacy stack limit.
    function _requireRecipientPoP(address lpEth, bytes32 xOnlyKey, bytes calldata sig) private view {
        if (sig.length != 64) revert NotPubkeyHash();
        bytes32 r; bytes32 s_;
        assembly { r := calldataload(sig.offset) s_ := calldataload(add(sig.offset, 32)) }
        if (!MuSig2Agg.schnorrVerify(xOnlyKey, r, s_, btcRecipientPoPDigest(lpEth)))
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
