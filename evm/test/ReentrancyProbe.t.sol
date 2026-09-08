// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture, MockSPV} from "./Alles.t.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {Types} from "../src/imports/Types.sol";

/// A token whose fallback WOULD re-enter the protocol. It is the INSTRUMENT of the third test
/// below, not decoration: `creditSwapIn` is handed this address as the swap-in payout token, and
/// the proof is that the call dies at validation with `StableMissing()` — so the fallback below is
/// never entered and the attacker never gets control.
/// 🔴 IT WAS DECLARED AND NEVER INSTANTIATED until 2026-09-08, next to a docblock claiming the
///    surface it names was proven closed. A mock that nothing constructs is prose with a compiler
///    check on its syntax; it proves nothing at all, and it reads exactly like coverage.
contract EvilToken {
    fallback() external { /* would re-enter here — but we never reach it */ }
}

/// Empirically prove the BTC swap-in re-entry SURFACE is closed. The nonReentrant guards on
/// redeem/swapTo/requestDeposit are belt-and-suspenders; the actual proof is that an attacker can
/// never obtain a callback on these paths. THREE CLAIMS, THREE TESTS, ONE FOR ONE:
///   (1) `creditSwapIn` is unreachable except via BTCChannels (itself nonReentrant + hop-gated) —
///       `onlyBTCChannels`. Asserted: `test_creditSwapIn_only_btcChannels`.
///   (2) `creditSwapOut`, the mirror, same gate. Asserted: `test_creditSwapOut_only_btcChannels`.
///   (3) the swap-in payout token MUST be a whitelisted basket stable, so a hook-bearing token
///       cannot be injected to gain control during delivery — `SwapLib.creditSwapInBody` runs
///       `_requireStable(aux, token)` BEFORE it draws any pool USD (`SwapLib.sol:624`), so an
///       unknown token reverts up-front rather than mid-delivery. Asserted:
///       `test_swapInPayoutToken_MustBeABasketStable`.
/// Deliveries are standard ERC20 / WETH (no native-ETH `call{value}`), so the protocol never hands
/// control to attacker code — the guards have nothing to fire against.
///
/// ⛔ THE LIST ABOVE USED TO HAVE FOUR ENTRIES AND THE FILE TWO TESTS, AND BOTH TESTS WERE ITEM (1).
///    The two that went, and why they are not coming back:
///      • *"(2) settleSwapIn is hop-gated — a non-hop can't even initiate a swap-in."* **There is no
///        `settleSwapIn`.** The entrypoint was deleted when its two unrelated jobs were split
///        (`BTCChannels.sol:2124`): the credit path is now `settleSwapInProven`, which requires an
///        SPV proof of the deposit rather than the hop's word, and the reversal is its own function.
///        A gate on a deleted function is not a surface, and "credit requires a proof" is a
///        STRONGER property than the one that sentence claimed — it belongs to the SPV suite, not
///        to a re-entrancy probe.
///      • *"(4) the ETH unlock callback is PoolManager-gated."* §V4-CUT deleted the PoolManager, the
///        unlock and the callback; the deletion note for the test that probed it is at the foot of
///        this file. A claim about a mechanism that does not exist cannot be closed OR open.
///    ⇒ A docblock enumerating more surfaces than the file tests is the failure mode this whole
///      file exists to catch, committed in the file's own header: it reads as four proofs and
///      delivered one, so the two REAL gaps (item 3 untested, EvilToken unused) were invisible
///      behind it. Keep the list one-for-one with the tests below.
contract ReentrancyProbe is AllesFixture {
    bytes constant HOP_PUBKEY =
        hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0";

    function _deployChannels() internal returns (BTCChannels ch) {
        ch = new BTCChannels(_realSPV(), address(BTC), makeAddr("hop"), makeAddr("hop-fallback"), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
        _btcChannels = address(ch);   // (E138) PoP digest binds this address
        AUX.setBTCChannels(address(ch));
    }

    // (1) creditSwapIn is unreachable except via BTCChannels. A direct call from
    //     a non-BTCChannels address reverts — so any re-entry MUST route through
    //     the nonReentrant + hop-gated settleSwapIn, which is the whole point.
    function test_creditSwapIn_only_btcChannels() public {
        _deployChannels();
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("NotBTCChannels()")));
        BTC.creditSwapIn(address(0xBAD), 1_000_000, address(USDC), 0);
    }

    function test_creditSwapOut_only_btcChannels() public {
        _deployChannels();
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("NotBTCChannels()")));
        BTC.creditSwapOut(address(0xBAD), address(USDC), 1e18, 0);
    }

    // (3) THE PAYOUT TOKEN MUST BE A BASKET STABLE. This is the claim `EvilToken` was declared for
    //     and never used to make. `creditSwapInBody` validates BEFORE it swaps: `_requireStable`
    //     reverts `StableMissing()` on any token `Aux.toIndex` does not know, so the pool USD is
    //     never drawn and the token's fallback never runs — the surface is closed at validation,
    //     not by a guard firing after control has already been handed over.
    // ⚠️ THE EXPECTED ERROR IS EXACT, DELIBERATELY. A bare `vm.expectRevert()` would also be
    //    satisfied by `NotBTCChannels()` — i.e. by the caller being wrong rather than the TOKEN
    //    being wrong — and would then pass while proving item (1) for a third time. The prank makes
    //    the caller legitimate precisely so that the only remaining reason to revert is the token.
    function test_swapInPayoutToken_MustBeABasketStable() public {
        BTCChannels ch = _deployChannels();
        EvilToken evil = new EvilToken();
        vm.prank(address(ch));
        vm.expectRevert(bytes4(keccak256("StableMissing()")));
        BTC.creditSwapIn(User01, 1_000_000, address(evil), 0);
    }

    // §ETH-ZERO — the unlock-callback reentrancy probe is DELETED WITH THE CALLBACK. It asserted
    // `Aux.unlockCallback` reverts `NotPoolManager()` for a forged caller, a real property of the
    // `SafeCallback` base. There is no PoolManager, no unlock and no callback to forge: the surface
    // it guarded does not exist, so the test could only assert that a missing function is missing.
}
