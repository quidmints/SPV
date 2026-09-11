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


}
