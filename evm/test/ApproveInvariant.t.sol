// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ForkPin} from "./utils/ForkPin.sol";
import {ChannelLib} from "../src/imports/ChannelLib.sol";

/// @dev External boundary for `vm.expectRevert`. `_approveMax` is an INTERNAL library function, so it
///      is INLINED into its caller — a revert inside it aborts the TEST's own frame, and
///      `vm.expectRevert` only ever watches the NEXT EXTERNAL call. Without this shim the reject test
///      fails while the code under test is behaving correctly, which is how my first version read.
contract ApproveShim {
    function approveMax(address token, address spender) external { ChannelLib._approveMax(token, spender); }
}

/// §APPROVE-INVARIANT — the REJECT half of `ChannelLib._approveMax`.
///
/// ⚠️ WHY THIS FILE EXISTS: the ACCEPT half was already covered and the REJECT half was not. Every
/// fixture's `setUp` wires vaults through `initVaultsBody`, so a green suite proves the guard lets real
/// tokens through — and proves NOTHING about whether it ever fires. A one-way guard whose firing
/// direction is untested is a shape this repo has shipped before.
///
/// NO MOCKS — every address is real mainnet. The codeless case must be an address that GENUINELY has
/// no code: the defect being closed is that a call to a NON-CONTRACT returns `ok=true` with empty
/// returndata, which is byte-identical to USDT succeeding. A mock "token that returns nothing" would
/// test a fake and pass either way.
contract ApproveInvariantTest is Test, ForkPin {
    address constant USDT    = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // returns NO returndata
    address constant USDC    = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // returns true
    address constant SPENDER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant NO_CODE = 0x00000000000000000000000000000000DeaDBeef;

    ApproveShim shim;

    function setUp() public {
        // ⚠️ `_forkMainnet()` CREATES a fork; it does not SELECT one. Without the select, the test
        // runs on a blank chain where USDC itself has no code — and then EVERY case "fails" for the
        // environment rather than the code. My first version omitted this and read as three defects.
        vm.selectFork(_forkMainnet());
        shim = new ApproveShim();
        // Assert the precondition that makes every assertion below meaningful.
        assertGt(USDT.code.length, 0, "PREMISE: fork not selected - USDT has no code");
        assertGt(USDC.code.length, 0, "PREMISE: fork not selected - USDC has no code");
    }

    /// USDT returns no returndata and HAS code ⇒ accepted. This is the case the raw `call` exists for:
    /// a typed `IERC20.approve` would revert here.
    function test_Accepts_UsdtStyle_NoReturndata() public { shim.approveMax(USDT, SPENDER); }

    /// USDC returns `true` ⇒ accepted.
    function test_Accepts_StandardTrueReturn() public { shim.approveMax(USDC, SPENDER); }

    /// 🔴 THE REGRESSION THIS FILE IS FOR — and it caught a real hole in the first version of the
    /// guard, which omitted the `extcodesize` leg. A call to a codeless address succeeds with empty
    /// returndata, so without that leg this case PASSES and the caller is left believing an allowance
    /// exists that was never granted.
    function test_Rejects_CodelessAddress() public {
        assertEq(NO_CODE.code.length, 0, "PREMISE: the address must genuinely have no code");
        vm.expectRevert(ChannelLib.ApproveFailed.selector);
        shim.approveMax(NO_CODE, SPENDER);
    }
}
