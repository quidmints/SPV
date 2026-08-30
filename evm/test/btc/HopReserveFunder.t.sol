// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";
import {Types, BadSPV} from "../../src/imports/Types.sol";

/// @notice (§LN-RESERVE-FUNDER) The funder that makes the **Lightning** swap-in rail work.
///
/// 🔴 **THE STATE THIS FIXES.** `settleSwapInBuffered` is the entrypoint the LN rail actually calls
///    (`settle_swapin_calldata` builds `SIG_SETTLE_SWAP_IN_BUFFERED`; `swap_in.rs:291`;
///    `run_swap_in_sender` spawned unconditionally at `daemon.rs:345`). It is bounded by
///    `provenSatsAvailable`, whose ONLY increment was `parkProvenSats` — which has no Rust encoder
///    and no caller. **So every LN swap-in reverted `InsufficientProvenSats`.**
///
/// 🔑 **WHY A RESERVE AND NOT A PROOF.** There is no on-chain proof of an off-chain payment: the hop
///    ISSUES the invoice (`create_inbound_payment`), so it knows the preimage before any payment
///    exists and holding it proves nothing. The anti-conjuring guarantee can therefore only be a CAP
///    on what a compromised hop may credit. The cap was always the right idea; its funder required
///    an LP's 2-of-2 co-signature, for a rail whose purpose is serving swappers while LPs sleep.
///    **The fleet now funds its own cap against sats it holds on-chain — no LP, no channel, no
///    splice** — reusing the same SPV + txid-dedup path `_provenDeposit` uses.
contract HopReserveFunderTest is Test {
    bytes32 constant INTERNAL =
        bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));
    /// The fleet's reserve address — the hop's own wallet key-path P2TR (owner: "the third").
    bytes constant RESERVE =
        hex"5120c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
    uint64 constant TOPUP = 1_500_000;

    BTCChannels ch;
    MockBtcVault vault;
    address hop = makeAddr("hop");

    function setUp() public {
        vault = new MockBtcVault();
        ch = new BTCChannels(address(new SpvYes()), address(vault),
                             hop, makeAddr("hop-fallback"), INTERNAL);
        ch.setHopReserveScript(RESERVE);
    }

    function _le8(uint64 v) internal pure returns (bytes8 o) {
        for (uint i; i < 8; ++i) o |= bytes8(bytes1(uint8(v >> (8 * i)))) >> (8 * i);
    }

    /// A wallet-built funding tx, LEGACY (witness-stripped) — the shape `TxInclusion.raw` already
    /// hands every other proof path.
    ///
    /// ⚠️ **THAT IS FORCED, NOT STYLISTIC.** `BitcoinTx.txid` double-SHA256s its input WITHOUT
    /// stripping a witness, so passing segwit bytes yields a hash that is not the txid and fails
    /// SPV inclusion. An earlier draft of this file built a SEGWIT tx and still passed — only
    /// because `SpvYes` returns true unconditionally, so the wrong txid was never checked. The
    /// mock hid the mistake; the serialisation is pinned here so it cannot recur.
    function _fundingTx(bytes memory spk, uint64 value, uint nonce)
        internal pure returns (bytes memory)
    {
        return abi.encodePacked(
            hex"02000000", hex"01",
            bytes32(nonce), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le8(value), bytes1(uint8(spk.length)), spk,
            hex"00000000");
    }

    function _prove(bytes memory raw) internal {
        vm.prank(hop);
        ch.proveHopReserve(bytes32(uint256(0xB10C)), 0, new bytes32[](0), raw);
    }

    /// The allowance rises by exactly what the transaction paid the reserve.
    function test_provingAReserveRaisesTheAllowance() public {
        assertEq(ch.provenSatsAvailable(hop), 0, "starts empty");
        _prove(_fundingTx(RESERVE, TOPUP, 1));
        assertEq(ch.provenSatsAvailable(hop), TOPUP, "allowance == sats paid to the reserve");
    }

    /// ⭐ THE ONE THAT PROVES THE RAIL IS FIXED. Before: every LN swap-in reverts. After: it settles.
    function test_theLightningRailRevertsWithoutAReserveAndSucceedsWithOne() public {
        vm.prank(hop);
        vm.expectRevert(BTCChannels.InsufficientProvenSats.selector);
        ch.settleSwapInBuffered(bytes32(uint256(0x11)), address(0xA1), 1_000_000, address(0xB2), 0, true);

        _prove(_fundingTx(RESERVE, TOPUP, 2));

        vm.prank(hop);
        uint consumed = ch.settleSwapInBuffered(bytes32(uint256(0x22)), address(0xA1), 1_000_000, address(0xB2), 0, true);
        assertEq(consumed, 1_000_000, "the LN rail now settles");
        assertEq(ch.provenSatsAvailable(hop), TOPUP - 1_000_000, "and the cap is drawn down");
    }

    /// ⛔ ONE TRANSACTION, ONE TOP-UP. `swapInUsed` is shared with `_provenDeposit`, so a proof
    /// cannot be replayed — and the same tx cannot be banked once as a deposit and again as reserve.
    function test_theSameTransactionCannotTopUpTwice() public {
        bytes memory raw = _fundingTx(RESERVE, TOPUP, 3);
        _prove(raw);
        vm.prank(hop);
        vm.expectRevert(BTCChannels.SwapInDepositReplay.selector);
        ch.proveHopReserve(bytes32(uint256(0xB10C)), 0, new bytes32[](0), raw);
        assertEq(ch.provenSatsAvailable(hop), TOPUP, "no second credit");
    }

    /// ⛔ THE ANTI-CONJURING EDGE. A transaction paying somewhere the fleet does not hold must raise
    /// nothing, or the cap is backed by sats the protocol never received.
    function test_aTransactionPayingElsewhereRaisesNothing() public {
        bytes memory foreign = abi.encodePacked(hex"5120", bytes32(uint256(0xC0FFEE)));
        vm.prank(hop);
        vm.expectRevert(ChannelLib.ReserveNotPaid.selector);
        ch.proveHopReserve(bytes32(uint256(0xB10C)), 0, new bytes32[](0),
                           _fundingTx(foreign, TOPUP, 4));
        assertEq(ch.provenSatsAvailable(hop), 0, "nothing proven");
    }

    /// ⚠️ AND THE EMPTY-SCRIPT CASE, WHICH IS A SECURITY CHECK. With no reserve pinned, an empty
    /// script must not match a zero-length output and mint allowance against no backing.
    function test_anUnpinnedReserveProvesNothing() public {
        BTCChannels bare = new BTCChannels(address(new SpvYes()), address(vault),
                                           hop, makeAddr("hop-fallback"), INTERNAL);
        vm.prank(hop);
        vm.expectRevert(ChannelLib.ReserveNotPaid.selector);
        bare.proveHopReserve(bytes32(uint256(0xB10C)), 0, new bytes32[](0),
                             _fundingTx(hex"", TOPUP, 5));
    }

    function test_aStrangerCannotProveAReserve() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BTCChannels.NotChannelHop.selector);
        ch.proveHopReserve(bytes32(uint256(0xB10C)), 0, new bytes32[](0),
                           _fundingTx(RESERVE, TOPUP, 6));
    }

    /// An unconfirmed top-up proves nothing — the reserve must be real before it backs a credit.
    function test_anUnprovenTransactionRaisesNothing() public {
        BTCChannels no = new BTCChannels(address(new SpvNo()), address(vault),
                                         hop, makeAddr("hop-fallback"), INTERNAL);
        no.setHopReserveScript(RESERVE);
        vm.prank(hop);
        vm.expectRevert(BadSPV.selector);
        no.proveHopReserve(bytes32(uint256(0xB10C)), 0, new bytes32[](0),
                           _fundingTx(RESERVE, TOPUP, 7));
    }

    function test_onlyTheOwnerPinsTheReserve() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        ch.setHopReserveScript(hex"5120aa");
    }
}

contract SpvYes {
    function checkTxInclusion(bytes32[] calldata, bytes32, bytes32, uint256, uint256)
        external pure returns (bool) { return true; }
}

contract SpvNo {
    function checkTxInclusion(bytes32[] calldata, bytes32, bytes32, uint256, uint256)
        external pure returns (bool) { return false; }
}

contract MockBtcVault {
    function creditSwapIn(address, uint sats, address, uint) external pure returns (uint) {
        return sats;
    }
}
