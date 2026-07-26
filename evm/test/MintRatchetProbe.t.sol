// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";

/// @notice Decisive test of the mint->swap ratchet. Mint a FIXED $50k of QUI (which
///   credits "a bit more" via forward-yield: minted > deposited), then immediately swap
///   ALL of that QUI for ETH and measure the ETH value out.
///     - If WETH_out_value ~= the QUI's nominal (>= $50k): fresh QUI IS curve-swappable
///       before its backing yield accrues -> you extracted >= what you put in -> RATCHET.
///     - If WETH_out_value ~= 0: turn() burns matured-only, fresh QUI draws nothing -> safe.
///   Run: forge test --match-contract MintRatchetProbe --match-test testMintSwapRatchet -vv
contract MintRatchetProbe is Alles {
    function testMintSwapRatchet() public {
        // Deep ETH inventory so a QUI->ETH swap CAN draw, if allowed.
        vm.prank(User02); V4.deposit{value: 1000 ether}(0, User02);

        uint px = AUX.getTWAPforAsset(address(WETH), 1800); // USD18 per 1e18 ETH
        uint X = 50_000 * USDC_PRECISION;                   // $50k per round

        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);
        QUID.approve(address(AUX), type(uint).max);

        for (uint r = 0; r < 3; r++) {
            require(USDC.balanceOf(User01) >= X, "need USDC");
            uint usdcBefore = USDC.balanceOf(User01);

            uint minted = QUID.mint(User01, X, address(USDC), 0);   // get $50k + epsilon QUI
            uint qd = QUID.balanceOf(User01);

            uint w0 = WETH.balanceOf(User01);
            try AUX.swap(address(QUID), address(WETH), true, qd, 0) {}
            catch { emit log_string("  QUI->WETH reverted"); }
            uint wout = WETH.balanceOf(User01) - w0;
            uint woutUsd = wout * px / 1e18;                        // 18-dec USD value of ETH drawn

            if (wout > 0)
                try AUX.swap(address(USDC), address(WETH), false, wout, 0) {}
                catch { emit log_string("  WETH->USDC reverted"); }

            uint usdcAfter = USDC.balanceOf(User01);

            emit log_named_uint("round", r);
            emit log_named_uint("  USDC in (6d)", X);
            emit log_named_uint("  QUI minted normalized (18d)", minted);
            emit log_named_uint("  QUI swapped (18d)", qd);
            emit log_named_uint("  ETH drawn, USD18", woutUsd);
            emit log_named_int ("  net USDC this cycle (6d)", int(usdcAfter) - int(usdcBefore));
            emit log_named_uint("  QUI left stuck (18d)", QUID.balanceOf(User01));

            // ANTI-RATCHET GATE (was a toothless -vv probe): minting $X of fresh QUI and
            // immediately round-tripping it QUI->WETH->USDC must NOT return your capital —
            // fresh QUI cannot be swapped out at face before its backing yield accrues, so
            // the cycle is strictly net-negative. If this ever fails, the mint->swap
            // ratchet is live (you extracted >= what you deposited).
            assertLt(usdcAfter, usdcBefore,
                "RATCHET: fresh QUI round-tripped out for >= its mint cost");
        }
        vm.stopPrank();
        AUX.checkBacking();
    }
}
