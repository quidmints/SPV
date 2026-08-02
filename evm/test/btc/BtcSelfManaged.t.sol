// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles, MockSPV} from "../Alles.t.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {Vault} from "../../src/Vault.sol";

/// @notice BTC-pool self-managed boundary orders — `Vault.outOfRangeBtc`/`pullBtc`,
///         the USD-funded BTC twin of the ETH `Vogue.outOfRange`/`pull` path. Mirrors
///         `Alles.testOutOfRangeUSDPosition` on the BTC (USD/WBTC) curve: place a
///         single-sided USD limit order outside range, then pull it back.
contract BtcSelfManagedTest is Alles {
    /// Create a USD-funded boundary order on the BTC curve, then fully pull it.
    function testOutOfRangeBtc_USDPosition() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint balanceBefore = USDC.balanceOf(User01);

        // distance sign mirrors the ETH USD test; the BTC pool ordering is handled
        // inside oorTicks via token1isBTC (same shared geometry).
        uint id = BTC.outOfRangeBtc(rack / 10, address(USDC), 1000, 100);

        assertGt(id, 0, "BTC self-managed position id > 0");
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore - rack / 10,
                          rack / 100, "USDC deducted for the boundary order");

        vm.roll(vm.getBlockNumber() + 1000);
        balanceBefore = USDC.balanceOf(User01);
        BTC.pullBtc(id, 100, address(USDC));
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore, rack / 50,
                          "USDC returned on full pull");
        vm.stopPrank();
    }

    /// USD-funded only: native/WBTC funding is rejected (no BTC user-deposit leg).
    function testOutOfRangeBtc_RejectsNative() public {
        vm.prank(User01);
        vm.expectRevert(Vault.NotAStable.selector);
        BTC.outOfRangeBtc(0, address(0), 1000, 100);
    }

    /// Only the position owner can pull it.
    function testPullBtc_OnlyOwner() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint id = BTC.outOfRangeBtc(rack / 10, address(USDC), 1000, 100);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 1000);
        vm.prank(User02);
        vm.expectRevert(Vault.NotOwner.selector);
        BTC.pullBtc(id, 100, address(USDC));
    }

    // ─── REAL Lightning swap-in e2e — DELIBERATELY HOUSED HERE, not in `Alles.t.sol` ──────────
    // It used to live in `Alles.t.sol`, which **25 contracts inherit**, so a whole-suite run fired
    // the `vm.ffi` orchestrator ~30 TIMES CONCURRENTLY. Each invocation kills, wipes and restarts
    // both LND nodes, so they raced into a half-built harness and every copy returned SKIP. Thirty
    // concurrent runs of one stateful external daemon is not coverage; it is one test plus
    // twenty-nine ways to corrupt it.
    //
    // It lives in an EXISTING `is Alles` contract on purpose. A NEW `is Alles` suite would also
    // have worked for the race, but inheriting `Alles` re-runs all ~112 of its tests — measured:
    // a fresh suite reported 113 tests. So a new file would have traded 29 redundant ffi calls for
    // 112 redundant test instances. Here the orchestrator runs EXACTLY ONCE and nothing is
    // duplicated. A lock was the other option and is worse: it would serialise thirty identical
    // ~40s runs for zero extra coverage.

    /// @notice REAL Lightning swap-in, orchestrated entirely by `forge` via
    ///         vm.ffi: the regtest/ harness spins up bitcoind + two LND nodes +
    ///         an alice->bob channel and performs a GENUINE HTLC payment (alice
    ///         the BTC seller pays bob the hop); bob learns the preimage. We then
    ///         prove ON-CHAIN that the settled paymentHash IS sha256 of that real
    ///         Lightning preimage, drive the REAL BTCChannels.settleSwapIn with
    ///         it (minting QUI to the seller against drawn pool dollars), and that
    ///         replaying the same real hash reverts. Skips cleanly (suite stays
    ///         green) if the harness binaries aren't installed - run once:
    ///           regtest/setup.sh && regtest/setup-ln.sh
    function testSwapIn_RealLightningHTLC() public {
        string[] memory cmd = new string[](2);
        cmd[0] = "bash";
        cmd[1] = string.concat(vm.projectRoot(), "/../regtest/swapin-e2e.sh");
        bytes memory sig = vm.ffi(cmd);
        // Only an explicit READY drives the live assertions. ANY other token -
        // SKIP (binaries not installed), an orchestration-failure marker, or empty
        // output (a partially-available / flaky live harness) - skips cleanly so
        // the suite stays green wherever the bitcoind/LND harness cannot come up.
        // ⚠️ SKIP means ONE thing only: the binaries are not installed. An installed-but-BROKEN
        // harness returns BROKEN and FAILS here. Collapsing the two into a single SKIP token is
        // what hid this test for the whole project: LND's stale-tip bug made every run emit SKIP,
        // indistinguishable from "not installed", so a real breakage looked like a clean skip.
        if (keccak256(sig) == keccak256(bytes("SKIP"))) {
            emit log("regtest/LND binaries absent - run regtest/setup.sh && regtest/setup-ln.sh - skipping");
            vm.skip(true);
            return;
        }
        require(keccak256(sig) == keccak256(bytes("READY")),
            "live LN harness is INSTALLED but BROKEN (see /tmp/quid-swapin-e2e.log). Deliberately NOT skipped.");

        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/test/btc/swapin_fixture.json"));
        uint    sats        = vm.parseJsonUint(j, ".sats");
        bytes32 paymentHash = vm.parseJsonBytes32(j, ".paymentHash");
        bytes memory preimage = vm.parseJsonBytes(j, ".preimage");

        // The settled hash IS sha256 of the real Lightning preimage (the HTLC tie).
        assertEq(sha256(preimage), paymentHash, "paymentHash == sha256(real LN preimage)");

        // Real BTCChannels wired as THE btcChannels (pin-once); hopNode = our addr.
        address hop = makeAddr("hop");
        BTCChannels ch = new BTCChannels(
            address(new MockSPV()), address(AUX), address(ETH), hop);
        AUX.setBTCChannels(address(ch));
        // The USD->BTC swaps deliver BTC to the swapper -> it needs a BTC recipient.
        vm.prank(User03); ch.setBtcRecipient(bytes32(uint(0xB7C)));

        // Fund POOLED_USD_BTC headroom (a swap-in draws the swappers' dollars).
        // MULTI-HOP: a REAL open (not a registerBtcLp shortcut) so `hop` owns an OPEN
        // channel and may therefore attest the swap-in — settleSwapIn's
        // `openChannelsOf[hop] >= 1` gate is the authority binding that replaced the
        // old single trusted hopNode. (This test previously kept the direct
        // registerBtcLp shortcut and only stayed green because the live-harness ffi
        // was SKIPping; with the harness fixed it runs and requires the real open.)
        _openHopChannel(ch, hop, 91, 2e7);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        assertGt(CORE.POOLED_USD_BTC(), 0, "POOLED_USD_BTC funded");

        // No-CRE fork: heal USDC severity to 0 for the realistic healthy case.
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)),
            abi.encode(uint(0)));
        address seller = address(0x5EE7);
        uint usdcBefore   = USDC.balanceOf(seller);
        uint pooledBefore = CORE.POOLED_USD_BTC();
        vm.prank(hop);
        ch.settleSwapIn(seller, sats, address(USDC), paymentHash, 0, false);
        // ETH-parity: the real LN swap-in settles ON-CURVE from existing pooled
        // dollars - the seller receives USDC, NOT minted QUI.
        assertGt(USDC.balanceOf(seller), usdcBefore, "seller received USDC for the real LN swap-in");
        assertLt(CORE.POOLED_USD_BTC(), pooledBefore, "POOLED_USD_BTC drawn down by the curve");
        assertTrue(ch.swapInUsed(paymentHash), "real HTLC hash recorded");

        // Replaying the SAME real hash must revert - one credit per HTLC, ever.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.SwapInReplay.selector);
        ch.settleSwapIn(seller, sats, address(USDC), paymentHash, 0, false);
    }
}
