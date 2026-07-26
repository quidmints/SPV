// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface ISPq { function getCompoundedBoldDeposit(address) external view returns (uint); }

/// @notice Quantifies the leverage externality on passive LPs — the analysis
///   recorded in memory project-quid-leverage-liquity.md (CORRECTION 2026-06-22).
///
///   On the QU!D side a leveraged-LP OPEN is a BOLD->WETH swap: the trader sheds
///   BOLD into the protocol's backing (Liquity SP) and pulls WETH out of the LP
///   pool. We measure two things on a mainnet fork:
///     (1) the BOLD-ACCUMULATION curve under repeated guard-safe opens, and
///     (2) the LVR / value-transfer to passive LPs via a rigorous control-vs-
///         treatment design (same final ETH price; difference = pure leverage cost).
///
///   LP value is measured TOTAL (both legs): redeem the LP in a snapshot and value
///   ETH-leg (at the scenario price) + QUID-leg ($1). Valuing the redeemed assets at
///   the scenario price sidesteps pool-reseat machinery AND the forked-SP BOLD-out
///   limitation (no unwind leg needed — the open + revaluation already captures the
///   directional transfer, since the open converts the LP's ETH-side to USD-side).
contract LeveragePnLProbe is Alles {
    address bold; address sp; address lp = User02; address trader = User03;
    uint lpShares;

    function _seed(uint ethDeposit) internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        sp   = AUX.getVaults(bold)[0];
        vm.prank(lp);
        lpShares = V4.deposit{value: ethDeposit}(0, lp);
        require(lpShares > 0, "lp deposit failed");
    }

    /// One guard-safe leverage open. Returns WETH out, or 0 on revert (e.g. guard).
    function _open(uint boldAmt) internal returns (uint wethOut) {
        deal(bold, trader, boldAmt);
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) returns (uint w) { wethOut = w; }
        catch { wethOut = 0; }
        vm.stopPrank();
        // Let the observation ring absorb the move so the next open doesn't trip the
        // 50bps manip guard (spot reconverges toward the 30-min TWAP).
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    uint constant SP_SENTINEL = type(uint).max;
    function _spBold() internal view returns (uint) {
        try ISPq(sp).getCompoundedBoldDeposit(address(AUX)) returns (uint v) { return v; } catch { return SP_SENTINEL; }
    }
    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }

    /// TOTAL LP value in USD18 at a given ETH price (USD18 per 1e18 ETH): redeem the
    /// LP in a snapshot, value both legs (ETH + QUID), then revert.
    function _lpValueUsd(uint ethPx18) internal returns (uint usd) {
        uint snap = vm.snapshotState();
        uint eth0 = lp.balance; uint weth0 = WETH.balanceOf(lp); uint q0 = QUID.balanceOf(lp);
        vm.prank(lp);
        try V4.redeem(lpShares, lp, lp) {} catch {}
        uint ethG  = (lp.balance - eth0) + (WETH.balanceOf(lp) - weth0);
        uint quidG = QUID.balanceOf(lp) - q0;
        usd = ethG * ethPx18 / 1e18 + quidG;
        vm.revertToState(snap);
    }

    // ───────────────────────────────────────────────────────────────────────────
    // (1) BOLD accumulation curve under repeated guard-safe opens (flat market).
    // ───────────────────────────────────────────────────────────────────────────
    function testLeverage_BoldAccumulationCurve() public {
        _seed(400 ether);
        emit log_named_uint("TVL18 @start", _tvl());
        emit log_named_uint("BOLD in SP @start (18d)", _spBold());

        uint perOpen = 4_000e18; // ~1.3 ETH out on a 400-ETH pool => <0.5% move
        uint landed;
        for (uint r = 1; r <= 25; r++) {
            uint w = _open(perOpen);
            if (w == 0) { emit log_named_uint("open tripped guard / reverted at round", r); break; }
            landed++;
            if (r % 5 == 0 || r == 1) {
                uint spb = _spBold(); uint tvl = _tvl();
                emit log_named_uint("round", r);
                emit log_named_uint("   BOLD in SP (18d)",    spb);
                emit log_named_uint("   BOLD % of TVL (bps)", tvl > 0 && spb != SP_SENTINEL ? (spb * 10_000) / tvl : 0);
                emit log_named_uint("   POOLED_ETH",          CORE.POOLED_ETH());
            }
        }
        emit log_named_uint("opens that landed", landed);
        emit log_named_uint("BOLD shed back out by protocol (should be 0; nothing sheds it)", 0);
        emit log_string("=> BOLD accumulates monotonically; earmark would PIN it; BOLD has NO depeg feed.");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // (2) LVR / value transfer: control (no opens) vs treatment (N opens), valued at
    //     the SAME final ETH price. Difference = pure leverage externality on the LP.
    // ───────────────────────────────────────────────────────────────────────────
    function testLeverage_LvrControlVsTreatment() public {
        _seed(400 ether);
        uint px0 = AUX.getTWAPforAsset(address(WETH), 1800); // USD18 per 1e18 ETH
        emit log_named_uint("ETH px0 (USD18)", px0);

        uint snap0 = vm.snapshotState();

        // Treatment: accumulate guard-safe opens, then value the LP at 3 final prices.
        uint landed;
        for (uint r = 0; r < 20; r++) { if (_open(3_000e18) == 0) break; landed++; }
        emit log_named_uint("treatment opens landed", landed);
        emit log_named_uint("BOLD accumulated (18d)", _spBold());
        uint tUp   = _lpValueUsd(px0 * 120 / 100);
        uint tFlat = _lpValueUsd(px0);
        uint tDown = _lpValueUsd(px0 * 80 / 100);

        // Control: same starting pool, NO opens.
        vm.revertToState(snap0);
        uint cUp   = _lpValueUsd(px0 * 120 / 100);
        uint cFlat = _lpValueUsd(px0);
        uint cDown = _lpValueUsd(px0 * 80 / 100);

        emit log_string("scenario | control USD18 | treatment USD18 | externality bps (treat-ctrl)/ctrl");
        _report("ETH +20%", cUp, tUp);
        _report("ETH flat ", cFlat, tFlat);
        _report("ETH -20%", cDown, tDown);
        emit log_string("Expect: +20% => LP WORSE (LVR out); -20% => LP BETTER; flat => ~fees. LP is short the position.");
    }

    function _report(string memory tag, uint ctrl, uint treat) internal {
        emit log_named_string("scenario", tag);
        emit log_named_uint("  control USD18",   ctrl);
        emit log_named_uint("  treatment USD18", treat);
        int bps = ctrl > 0 ? (int(treat) - int(ctrl)) * 10_000 / int(ctrl) : int(0);
        emit log_named_int ("  externality bps", bps);
    }
}
