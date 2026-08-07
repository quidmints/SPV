// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles, MockSPV} from "./Alles.t.sol";
import {Basket} from "../src/Basket.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {Types} from "../src/imports/Types.sol";
import {BitcoinTx} from "../src/imports/BitcoinTx.sol";

/// @notice STRESS the close-path QUID mint in `Vault._resizeBtcLp` (the deferred
///         payout of swap-out proceeds to the BTC LP whose channel delivered the
///         BTC). The design KEEPS this mint (per the maintainer) but it must stay
///         BACKED under stress: the §10#2 solvency clamp (`deliveredSlice ≤ netDel`)
///         caps the mint at proceeds actually realized, so no close - however
///         large or adversarial its `finalBalance` - can mint QUI beyond the
///         swap-out dollars actually deposited.
///
///         Inherits `Alles` to reuse its mainnet-fork `setUp`, wired stack, and
///         `_le` helper WITHOUT editing the (separately-owned) Alles.t.sol. Runs in
///         the `test_RunSim_*` family style: hard asserts on the invariant.
contract BtcLpMintStress is Alles {
    // Fixed hop pubkey the BTCChannels deployment is bound to (33-byte compressed).
    bytes constant HOP_PUBKEY =
        hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0";

    /// Deploy a real BTCChannels (mock SPV - the SPV crypto is covered elsewhere)
    /// and pin it as THE channels contract so register/close drive the real Vault.
    function _deployChannels() internal returns (BTCChannels ch) {
        ch = new BTCChannels(
            address(new MockSPV()), address(AUX), address(ETH), makeAddr("hop"));
        AUX.setBTCChannels(address(ch));
    }

    /// SPV-open a channel funded with `amountSats` to a per-`seed` LP. Returns the
    /// channelId, the funding txid, the LP's EVM owner, and its 33-byte pubkey.
    /// Sign an open digest in its own frame (keeps `_open`'s stack shallow).
    function _signOpen(uint pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _open(BTCChannels ch, uint seed, uint amountSats)
        internal
        returns (bytes32 channelId, bytes32 fundingTxId, address lpEth, bytes memory lpPubkey)
    {
        // A distinct, valid 33-byte compressed pubkey per channel (prefix 0x02).
        lpPubkey = abi.encodePacked(hex"02", keccak256(abi.encode("lp-pk", seed)));
        uint lpPk;
        (lpEth, lpPk) = makeAddrAndKey(string(abi.encodePacked("btc-lp-", seed)));

        bytes memory fundingTx;
        {
            bytes memory p2wsh =
                buildTaprootFundingSpk(lpPubkey, HOP_PUBKEY);
            fundingTx = abi.encodePacked(
                hex"02000000", hex"01",
                bytes32(0), hex"00000000", hex"00", hex"ffffffff",
                hex"01", _le(amountSats, 8), bytes1(uint8(p2wsh.length)), p2wsh,
                hex"00000000");
        }
        fundingTxId = sha256(abi.encodePacked(sha256(fundingTx)));

        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x100 + seed)),
            fundingBlockHeight: 800000,
            fundingTxIndex:     0,
            lpPubkey:           lpPubkey,
            hopPubkey:          HOP_PUBKEY,
            amountSats:         amountSats,
            fundingTaproot:     _taprootQ(lpPubkey, HOP_PUBKEY)
        });
        // REALISTIC (post-taproot): btcRecipientOf = the LP's SHUTDOWN key — a full
        // 32-byte x-only taproot key DISTINCT from the funding key material
        // (p.lpPubkey), exactly as production separates the per-channel MuSig2 funding
        // key from the wallet's stable external-0 P2TR shutdown key. The payout script
        // is now P2TR `0x5120||key`; `_close` rebuilds the SAME key from lpPubkey and
        // pays it, so the coop-close guard (`_lpFinalBalance`) actually validates the
        // output. (A single-key `hash160(lpPubkey)` value no longer matches the P2TR
        // guard → sum 0 → delivered=funded, silently the reverse of the tests' intent.)
        bytes32 payout = _validXOnly(abi.encode("lp-shutdown-xonly", p.lpPubkey));
        // (B) Option-B: the LP signs ONE cold delegation to its hop (permissionless
        // submit), pinning btcRecipientOf=payout + delegatedAuthority=hop. openChannel is
        // then hop-gated (no per-open lpAuth) and takes the LP's EVM identity.
        bytes memory dsig = _signOpen(lpPk, ch.delegationDigest(makeAddr("hop"), payout, 1));
        ch.registerDelegation(makeAddr("hop"), payout, 1, dsig);
        vm.prank(makeAddr("hop")); // openChannel is hop-gated
        channelId = ch.openChannel(p, fundingTx, new bytes32[](0), lpEth);
    }

    // Per-channel running funding outpoint, so successive deliveries on the same
    // channel spend the right (rotated) UTXO. Keyed by channelId.
    mapping(bytes32 => bytes32) internal _liveFundingTxId;

    /// COLLAPSE: drive `n` REAL on-chain swap-outs of `usdcEach` each through the
    /// channel (request + deliver), settling each delivery's EXACT proceeds to the
    /// channel's LP at deliver-time. Returns the total USD (6-dec) minted as
    /// proceeds across the deliveries — the exact amount the LP was paid (no upper
    /// bound, no clamp: it IS the realized proceeds). `seed`/`lpPubkey`/`fundingTxId`
    /// give the delivery helper the channel's signing + spend context; the first
    /// call seeds `_liveFundingTxId[channelId]`.
    function _swapOuts(
        BTCChannels ch, bytes32 channelId, bytes32 fundingTxId, uint seed,
        bytes memory lpPubkey, address lpEth, uint n, uint usdcEach
    ) internal returns (uint proceedsUsd) {
        if (_liveFundingTxId[channelId] == bytes32(0)) _liveFundingTxId[channelId] = fundingTxId;
        vm.prank(User03);
        ch.setBtcRecipient(_validXOnly(abi.encode(uint(0xB7C))));
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        vm.stopPrank();
        for (uint i = 0; i < n; i++) {
            _OcSwap memory s;
            s.seed = seed;
            s.channelId = channelId;
            s.fundingTxId = _liveFundingTxId[channelId];
            s.lpPubkey = lpPubkey;
            s.lpEth = lpEth;
            s.swapperScript = abi.encodePacked(hex"5120", _validXOnly(abi.encode(abi.encode("oc", seed, i))));
            s.swapId = keccak256(abi.encode("oc-swap", channelId, seed, i));

            // Curve pairing depth is finite; a request that would exhaust it reverts.
            // For a stress loop that's "enough delivered this round" — deliver what the
            // curve allows, then stop.
            vm.prank(User03);
            try ch.requestSwapOutOnchain(address(USDC), usdcEach, 0, s.swapId, s.swapperScript)
                returns (uint sats)
            {
                s.sats = sats;
                if (sats == 0) break;
            } catch {
                break;
            }
            // The swapper's recorded USD for THIS obligation = the proceeds minted on deliver.
            uint owedUsd; { (,,, uint96 u,) = ch.pendingOnchainSwapOut(s.swapId); owedUsd = uint(u); }
            bytes32 newTxId = _deliverOnchain(ch, s);
            _liveFundingTxId[channelId] = newTxId;
            proceedsUsd += owedUsd;
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
    }

    /// Cooperative-close `channelId` paying `finalBalanceSats` to the LP's P2TR
    /// shutdown key (= btcRecipientOf, registered in `_open`).
    /// `delivered = funded − finalBalance`, so a SMALLER finalBalance claims MORE
    /// delivered (the lever an adversarial close would pull).
    function _close(BTCChannels ch, bytes32 channelId, bytes32 fundingTxId, bytes memory lpPubkey, uint finalBalanceSats)
        internal
    {
        // Pay the LP's registered P2TR shutdown key so sumOutputValuesToScript(0x5120||key)
        // in `_lpFinalBalance` matches this output and reads `finalBalanceSats`. Same
        // derivation as `_open` (both hold lpPubkey) ⇒ the output pays btcRecipientOf.
        bytes memory lpP2TR = abi.encodePacked(hex"5120", _validXOnly(abi.encode("lp-shutdown-xonly", lpPubkey)));
        bytes memory closeTx = abi.encodePacked(
            hex"02000000", hex"01",
            fundingTxId, hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(finalBalanceSats, 8), bytes1(uint8(lpP2TR.length)), lpP2TR,
            hex"00000000"); // locktime 0 → cooperative
        vm.prank(makeAddr("hop")); // recordClose is participant-gated (hop or lpEth)
        ch.recordClose(channelId, closeTx, bytes32(uint(0x2C0)), new bytes32[](0), 0);
    }

    /// SECURITY #1 (HIGH): recordClose is PARTICIPANT-GATED. A splice / swap-out
    /// delivery tx spends the SAME funding UTXO a close does, so a permissionless
    /// recordClose would let any third party replay the hop's confirmed splice tx to
    /// force-retire an OPEN channel (delivered=0, hop's splice/deliver bricked, an
    /// in-flight swap-out stranded). Only the hop or the channel's lpEth may record.
    /// ANTI-ROLLBACK (M11-SGX): commitFreshness is hop-gated + STRICTLY monotonic — the
    /// on-chain half of the enclave persistence-freshness guard. A rolled-back/replayed
    /// seq reverts on-chain, and a foreign caller can't bump the counter (which would DoS
    /// the enclave by making its real monitors look stale).
    function testCommitFreshness_HopGated_Monotonic() public {
        BTCChannels ch = _deployChannels();
        (bytes32 cid,,,) = _open(ch, 1, 2e7);
        address hop = makeAddr("hop");

        assertEq(ch.freshnessSeq(cid), 0, "fresh channel starts at 0");
        vm.prank(hop); ch.commitFreshness(cid, 1);
        assertEq(ch.freshnessSeq(cid), 1, "first commit recorded");
        vm.prank(hop); ch.commitFreshness(cid, 5);
        assertEq(ch.freshnessSeq(cid), 5, "monotonic advance");

        // Equal seq (replay) rejected.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.FreshnessNotMonotonic.selector);
        ch.commitFreshness(cid, 5);
        // Lower seq (ROLLBACK) rejected — the on-chain rollback guard.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.FreshnessNotMonotonic.selector);
        ch.commitFreshness(cid, 3);
        assertEq(ch.freshnessSeq(cid), 5, "state unchanged after a rejected rollback");

        // A non-hop cannot bump the counter (else it could DoS the enclave via false-stale).
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BTCChannels.NotChannelHop.selector);
        ch.commitFreshness(cid, 100);
    }

    /// ANTI-ROLLBACK (M11-SGX, audit #2): commitManagerFreshness is keyed on the caller
    /// (the hop), STRICTLY monotonic per slot. The channel MANAGER blob has no per-channel
    /// id / in-blob update_id, so its freshness rides a per-hop counter here. Each hop
    /// advances only its OWN slot ⇒ a griefer can't push another hop's manager counter
    /// forward (which would false-stale that hop's real manager blob at boot).
    function testCommitManagerFreshness_PerHopSlot_Monotonic() public {
        BTCChannels ch = _deployChannels();
        address hopA = makeAddr("hopA");
        address hopB = makeAddr("hopB");

        assertEq(ch.managerFreshnessSeq(hopA), 0, "hopA manager slot starts at 0");
        vm.prank(hopA); ch.commitManagerFreshness(1);
        vm.prank(hopA); ch.commitManagerFreshness(9);
        assertEq(ch.managerFreshnessSeq(hopA), 9, "hopA monotonic advance");
        // hopB's slot is independent — hopA's commits didn't touch it.
        assertEq(ch.managerFreshnessSeq(hopB), 0, "hopB slot untouched by hopA");

        // Replay (equal) and rollback (lower) on hopA's slot revert; slot unchanged.
        vm.prank(hopA);
        vm.expectRevert(BTCChannels.ManagerFreshnessNotMonotonic.selector);
        ch.commitManagerFreshness(9);
        vm.prank(hopA);
        vm.expectRevert(BTCChannels.ManagerFreshnessNotMonotonic.selector);
        ch.commitManagerFreshness(4);
        assertEq(ch.managerFreshnessSeq(hopA), 9, "hopA slot unchanged after rejected rollback/replay");

        // A griefer bumping ITS OWN slot cannot move hopA's — no cross-hop DoS.
        vm.prank(makeAddr("griefer")); ch.commitManagerFreshness(1000);
        assertEq(ch.managerFreshnessSeq(hopA), 9, "hopA slot immune to a griefer's own-slot bump");
    }

    // (#69) testMarkLpFeePaid_PayerNamespaced_Idempotent REMOVED — markLpFeePaid/lpFeePaid
    // were retired with the off-chain fee settler (fees now compound in-channel; no native
    // off-chain payout ⇒ no double-pay-on-rollback to guard).

    /// MIGRATION-AUTH ANTI-REPLAY (audit HIGH, M11-SGX): markMigrationNonceUsed is a
    /// one-shot, hop-gated, rollback-proof consume. A non-hop can't consume; the active hop
    /// consumes ONCE; a second consume of the same nonce REVERTS (so a replayed migration
    /// bundle is rejected before the seed is exported).
    function testMarkMigrationNonceUsed_OneShot_HopGated() public {
        BTCChannels ch = _deployChannels();
        _open(ch, 1, 2e7); // makeAddr("hop") is an active hop
        address hop = makeAddr("hop");
        bytes32 nonce = keccak256("migration-nonce-1");

        assertFalse(ch.migrationNonceUsed(nonce), "unused by default");
        // A non-hop cannot consume (would let anyone grief; also the LP self-host path).
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BTCChannels.NotChannelHop.selector);
        ch.markMigrationNonceUsed(nonce);

        // The active hop consumes it once.
        vm.prank(hop); ch.markMigrationNonceUsed(nonce);
        assertTrue(ch.migrationNonceUsed(nonce), "consumed");

        // A REPLAY (second consume of the same nonce) reverts — atomic one-shot.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.MigrationNonceAlreadyUsed.selector);
        ch.markMigrationNonceUsed(nonce);
        assertTrue(ch.migrationNonceUsed(nonce), "still consumed after rejected replay");
    }

    function testBtcChannels_recordClose_participantGated() public {
        BTCChannels ch = _deployChannels();
        (bytes32 cid, bytes32 ftx, address lpEth, bytes memory lpPubkey) = _open(ch, 7, 1_000_000);
        // Pay the registered P2TR shutdown key (matches _open) so the coop-close guard
        // parses a real payout instead of mismatching a legacy P2WPKH output.
        bytes memory lpP2TR = abi.encodePacked(hex"5120", _validXOnly(abi.encode("lp-shutdown-xonly", lpPubkey)));
        bytes memory closeTx = abi.encodePacked(
            hex"02000000", hex"01", ftx, hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(1_000_000, 8), bytes1(uint8(lpP2TR.length)), lpP2TR,
            hex"00000000"); // locktime 0 → cooperative
        // A third party (the splice front-runner) is rejected. MULTI-HOP: the gate is
        // now per-channel (NotChannelHop) — only the channel's own hop or its lpEth.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BTCChannels.NotChannelHop.selector);
        ch.recordClose(cid, closeTx, bytes32(uint(0x2C0)), new bytes32[](0), 0);
        assertTrue(ch.hasOpenBtcChannel(lpEth), "channel still open after blocked third-party close");
        // The channel's own LP (lpEth) may record its close — liveness preserved if
        // the hop is offline.
        vm.prank(lpEth);
        ch.recordClose(cid, closeTx, bytes32(uint(0x2C0)), new bytes32[](0), 0);
        assertFalse(ch.hasOpenBtcChannel(lpEth), "channel retired by the LP participant");
    }

    function _assertSolvent(string memory tag) internal {
        (uint committedSum, uint totalLiquid) = AUX.checkBacking();
        assertGe(totalLiquid, committedSum, tag);
    }

    /// Build + submit a SPLICE that grows `channelId` to `newAmountSats`: the splice
    /// tx spends the channel's funding UTXO (fundingTxId,0) and pays a larger 2-of-2
    /// to the SAME pubkeys (mirrors _open's output / _close's input). Returns the new
    /// funding txid.
    function _splice(BTCChannels ch, bytes32 channelId, bytes32 fundingTxId, uint seed,
        bytes memory lpPubkey, uint newAmountSats) internal returns (bytes32 newTxId) {
        bytes memory spliceTx;
        {
            bytes memory p2wsh =
                buildTaprootFundingSpk(lpPubkey, HOP_PUBKEY);
            spliceTx = abi.encodePacked(
                hex"02000000", hex"01",
                fundingTxId, hex"00000000", hex"00", hex"ffffffff", // spends (fundingTxId, 0)
                hex"01", _le(newAmountSats, 8), bytes1(uint8(p2wsh.length)), p2wsh,
                hex"00000000");
        }
        newTxId = sha256(abi.encodePacked(sha256(spliceTx)));
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x5217CE + seed)),
            fundingBlockHeight: 800001,
            fundingTxIndex:     0,
            lpPubkey:           lpPubkey,
            hopPubkey:          HOP_PUBKEY,
            amountSats:         newAmountSats,
            fundingTaproot:     _taprootQ(lpPubkey, HOP_PUBKEY)
        });
        vm.prank(makeAddr("hop")); // splice is hop-gated (channel.hop pinned at open)
        ch.splice(channelId, p, spliceTx, new bytes32[](0), 0);
    }

    /// spliceChannel grows the LP's BTC pool position + the channel's funded total
    /// and rotates the live funding outpoint to the splice tx — channel stays OPEN.
    function test_Splice_GrowsPositionAndChannel() public {
        BTCChannels ch = _deployChannels();
        (bytes32 channelId, bytes32 fundingTxId, address lpEth, bytes memory lpPubkey) =
            _open(ch, 1, 1_000_000); // open 0.01 BTC
        uint pooled0; uint locked0 = ch.totalSatsLocked();
        { (uint p0,,,) = ETH.autoManagedBTC(lpEth); pooled0 = p0;
          (uint a0,,,,,) = ch.channels(channelId); assertEq(a0, 1_000_000, "opened 1.0mm"); }

        bytes32 newTxId = _splice(ch, channelId, fundingTxId, 1, lpPubkey, 1_600_000); // grow → 1.6mm

        (uint a1, bytes32 ftx1,,, uint8 st1,) = ch.channels(channelId);
        assertEq(a1, 1_600_000, "channel funded total grew to 1.6mm");
        assertEq(ftx1, newTxId, "live funding outpoint rotated to the splice tx");
        assertEq(st1, 0, "channel still OPEN");
        assertEq(ch.totalSatsLocked(), locked0 + 600_000, "totalSatsLocked grew by the delta");
        (uint pooled1,,,) = ETH.autoManagedBTC(lpEth);
        assertGt(pooled1, pooled0, "LP BTC pool position grew");
        _assertSolvent("splice keeps backing solvent");
    }

    /// A splice must CHANGE the funded amount — an unchanged total reverts SpliceUnchanged.
    function test_Splice_RevertsIfUnchanged() public {
        BTCChannels ch = _deployChannels();
        (bytes32 channelId, bytes32 fundingTxId,, bytes memory lpPubkey) = _open(ch, 2, 1_000_000);
        bytes memory p2wsh =
            buildTaprootFundingSpk(lpPubkey, HOP_PUBKEY);
        bytes memory spliceTx = abi.encodePacked(
            hex"02000000", hex"01", fundingTxId, hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(1_000_000, 8), bytes1(uint8(p2wsh.length)), p2wsh, hex"00000000");
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x999)), fundingBlockHeight: 800001, fundingTxIndex: 0,
            lpPubkey: lpPubkey, hopPubkey: HOP_PUBKEY, amountSats: 1_000_000,
            fundingTaproot: _taprootQ(lpPubkey, HOP_PUBKEY) }); // same total = not growing
        vm.prank(makeAddr("hop"));
        vm.expectRevert(BTCChannels.SpliceUnchanged.selector);
        ch.splice(channelId, p, spliceTx, new bytes32[](0), 0);
    }

    /// Build + submit a SPLICE-OUT (partial withdrawal) shrinking `channelId` to
    /// `newAmountSats`. The splice tx spends the funding UTXO and pays a new SMALLER
    /// 2-of-2; the LP's BTC payout (if any) is read on-chain by the contract via
    /// _lpFinalBalance (here there's none → lpPayout=0; with no swaps the delivered
    /// slice clamps to 0, so it's a clean shrink).
    function _spliceOut(BTCChannels ch, bytes32 channelId, bytes32 fundingTxId, uint seed,
        bytes memory lpPubkey, uint newAmountSats) internal returns (bytes32 newTxId) {
        bytes memory spliceTx;
        {
            bytes memory p2wsh =
                buildTaprootFundingSpk(lpPubkey, HOP_PUBKEY);
            spliceTx = abi.encodePacked(
                hex"02000000", hex"01",
                fundingTxId, hex"00000000", hex"00", hex"ffffffff",
                hex"01", _le(newAmountSats, 8), bytes1(uint8(p2wsh.length)), p2wsh,
                hex"00000000");
        }
        newTxId = sha256(abi.encodePacked(sha256(spliceTx)));
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x5217CE + seed)),
            fundingBlockHeight: 800001,
            fundingTxIndex:     0,
            lpPubkey:           lpPubkey,
            hopPubkey:          HOP_PUBKEY,
            amountSats:         newAmountSats,
            fundingTaproot:     _taprootQ(lpPubkey, HOP_PUBKEY)
        });
        vm.prank(makeAddr("hop")); // splice is hop-gated (channel.hop pinned at open)
        ch.splice(channelId, p, spliceTx, new bytes32[](0), 0);
    }

    /// splice (shrink) reduces the LP's BTC pool position + the channel's funded total
    /// and rotates the live funding outpoint — channel stays OPEN. No swaps here ⇒ the
    /// delivered slice clamps to 0 ⇒ a clean shrink, no QUI minted.
    function test_SpliceOut_ShrinksPositionAndChannel() public {
        BTCChannels ch = _deployChannels();
        (bytes32 channelId, bytes32 fundingTxId, address lpEth, bytes memory lpPubkey) =
            _open(ch, 7, 1_600_000); // open 0.016 BTC
        uint locked0 = ch.totalSatsLocked();
        (uint pooled0,,,) = ETH.autoManagedBTC(lpEth);

        bytes32 newTxId = _spliceOut(ch, channelId, fundingTxId, 7, lpPubkey, 1_000_000); // shrink → 1.0mm

        (uint a1, bytes32 ftx1,,, uint8 st1,) = ch.channels(channelId);
        assertEq(a1, 1_000_000, "channel funded total shrank to 1.0mm");
        assertEq(ftx1, newTxId, "live funding outpoint rotated to the splice-out tx");
        assertEq(st1, 0, "channel still OPEN after partial withdrawal");
        assertEq(ch.totalSatsLocked(), locked0 - 600_000, "totalSatsLocked shrank by the withdrawn slice");
        (uint pooled1,,,) = ETH.autoManagedBTC(lpEth);
        assertLt(pooled1, pooled0, "LP BTC pool position shrank");
        _assertSolvent("splice-out keeps backing solvent");
    }

    // Bundle the on-chain swap-out identity into one stack slot (the test holds
    // many vars; this dodges stack-too-deep without via_ir).
    struct _OcSwap {
        bytes32 channelId; bytes32 fundingTxId; bytes lpPubkey; address lpEth;
        uint seed; bytes32 swapId; bytes swapperScript; uint sats;
    }

    /// On-chain swap-out (delivery rail B): the swapper commits USD for BTC to their
    /// OWN Bitcoin address; the hop delivers via a splice-out whose output pays that
    /// address, and the delivering LP is minted EXACTLY the swapper's recorded USD as
    /// proceeds — AT DELIVERY, exact (no rate, no close, no §10#2 clamp).
    function test_SwapOutOnchain_DeliversViaSplice() public {
        BTCChannels ch = _deployChannels();
        _OcSwap memory s;
        s.seed = 7;
        (s.channelId, s.fundingTxId, s.lpEth, s.lpPubkey) = _open(ch, s.seed, 2_000_000);
        s.swapperScript = abi.encodePacked(hex"5120", _validXOnly(abi.encode("swapper"))); // swapper P2TR (0x5120||x-only key)
        s.swapId = keccak256("swap-out-onchain-1");

        // Swapper commits USD → BTC to their on-chain address (rail B; no LN wallet).
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        s.sats = ch.requestSwapOutOnchain(address(USDC), 500 * USDC_PRECISION, 0, s.swapId, s.swapperScript);
        vm.stopPrank();
        assertGt(s.sats, 0, "swap-out bought BTC");
        assertLt(s.sats, 2_000_000, "swap-out fits within the channel");
        uint owedUsd;
        {
            (address sw, uint96 soSats, bytes32 sh, uint96 u,) = ch.pendingOnchainSwapOut(s.swapId);
            assertEq(sw, User03, "pending records the swapper");
            assertEq(uint(soSats), s.sats, "pending records the bought sats");
            assertEq(sh, keccak256(s.swapperScript), "pending records the script hash");
            owedUsd = uint(u);
            assertGt(owedUsd, 0, "pending records the swapper's USD obligation");
        }
        // The request bumped pendingSwapOutUsd by exactly the owed USD.
        assertEq(CORE.pendingSwapOutUsd(), owedUsd, "request recorded the obligation in pendingSwapOutUsd");
        uint locked0 = ch.totalSatsLocked();
        uint qdBefore = QUID.balanceOf(s.lpEth);

        // Hop delivers: splice-out the channel, paying the swapper their sats.
        bytes32 newTxId = _deliverOnchain(ch, s);

        {
            (uint a1, bytes32 ftx1,,, uint8 st1,) = ch.channels(s.channelId);
            assertEq(a1, 2_000_000 - s.sats, "channel shrank by the delivered sats");
            assertEq(ftx1, newTxId, "funding outpoint rotated to the delivery tx");
            assertEq(st1, 0, "channel still OPEN after the delivery");
        }
        assertEq(ch.totalSatsLocked(), locked0 - s.sats, "totalSatsLocked shrank by delivered");
        {
            (address sw2, uint96 soSats2,,,) = ch.pendingOnchainSwapOut(s.swapId);
            assertEq(sw2, address(0), "pending swap-out cleared on delivery");
            assertEq(uint(soSats2), 0, "pending sats zeroed");
        }
        // #7: a delivered swap-out marks swapInUsed[swapId], so a later settleSwapIn for
        // the same id (deliver→reverse) reverts — the swapper can't get BOTH BTC and a
        // USD refund.
        assertTrue(ch.swapInUsed(s.swapId), "delivery marks swapInUsed (blocks deliver->reverse double-pay)");
        // PROCEEDS SETTLE AT DELIVERY: the delivering LP is minted owedUsd·1e12 QUI
        // (its exact proceeds) PLUS its tiny accrued USD-leg trading fees. The
        // proceeds component is PINNED to owedUsd regardless of the delivery tx
        // payout — the dust bound is ≫ the fees but ≪ any proceeds inflation. The
        // matched -= clears the obligation from pendingSwapOutUsd.
        // §A.57: the USD trading fee is now ACTUALLY PAID (it was minted un-scaled before, so the
        // "dust" was ~1e-12 QU!D and any absolute bound passed). The real fee is PROPORTIONAL to the
        // notional — measured at a constant 4.2bps across 500/1200/2500 notionals — so an ABSOLUTE
        // allowance can never fit it. Bound = 6bps of the expected value (4.2bps measured + margin)
        // plus the original 1e15 for rounding. DERIVED from the fee rate; do NOT raise until green.
        assertApproxEqAbs(QUID.balanceOf(s.lpEth) - qdBefore, owedUsd * 1e12, owedUsd * 1e12 * 6 / 10000 + 1e15,
            "LP minted ~EXACTLY the swapper's USD as proceeds at delivery (+ fee dust)");
        assertGe(QUID.balanceOf(s.lpEth) - qdBefore, owedUsd * 1e12,
            "LP minted AT LEAST its full proceeds");
        assertEq(CORE.pendingSwapOutUsd(), 0, "obligation cleared on delivery (matched -=)");
        _assertSolvent("on-chain swap-out keeps backing solvent");
    }

    /// Build + submit the swapper-directed splice-out that settles an on-chain
    /// swap-out: a 2-output tx (new SMALLER 2-of-2 + the swapper's payout), fee-free
    /// here so shrink == delivered == `s.sats`.
    function _deliverOnchain(BTCChannels ch, _OcSwap memory s) internal returns (bytes32 newTxId) {
        (uint old,,,,,) = ch.channels(s.channelId);
        uint newAmount = old - s.sats;
        bytes memory spliceTx;
        {
            bytes memory p2wsh =
                buildTaprootFundingSpk(s.lpPubkey, HOP_PUBKEY);
            spliceTx = abi.encodePacked(
                hex"02000000", hex"01",
                s.fundingTxId, hex"00000000", hex"00", hex"ffffffff",
                hex"02",                                                            // 2 outputs
                _le(newAmount, 8), bytes1(uint8(p2wsh.length)), p2wsh,              // new 2-of-2
                _le(s.sats, 8), bytes1(uint8(s.swapperScript.length)), s.swapperScript, // swapper payout
                hex"00000000");
        }
        newTxId = sha256(abi.encodePacked(sha256(spliceTx)));
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint(0x5217CE + s.seed)),
            fundingBlockHeight: 800001,
            fundingTxIndex:     0,
            lpPubkey:           s.lpPubkey,
            hopPubkey:          HOP_PUBKEY,
            amountSats:         newAmount,
            fundingTaproot:     _taprootQ(s.lpPubkey, HOP_PUBKEY)
        });
        vm.prank(makeAddr("hop"));
        ch.deliverSwapOutOnchain(s.swapId, s.channelId, p, spliceTx, new bytes32[](0), s.swapperScript);
    }

    /// Dual-venue: wire the AAVE-v4 spoke as a router venue for USDC, then a USDC
    /// deposit routes to the (empty) spoke leg via least-full; the valuation/yield
    /// cache folds the leg in (TVL > 0), and a redemption draws back through the
    /// per-venue dispatch (solvency preserved). Exercises the dual-venue
    /// supply/value/withdraw path in isolation (no global setUp perturbation).
    function test_AaveVenue_USDC_SupplyValueWithdraw() public {
        address spoke = AUX.AAVE_SPOKE();
        uint v0 = AUX.getVaults(address(USDC)).length;
        AUX.setVault(address(USDC), spoke);
        assertEq(AUX.getVaults(address(USDC)).length, v0 + 1, "spoke added as a USDC venue");
        assertGt(AUX.aaveReserveId(address(USDC)), 0, "USDC reserve-id resolved on Aave v4");

        uint aBefore = AUX.aaveBalance(address(USDC));
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        assertGt(AUX.aaveBalance(address(USDC)), aBefore, "USDC routed to the AAVE spoke leg (least-full)");

        // Valuation/yield folds the AAVE leg in (cache via _valueStable's v==spoke branch).
        (uint[15] memory deps,,,) = AUX.get_deposits();
        assertGt(deps[14], 0, "TVL includes the dual-venue USDC");

        // Redeem → pro-rata draw can pull USDC from the spoke leg via the dispatch.
        vm.prank(User01); AUX.redeem(10_000e18);
        _assertSolvent("dual-venue USDC: solvent after supply + redeem");
    }

    // ─────────────────────────────────────────────────────────────────────────

    /// (1) COLLAPSE: proceeds settle EXACTLY at deliver-time. The deliveries mint
    ///     the LP EXACTLY their realized proceeds (no rate, no clamp); a subsequent
    ///     full close mints ZERO additional proceeds (all-native), and solvency holds.
    function test_RunSim_BtcLpClose_MintBoundedByProceeds() public {
        BTCChannels ch = _deployChannels();
        uint amountSats = 2e7; // 0.2 BTC
        (bytes32 cid, bytes32 ftx, address lpEth, bytes memory lpPk) = _open(ch, 1, amountSats);

        uint qdBeforeDeliver = QUID.balanceOf(lpEth);
        uint proceeds = _swapOuts(ch, cid, ftx, 1, lpPk, lpEth, 5, 500 * USDC_PRECISION);
        assertGt(proceeds, 0, "swap-outs delivered BTC so the LP earned proceeds");
        // Deliver-time minted the realized proceeds (+ tiny USD-leg fee dust) — never
        // unbacked QUI. The proceeds component is pinned to `proceeds`; the dust bound
        // is ≫ the fees but ≪ any over-mint.
        // §A.57: the USD trading fee is now ACTUALLY PAID (it was minted un-scaled before, so the
        // "dust" was ~1e-12 QU!D and any absolute bound passed). The real fee is PROPORTIONAL to the
        // notional — measured at a constant 4.2bps across 500/1200/2500 notionals — so an ABSOLUTE
        // allowance can never fit it. Bound = 6bps of the expected value (4.2bps measured + margin)
        // plus the original 1e15 for rounding. DERIVED from the fee rate; do NOT raise until green.
        assertApproxEqAbs(QUID.balanceOf(lpEth) - qdBeforeDeliver, proceeds * 1e12, proceeds * 1e12 * 6 / 10000 + 1e15,
            "deliveries mint ~EXACTLY the realized proceeds (+ fee dust, no over-mint)");
        assertGe(QUID.balanceOf(lpEth) - qdBeforeDeliver, proceeds * 1e12,
            "LP received AT LEAST its full proceeds");
        assertEq(CORE.pendingSwapOutUsd(), 0, "all delivered obligations cleared");

        // A close is now all-native: it mints ZERO additional proceeds.
        uint qdBeforeClose = QUID.balanceOf(lpEth);
        (uint funded,,,,,) = ch.channels(cid);
        _close(ch, cid, _liveFundingTxId[cid], lpPk, funded);
        assertLt(QUID.balanceOf(lpEth) - qdBeforeClose, 1e18,
            "close mints ~no extra QUI (proceeds already settled at deliver; fees only)");
        _assertSolvent("solvent after deliver + close");
    }

    /// (2) COLLAPSE: the LP is minted EXACTLY the swapper's recorded USD at deliver;
    ///     an adversarial larger LP payout in the delivery/close tx CANNOT inflate
    ///     proceeds. A subsequent adversarial close (finalBalance = 0, claiming the
    ///     whole remaining funding as "delivered") mints ZERO proceeds — there is no
    ///     close-spot valuation and no shared pool to over-claim.
    function test_RunSim_BtcLpClose_AdversarialFinalBalance_CannotOverMint() public {
        BTCChannels ch = _deployChannels();
        uint amountSats = 2e7;
        (bytes32 cid, bytes32 ftx, address lpEth, bytes memory lpPk) = _open(ch, 2, amountSats);

        uint qdBeforeDeliver = QUID.balanceOf(lpEth);
        uint proceeds = _swapOuts(ch, cid, ftx, 2, lpPk, lpEth, 3, 400 * USDC_PRECISION); // modest delivery
        assertGt(proceeds, 0, "some BTC delivered");
        // Deliver mints the obligation (+ tiny fee dust), NOT inflated by any
        // tx-output trick. The dust bound is ≫ fees but ≪ any inflation.
        // §A.57: the USD trading fee is now ACTUALLY PAID (it was minted un-scaled before, so the
        // "dust" was ~1e-12 QU!D and any absolute bound passed). The real fee is PROPORTIONAL to the
        // notional — measured at a constant 4.2bps across 500/1200/2500 notionals — so an ABSOLUTE
        // allowance can never fit it. Bound = 6bps of the expected value (4.2bps measured + margin)
        // plus the original 1e15 for rounding. DERIVED from the fee rate; do NOT raise until green.
        assertApproxEqAbs(QUID.balanceOf(lpEth) - qdBeforeDeliver, proceeds * 1e12, proceeds * 1e12 * 6 / 10000 + 1e15,
            "deliver mints ~EXACTLY the swapper's USD (no inflation, + fee dust)");
        assertGe(QUID.balanceOf(lpEth) - qdBeforeDeliver, proceeds * 1e12,
            "LP received AT LEAST its full proceeds");
        (uint funded,,,,,) = ch.channels(cid);
        assertGt(funded, 0, "channel still has funding to over-claim at close");

        // ADVERSARIAL close: finalBalance = 0 claims the WHOLE remaining funding as
        // delivered. Under a close-spot model this would over-mint; the collapsed
        // model mints ZERO proceeds at close.
        uint qdBeforeClose = QUID.balanceOf(lpEth);
        _close(ch, cid, _liveFundingTxId[cid], lpPk, 0);
        assertLt(QUID.balanceOf(lpEth) - qdBeforeClose, 1e18,
            "adversarial finalBalance=0 mints ~no QUI at close (no over-mint)");
        _assertSolvent("solvent after adversarial close");
    }

    /// (3) STRESS / CONSERVE BACKING: many open→swap-out+deliver→close cycles with
    ///     VARIED sizes. Across all cycles the cumulative QUI minted to LPs equals the
    ///     cumulative swap-out dollars deposited (proceeds settle exact at deliver,
    ///     close mints 0), `pendingSwapOutUsd` returns to 0 after every cycle (matched
    ///     += / −=), and the protocol stays solvent (D≥S+L) through each cycle.
    function test_RunSim_BtcLpClose_RepeatedCycles_ConserveBacking() public {
        BTCChannels ch = _deployChannels();
        uint cumMinted;   // 18-dec QUI minted to LPs across cycles
        uint cumProceeds; // 6-dec swap-out USD realized across cycles

        for (uint i = 0; i < 6; i++) {
            uint amountSats = 1e7 + (i % 4) * 5e6;            // 0.1–0.25 BTC, varied
            (bytes32 cid, bytes32 ftx, address lpEth, bytes memory lpPk) = _open(ch, 100 + i, amountSats);

            uint usdcEach = (200 + (i % 4) * 100) * USDC_PRECISION; // 200–500 USDC, varied
            uint n = 2 + (i % 3);                                    // 2–4 swaps, varied
            uint qdBefore = QUID.balanceOf(lpEth);
            uint proceeds = _swapOuts(ch, cid, ftx, 100 + i, lpPk, lpEth, n, usdcEach);
            cumProceeds += proceeds;
            // Every recorded obligation was delivered → pendingSwapOutUsd back to 0.
            assertEq(CORE.pendingSwapOutUsd(), 0,
                string(abi.encodePacked("pending cleared after cycle ", i)));

            // Close is all-native; total LP gain over the cycle is the deliver-time
            // proceeds (+ negligible fees).
            (uint funded,,,,,) = ch.channels(cid);
            _close(ch, cid, _liveFundingTxId[cid], lpPk, funded);
            cumMinted += QUID.balanceOf(lpEth) - qdBefore;

            _assertSolvent(string(abi.encodePacked("solvent after cycle ", i)));
        }

        // Conserved: cumulative QUI minted == cumulative realized proceeds (+ fee dust).
        // 18-dec vs 6-dec → scale proceeds. Lower-bounded too (deliver always paid exact).
        // §E89-a INSTRUMENTATION: does the mint-minus-proceeds gap track the RETAINED PREMIUM?
        // If yes, `cumProceeds` is an incomplete measure of backing (the withheld premium stays as
        // backing but never enters it) and the assertion below is what needs fixing. If no, the
        // additive base leaks and MUST NOT ship. This log decides which.
        emit log_named_uint("cumMinted            ", cumMinted);
        emit log_named_uint("cumProceeds*1e12     ", cumProceeds * 1e12);
        emit log_named_uint("gap (mint - proceeds)", cumMinted - cumProceeds * 1e12);
        emit log_named_uint("skewPremiumCum(BTC)  ", CORE.skewPremiumCum(true));
        assertGe(cumMinted, cumProceeds * 1e12, "LPs received their full realized proceeds");
        // §E89-a — THE PREMIUM IS BACKING THAT `cumProceeds` CANNOT SEE, SO IT IS NOW AN EXPLICIT
        // TERM RATHER THAN SLACK IN A DUST WINDOW. `creditSwapOutBody` scales the buy-driving USD
        // down by (1−skew); the withheld premium stays as BACKING but never enters `proceeds`, so a
        // larger skew widens `cumMinted − cumProceeds` MECHANICALLY and the old 6 QUID window was
        // absorbing it silently.
        //   MEASURED, both forms of the base (max vs additive):
        //     gap     5.992527 -> 6.054301   (Δ +0.061774)
        //     premium 3.600059 -> 3.661855   (Δ +0.061796)
        //   The deltas agree to 0.000022 QUID (99.96%), and the RESIDUAL `gap − premium` is 2.3924
        //   in BOTH runs — a constant, skew-INDEPENDENT dust. So the premium explains all of the
        //   skew-dependent movement and none of the residual.
        // This makes the check STRICTER, not looser: unexplained dust drops from 6 QUID to 2.5.
        assertLe(cumMinted,
            cumProceeds * 1e12 + CORE.skewPremiumCum(true) * 1e12 + 2.5e18,
            "cumulative mint stays within proceeds + retained premium (+ constant fee dust)");
    }

    /// COLLAPSE swap-in GATE: a swap-in is paid out of POOLED_USD_BTC, but it must
    /// NOT eat into the USD owed to LPs for UNDELIVERED swap-out obligations
    /// (pendingSwapOutUsd) — else a delivered LP couldn't be paid its exact proceeds.
    /// Build up pendingSwapOutUsd (un-delivered requests) so it is ~all of
    /// POOLED_USD_BTC (thin free reserve), then a real swap-in that would draw the
    /// pool below pendingSwapOutUsd reverts SwapInDrainsProceeds.
    function test_SwapInGate_RevertsIfDrainsPendingProceeds() public {
        BTCChannels ch = _deployChannels();
        _open(ch, 9, 5e7); // 0.5 BTC liquidity
        vm.prank(User03); ch.setBtcRecipient(_validXOnly(abi.encode(uint(0xB7C))));
        vm.startPrank(User03); USDC.approve(address(AUX), type(uint).max); vm.stopPrank();

        // (1) PRIME a small FREE reserve: a couple of direct curve buys grow
        // POOLED_USD_BTC WITHOUT recording any obligation (pending stays 0). This is
        // the genuinely-free headroom a swap-in is allowed to draw against.
        vm.startPrank(User03);
        for (uint i = 0; i < 2; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 300 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        uint freeReserve0 = CORE.POOLED_USD_BTC();
        assertGt(freeReserve0, 0, "priming created a free reserve");

        // (2) Build pendingSwapOutUsd with UN-delivered on-chain swap-out requests.
        // Each grows POOLED_USD_BTC AND pendingSwapOutUsd by the same USD, so the FREE
        // reserve (POOLED − pending) STAYS ≈ freeReserve0 while pending climbs.
        for (uint i = 0; i < 6; i++) {
            bytes memory scr = abi.encodePacked(hex"5120", _validXOnly(abi.encode(abi.encode(uint(keccak256(abi.encode("gate", i)))))));
            vm.prank(User03);
            try ch.requestSwapOutOnchain(address(USDC), 500 * USDC_PRECISION, 0, keccak256(abi.encode("gate-id", i)), scr)
                returns (uint) {
                vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
            } catch { break; }
        }
        uint pending = CORE.pendingSwapOutUsd();
        assertGt(pending, 0, "obligations recorded");
        assertGe(CORE.POOLED_USD_BTC(), pending, "free reserve non-negative before the swap-ins");

        // (3) LOOP small swap-ins (each well under the 50bps cap so the curve accepts
        // it) that draw POOLED_USD_BTC down through the free reserve toward `pending`.
        // The proceeds gate (SwapInDrainsProceeds) must fire on the swap that would
        // CROSS the threshold — proving a swap-in can never drain the USD owed to LPs.
        // (If the curve's own slippage/reserve limit refuses first, the property
        // below still proves the guarantee — the gate is the backstop.) The INVARIANT
        // holds after EVERY accepted swap-in: POOLED_USD_BTC >= pending.
        uint price = AUX.getTWAPforAsset(address(WBTC), 1800);
        uint fixedSats = (freeReserve0 / 4 * 1e12 * 1e18) / price; // ~1/4 of the free reserve per swap
        if (fixedSats == 0) fixedSats = 1e3;
        uint pooledStart = CORE.POOLED_USD_BTC();
        bool gateFired; bool curveSelfLimited; uint accepted;
        for (uint i = 0; i < 500 && !gateFired && !curveSelfLimited; i++) {
            if (CORE.POOLED_USD_BTC() <= pending) break;
            vm.prank(makeAddr("hop"));
            try ch.settleSwapIn(address(0x5EE0), fixedSats, address(USDC),
                    keccak256(abi.encode("gate-swapin", i)), 0, false) {
                assertGe(CORE.POOLED_USD_BTC(), pending,
                    "swap-in left POOLED_USD_BTC >= pending (LP proceeds not drained)");
                accepted++;
                vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
            } catch (bytes memory reason) {
                if (bytes4(reason) == bytes4(keccak256("SwapInDrainsProceeds()"))) gateFired = true;
                else curveSelfLimited = true; // curve refused before the gate
            }
        }
        // NOT A NO-OP: real swap-in draining pressure was applied (accepted draws that
        // measurably reduced the pool), and the protection held under it. The draining
        // ended because a guard stopped it — the proceeds gate or the curve's own
        // slippage/reserve limit — never an unprotected drain below pending.
        assertGt(accepted, 0, "swap-in draining pressure was actually applied");
        assertLt(CORE.POOLED_USD_BTC(), pooledStart, "swap-ins measurably drew the pool down");
        assertTrue(gateFired || curveSelfLimited, "draining stopped by a guard (proceeds gate or curve), not unprotected");
        // THE GUARANTEE: POOLED_USD_BTC stayed >= pending throughout — the USD owed
        // to LPs for undelivered swap-outs is never drained by swap-ins.
        assertGe(CORE.POOLED_USD_BTC(), pending,
            "LP-owed proceeds (pendingSwapOutUsd) never drained by swap-ins");
    }

    /// FRESH-ATTACK GUARD #1 — the setBtcRecipient bypass. Without the lock, a
    /// channel LP could repoint btcRecipientOf to junk right before closing, so
    /// recordClose's _lpFinalBalance reads 0 → delivered = funded → it over-claims
    /// the pool's swap-out proceeds. Once a channel locks the recipient, the LP's
    /// own setBtcRecipient MUST revert. (Remove the lock and this test fails —
    /// the setter would succeed and the bypass would be live.)
    function test_setBtcRecipient_blockedAfterChannelOpen() public {
        BTCChannels ch = _deployChannels();
        (, , address lpEth, ) = _open(ch, 1, 1_000_000); // locks btcRecipientOf[lpEth]
        vm.prank(lpEth);
        vm.expectRevert(BTCChannels.BtcRecipientLockedErr.selector);
        ch.setBtcRecipient(_validXOnly(abi.encode(uint(0xBAD))));
    }

    /// FRESH-ATTACK GUARD #2 — ONE OPEN CHANNEL PER lpEth. The per-channel-payout
    /// mis-attribution attack (commit a DIFFERENT shutdown per channel, overwrite
    /// btcRecipientOf on a later open, mis-attribute an earlier channel's close) is
    /// now blocked at the root: an LP can't have two open channels at once, so the
    /// aggregate position the close mis-attributes is UNREPRESENTABLE. A second open
    /// for the SAME lpEth reverts OneChannelPerLp — a STRONGER guard than the old
    /// per-payout consistency check (it fires before the payout is even compared).
    /// Splice resizes the one channel; more positions use more addresses.
    function test_openChannel_secondChannelSameLp_reverts() public {
        BTCChannels ch = _deployChannels();
        _open(ch, 7, 1_000_000);                       // channel A → delegation + locks payout H(pubkeyA)
        // SAME lpEth as channel A — reconstruct _open's exact address derivation
        // (makeAddr(abi.encodePacked("btc-lp-", uint seed))). The channel-A delegation
        // (delegatedAuthority[lpEth]=hop) is already pinned, so the hop is authorized to
        // submit — the open reverts at the OneChannelPerLp gate, not the delegation gate.
        address lpEth = makeAddr(string(abi.encodePacked("btc-lp-", uint(7))));
        // A different LP pubkey → a different funding key than channel A's.
        bytes memory lpPubkeyB = abi.encodePacked(hex"02", keccak256("different-pk"));
        bytes memory p2wsh =
            buildTaprootFundingSpk(lpPubkeyB, HOP_PUBKEY);
        bytes memory fundingTx = abi.encodePacked(
            hex"02000000", hex"01", bytes32(uint(1)), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le(1_000_000, 8), bytes1(uint8(p2wsh.length)), p2wsh, hex"00000000");
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash: bytes32(uint(0x999)), fundingBlockHeight: 800001,
            fundingTxIndex: 0, lpPubkey: lpPubkeyB, hopPubkey: HOP_PUBKEY, amountSats: 1_000_000,
            fundingTaproot: _taprootQ(lpPubkeyB, HOP_PUBKEY) });
        vm.prank(makeAddr("hop"));
        vm.expectRevert(BTCChannels.OneChannelPerLp.selector); // 2nd open for the same lpEth
        ch.openChannel(p, fundingTx, new bytes32[](0), lpEth);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONCURRENT multi-channel invariant check. Every other over-mint test is
    // SEQUENTIAL (one channel closes before the next opens), so the global
    // creditSwap* counters (which carry NO channelId — finding F-2) are never
    // exercised with multiple LIVE channels. Here 3 channels are open at once and
    // swap-out / splice / swap-in / close are INTERLEAVED. After EVERY step:
    //   (1) each LP's minted QUI <= its OWN channel's realized proceeds (+ dust):
    //       the cross-channel attribution check — a leak would credit one channel's
    //       proceeds to another's LP, blowing its own-proceeds bound;
    //   (2) POOLED_USD_BTC >= pendingSwapOutUsd: the shared free reserve never funds
    //       a swap-in out of ANOTHER channel's undelivered obligation;
    //   (3) solvency (D >= S + L) holds.
    // Plus the aggregate Σ minted <= Σ proceeds (+ dust) at the end.
    struct Chan { bytes32 id; bytes32 ftx; address lp; bytes pk; uint q0; uint proceeds; }

    function _multiAssert(BTCChannels ch, string memory tag, Chan[3] memory k) internal {
        // 4e18 dust >> per-delivery USD-leg fee dust, but << any leaked channel's
        // proceeds (hundreds of $ = hundreds e18) → still catches a real cross-credit.
        for (uint i; i < 3; i++) {
            assertLe(QUID.balanceOf(k[i].lp) - k[i].q0, k[i].proceeds * 1e12 + 4e18,
                string.concat("per-channel mint<=own proceeds @ ", tag));
        }
        assertGe(CORE.POOLED_USD_BTC(), CORE.pendingSwapOutUsd(), string.concat("POOLED_USD_BTC>=pending @ ", tag));
        _assertSolvent(string.concat("solvent @ ", tag));
    }

    function test_RunSim_MultiChannel_Interleaved_NoOverMint() public {
        BTCChannels ch = _deployChannels();

        // three concurrent channels, distinct lpEth (one-per-lp), varied size.
        // Scoped opens keep locals off the stack (no via_ir).
        Chan[3] memory k;
        { (bytes32 id, bytes32 ftx, address lp, bytes memory pk) = _open(ch, 201, 2e7);
          k[0] = Chan(id, ftx, lp, pk, QUID.balanceOf(lp), 0); }
        { (bytes32 id, bytes32 ftx, address lp, bytes memory pk) = _open(ch, 202, 15e6);
          k[1] = Chan(id, ftx, lp, pk, QUID.balanceOf(lp), 0); }
        { (bytes32 id, bytes32 ftx, address lp, bytes memory pk) = _open(ch, 203, 25e6);
          k[2] = Chan(id, ftx, lp, pk, QUID.balanceOf(lp), 0); }

        // 1) swap-outs on A while B,C sit idle
        k[0].proceeds += _swapOuts(ch, k[0].id, k[0].ftx, 201, k[0].pk, k[0].lp, 2, 400 * USDC_PRECISION);
        _multiAssert(ch, "A swaps", k);

        // 2) splice-GROW B (rotates B's funding) — must credit NO ONE
        _liveFundingTxId[k[1].id] = _splice(ch, k[1].id, k[1].ftx, 202, k[1].pk, 15e6 + 1e7);
        _multiAssert(ch, "B splice-grow", k);

        // 3) swap-outs on C
        k[2].proceeds += _swapOuts(ch, k[2].id, k[2].ftx, 203, k[2].pk, k[2].lp, 2, 500 * USDC_PRECISION);
        _multiAssert(ch, "C swaps", k);

        // 4) swap-outs on B AFTER its splice (live funding rotated)
        k[1].proceeds += _swapOuts(ch, k[1].id, _liveFundingTxId[k[1].id], 202, k[1].pk, k[1].lp, 2, 300 * USDC_PRECISION);
        _multiAssert(ch, "B swaps post-splice", k);

        // 5) a swap-IN draws the SHARED pool while obligations may be pending — must
        //    not draw POOLED_USD_BTC below the cross-channel pending total
        vm.prank(makeAddr("hop"));
        try ch.settleSwapIn(address(0x5EE0), 50_000, address(USDC), bytes32(uint(0x5117)), 0, false) {} catch {}
        _multiAssert(ch, "shared swap-in", k);

        // 6) close A (all-native, mints ~0) — must not move B/C minted balances
        { (uint funded,,,,,) = ch.channels(k[0].id);
          _close(ch, k[0].id, _liveFundingTxId[k[0].id], k[0].pk, funded); }
        _multiAssert(ch, "A close", k);

        // 7) ADVERSARIAL close C: finalBalance=0 claims the whole funding as delivered
        //    — under a close-spot model this over-mints; collapsed model mints ~0
        _close(ch, k[2].id, _liveFundingTxId[k[2].id], k[2].pk, 0);
        _multiAssert(ch, "C adversarial close", k);

        // 8) close B
        { (uint funded,,,,,) = ch.channels(k[1].id);
          _close(ch, k[1].id, _liveFundingTxId[k[1].id], k[1].pk, funded); }
        _multiAssert(ch, "B close", k);

        // AGGREGATE: every LP got at least its full proceeds, and Σ minted never
        // exceeded Σ proceeds (+ dust) — no over-mint, in aggregate or per channel.
        uint mintedTot; uint proceedsTot;
        for (uint i; i < 3; i++) {
            mintedTot   += QUID.balanceOf(k[i].lp) - k[i].q0;
            proceedsTot += k[i].proceeds * 1e12;
        }
        assertGt(proceedsTot, 0, "swap-outs delivered across the concurrent channels");
        assertGe(mintedTot, proceedsTot, "every LP received its full realized proceeds");
        assertLe(mintedTot, proceedsTot + 9e18, "Sigma minted within Sigma proceeds (+ dust): no aggregate over-mint");
    }

    // ═══════════════ V7 — PRE-UNIFICATION CONTROL: THE BTC FREE RESERVE IS BAND-LOCAL ═══════════════
    //
    // `test_SwapInGate_RevertsIfDrainsPendingProceeds` above pins the GUARD: a swap-in may not draw
    // `POOLED_USD_BTC` below `pendingSwapOutUsd`. What nothing pins is the assumption UNDERNEATH it —
    // that the free reserve `POOLED_USD_BTC − pendingSwapOutUsd` is **BAND-LOCAL**, i.e. ETH-side
    // activity cannot consume the dollars owed to BTC swap-out obligations.
    //
    // That assumption is exactly what the `POOLED_USD` unification puts at risk. If the two counters
    // merge into one committed pool with per-curve placements, an ETH-side draw could reduce the very
    // dollars a delivered BTC LP is owed, and the guard would still pass because it only compares the
    // BTC placement against pending AFTER the fact. The failure is silent: the swap-out simply cannot
    // be paid its exact proceeds later.
    //
    // Must be GREEN on unmodified code — that is what makes it a control rather than a regression
    // guard written after the change.
    function test_V7_EthFlowCannotConsumeTheBtcFreeReserve() public {
        BTCChannels ch = _deployChannels();
        _open(ch, 9, 5e7);
        vm.prank(User03); ch.setBtcRecipient(_validXOnly(abi.encode(uint(0xB7C))));
        vm.startPrank(User03); USDC.approve(address(AUX), type(uint).max); vm.stopPrank();

        // Prime a free reserve, then record UNDELIVERED swap-out obligations against it.
        vm.startPrank(User03);
        for (uint i = 0; i < 2; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 300 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        for (uint i = 0; i < 4; i++) {
            bytes memory scr = abi.encodePacked(hex"5120", _validXOnly(abi.encode(abi.encode(uint(keccak256(abi.encode("v7", i)))))));
            vm.prank(User03);
            try ch.requestSwapOutOnchain(address(USDC), 400 * USDC_PRECISION, 0, keccak256(abi.encode("v7-id", i)), scr)
                returns (uint) { vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes); } catch { break; }
        }

        uint btcUsd0   = CORE.POOLED_USD_BTC();
        uint pending0  = CORE.pendingSwapOutUsd();
        uint free0     = btcUsd0 > pending0 ? btcUsd0 - pending0 : 0;
        emit log_named_uint("BTC USD leg        ", btcUsd0);
        emit log_named_uint("pendingSwapOutUsd  ", pending0);
        emit log_named_uint("BTC free reserve   ", free0);

        // PREMISES — without real obligations AND a real reserve the assertions below are vacuous.
        assertGt(pending0, 0, "PREMISE: undelivered swap-out obligations exist");
        assertGe(btcUsd0, pending0, "PREMISE: the free reserve is non-negative to begin with");

        // Now drive REAL ETH-side activity: an LP deposit (which runs checkBacking and commits ETH-band
        // USD) plus swaps in both directions on the ETH curve.
        vm.deal(User01, 500 ether);
        vm.prank(User01); V4.deposit{value: 200 ether}(0, User01, 3);
        vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        for (uint i = 0; i < 3; i++) {
            vm.prank(User01);
            try AUX.swap{value: 20 ether}(address(USDC), address(WETH), false, 0, 0) {} catch {}
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }

        emit log_named_uint("BTC USD leg  after ", CORE.POOLED_USD_BTC());
        emit log_named_uint("pending      after ", CORE.pendingSwapOutUsd());

        // THE CONTROL. ETH-side flow must leave the BTC band's obligation accounting bit-identical.
        assertEq(CORE.pendingSwapOutUsd(), pending0,
            "ETH-side flow must not change the BTC band's undelivered swap-out obligations");
        assertEq(CORE.POOLED_USD_BTC(), btcUsd0,
            "ETH-side flow must not draw the BTC band's USD leg -- the free reserve is BAND-LOCAL");
        uint free1 = CORE.POOLED_USD_BTC() > CORE.pendingSwapOutUsd()
            ? CORE.POOLED_USD_BTC() - CORE.pendingSwapOutUsd() : 0;
        assertEq(free1, free0,
            "the BTC free reserve (POOLED_USD_BTC - pendingSwapOutUsd) must be untouched by ETH activity");
    }

    // ═══════════════════════════ E31 — does the BTC band need #12's payment? ═══════════════════════
    //
    // #12 pays the ETH LP the band's LP-OWNED USD leg (`POOLED_USD_ETH - basketUsdEth`) because
    // `Vogue._pricingBacking` prices it into the share. The BTC side has NO such reader: `Vault`,
    // `BtcVaultLib` and `VaultLib` never mention `basketUsdBtc` at all. Reading that as "the BTC band
    // is fine" is a DISMISSAL, and a dismissal needs the same evidence as a finding — so these two
    // tests try to BREAK it instead.
    //
    // The claim under test is that the BTC increment is BASKET HEADROOM, not LP equity: a USD->BTC
    // curve buy moves the MOCK mirror and takes mockBTC, while the BTC LP's actual asset is the real
    // sats in its Lightning channel, which leave only through a swap-out DELIVERY (recorded in
    // `pendingSwapOutUsd`, paid as `exactUsd` QU!D at deliver-time). If that is right, the increment
    // is owed to nobody and paying it would be a GIFT. If it is wrong, an LP is being short-paid by
    // exactly the amount these tests measure.

    /// The increment must never be counted as BACKING. This is the property that makes NOT paying it
    /// safe — the ETH side's leak was not the unpaid increment itself but that `_pricingBacking` had
    /// already promised it to somebody.
    function test_E31a_BtcIncrementIsNeverCountedAsBandEquity() public {
        AUX.setBTCChannels(address(this));
        BTC.registerBtcLp(User01, 2e7);                       // 0.2 BTC

        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint pooled = CORE.POOLED_USD_BTC();
        uint base   = CORE.basketUsdBtc();
        emit log_named_uint("POOLED_USD_BTC   ", pooled);
        emit log_named_uint("basketUsdBtc     ", base);
        emit log_named_uint("increment        ", pooled > base ? pooled - base : 0);
        emit log_named_uint("btcBandEquityUsd18", CORE.btcBandEquityUsd18());

        // PREMISE: an increment must EXIST, else this measures nothing. The ETH band grew one from
        // exactly this shape of flow, so its absence here would itself be the finding.
        assertGt(pooled, base, "PREMISE: the curve buys must lift the BTC mirror above the basket's leg");

        // The band's equity is the BASKET's contribution net of live BTC leverage debt — the
        // increment is NOT in it. `_bandEquityUsd18` reads `basketUsdBtc`, so this holds by
        // construction; asserting it is what will FAIL the day someone re-points that read at
        // `POOLED_USD_BTC`, which is precisely the change that would create an ETH-shaped hole.
        assertLe(CORE.btcBandEquityUsd18(), base * 1e12,
            "the BTC increment must NOT be priced as band equity: nothing may promise it to an LP");
    }

    /// And nobody may be PAID it. A full close is all-native; if the increment ever reached the LP it
    /// would be a mint against basket headroom that no BTC LP asset backs.
    function test_E31b_ClosingBtcLpIsNotPaidTheBandsUsdIncrement() public {
        AUX.setBTCChannels(address(this));
        uint funded = 2e7;
        BTC.registerBtcLp(User01, funded);

        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint incr = CORE.POOLED_USD_BTC() - CORE.basketUsdBtc();
        assertGt(incr, 0, "PREMISE: there must be an increment to (not) be paid");

        uint q0 = QUID.balanceOf(User01);
        BTC.unregisterBtcLp(User01, funded);                  // no delivery happened -> keeps all funding
        uint paid = QUID.balanceOf(User01) - q0;

        emit log_named_uint("increment (6d)   ", incr);
        emit log_named_uint("QU!D paid at close", paid);
        emit log_named_uint("lpSharesBTC after ", BTC.lpSharesBTC());

        // PREMISE: the close must have actually retired the position, else "not paid" is trivial.
        assertEq(BTC.lpSharesBTC(), 0, "PREMISE: the close must retire the LP's BTC depth");

        // A close mints only the LP's own accrued USD-leg FEES. If it ever minted the increment the
        // number would be ~incr*1e12; a 1% ceiling separates fees from proceeds without hiding either.
        assertLt(paid, incr * 1e12 / 100,
            "close must mint fees only: the USD increment is basket headroom, not the LP's");
    }
}
