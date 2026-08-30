// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {BitcoinTx} from "../../src/imports/BitcoinTx.sol";
import {Types, BadSPV} from "../../src/imports/Types.sol";

/// @notice (§SETTLE-PROVEN-UNTESTED) `settleSwapInProven` — **the only swap-in entrypoint
///         production actually calls**, exercised here for the first time.
///
/// 🔴 **WHY THIS FILE EXISTS.** The daemon settles on-chain swap-ins through this function
///    (`swap_in_onchain.rs:194` → `client.rs:640`), and before this file it had **ZERO** call
///    sites in `evm/test`. Meanwhile `parkProvenSats` — which has no Rust encoder and therefore
///    cannot be called in production at all — had five. **The coverage sat entirely on the
///    unreachable half of the pair**, which is how a green suite can coexist with an unexercised
///    money path. `§HOP-RCE-3` independently lists this function among the unaudited entrypoints.
///
/// ⚠️ **SCOPE, STATED SO IT IS NOT OVERREAD.** `SwapInDeposit.t.sol` already pins the address
///    derivation at the LIBRARY level and `MockSPV` is not an SPV proof. What is new here is the
///    ENTRYPOINT's own behaviour: authority, replay, the SPV gate, and — the part that carries
///    value — that the sats credited are the ones the PROOF derives and the floor is the one the
///    committed terms imply, neither of them a hop-supplied number.
contract SettleSwapInProvenTest is Test {
    /// secp256k1 G.x — the same stand-in for the pinned fleet deposit key that every BTCChannels
    /// construction in this suite already passes, so the fixture address derives identically.
    bytes32 constant INTERNAL =
        bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));
    bytes32 constant REFUND =
        bytes32(uint256(0x2F8BDE4D1A07209355B4A7250A5C5128E88B84BDDC619AB7CBA8D569B240EFE4));
    uint32  constant CLTV = 800_001;
    /// The deposit output key for (INTERNAL, terms, REFUND, CLTV), pinned by `SwapInDeposit.t.sol`.
    bytes32 constant EXPECTED_Q =
        bytes32(0xe74702c761ab3b61649eedb86bb4d8f5f7dfc84873e5096862b17fe08e69640d);
    uint64  constant SATS = 1_500_000;

    BTCChannels ch;
    MockBtcVault vault;
    address hop = makeAddr("hop");

    function setUp() public {
        vault = new MockBtcVault();
        ch = new BTCChannels(address(new SpvYes()), address(vault),
                             hop, makeAddr("hop-fallback"), INTERNAL);
    }

    function _terms() internal pure returns (Types.Terms memory) {
        return Types.Terms({
            seller: address(0xA1), token: address(0xB2),
            pricePerBtc: 50_000 * 1_000_000, slippageBps: 100
        });
    }

    function _proof() internal pure returns (Types.DepositProof memory) {
        return Types.DepositProof({
            userRefund: REFUND, cltvHeight: CLTV,
            blockHash: bytes32(uint256(0xB10C)), txIndex: 0, merkleProof: new bytes32[](0)
        });
    }

    function _le8(uint64 v) internal pure returns (bytes8 o) {
        for (uint i; i < 8; ++i) o |= bytes8(bytes1(uint8(v >> (8 * i)))) >> (8 * i);
    }

    function _depositTx(bytes memory spk, uint64 value) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"02000000", hex"01",
            bytes32(uint256(0xBEEF)), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le8(value), bytes1(uint8(spk.length)), spk,
            hex"00000000");
    }

    function _paid() internal pure returns (bytes memory) {
        return _depositTx(abi.encodePacked(hex"5120", EXPECTED_Q), SATS);
    }

    /// ⭐ THE ONE THAT CARRIES VALUE. The credited sats must come from the PROOF, and the floor
    /// from the COMMITTED TERMS — not from anything the hop passes alongside them. A hop that
    /// could name either number could buy USD for sats that never arrived, or accept a delivery
    /// below the rate the seller was quoted.
    function test_creditsTheProvenSatsAtTheCommittedFloor() public {
        vm.prank(hop);
        ch.settleSwapInProven(_terms(), _proof(), _paid());
        assertEq(vault.lastSats(), SATS, "sats must be derived from the deposit tx, not supplied");
        assertEq(vault.lastSeller(), address(0xA1), "the terms' seller is credited");
        assertEq(vault.lastToken(), address(0xB2), "the terms' token is delivered");
        assertEq(vault.lastMinUsd(), BitcoinTx.settleFloorUsd(_terms(), SATS),
            "the floor is derived from the committed rate and slippage");
        assertEq(vault.calls(), 1, "exactly one credit");
    }

    /// ⛔ THE ANTI-CONJURING PROPERTY, ASSERTED AT THE ENTRYPOINT. `SwapInDeposit.t.sol` proves
    /// the library refuses a foreign script; this proves nothing downstream re-admits it. A hop
    /// paying a script it controls must credit NOTHING, or a genuine SPV proof buys USD for BTC
    /// that never entered protocol custody.
    function test_aDepositToAScriptTheHopControlsCreditsNothing() public {
        bytes memory foreign = abi.encodePacked(hex"5120", bytes32(uint256(0xC0FFEE)));
        vm.prank(hop);
        vm.expectRevert(BitcoinTx.DepositNotPaid.selector);
        ch.settleSwapInProven(_terms(), _proof(), _depositTx(foreign, SATS));
        assertEq(vault.calls(), 0, "no credit may reach the vault");
    }

    /// One deposit, one credit. Without this the daemon's own retry-after-restart would pay twice.
    function test_theSameDepositCannotSettleTwice() public {
        vm.prank(hop);
        ch.settleSwapInProven(_terms(), _proof(), _paid());
        vm.prank(hop);
        vm.expectRevert(BTCChannels.SwapInDepositReplay.selector);
        ch.settleSwapInProven(_terms(), _proof(), _paid());
        assertEq(vault.calls(), 1, "the second attempt must not credit");
    }

    /// The authority gate. `_onlyHop` accepts either immutable hop; nobody else settles.
    function test_aStrangerCannotSettle() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BTCChannels.NotChannelHop.selector);
        ch.settleSwapInProven(_terms(), _proof(), _paid());
    }

    /// ⚠️ AND THE GATE THAT MAKES THE PROOF A PROOF. If SPV inclusion is refused the deposit is
    /// unconfirmed, and crediting it would pay for a transaction that may never be mined.
    function test_anUnprovenDepositIsRefused() public {
        BTCChannels no = new BTCChannels(address(new SpvNo()), address(vault),
                                         hop, makeAddr("hop-fallback"), INTERNAL);
        vm.prank(hop);
        vm.expectRevert(BadSPV.selector);
        no.settleSwapInProven(_terms(), _proof(), _paid());
        assertEq(vault.calls(), 0, "an unproven deposit credits nothing");
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

/// Records what the entrypoint hands the vault. Deliberately NOT the real `Vault`: what is under
/// test is which NUMBERS reach `creditSwapIn`, and a real vault would substitute its own pricing
/// for exactly the values these assertions exist to pin.
contract MockBtcVault {
    uint public calls;
    address public lastSeller;
    address public lastToken;
    uint public lastSats;
    uint public lastMinUsd;

    function creditSwapIn(address seller, uint sats, address token, uint minDeliveredUsd)
        external returns (uint)
    {
        ++calls;
        lastSeller = seller; lastSats = sats; lastToken = token; lastMinUsd = minDeliveredUsd;
        return sats;
    }
}
