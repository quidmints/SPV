// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {IAaveV4Spoke, IAaveV4Hub} from "../src/imports/Interfaces.sol";
import {Deploy} from "../script/DeployL1_s.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20D { function balanceOf(address) external view returns (uint256); function decimals() external view returns (uint8); }

/// @notice §S12 — **WHAT `getReserveSuppliedAssets` AND `getReserveTotalDebt` ACTUALLY MEASURE, SETTLED
///         AGAINST THE HUB'S OWN ACCESSORS.**
///
/// The owner's scoping analysis of `BasketLib:929-932` ended: *"Either way `avail` needs to stop being
/// `rs − rd` until we know what the two operands measure."* This file is what settled it, and it exists
/// because **the answer could not be reached by reading our own tree** — the operands are named as if
/// reserve-wide and are not.
///
/// 🔑 **THE FINDING: BOTH ARE OUR SPOKE'S OWN BOOK AGAINST THE HUB.** Aave v4 is hub-and-spoke — the hub
///    custodies the asset, spokes `add` liquidity to it and `draw` from it. The identities below are
///    asserted, not asserted-about: `spoke.getReserveSuppliedAssets(rid) == hub.getSpokeAddedAssets(aid,
///    spoke)` and `spoke.getReserveTotalDebt(rid) == hub.getSpokeTotalOwed(aid, spoke)`.
///    ⇒ **`rs − rd` is a NET INTERCOMPANY POSITION, not cash.** A spoke owing more than it added is an
///    ordinary credit line, not distress — USDC sits at **123.1%** at the pinned block.
///
/// ⚠️ **AND THE DEAD END THAT CAME FIRST IS RECORDED BECAUSE IT LOOKED SO PROMISING.** The spoke exposes
///    BOTH `getReserveDebt` and `getReserveTotalDebt` — exactly the singular/plural legacy-getter shape
///    `CLAUDE.md`'s verification table warns about. It was the obvious explanation for the 123.1%.
///    **Measured, the two are EQUAL on every reserve and the premium is 0**, so that hypothesis is dead;
///    `test_TheTwoDebtGettersAgree` keeps it dead rather than leaving it as folklore.
contract AaveHubLiquidity is ForkPin, Deploy {
    IAaveV4Spoke sp;
    IAaveV4Hub   hb;

    // rid → the four stable reserves this tree actually supplies into.
    uint256[4] rids = [uint256(7), 8, 11, 13];

    function setUp() public {
        vm.selectFork(_forkMainnet());
        sp = IAaveV4Spoke(aaveSpoke);
        hb = IAaveV4Hub(aaveHub);
    }

    function _aidOf(uint256 rid) internal view returns (address asset, uint256 aid) {
        (bool ok, bytes memory ret) = aaveSpoke.staticcall(abi.encodeWithSignature("getReserve(uint256)", rid));
        require(ok && ret.length >= 128, "getReserve failed");
        (asset, , aid) = abi.decode(ret, (address, address, uint256));
    }

    /// ⭐ THE ANSWER. The two spoke getters ARE the hub's per-spoke book, to the unit.
    function test_SpokeGettersAreThisSpokesBookAgainstTheHub() public view {
        for (uint256 i; i < rids.length; ++i) {
            (address asset, uint256 aid) = _aidOf(rids[i]);
            assertEq(sp.getReserveSuppliedAssets(rids[i]),
                     _hubU("getSpokeAddedAssets(uint256,address)", aid),
                     "suppliedAssets is NOT this spoke's added-to-hub balance");
            assertEq(sp.getReserveTotalDebt(rids[i]),
                     _hubU("getSpokeTotalOwed(uint256,address)", aid),
                     "totalDebt is NOT this spoke's owed-to-hub balance");
            console2.log("rid", rids[i], "asset", asset);
        }
    }

    function _hubU(string memory sig, uint256 aid) internal view returns (uint256) {
        (bool ok, bytes memory r) = aaveHub.staticcall(abi.encodeWithSignature(sig, aid, aaveSpoke));
        require(ok, "hub read failed");
        return abi.decode(r, (uint256));
    }

    /// 🔑 THE CASH. `getAssetLiquidity` is the hub's real token balance — which is what `_aaveAvail` caps by.
    function test_HubLiquidityIsTheHubsRealTokenBalance() public view {
        for (uint256 i; i < rids.length; ++i) {
            (address asset, uint256 aid) = _aidOf(rids[i]);
            uint256 liq = hb.getAssetLiquidity(aid);
            uint256 bal = IERC20D(asset).balanceOf(aaveHub);
            // Dust-tolerant: a donated transfer raises the balance without the accounting seeing it.
            // Measured at the pin: 0 drift on USDT/USDG/GHO, 315 units ($0.0003) on USDC.
            assertGe(bal, liq, "hub holds LESS than it accounts for - liquidity would over-promise");
            assertLe(bal - liq, liq / 1_000_000 + 1000, "drift is too large to call this the cash");
            assertGt(liq, 0, "a zero-liquidity reserve would make the cap vacuously binding");
        }
    }

    /// 🔴 THE CONTROL, and it is the one that matters: the OLD formula and the NEW one must DISAGREE,
    ///    and the old one must be the one that over-promises. If they agreed, the §S12 fix would be a
    ///    no-op dressed as a correction.
    function test_Control_OldFormulaOverPromisesAgainstRealCash() public view {
        uint256 overPromising;
        for (uint256 i; i < rids.length; ++i) {
            (, uint256 aid) = _aidOf(rids[i]);
            uint256 rs  = sp.getReserveSuppliedAssets(rids[i]);
            uint256 rd  = sp.getReserveTotalDebt(rids[i]);
            uint256 old = rs > rd ? rs - rd : 0;
            uint256 liq = hb.getAssetLiquidity(aid);
            uint256 neu = liq < rs ? liq : rs;          // the shipped `_aaveAvail` shape
            console2.log("rid", rids[i]);
            console2.log("   old avail (rs-rd):", old);
            console2.log("   new avail min(rs,liq):", neu);
            if (old > neu) ++overPromising;
        }
        assertGt(overPromising, 0,
            "CONTROL FAILED - the old formula never over-promises, so the fix corrects nothing");
    }

    /// ⛔ THE DEAD HYPOTHESIS, PINNED. `getReserveDebt` vs `getReserveTotalDebt` is the singular/plural
    ///    legacy shape, and it is NOT the explanation - they are equal, premium 0.
    function test_TheTwoDebtGettersAgree() public view {
        for (uint256 i; i < rids.length; ++i) {
            (bool ok, bytes memory r) =
                aaveSpoke.staticcall(abi.encodeWithSignature("getReserveDebt(uint256)", rids[i]));
            require(ok, "getReserveDebt missing");
            assertEq(abi.decode(r, (uint256)), sp.getReserveTotalDebt(rids[i]),
                "the two debt getters DIVERGED - re-open the premium hypothesis");
        }
    }
}
