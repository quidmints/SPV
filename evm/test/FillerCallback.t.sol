// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IT { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }
interface IV3c { function token0() external view returns (address); }
interface IFiller { function onQuidFill(address give, uint256 amt, address want, uint256 owed, bytes calldata d) external; }

/// @notice §SESS-40 — **THE STALENESS PROBLEM DISSOLVES IF NOTHING IS EMBEDDED: INVERT CONTROL.**
///
/// §SESS-39 proved a contract-maker order FILLS. But our conversion paths are **flash-bound**
/// (`LevMath:1605`, `LevManager:625`) — the sale must complete in the SAME transaction as the repay.
/// ⇒ **a posted order cannot serve them, and the reason is ASYNCHRONY, not staleness.** An order is
/// filled later; a flash loan repays now. Fixing the embedded amount would not have fixed that.
///
/// ⭐ **SO DO NOT POST AN AMOUNT — DO NOT POST ANYTHING.** Let the FILLER initiate. We hand over what we
///    are selling inside THEIR transaction, and require that by the end our balance of the wanted asset
///    rose by a floor **we computed before we let go of anything**. Nothing is embedded, so nothing can
///    be stale: the amount is whatever our internal computation just produced, and the price is our own
///    TWAP read in the same instant.
///
/// 🔑 **AND IT IS STRICTLY SAFER THAN TODAY'S `approve`-AND-CALL.** `convertTo` grants the router an
///    allowance and calls it; this TRANSFERS and demands repayment. **No allowance survives the call**,
///    so there is nothing left to drain in a later block — the standing-allowance hazard §SESS-2 flags
///    on `curveExchange` cannot exist in this shape at all.
/// ⚠️ **THE FLOOR IS READ BEFORE THE TRANSFER, DELIBERATELY.** If it were read after the callback, the
///    filler could move the oracle inside their own call and lower the bar they must clear.
contract QuidFillDesk {
    error Short(uint256 got, uint256 owed);
    bool private locked;

    /// Hand `amt` of `give` to `msg.sender`; require `owed` of `want` back by the end of the call.
    function fill(address give, uint256 amt, address want, uint256 owed, bytes calldata d) external {
        require(!locked, "reentrant"); locked = true;
        uint256 before = IT(want).balanceOf(address(this));
        IT(give).transfer(msg.sender, amt);                    // no allowance, ever
        IFiller(msg.sender).onQuidFill(give, amt, want, owed, d);
        uint256 got = IT(want).balanceOf(address(this)) - before;
        if (got < owed) revert Short(got, owed);
        locked = false;
    }
}

/// An HONEST filler: sources the wanted asset from any venue it likes and repays.
contract GoodFiller is IFiller {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev `repay` is SEPARATE from `owed` on purpose: a control that shorts the desk must short it
    ///      deliberately, not by being insolvent. A first draft asked for 1,000 WETH and so tested the
    ///      FILLER's balance rather than the DESK's floor check — it passed for the wrong reason.
    function go(QuidFillDesk desk, address give, uint256 amt, address want, uint256 owed, uint256 dexWord, uint256 repay) external {
        desk.fill(give, amt, want, owed, abi.encode(dexWord, repay));
    }
    function onQuidFill(address give, uint256 amt, address want, uint256 owed, bytes calldata d) external {
        (uint256 dex, uint256 repay) = abi.decode(d, (uint256, uint256));
        owed;
        (bool ok,) = give.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, amt));
        require(ok, "ap");
        (bool k,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP_SELECTOR, uint256(uint160(give)), amt, uint256(1), dex)); k;
        IT(want).transfer(msg.sender, repay);                  // repay whatever the caller chose
    }
}
/// A HOSTILE filler: takes the asset and returns nothing.
contract ThiefFiller is IFiller {
    function go(QuidFillDesk desk, address give, uint256 amt, address want, uint256 owed) external {
        desk.fill(give, amt, want, owed, "");
    }
    function onQuidFill(address, uint256, address, uint256, bytes calldata) external {}
}

contract FillerCallbackTest is ForkPin {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant P_USDC_WETH = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    QuidFillDesk desk;

    function setUp() public { vm.selectFork(_forkMainnet()); desk = new QuidFillDesk(); }

    function _word(address pool, address tin) internal view returns (uint256 w) {
        w = (uint256(1) << 253) | uint256(uint160(pool));
        if (IV3c(pool).token0() == tin) w |= (uint256(1) << 247);
    }

    /// ⭐ THE ANSWER: an honest filler converts through ANY venue and we are paid our own floor.
    function test_AnHonestFillerIsPaidOurFloor() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(desk), amt);
        uint256 owed = 19 ether;                        // our floor, computed by US before letting go
        GoodFiller f = new GoodFiller();
        uint256 g0 = gasleft();
        f.go(desk, USDC, amt, WETH, owed, _word(P_USDC_WETH, USDC), owed);
        console2.log("filler-callback gas:", g0 - gasleft());
        console2.log("desk WETH received :", IT(WETH).balanceOf(address(desk)));
        assertGe(IT(WETH).balanceOf(address(desk)), owed, "desk was not paid its floor");
        assertEq(IT(USDC).balanceOf(address(desk)), 0, "desk should have handed over the input");
    }

    /// 🔴 CONTROL 1 — a filler that takes and returns nothing REVERTS, and the state rolls back.
    function test_Control_AThievingFillerReverts() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(desk), amt);
        ThiefFiller t = new ThiefFiller();
        vm.expectRevert();
        t.go(desk, USDC, amt, WETH, 19 ether);
        assertEq(IT(USDC).balanceOf(address(desk)), amt, "the revert must return the input");
    }

    /// 🔴 CONTROL 2 — **ONE WEI SHORT REVERTS.** The filler is SOLVENT and chooses to underpay by 1,
    ///    which is the only construction that tests the DESK rather than the filler's balance.
    function test_Control_OneWeiShortReverts() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(desk), amt);
        uint256 owed = 19 ether;
        GoodFiller f = new GoodFiller();
        // ⚠️ **HOIST THE WORD — `vm.expectRevert` BINDS TO THE NEXT EXTERNAL CALL, AND AN ARGUMENT
        //    EXPRESSION MAKES ONE.** `_word(...)` staticcalls `token0()`, so inline it captured THAT
        //    and reported "did not revert" while the desk was working perfectly. **Second time this
        //    session** — §SESS-22 hit the same cheatcode against an inlined internal library call.
        uint256 w = _word(P_USDC_WETH, USDC);
        vm.expectRevert(abi.encodeWithSelector(QuidFillDesk.Short.selector, owed - 1, owed));
        f.go(desk, USDC, amt, WETH, owed, w, owed - 1);
        assertEq(IT(USDC).balanceOf(address(desk)), amt, "the revert must return the input");
    }

    /// 🔴 CONTROL 3 — **AND EXACTLY THE FLOOR IS ENOUGH.** A bound that rejects an exact payment is a
    ///    different bound from the one documented, and the difference only shows at the boundary.
    function test_Control_ExactlyTheFloorIsAccepted() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(desk), amt);
        uint256 owed = 19 ether;
        GoodFiller f = new GoodFiller();
        f.go(desk, USDC, amt, WETH, owed, _word(P_USDC_WETH, USDC), owed);
        assertEq(IT(WETH).balanceOf(address(desk)), owed, "exactly the floor must be accepted");
    }
}
