
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
    }

    /// @notice Params for BTCChannels.openChannel; lives here so ChannelLib can
    /// reference the same struct without a circular file dependency.
    /// `hopPubkey` is the hop's PER-CHANNEL LDK funding pubkey (33-byte) — the
    /// 2-of-2 uses the two per-channel keys, not a fixed hop identity key.
    ///
    /// the channel funds a key-path MuSig2 P2TR output
    /// `0x5120||fundingTaproot`. `fundingTaproot` is the 32-byte x-only key-path
    /// aggregate `Q = lift_x(KeyAgg(KeySort(lp,hop))) + H_TapTweak(agg)·G` (empty
    /// merkle root). The contract does NO secp256k1 EC math: it byte-matches the
    /// SPV-proven funding output against `0x5120||Q`. The LP's lpAuth signs the
    /// whole OpenParams (incl. `fundingTaproot`), so Q is bound to the LP's consent
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
