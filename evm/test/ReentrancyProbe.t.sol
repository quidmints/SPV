// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles, MockSPV} from "./Alles.t.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {Types} from "../src/imports/Types.sol";

/// A token whose transfer WOULD re-enter the protocol — used to prove it can
/// never be injected as a swap-in payout token (rejected at validation, before
/// it ever gets control).
contract EvilToken {
    fallback() external { /* would re-enter here — but we never reach it */ }
}

/// Empirically prove the swap-in / BTC-path re-entry SURFACE is closed. The
/// nonReentrant guards on settleSwapIn/redeem/swapTo/registerBtcLp are
/// belt-and-suspenders; the actual proof is that an attacker can never obtain a
/// callback in these paths:
///   (1) creditSwapIn/creditSwapOut are unreachable except via BTCChannels
///       (which is nonReentrant + hop-gated) — onlyBTCChannels.
///   (2) settleSwapIn is hop-gated — a non-hop can't even initiate a swap-in.
///   (3) the swap-in payout token MUST be a whitelisted basket stable, so a
///       hook-bearing token can't be injected to gain control during delivery.
///   (4) the V4 unlock callback is PoolManager-gated — the swap path can't be
///       re-entered by forging the callback.
/// Deliveries are standard ERC20 / WETH (no native-ETH `call{value}`), so the
/// protocol never hands control to attacker code — the guards have nothing to
/// fire against.
contract ReentrancyProbe is Alles {
    bytes constant HOP_PUBKEY =
        hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0";

    function _deployChannels() internal returns (BTCChannels ch) {
        ch = new BTCChannels(_realSPV(), address(ETH));
        AUX.setBTCChannels(address(ch));
    }

    // (1) creditSwapIn is unreachable except via BTCChannels. A direct call from
    //     a non-BTCChannels address reverts — so any re-entry MUST route through
    //     the nonReentrant + hop-gated settleSwapIn, which is the whole point.
    function test_creditSwapIn_only_btcChannels() public {
        _deployChannels();
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("NotBTCChannels()")));
        ETH.creditSwapIn(address(0xBAD), 1_000_000, address(USDC), 0);
    }

    function test_creditSwapOut_only_btcChannels() public {
        _deployChannels();
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("NotBTCChannels()")));
        ETH.creditSwapOut(address(0xBAD), address(USDC), 1e18, 0);
    }

    // (2) settleSwapIn is hop-gated: a non-hop caller can't initiate a swap-in
    //     credit (so the only entry is the hop, through the nonReentrant guard).
    function test_settleSwapIn_only_hop() public {
        BTCChannels ch = _deployChannels();
        // MULTI-HOP: a caller that owns no open channel cannot attest a swap-in.
        vm.prank(address(0xBAD));
        vm.expectRevert(BTCChannels.NotChannelHop.selector);
        ch.settleSwapIn(address(0xBAD), 1_000_000, address(USDC), bytes32(uint(1)), 0, false);
    }

    // (3) THE creditSwapIn re-entry-vector closure: the payout token must be a
    //     REGISTERED basket stable. A malicious hook-bearing token (EvilToken)
    //     is rejected with StableMissing BEFORE any liquidity/state is touched,
    //     so it never gets the callback the agent's theory relied on. We pass the
    //     hop-gate (prank hop) and nonzero sats so we actually reach the
    //     creditSwapInBody validation.
    function test_swapIn_rejects_unregistered_hook_token() public {
        BTCChannels ch = _deployChannels();
        address evil = address(new EvilToken());
        // MULTI-HOP: give the hop a real open channel so it passes the attestation
        // gate and we actually reach the payout-token validation (the point of the test).
        _openHopChannel(ch, makeAddr("hop"), 1, 2e7);
        vm.prank(makeAddr("hop"));
        vm.expectRevert(bytes4(keccak256("StableMissing()")));
        ch.settleSwapIn(address(0x5E), 1_000_000, evil, bytes32(uint(7)), 0, false);
    }

    // (4) The Uniswap-v4 unlock callback is PoolManager-gated. An attacker can't
    //     forge it to re-enter the swap path mid-unlock.
    function test_unlockCallback_only_poolManager() public {
        vm.prank(address(0xBAD));
        // SafeCallback.onlyPoolManager (ImmutableState.NotPoolManager) — pin the
        // exact selector so this proves the GATE, not an ABI-decode failure. The
        // modifier checks msg.sender BEFORE decoding, so even well-formed callback
        // args revert here on the caller gate.
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        AUX.unlockCallback(abi.encode(uint8(0), bytes("")));
    }
}
