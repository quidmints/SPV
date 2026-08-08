// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBtcVaultBridge} from "./imports/Interfaces.sol";
import {Types} from "./imports/Types.sol";
import {ISPVGateway} from "./spv/interfaces/ISPVGateway.sol";
import {BitcoinTx} from "./imports/BitcoinTx.sol";
import {ChannelLib} from "./imports/ChannelLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MuSig2Agg} from "./imports/MuSig2Agg.sol";

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
//  NO secp256k1 EC: it byte-matches the lpAuth-committed Q, so it does NOT prove
//  on-chain that Q == KeyAgg(lp, hop). That 2-of-2 genuineness rests on the
//  off-chain MuSig2 keygen (the LP recomputes Q from its own + the hop's key
//  before signing lpAuth) + the hop-only msg.sender gate. SGX attestation IS wired
//  as the trust anchor: `_requireAttested`/`_authorizedHop` call
//  `AttestedHopRegistry.isAttested` on the hop money-paths (openChannel, settleSwapIn,
//  emitDeadManExit). It is GOVERNANCE-ARMED — a no-op until `setHopRegistry` pins the
//  live registry, so any deployment/regtest that never pins it falls back to the
//  `openChannelsOf` gate (owns an OPEN channel = has real BTC locked). Pinning the
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
interface IAttestedHopRegistry { function isAttested(address hop) external view returns (bool); }

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
    // BtcVault — the regrouped BTC side (LP register/close + swap credit). The
    // constructor still accepts the legacy (_aux, _vogue) pair for call-site
    // compatibility; both now point at the SAME BtcVault, bound here.
    IBtcVaultBridge public immutable btcVault;
    // MULTI-HOP: there is NO single global `hopNode`. Each channel records the hop
    // (EVM address) that opened it (`channel.hop`). ⚠️ UPDATED 2026-08-07 (E122): that hop is
    // no longer the SOLE authority — splice and swap-out delivery now gate on
    // `_authorizedHopForChannel`, which ALSO admits the LP's current `delegatedAuthority` and,
    // after staleness or a disavowal, its named fallback. The partition still holds (one
    // delegation per LP), and a primary/fallback overlap during the window is safe: splices
    // self-serialise on the funding UTXO. Historically this said SOLE authority
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
    // USD pool, mirroring the old single-`hopNode` trust with per-instance scope.
    mapping(address => uint) public openChannelsOf;

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
    // A delegation exists iff delegationVersion[lpEth] > 0.
    mapping(address => uint64) public delegationVersion;
    // `delegatedAuthority` is who the LP trusts to operate its channels — EITHER a
    // concrete hop address (FAMILY/self-host: pinned exactly), OR THE single Safe-governed
    // `hopRegistry` address (FLEET: any hop it attests — so a governance rotation of
    // the enclave-generated hop key, pinned post-deploy, is ONE Safe tx every fleet LP
    // auto-follows with NO re-signing). One field, no mode flag. Payout still pins to
    // btcRecipientOf in BOTH cases ⇒ theft-proof regardless of which hop is designated.
    mapping(address => address) public delegatedAuthority;

    // (E122) LP-NAMED FALLBACK. `delegatedAuthority` is the primary; this hop may act on the
    // LP's channel ONLY once the primary has stopped heartbeating for FALLBACK_STALENESS_BLOCKS.
    // Chosen over a registry+attestation model deliberately: the fallback is named by the LP,
    // so it can never become standing-over-everyone, and it drops the DCAP verifier + on-chain
    // PCCS mirror (two third parties beyond Intel) out of the trust chain entirely.
    // It also fixes an inversion in registry mode, where ANY attested hop could refresh the
    // heartbeat forever and keep an LP's escape hatch permanently un-maturable.
    mapping(address => address) public fallbackAuthority;

    // Block of the last heartbeat (`emitDeadManExit`) for a channel; seeded at open so a
    // primary that NEVER heartbeats still hands over rather than stranding the LP.
    mapping(bytes32 => uint64) public lastHeartbeatBlock;

    // ~1 hour at 12s. The primary must be down this long before the fallback may act.
    uint64 public constant FALLBACK_STALENESS_BLOCKS = 300;

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
    mapping(bytes32 => uint64) public deadManDeadline;

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
    error SpliceKeyNotTwoOfTwo();     // (E129) new funding Q is not KeyAgg(lpPubkey, hopPubkey)
    error FundingKeyNotTwoOfTwo();    // (E142) initial funding Q is not KeyAgg(lpPubkey, hopPubkey)
    error ForeignSpliceOutput();      // a withdrawal splice paid value somewhere other than the
                                      // new funding output or the LP's committed btcRecipientOf
    error FreshnessNotMonotonic();    // a freshness commit must strictly increase (rollback/replay guard)
    error ManagerFreshnessNotMonotonic(); // a channel-manager freshness commit must strictly increase
    error MigrationNonceAlreadyUsed();    // a MigrationAuth nonce may be consumed at most once (anti-replay)
    error NotDelegatedHop();          // (B) caller is not the LP's delegated hop (open) — see registerDelegation
    error StaleDelegation();          // (B) a delegation's version must strictly increase (revoke/rollback guard)

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
    event DelegationRegistered(address indexed lpEth, address indexed authority, bytes32 btcRecipient, uint64 version);
    event FallbackRegistered(address indexed lpEth, address indexed fallbackHop, uint64 version);
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
        if (openChannelsOf[ch.hop] != 0) openChannelsOf[ch.hop] -= 1; // hop no longer owns this open channel
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

    /// @param _hopNode LEGACY / no-op. Retained only to keep the 4-arg constructor
    ///        signature (deployers unchanged). There is no global hop under the
    ///        multi-hop model; authority is per-channel (`channel.hop`).
    constructor(address _spv, address _aux, address _vogue, address _hopNode)
        Ownable(msg.sender)
    {
        spv = ISPVGateway(_spv);
        // The BTC side regrouped into a single BtcVault; both legacy params now
        // designate it (deployers pass the BtcVault address for _vogue, falling
        // back to _aux). Behaviour-identical to the old split aux/vogue wiring.
        btcVault = IBtcVaultBridge(_vogue != address(0) ? _vogue : _aux);
        _hopNode; // silence unused-param (legacy signature retained)
    }

    // ─── Attested-hop gate ──────────────────────────────────────
    // The whitelist that decides who may become a shared-pool hop. UNSET (0) ⇒ the gate is OFF (the permissionless
    // open behaviour, for testnet / pre-attestation bootstrap). Governance PINS it ONCE to the live registry to turn
    // the gate on; PIN-ONCE (can never be un-set or repointed) so a later compromised owner cannot disable it.
    address public hopRegistry;
    function setHopRegistry(address r) external onlyOwner {
        require(hopRegistry == address(0) && r != address(0), "pinned"); // one-way: off → on, forever
        hopRegistry = r;
    }
    /// Revert unless `hop` is an attested shared-pool hop — a no-op while the registry is unset (bootstrap).
    function _requireAttested(address hop) internal view {
        address reg = hopRegistry;
        if (reg != address(0)) require(IAttestedHopRegistry(reg).isAttested(hop), "hop !attested");
    }

    // ═════════════════════════════════════════════════════════════════
    //  OPEN — anyone submits the raw funding tx + SPV proof + lpAuth.
    //
    //  ch.lpEth = the recovered signer of lpAuth (NOT msg.sender), so a
    //  relayer/front-runner cannot redirect the credited pool position.
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
    function delegationDigest(address authority, bytes32 btcRecipient, uint64 version)
        public view returns (bytes32)
    {
        return keccak256(abi.encode(
            keccak256("BTCChannels.delegation.v1"),
            block.chainid,
            address(this),
            authority,
            btcRecipient,
            version
        ));
    }

    /// @notice (E122) Digest for the LP's OPTIONAL fallback hop. SEPARATE from the primary
    ///         delegation on purpose: folding it into `delegationDigest` would have been tidier
    ///         but breaks the v1 wire format shared by 19 Solidity call sites, the Rust `e2e_ffi`
    ///         signer (`BtcSelfManaged.t.sol:309`) and the SPA ABI — three codebases for a field
    ///         most LPs will leave unset. Additive keeps them all working.
    ///         It is still LP-SIGNED, which is the property that matters: the operator relaying
    ///         the gasless call must not be able to name the fallback itself.
    function fallbackDigest(address fallbackHop, uint64 version) public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("BTCChannels.fallback.v1"),
            block.chainid,
            address(this),
            fallbackHop,
            version
        ));
    }

    /// @notice (B) Register / rotate / revoke an LP's delegation. PERMISSIONLESS submit —
    ///         the operator relays the LP's cold signature (gasless for the LP). Recovers
    ///         lpEth, requires a strictly-higher version (rollback/replay guard), pins the
    ///         `authority` (a concrete hop, or a registry contract that attests hops) +
    ///         `btcRecipient` payout script (LOCKED — the same pin recordClose/
    ///         _withdrawalPayout enforce). Sign a higher version with authority=0 to revoke.
    /// @dev ✅ NO `msg.sender` CHECK, AND THAT IS THE POINT: authority is the LP's SIGNATURE,
    ///      not the caller. So an LP that wants to do NO ongoing work pre-signs a re-delegation
    ///      naming a successor hop at setup, hands the bytes to a watchtower / the successor /
    ///      a family member, and never acts again — that holder submits it if the primary turns
    ///      unresponsive or obstructive. **This is why no separate "disavow" entrypoint exists:
    ///      a pre-signed re-delegation already IS the on-demand hand-over, and a second path to
    ///      the same capability would be surface for nothing.**
    ///      ⚠️ The trade, so it is chosen rather than discovered: whoever holds the pre-signed
    ///      bytes can switch operators AT ANY TIME, not only on misbehaviour. Bounded — payouts
    ///      still pin to `btcRecipientOf`, so the worst case is churn, never theft.
    function registerDelegation(address authority, bytes32 btcRecipient, uint64 version, bytes calldata sig)
        external
    {
        address lpEth = ECDSA.recover(delegationDigest(authority, btcRecipient, version), sig);
        if (lpEth == address(0)) revert InvalidParam();
        if (version <= delegationVersion[lpEth]) revert StaleDelegation();
        if (btcRecipientLocked[lpEth] && btcRecipientOf[lpEth] != btcRecipient) revert WrongBtcRecipient();
        delegatedAuthority[lpEth] = authority;
        delegationVersion[lpEth] = version;
        _registerBtcRecipient(lpEth, btcRecipient);
        btcRecipientLocked[lpEth] = true;
        emit DelegationRegistered(lpEth, authority, btcRecipient, version);
    }

    /// @notice (E122) Name the LP's fallback hop, gaslessly, from a cold LP signature. Reuses
    ///         `delegationVersion` as the monotonic guard so an old fallback cannot be replayed
    ///         over a newer one, and requires a delegation to exist first — a fallback with no
    ///         primary has nothing to fall back FROM.
    function registerFallback(address fallbackHop, uint64 version, bytes calldata sig) external {
        address lpEth = ECDSA.recover(fallbackDigest(fallbackHop, version), sig);
        if (lpEth == address(0)) revert InvalidParam();
        if (delegationVersion[lpEth] == 0) revert NotDelegatedHop();     // primary must exist
        if (version <= delegationVersion[lpEth]) revert StaleDelegation();
        // Equal to the primary is a no-op that READS as protection — reject rather than store.
        if (fallbackHop == delegatedAuthority[lpEth]) revert InvalidParam();
        fallbackAuthority[lpEth] = fallbackHop;
        delegationVersion[lpEth] = version;
        emit FallbackRegistered(lpEth, fallbackHop, version);
    }

    /// @dev (E122) Authorized to act on THIS channel: the primary always, or the LP's named
    ///      fallback once the primary has gone quiet for `FALLBACK_STALENESS_BLOCKS`.
    ///
    ///      ⚠️ WHAT THIS PROTECTS AGAINST, AND WHAT IT DOES NOT. The clock is refreshed by any
    ///      primary action — splice, delivery, or heartbeat. It therefore detects a DEAD
    ///      primary, not a MALICIOUS one: `emitDeadManExit` is emit-only and cheap, so a hop
    ///      that is alive but refusing to work can keep the clock fresh indefinitely and the
    ///      fallback never activates.
    ///
    ///      That is not an oversight to be patched. Excluding the heartbeat from the clock
    ///      would make a QUIET channel — no trades, nothing to splice — look dead and trigger
    ///      a false hand-over. **On-chain liveness cannot distinguish "alive and idle" from
    ///      "alive and refusing", because both look identical from here.**
    ///
    ///      So the LP has two remedies for two threat models: this fallback is AUTOMATIC
    ///      protection against a dead primary, and re-delegation (`registerDelegation` at a
    ///      higher version, cold-signed and gasless) is MANUAL protection against a malicious
    ///      one. Do not extend this gate to try to cover the second — it cannot.
    ///      `lastHeartbeatBlock` is seeded at open, so a primary that never heartbeats still
    ///      hands over instead of stranding the LP. Channel-scoped on purpose — `openChannel`
    ///      keeps using `_authorizedHop`, because a channel that does not exist has no
    ///      liveness history and a fallback must not be able to open one.
    function _authorizedHopForChannel(bytes32 channelId, address lpEth, address hop)
        internal view returns (bool)
    {
        if (_authorizedHop(lpEth, hop)) return true;
        address fb = fallbackAuthority[lpEth];
        if (fb == address(0) || hop != fb) return false;
        uint64 last = lastHeartbeatBlock[channelId];
        return last != 0 && block.number > uint(last) + FALLBACK_STALENESS_BLOCKS;
    }

    /// @dev (B) Is `hop` authorized to operate for `lpEth`? Either the LP pinned it
    ///      exactly (family/self-host hop — direct match), or the LP delegated to THE
    ///      Safe-governed `hopRegistry` and it currently attests `hop` (fleet — a
    ///      governance rotation needs no LP re-sign). `isAttested` is `view` ⇒ STATICCALL.
    ///      No delegation (authority 0) ⇒ false.
    function _authorizedHop(address lpEth, address hop) internal view returns (bool) {
        address a = delegatedAuthority[lpEth];
        if (a == address(0)) return false;                          // no delegation
        if (a == hop) return true;                                  // pinned hop (direct)
        return a == hopRegistry && hopRegistry != address(0)
            && IAttestedHopRegistry(hopRegistry).isAttested(hop);   // fleet: THE registry attests
    }

    function openChannel(
        Types.OpenParams calldata p,
        bytes calldata rawFundingTx,
        bytes32[] calldata fundingMerkleProof,
        address lpEth
    ) external nonReentrant returns (bytes32 channelId)
    {
        // (B) DELEGATED OPEN — the LP runs nothing. `lpEth` owns the position; the
        // submitter must be a hop the LP delegated to (registerDelegation) — its pinned
        // family hop, or (FLEET_HOP) any hop the Safe-governed hopRegistry attests.
        // channel.hop = msg.sender (below) owns the later splice/deliver/close. Security
        // is identical to the retired per-open lpAuth: openChannelBody SPV-proves +
        // taproot byte-matches (0x5120||Q) the funding, and btcRecipientOf (pinned at
        // delegation) is the sole payout — a non-delegated hop can't open, and no hop can
        // redirect funds (payout pin). Unproven-funding-key-control residual.
        _requireAttested(msg.sender);   // only an attested hop may become a shared-pool hop (off until pinned)
        if (!_authorizedHop(lpEth, msg.sender)) revert NotDelegatedHop();
        // ONE OPEN CHANNEL PER lpEth (see hasOpenBtcChannel): a 2nd open for an LP
        // that already has one would form the aggregate position the per-channel
        // close mis-attributes. Splice resizes the existing channel; more positions
        // use more addresses. This makes the over-mint/wipe bug unrepresentable.
        if (hasOpenBtcChannel[lpEth]) revert OneChannelPerLp();

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
        if (!MuSig2Agg.isTwoOfTwoOutputKey(p.lpPubkey, p.hopPubkey, p.fundingTaproot))
            revert FundingKeyNotTwoOfTwo();
        if (channels[channelId].amountSats != 0) revert AlreadyOpen();
        // MULTI-HOP: bind this channel to its opening hop + bump its open-channel count.
        channel.hop = msg.sender;
        openChannelsOf[msg.sender] += 1;
        // OUTPOINT-UNIQUENESS: this confirmed funding UTXO may back only ONE channel
        // (else the same on-chain BTC double-counts as backing under two channelIds).
        _useOutpoint(channel.fundingTxId, channel.fundingVout);

        // (B) The LP's BTC payout key (btcRecipientOf) is pinned + LOCKED at
        // registerDelegation time — it is the SAME committed key-path P2TR shutdown
        // script recordClose/_withdrawalPayout enforce, and `_authorizedHop` above
        // already required a delegation to exist, so it is guaranteed set here (no
        // per-open lpBtcPayoutHash). recordClose attributes the LP's cooperative-close
        // balance to outputs paying that script; a hop can never redirect the payout.
        channels[channelId] = channel;
        hasOpenBtcChannel[channel.lpEth] = true; // one-per-lpEth (cleared on close)
        lastHeartbeatBlock[channelId] = uint64(block.number); // (E122) start the liveness clock
        totalSatsLocked += channel.amountSats;

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
            channelId, channel.lpEth, channel.hop, channel.amountSats,
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
        // (B) Authorization. ⚠️ UPDATED 2026-08-07 (E122): this said "`channel.hop` … so ONLY
        // that hop can resize". No longer true — the gate is `_authorizedHopForChannel`, which
        // also admits the LP's current `delegatedAuthority` and, after staleness or an explicit
        // disavowal, its named fallback. Still bounded the same way: every payout output pins
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
        // (E122) Primary, OR the LP's named fallback after FALLBACK_STALENESS_BLOCKS of silence.
        // Widening this is REQUIRED, not optional: a fallback that could only heartbeat would
        // keep the LP's dead-man exit from maturing while being unable to operate the channel —
        // strictly worse than no fallback. Bounded by the same guarantees as the primary: the
        // splice is SPV-proven and every payout output pins to `btcRecipientOf`.
        if (!_authorizedHopForChannel(channelId, channels[channelId].lpEth, msg.sender))
            revert NotChannelHop();
        if (p.amountSats == channels[channelId].amountSats) revert SpliceUnchanged();
        lastHeartbeatBlock[channelId] = uint64(block.number);   // (E122) work IS liveness
        // Verify + rotate + (grow|shrink) in its own frame (legacy stack, no via_ir); returns the grow delta.
        uint grewBy = _applySplice(channelId, p, rawSpliceTx, spliceMerkleProof);
        // FEE-INTO-CHANNEL: the hop may mark up to `grewBy` of this grow as BTC-leg fees it is FUNDING in —
        // they compound into the LP's position (registerBtcLp already grew pooled by the full delta, so `delivered`
        // stays invariant); the bigger pooled share grows the LP's coop-close payout. (An earlier version of this
        // line added "and the hop keysends the same sats onto the LP's LN balance off-chain" — that leg is
        // OBSOLETE under delegation, where the LP runs no LN node.) `<= grewBy` ⇒ it
        // can only settle fees it actually spliced in (no theft); the Vault clamps to the real owed (no over-settle).
        if (feeSettleSats > 0) {
            require(feeSettleSats <= grewBy, "fee>splice");
            btcVault.settleBtcFeesOwed(channels[channelId].lpEth, feeSettleSats);
        }
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
    ///         `_authorizedHop`, so only a hop the LP delegated to (or, in fleet mode,
    ///         any hop the Safe-governed registry currently attests) may emit; a hop
    ///         de-attested after opening can't keep refreshing. The payout is pinned to
    ///         `btcRecipientOf` INSIDE the signed bytes, so this can only publish a
    ///         backstop that pays the LP — it can never redirect funds. Emit-only (no
    ///         external call, no fund movement) ⇒ no reentrancy surface.
    function emitDeadManExit(
        bytes32 channelId,
        uint64  cltvDeadline,
        uint    checkpointSats,
        bytes   calldata signedExitTx
    ) external whenOpen(channelId) {
        Types.BTCChannel storage ch = channels[channelId];
        _requireAttested(msg.sender);
        if (!_authorizedHopForChannel(channelId, ch.lpEth, msg.sender)) revert NotDelegatedHop();
        lastHeartbeatBlock[channelId] = uint64(block.number);   // (E122) the liveness signal
        deadManDeadline[channelId] = cltvDeadline;
        // Persist what was previously event-only. The tally restarts because the new
        // attestation already reflects every payout that preceded it.
        checkpointOf[channelId] = checkpointSats;
        paidOutSinceCheckpoint[channelId] = 0;
        emit DeadManExitEmitted(channelId, ch.lpEth, cltvDeadline, checkpointSats, signedExitTx);
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
        // (E122) Primary, or the LP's fallback after the staleness window — see `splice`.
        if (!_authorizedHopForChannel(channelId, channels[channelId].lpEth, msg.sender))
            revert NotChannelHop();
        lastHeartbeatBlock[channelId] = uint64(block.number);   // (E122) work IS liveness
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
        if (openChannelsOf[msg.sender] == 0) revert NotChannelHop();
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
    function recordClose(
        bytes32 channelId,
        bytes calldata rawCloseTx,
        bytes32 closeBlockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) external nonReentrant whenOpen(channelId) {
        // PARTICIPANT-GATE (SPV front-run fix): a SPLICE / swap-out-delivery tx
        // spends the SAME funding UTXO a cooperative/force close does, and recordClose
        // has no on-chain splice-vs-close discriminator (it can't reconstruct the
        // rotated 2-of-2 keys of the splice's CONTINUING output). If recording were
        // permissionless, a third party could replay the hop's confirmed splice tx here
        // to force-retire an OPEN channel — delivered=0, the hop's splice()/deliver()
        // bricked on whenOpen, and an in-flight on-chain swap-out stranded (swapper got
        // BTC, settlement now impossible). Restrict recording to the channel's two
        // participants: the hop, or the LP via its own lpEth (preserving the LP's
        // liveness path when the hop is offline). Neither rationally griefs — the LP
        // would forfeit its OWN proceeds, and the hop is the already-trusted operator.
        if (msg.sender != channels[channelId].hop && msg.sender != channels[channelId].lpEth)
            revert NotChannelHop();
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
    ///         AUTHORITY: the LP only. It is the party still present once the fleet is gone, and
    ///         it cannot grief itself — retiring forfeits its own position (same reasoning
    ///         `recordClose` gives for participant-gating). This deliberately does NOT accept a
    ///         splice tx that happened to share the deadline's locktime: a splice recreates the
    ///         funding output and the channel continues, so retiring on one would strand it.
    function recordDeadManExit(
        bytes32 channelId,
        bytes calldata rawExitTx,
        bytes32 exitBlockHash,
        bytes32[] calldata merkleProof,
        uint    txIndex
    ) external nonReentrant whenOpen(channelId) {
        address lpEth = channels[channelId].lpEth;
        if (msg.sender != lpEth) revert NotLP();
        uint64 deadline = deadManDeadline[channelId];
        if (deadline == 0) revert NoDeadManExit();
        _verifyTxSpendsChannel(channelId, rawExitTx, exitBlockHash, merkleProof, txIndex);
        if (BitcoinTx.extractLocktime(rawExitTx) != deadline) revert NotDeadManExit();
        // Same attribution as a cooperative close: sum every output paying the LP's committed
        // P2TR. The exit pays `btcRecipientOf` by construction, pinned inside the signed bytes.
        uint total = _finalizeClose(channelId, _lpFinalBalance(lpEth, rawExitTx));
        emit ChannelClosed(channelId, total);
    }

    error NoDeadManExit();   // no dead-man exit was ever emitted for this channel
    error NotDeadManExit();  // tx locktime != the recorded deadManDeadline

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
    function settleSwapIn(address seller, uint sats, address token,
        bytes32 paymentHash, uint minDeliveredUsd, bool requireFull) external nonReentrant {
        // MULTI-HOP attestation authority: a swap-in credit draws the shared
        // POOLED_USD_BTC, so only a GENUINE hop — one that currently owns at least one
        // OPEN channel (i.e. has BTC locked) — may attest, exactly as only the single
        // trusted `hopNode` could before. `openChannelsOf` is the per-hop open-channel
        // count (++ at open, -- at close). Per-hop bounding of pool drainage vs a hop's
        // OWN locked sats is a tracked refinement; the has-an-open-channel gate is the
        // essential authority binding that keeps a random address from crediting.
        if (openChannelsOf[msg.sender] == 0) revert NotChannelHop();
        _requireAttested(msg.sender);   // defence-in-depth: a hop de-attested AFTER opening can't keep crediting
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
    function requestSwapOutOnchain(
        address token, uint usdAmount, uint minSats, bytes32 swapId, bytes calldata swapperScript
    ) external nonReentrant returns (uint sats) {
        if (swapId == bytes32(0) || swapOutUsed[swapId]) revert SwapOutReplay();
        // Symmetric dedup: a swapId that collides with an already-used swap-IN key
        // (swapInUsed is set by settleSwapIn AND by a delivered swap-out) would be BOTH
        // undeliverable (deliverSwapOutOnchain reverts on swapInUsed) AND unreversible
        // (settleSwapIn reverts on swapInUsed) → the swapper's USD would strand with no
        // recovery. Reject it up front, BEFORE creditSwapOut pulls the USD.
        if (swapInUsed[swapId]) revert SwapOutReplay();
        // P2TR ONLY (tightened 2026-07-27). This was a loose 22..34 length range that also admitted
        // P2WPKH (22), P2PKH (25) and P2WSH (34) — the last outlier in a protocol that is taproot
        // everywhere else: the funding output is byte-matched as `0x5120||Q` (BitcoinTx:281,
        // ChannelLib:529) and the LP payout script is built as `0x51 0x20 || btcRecipientOf` (:506).
        // A key-path P2TR scriptPubKey is EXACTLY `OP_1 (0x51) PUSH32 (0x20) || 32-byte x-only key`,
        // so check the prefix, not just a plausible length — a length-only test accepts any 34-byte
        // blob, including a P2WSH script the rest of the stack cannot produce or match.
        if (swapperScript.length != 34
            || swapperScript[0] != bytes1(0x51) || swapperScript[1] != bytes1(0x20)) revert InvalidParam();
        // (E131) The PREFIX check above says it is shaped like P2TR; it says nothing about the
        // 32 bytes after it. Without this, a malformed key makes the delivery output unspendable
        // — the hop SPV-proves payment to it, the obligation settles, the delivering LP is paid,
        // and the swapper's BTC is burned while the system records a successful delivery.
        if (!BitcoinTx.isValidXOnlyKey(bytes32(swapperScript[2:34]))) revert InvalidParam();
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
    ///         tx that paid the swapper. Hop-gated + lpAuth-consented like `splice`
    ///         (the LP signs THIS exact tx via `swapOutDeliverDigest`). Verifies the tx
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
        // (B) Authorization = the channel's HOP GATE (channel.hop was fixed at open to a
        // delegated hop). The retired per-delivery lpAuth was redundant: the swapper's BTC
        // payment is SPV-proven below, the shrink pins the delivered slice to the on-chain
        // obligation, and any withdrawal output still pins to btcRecipientOf.
        if (msg.sender != channels[channelId].hop) revert NotChannelHop();
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
        // Settle in a fresh frame: the calldata params (p / rawSpliceTx / proof / lpAuth)
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
    function setBtcRecipient(bytes32 xOnlyKey) external {
        // A channel LP's payout is pinned by its channels (see btcRecipientLocked);
        // only non-channel swap users may set/update it freely. `xOnlyKey` = the LP's
        // 32-byte x-only taproot key (key-path P2TR payout, `0x5120||xOnlyKey`).
        if (btcRecipientLocked[msg.sender]) revert BtcRecipientLockedErr();
        _registerBtcRecipient(msg.sender, xOnlyKey);
    }

    /// Shared by `setBtcRecipient` (non-channel Aux users) and `openChannel` (channel LPs,
    /// set from the committed P2TR upfront-shutdown script). `xOnlyKey` is the LP's 32-byte
    /// x-only taproot key; the payout is key-path P2TR `0x5120||xOnlyKey`. A malformed key
    /// makes only the LP's OWN payout unspendable (its loss), so on-chain we require only
    /// nonzero (all 32 bytes are the key — no high-bytes-zero mask).
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
