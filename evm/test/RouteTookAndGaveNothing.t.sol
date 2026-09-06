// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {ONEINCH_ROUTER, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20T { function balanceOf(address) external view returns (uint256); function transferFrom(address,address,uint256) external returns (bool); }

/// @notice §SESS-22 — **A ROUTE THAT CONSUMES AN INPUT LEG AND DELIVERS NOTHING NOW REVERTS.**
///
/// **Owner, 2026-09-06:** *"we shouldnt just hardcode those 3 possibilities. any 1inch venue should be
/// possible without making it a vulnerability."* ⇒ the ladder (`routedSwap`) already reaches any venue
/// via aggregator calldata — measured worth: *"Fluid, Balancer, Maverick, Ekubo and the lite-psm/dai-usds
/// par converters that beat every AMM at 0.000%, plus SPLIT routes."* **This file is what makes that
/// arbitrary reach safe.**
///
/// 🔴 **THE HOLE THE AGGREGATE FLOOR DOES NOT CLOSE.** 1inch's `swap` descriptor names a `dstReceiver`,
///    so a hacked keeper can have the pinned router pull leg `k`'s input and pay ITSELF. That leg
///    contributes 0 to `got`, and the conversion still passes provided the OTHER legs clear `minOut` —
///    so up to the floor's own slack walks out per conversion. `convertShortfall` runs **one leg per
///    stable**, which is exactly a supply of small legs to divert.
/// ⇒ `spent > 0 ⇒ delivered > 0`, per leg, makes it **UNCONSTRUCTIBLE** (rule 17) rather than bounded.
///
/// @dev The "malicious venue" here is a REAL contract doing the REAL thing an attacker would: pull the
///      approved input and keep it. It is not a mock of 1inch — the pinned router is untouched. We reach
///      it by `etch`ing this behaviour at the router address, which is the only way to exercise a hostile
///      callee while keeping the callee PINNED (the pin is the property under test, so it must not be
///      relaxed to test it).
contract Thief {
    address public immutable TOK;
    constructor(address t) { TOK = t; }
    fallback() external {
        // Pull everything we were approved for and keep it. Returns success — the point of the test.
        uint256 bal = IERC20T(TOK).balanceOf(msg.sender);
        if (bal > 0) IERC20T(TOK).transferFrom(msg.sender, address(this), bal);
    }
}

contract RouteTookAndGaveNothingTest is ForkPin {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    function _one(address t, uint256 a, bytes memory r)
        internal pure returns (address[] memory ts, uint256[] memory as_, bytes[] memory rs) {
        ts = new address[](1); as_ = new uint256[](1); rs = new bytes[](1);
        ts[0] = t; as_[0] = a; rs[0] = r;
    }

    /// @dev ⚠️ **`convertTo` IS `internal`, SO IT IS INLINED AND HAS NO EXTERNAL FRAME.** A bare
    ///      `vm.expectRevert` bound to the FIRST external call the inlined body makes — the `balanceOf`
    ///      staticcall — and reported "did not revert" while the guard was working. This wrapper gives
    ///      the cheat-code something to catch. Recorded because the failure looked exactly like a
    ///      missing guard.
    function callConvert(address[] calldata t, uint256[] calldata a, address out, uint256 floor_, bytes[] calldata r)
        external returns (uint256) { return LevMath.convertTo(t, a, out, floor_, r); }

    /// ⭐ THE ANSWER: a route that takes and gives nothing REVERTS, rather than being absorbed.
    function test_ADivertingRouteReverts() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(this), amt);
        vm.etch(ONEINCH_ROUTER, address(new Thief(USDC)).code);

        (address[] memory t, uint256[] memory a, bytes[] memory r) =
            _one(USDC, amt, abi.encodeWithSelector(bytes4(0xfeedface)));
        uint256 usdc0 = IERC20T(USDC).balanceOf(address(this));
        vm.expectRevert(LevMath.RouteTookAndGaveNothing.selector);
        this.callConvert(t, a, WETH, 0, r);
        // and the revert is what SAVED the tokens — state is rolled back.
        assertEq(IERC20T(USDC).balanceOf(address(this)), usdc0, "the revert must return the input");
    }

    /// 🔴 CONTROL 1 — the guard must not fire on a leg that simply FAILED. A failed leg costs nothing
    ///    (no input consumed), and `continue`ing past it is the documented behaviour that lets one
    ///    unlucky leg not void a conversion the others completed.
    function test_Control_AFailedLegStillSkips() public {
        uint256 amt = 1_000e6;
        deal(USDC, address(this), amt);
        (address[] memory t, uint256[] memory a, bytes[] memory r) =
            _one(USDC, amt, abi.encodeWithSelector(bytes4(0xdeadbeef)));   // reverts inside the router
        // floor 0 so the ONLY thing that could revert is the new guard. It must not.
        uint256 got = LevMath.convertTo(t, a, WETH, 0, r);
        assertEq(got, 0, "a failed leg should deliver nothing");
        assertEq(IERC20T(USDC).balanceOf(address(this)), amt, "a failed leg must not consume input");
    }

    /// 🔴 CONTROL 2 — and the guard must not fire on an HONEST fill, or it bricks the money path.
    ///    Uses the tree's own encoder against the pool word it ships.
    function test_Control_AnHonestFillIsUnaffected() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(this), amt);
        uint256 before = IERC20T(WETH).balanceOf(address(this));
        LevMath._aggSwap(USDC, WETH, amt, 1, uint256(1) << 253 | uint256(uint160(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640)) | (uint256(1) << 247), 0);
        assertGt(IERC20T(WETH).balanceOf(address(this)) - before, 0,
            "CONTROL FAILED - the honest path no longer fills, so the guard is over-broad");
    }
}
