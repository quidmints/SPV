
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Types {
    /// @notice Vogue
    /// self-managed LP
    struct SelfManaged {
        uint created;
        address owner;
        int24 lower;
        int24 upper;
        int liq;
    }

    /// @notice Vogue LP deposit...
    /// MasterChef-style fee tracking
    struct Deposit { uint pooled;
        uint usd_owed;
        uint fees_tok;
        uint fees_usd;
    }

    /// @notice Native BTC channel — EVM funding/close ANCHOR only.
    ///
    /// Standard-LDK model: the channel's commitment state, revocation, HTLC
    /// resolution, and penalty enforcement all live on Bitcoin/BOLT (LDK
    /// justice txs + watchtowers), NOT on the EVM. The EVM keeps only what it
    /// needs to bridge the channel to the BTC pool position:
    ///   • open  — SPV-prove the 2-of-2 funding UTXO exists → credit the LP's
    ///             BTC pool position (Vogue.registerBtcLp).
    ///   • close — SPV-prove the funding UTXO was spent (cooperative close or
    ///             LP-refund) → retire the position (Vogue.unregisterBtcLp).
    ///
    /// There is deliberately NO commitRoot / latestCommitNum / revocationPoint
    /// / htlcListHash / redeemScriptHash / penalty machinery here — that was
    /// the EVM-anchored layer LDK makes redundant, and it forced a custom LDK
    /// fork. Disputes are Bitcoin-native.
    ///
    /// FIELDS:
    /// `amountSats` — the LP's locked sats == their BTC pool-backing position.
    /// `fundingTxId`/`fundingVout` — the funding UTXO (FIXED for the channel's
    /// EVM life; the EVM never tracks per-commitment respends — those are
    /// off-chain BOLT state). The close proof checks a tx spends this outpoint.
    /// `lpEth` — LP's Ethereum address (recovered signer of openChannel's
    /// lpAuth); owns the pool position and is the close recipient.
    /// `status`: 0 = open, 2 = closed.
    /// (No `hopEth`: it was always the global `hopNode` and never read — see
    /// ChannelLib. The counterparty is surfaced via the ChannelOpened event.)
    ///
    /// Standard LDK channel — NO `selfRefundTime`/CLTV-refund. Unilateral
    /// recovery is an LDK force-close on Bitcoin (commitment tx + justice), not a
    /// bespoke EVM-anchored timelock. The funding 2-of-2 uses the two PER-CHANNEL
    /// LDK funding pubkeys (lp + hop), sorted — matching `make_funding_redeemscript`.
    ///
    /// Identity fields surfaced only via the ChannelOpened event, not stored:
    /// lpPubkey, hopPubkey (33-byte each), fundingBlockHash, fundingBlockHeight.
    struct BTCChannel {
        uint    amountSats;
        bytes32 fundingTxId;
        address lpEth;
        uint32  fundingVout;
        uint8   status;
        // MULTI-HOP: the hop (EVM address) that opened this channel — set to
        // msg.sender at open, and the SOLE authority for this channel's splice /
        // swap-out delivery / swap-in attestation / cooperative recordClose. There
        // is no longer a single global `hopNode`: each channel is bound to its own
        // hop so independent SGX instances (fleet, self-hosted, family-plan) coexist
        // against the same contracts without one being able to act on another's
        // channels. The genuine-party binding is proven at open by a BIP-340 Schnorr
        // signature under the funding key Q (see BTCChannels.openChannel/taprootAuth).
        address hop;
        /// (E153) `keccak256(abi.encode(lpPubkey, hopPubkey))`, pinned at open.
        /// ⚠️ WHY THIS AND NOT A RE-DERIVATION OF `channelId`: `channelId` is
        /// `keccak256(lpPubkey, hopPubkey, fundingTxId, vout)` over the ORIGINAL funding
        /// outpoint, and `_verifySplice` ROTATES that outpoint — so after any splice the
        /// stored `fundingTxId`/`fundingVout` can no longer reproduce `channelId`, and a
        /// key check built on re-derivation fails for exactly the channels most likely to
        /// be closed. This binds the keys to the channel independently of rotation.
        /// It exists so `recordClose` can reconstruct the 2-of-2 and tell a SPLICE from a
        /// CLOSE — which is what lets recording be PERMISSIONLESS instead of restricted to
        /// the hop or the LP.
        bytes32 keysHash;
    }

    /// @notice Params for BTCChannels.openChannel; lives here so ChannelLib can
    /// reference the same struct without a circular file dependency.
    /// `hopPubkey` is the hop's PER-CHANNEL LDK funding pubkey (33-byte) — the
    /// 2-of-2 uses the two per-channel keys, not a fixed hop identity key.
    ///
    /// the channel funds a key-path MuSig2 P2TR output
    /// `0x5120||fundingTaproot`. `fundingTaproot` is the 32-byte x-only key-path
    /// aggregate `Q = lift_x(KeyAgg(KeySort(lp,hop))) + H_TapTweak(agg)·G` (empty
    /// merkle root). The contract byte-matches the SPV-proven funding output against
    /// `0x5120||Q` AND proves `Q == TapTweak(KeyAgg(KeySort(lp,hop)))` on-chain via
    /// `MuSig2Agg` (E129/E142), so both named keys are provably inside it.
    /// ⚠️ TWO CLAIMS THAT STOOD HERE ARE RETIRED, NOT RELOCATED: "the contract does NO
    /// secp256k1 EC math" is false, and "the LP's lpAuth signs the whole OpenParams"
    /// describes a mechanism removed when `openChannel` moved to `(…, address lpEth)` gated
    /// on `_authorizedHop` — `lpAuth` is not a parameter anywhere (E149). Q is bound by the
    /// EC proof now, not by consent to bytes
    /// — and spending the 2-of-2 still requires both parties' MuSig2 signatures
    /// (Bitcoin-enforced, SPV-verified at close). `lpPubkey`/`hopPubkey` remain the
    /// channel identity (channelId + btcRecipient derivation).
    struct OpenParams {
        bytes32 fundingBlockHash;
        uint64  fundingBlockHeight;
        uint    fundingTxIndex;
        bytes   lpPubkey;
        bytes   hopPubkey;
        uint    amountSats;
        bytes32 fundingTaproot;   // 32-byte x-only MuSig2 key-path aggregate Q
    }

    /// @notice (E157) The LP's consent, carried BY the open instead of pre-registered.
    ///
    /// `registerDelegation` existed to establish two things before any channel could open: WHO the
    /// `lpEth` behind a position is, and WHERE its BTC pays out. Both are supplied here and
    /// authenticated inline, so the standing registration — and every piece of state that existed
    /// only to keep it safe — deletes.
    ///
    /// 🔑 WHY THERE IS NO `version`. `delegationVersion` was a monotonic counter guarding a
    /// STANDING grant against replay and rollback. This signature is not standing: it commits to
    /// THIS channel's funding outpoint, and `_useOutpoint` already enforces that a confirmed
    /// funding UTXO backs at most one channel, ever. **Replaying it is not defeated by a counter,
    /// it is arithmetically impossible** — there is no second channel for the bytes to open.
    /// ⇒ The counter's other job (revocation) is also covered: an unused signature binds an
    /// outpoint the LP simply never funds, and a smart wallet can invalidate it by rotating owners.
    ///
    /// `lpSig` is checked with `SignatureChecker`, so ONE path serves both LP kinds — EOAs take the
    /// cheap ECDSA branch, Safes take ERC-1271. The EOA/smart-wallet entrypoint split existed only
    /// because `ECDSA.recover` RETURNS a signer while ERC-1271 can only CONFIRM one; supplying
    /// `lpEth` explicitly (as the `For` variant already did) removes the asymmetry that forced two.
    struct OpenAuth {
        address lpEth;         // the position's owner — supplied, then authenticated against lpSig
        bytes32 btcRecipient;  // x-only P2TR payout key, pinned + locked at open
        bytes   lpSig;         // over `openAuthDigest(hop, btcRecipient, fundingTxId, fundingVout)`
    }

    /// @notice (E156) The pre-signed dead-man exit that ARMS a channel — supplied at `openChannel`
    /// and refreshed by `emitDeadManExit` for as long as the channel lives.
    ///
    /// ⚠️ WHY THIS IS MANDATORY AT OPEN AND NOT A LATER HEARTBEAT. The fleet holds BOTH funding
    /// halves (`quid-bridge/src/deadman_exit.rs`: *"the hop node's + the vault node's, same
    /// process"*), so the LP has **no funding key and cannot sign anything, ever**. Its only exit is
    /// bytes the fleet pre-signed while alive. The daemon used to produce those on its next
    /// heartbeat tick — its own header says *"a freshly-opened channel is picked up on the NEXT
    /// TICK"* — which left a window where `deadManDeadline == 0`: no exit existed, and if the fleet
    /// died inside it, **no party in the system could ever produce one.** The LP's sats sit in a
    /// 2-of-2 whose both halves died with the fleet.
    /// ⇒ Arming is a CONSTRUCTION-TIME INVARIANT: a channel cannot exist without an escape. That is
    /// what lets the LP-named fallback (E122) delete outright — the recovery story was never "a
    /// nominated hop acts", it was already "the CLTV matures and ANYONE broadcasts the public bytes".
    struct ExitArming {
        uint64 cltvDeadline;    // absolute BTC height the exit may first confirm at; > tip while alive
        uint   checkpointSats;  // the LP balance these bytes attest (feeds the stale-close guard)
        bytes  signedExitTx;    // the FULLY-signed CLTV exit paying btcRecipientOf
    }

    /// @notice routing. `asset` is the volatile side of the swap — WETH for the
    /// ETH pool, WBTC for the BTC pool.
    struct AuxContext {
        address asset;
        address vault;
        address core;
        bool nativeWETH;   // true only for ETH path (unwrap WETH → ETH on delivery)
    }

    struct RouteParams {
        uint160 sqrtPriceX96;
        bool    zeroForOne;
        address token;
        uint    amount;
        uint    pooled;
        uint    v4Price;
        address recipient;
        bool    isBTC;
    }

}
