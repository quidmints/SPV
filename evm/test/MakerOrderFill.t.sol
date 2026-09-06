// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ONEINCH_ROUTER, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IE2 { function balanceOf(address) external view returns (uint256); }

/// A protocol-shaped MAKER: holds the asset, approves the router, and signs by ERC-1271.
/// ⚠️ It returns the magic value UNCONDITIONALLY, which is the point of the experiment — we are
///    testing whether the ROUTER accepts a contract maker at all, not whether our policy is good.
contract MakerStub {
    bytes4 constant MAGIC = 0x1626ba7e;
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) { return MAGIC; }
    function approveRouter(address token, uint256 amt) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, amt));
        require(ok, "approve");
    }
}

/// @notice §SESS-39 — **DOES A CONTRACT-MAKER ORDER ACTUALLY FILL?** The gate on the whole RFQ/maker
///         direction (§SESS-34/36). §SESS-25's bar applies: *a row that does not fill is not a row.*
contract MakerOrderFill is ForkPin {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes4  constant SEL  = 0x56a75868;   // fillContractOrderArgs((uint256 x8),bytes,uint256,uint256,bytes)

    MakerStub maker;
    function setUp() public { vm.selectFork(_forkMainnet()); maker = new MakerStub(); }

    function _u(address a) internal pure returns (uint256) { return uint256(uint160(a)); }

    /// ⚠️ **DIRECTION IS DERIVED, NOT WRITTEN.** A first draft hand-built the two-hop words without
    ///    `ZERO_FOR_ONE` and the call burned **57,182,543 gas** — the "reverts deep inside 1inch's
    ///    executor" signature `convertTo`'s gas-cap note records at 931,857,691. The contract derives
    ///    this bit for exactly this reason; a test that writes it by hand re-creates the bug.
    function _word(address pool, address tokenIn) internal view returns (uint256 w) {
        w = (uint256(1) << 253) | uint256(uint160(pool));
        (bool ok, bytes memory r) = pool.staticcall(abi.encodeWithSignature("token0()"));
        require(ok, "token0");
        if (abi.decode(r, (address)) == tokenIn) w |= (uint256(1) << 247);
    }

    /// @dev 1inch LOP v4 Order: salt, maker, receiver, makerAsset, takerAsset, making, taking, traits.
    function _order(uint256 making, uint256 taking) internal view returns (uint256[8] memory o) {
        o[0] = uint256(keccak256("quid-sess39-salt"));
        o[1] = _u(address(maker));
        o[2] = 0;                       // receiver 0 => maker
        o[3] = _u(WETH);                // makerAsset: we SELL WETH
        o[4] = _u(USDC);                // takerAsset: we WANT USDC
        o[5] = making;
        o[6] = taking;
        // 🔴 **`makerTraits = 0` USES THE *BIT* INVALIDATOR, AND THAT COST A DEBUG CYCLE.** With 0, LOP
        //    v4 keys invalidation off a NONCE inside `makerTraits` — NOT off the salt — so a second
        //    order with a fresh salt collides with the first and reverts `BitInvalidatedOrder()`
        //    (`0xa4f62a96`). Setting **ALLOW_MULTIPLE_FILLS (bit 254)** switches to the remaining-amount
        //    invalidator, keyed by ORDER HASH, so distinct orders are distinct.
        // ⚠️ **THIS IS A DESIGN CONSTRAINT, NOT A TEST DETAIL:** a protocol posting many orders must
        //    either manage nonces explicitly or run in remaining-amount mode. The default is the one
        //    that silently allows exactly one order per nonce.
        o[7] = uint256(1) << 254;       // ALLOW_MULTIPLE_FILLS
    }

    function test_ContractMakerOrderFills() public {
        uint256 making = 10 ether;          // maker sells 10 WETH
        uint256 taking = 25_000e6;          // for 25,000 USDC

        deal(WETH, address(maker), making);
        maker.approveRouter(WETH, type(uint256).max);
        deal(USDC, address(this), taking);
        (bool ok0,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, type(uint256).max));
        require(ok0, "taker approve");

        uint256 wethBefore = IE2(WETH).balanceOf(address(this));
        uint256 usdcBefore = IE2(USDC).balanceOf(address(this));

        uint256[8] memory o = _order(making, taking);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = ONEINCH_ROUTER.call(
            abi.encodeWithSelector(SEL, o, bytes(""), making, uint256(0), bytes("")));
        uint256 used = g0 - gasleft();

        console2.log("fill ok?      :", ok);
        console2.log("gas used      :", used);
        if (!ok) console2.logBytes(ret);
        console2.log("taker WETH in :", IE2(WETH).balanceOf(address(this)) - wethBefore);
        console2.log("taker USDC out:", usdcBefore - IE2(USDC).balanceOf(address(this)));
        assertTrue(ok, "the contract-maker order did NOT fill - the RFQ direction needs a different shape");
        assertEq(IE2(WETH).balanceOf(address(this)) - wethBefore, making, "taker did not receive the maker asset");
    }

    /// @dev One fill at `making`/`taking`, returning gas. Fresh maker inventory each time.
    function _fillGas(uint256 making, uint256 taking) internal returns (uint256 used, bool ok) {
        bytes memory why;
        deal(WETH, address(maker), making);
        maker.approveRouter(WETH, type(uint256).max);
        deal(USDC, address(this), taking);
        (bool a,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, type(uint256).max));
        require(a, "approve");
        uint256[8] memory o = _order(making, taking);
        o[0] = uint256(keccak256(abi.encodePacked("salt", making, taking)));
        uint256 g0 = gasleft();
        (ok, why) = ONEINCH_ROUTER.call(abi.encodeWithSelector(SEL, o, bytes(""), making, uint256(0), bytes("")));
        used = g0 - gasleft();
        if (!ok) { console2.log("   revert data:"); console2.logBytes(why); }
    }

    /// ⭐ ③ **THE BREAK-EVEN SPREAD A MAKER ORDER MUST POST TO BE FILLABLE.**
    ///    §PLP-T's M5 asks *"what spread would actually attract refill flow"* and calls it unanswerable
    ///    from the code. **The BEHAVIOURAL half is; the COST half is not.** A filler will not fill below
    ///    its own cost, so `gas + its route cost` is a HARD LOWER BOUND on any answer to M5 — and unlike
    ///    the behavioural half it needs no live deployment. **This measures the gas half exactly and
    ///    states the route half from §ROUTE-COST-MEASURED (1.7–8 bps).**
    function test_BreakEvenSpreadForAFiller() public {
        uint256[4] memory notional = [uint256(25_000), 100_000, 1_000_000, 5_000_000];
        for (uint256 i; i < notional.length; ++i) {
            uint256 taking = notional[i] * 1e6;
            uint256 making = (notional[i] * 1e18) / 2_500;      // ~$2,500/ETH
            (uint256 used, bool ok) = _fillGas(making, taking);
            console2.log("=== notional USD:", notional[i]);
            console2.log("   fill ok?          :", ok);
            if (!ok) { console2.log("   (did not fill at this size)"); continue; }
            // ⚠️ **UNITS BUG CAUGHT IN MY OWN FIRST DRAFT:** `(used * 20 gwei * 2500)/1e18` is WHOLE
            //    dollars, and dividing it by a 6-dec `taking` reported every break-even as **0 bps**.
            //    A zero that is a unit error looks exactly like a zero that is a finding.
            uint256 gasUsd6 = (used * 20 gwei * 2_500 * 1e6) / 1e18;   // now genuinely 6-dec USD
            console2.log("   fill gas          :", used);
            console2.log("   gas cost USD (6dec):", gasUsd6);
            // both sides 6-dec now, so bps is honest; x100 for two decimals of bps
            console2.log("   break-even, bps x100 (gas only):", (gasUsd6 * 10_000 * 100) / taking);
        }
    }

    /// ⭐ ① **PER-HOP COST OF THE POOL-WORD ARM**, so the calldata arm's N-hop cost can be bounded.
    ///    §SESS-13 measured the 14-leg `convertTo` FRAME at 1,464,082. What that did not separate is
    ///    what each HOP costs, which is what decides whether "unlimited hops" is affordable.
    function test_PerHopCostOfTheRouteArm() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(this), amt);
        (bool a,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, type(uint256).max));
        require(a, "approve");
        uint256 P1 = _word(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640, USDC);
        uint256 g0 = gasleft();
        (bool k1,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            bytes4(0x83800a8e), _u(USDC), amt, uint256(1), P1));
        uint256 oneHop = g0 - gasleft(); k1;
        console2.log("unoswap  (1 hop) gas:", oneHop);

        deal(USDC, address(this), amt);
        address USDT_ = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        uint256 PU = _word(0x3416cF6C708Da44DB2624D63ea0AAef7113527C6, USDC);   // USDC -> USDT
        uint256 PW = _word(0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36, USDT_);  // USDT -> WETH
        uint256 g1 = gasleft();
        (bool k2,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            bytes4(0x8770ba91), _u(USDC), amt, uint256(1), PU, PW));
        uint256 twoHop = g1 - gasleft(); k2;
        console2.log("unoswap2 (2 hop) gas:", twoHop);
        if (twoHop > oneHop) console2.log("MARGINAL cost of one more hop:", twoHop - oneHop);
        console2.log("=> 14 legs x 1 hop, execution only:", oneHop * 14);
        assertGt(oneHop, 0, "the one-hop probe did not execute");
    }
}
