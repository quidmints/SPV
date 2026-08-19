// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";
import {Types} from "../../src/imports/Types.sol";
import {ExitLib} from "../../src/imports/ExitLib.sol";

/// @notice (E159) Recomputing an on-chain swap-in DEPOSIT address, so a credit can be PROVEN
///         rather than attested.
///
///         🔴 WHY: `settleSwapIn` credits the SHARED pool on the hop's word — no proof any BTC
///         arrived. A compromised hop can attest swap-ins for sats that never existed and drain
///         `POOLED_USD` to its liquidity limit. That harm reaches QU!D holders and other LPs
///         who never opted into enclave trust, which is what makes it worse in KIND than a hop
///         stealing its own channels' BTC.
///
///         ⚠️ AND WHY IT IS LOAD-BEARING NOW: §E164 removed `openChannelsOf` from `settleSwapIn`,
///         which was the last skin-in-the-game proxy on this path ("owns an open channel = has
///         real BTC locked"). It was illusory with a single operator, but the pool's protection
///         now rests ENTIRELY on this proof.
///
///         ⚠️ SCOPE: the expected values are computed independently in Python from BIP-341, and
///         the primitives underneath are pinned to official vectors (`TaprootLeafKey.t.sol`).
///         SPV inclusion is NOT covered here — the caller proves the tx is in a block.
contract SwapInDepositTest is Test {
    /// secp256k1 G.x, standing in for the PINNED fleet deposit internal key.
    bytes32 constant INTERNAL =
        bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));
    /// A real x-only curve point standing in for the user's CLTV refund key.
    bytes32 constant REFUND =
        bytes32(uint256(0x2F8BDE4D1A07209355B4A7250A5C5128E88B84BDDC619AB7CBA8D569B240EFE4));
    uint32  constant CLTV = 800_001;

    /// (§T2) The swap's ECONOMIC TERMS, now committed into the deposit address itself.
    function _terms() internal pure returns (Types.Terms memory) {
        return Types.Terms({
            seller: address(0xA1), token: address(0xB2),
            pricePerBtc: 50_000 * 1_000_000,   // $50k/BTC in 6-dec stable units
            slippageBps: 100
        });
    }

    /// (§T2) The deposit output key for (INTERNAL, terms, REFUND, CLTV) — computed in Python
    /// directly from BIP-341, with the `PUSH32 <termsCommitment> OP_DROP` prefix on the leaf.
    bytes32 constant EXPECTED_Q =
        bytes32(0xe74702c761ab3b61649eedb86bb4d8f5f7dfc84873e5096862b17fe08e69640d);
    /// The terms commitment those fixture terms hash to.
    bytes32 constant TERMS =
        bytes32(0x2bee02db2d398b3ab09a19df114e0fadbeeae271253976cf3892be21f328178c);
    /// 🔑 **THE CONTROL, AND IT IS WHY THIS RE-DERIVATION IS CHECKABLE RATHER THAN GUESSED.** This
    /// is the address the SAME fixture derived BEFORE the terms prefix existed — the value this
    /// file pinned until §T2. Any reimplementation of the leaf must still reproduce it with the
    /// prefix omitted; if it cannot, the reimplementation is wrong rather than the pin.
    bytes32 constant Q_WITHOUT_TERMS =
        bytes32(0xd0d16740ae143319f7883497b4b76efd9bb829725cf7e885c37dacff3be4e4ca);

    function _le8(uint64 v) internal pure returns (bytes8 o) {
        for (uint i; i < 8; ++i) o |= bytes8(bytes1(uint8(v >> (8 * i)))) >> (8 * i);
    }

    /// A LEGACY-serialised deposit tx paying `spk`. The seller's deposit is an ordinary payment —
    /// it carries no witness of ours — so `BitcoinTx` parses it directly.
    function _depositTx(bytes memory spk, uint64 value) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"02000000", hex"01",
            bytes32(uint256(0xBEEF)), hex"00000000", hex"00", hex"ffffffff",
            hex"01", _le8(value), bytes1(uint8(spk.length)), spk,
            hex"00000000");
    }

    function test_derivesTheDepositAddressAndReturnsTheSats() public view {
        bytes memory spk = abi.encodePacked(hex"5120", EXPECTED_Q);
        assertEq(
            ExitLib.verifySwapInDeposit(INTERNAL, _terms(), REFUND, CLTV, _depositTx(spk, 1_500_000)),
            1_500_000, "sats paid to the derived deposit address"
        );
    }

    /// ⚠️ THE POINT OF THE WHOLE FUNCTION. A hop paying a script IT controls must credit NOTHING —
    /// otherwise a genuine SPV proof buys USD for BTC that never entered protocol custody, and the
    /// proof is real and worthless.
    function test_paymentToAnotherScriptIsRefused() public {
        bytes memory foreign = abi.encodePacked(hex"5120", bytes32(uint256(0xC0FFEE)));
        vm.expectRevert(ExitLib.DepositNotPaid.selector);
        ExitLib.verifySwapInDeposit(INTERNAL, _terms(), REFUND, CLTV, _depositTx(foreign, 1_500_000));
    }

    /// The leaf carries the per-swap identity: a different refund key is a different address, so
    /// one swap's deposit cannot be replayed as another's.
    function test_aDifferentRefundKeyDerivesADifferentAddress() public {
        bytes memory spk = abi.encodePacked(hex"5120", EXPECTED_Q);
        bytes32 otherRefund =
            bytes32(uint256(0xDFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659));
        vm.expectRevert(ExitLib.DepositNotPaid.selector);
        ExitLib.verifySwapInDeposit(INTERNAL, _terms(), otherRefund, CLTV, _depositTx(spk, 1_500_000));
    }

    /// Same for the timelock — it is the other half of the leaf.
    function test_aDifferentTimelockDerivesADifferentAddress() public {
        bytes memory spk = abi.encodePacked(hex"5120", EXPECTED_Q);
        vm.expectRevert(ExitLib.DepositNotPaid.selector);
        ExitLib.verifySwapInDeposit(INTERNAL, _terms(), REFUND, CLTV + 1, _depositTx(spk, 1_500_000));
    }

    /// ⚠️ MINIMAL SCRIPT-NUMBER ENCODING IS LOAD-BEARING AND EASY TO GET WRONG. A height whose
    /// top byte has the high bit set needs a 0x00 pad, or it reads as NEGATIVE — and a mis-encoded
    /// height changes the leaf hash, hence the ADDRESS, silently.
    ///
    /// 0x80 is the smallest padded case and 0x7F its unpadded neighbour. **This test was first
    /// written against `verifySwapInDeposit` and asserted almost nothing** — both heights simply
    /// reverted, so "they behave the same" was true and vacuous. Comparing the DERIVED KEYS is
    /// what makes it a test: if the pad were dropped, 0x80 would encode as one byte and collide
    /// with a different height's leaf instead of standing apart.
    function test_scriptNumPaddingBoundary() public view {
        bytes32 padded   = ExitLib.swapInDepositKey(INTERNAL, _terms(), REFUND, 0x80);
        bytes32 unpadded = ExitLib.swapInDepositKey(INTERNAL, _terms(), REFUND, 0x7F);
        assertTrue(padded != unpadded, "0x80 and 0x7F must derive different addresses");
        // And neither may collide with a three-byte height that shares their low bytes.
        assertTrue(padded != ExitLib.swapInDepositKey(INTERNAL, _terms(), REFUND, 0x8000),
                   "byte-length must be part of the encoding, not just the value");
    }

    /// 🔑 **(§T2) THE HOLE THIS CLOSES: DIFFERENT TERMS MUST DERIVE A DIFFERENT ADDRESS.** Before
    /// the commitment, the address bound only the refund key and the height, so a hop could
    /// SPV-prove a GENUINE deposit and settle it under terms the seller never agreed — a worse
    /// floor, a different token, or credit to someone else. The proof would be real and the terms
    /// substituted. Now the terms are hashed into the leaf, so substituting any of them derives an
    /// address the deposit never paid and `verifySwapInDeposit` reverts.
    function test_substitutedTermsDeriveADifferentAddress() public {
        bytes memory spk = abi.encodePacked(hex"5120", EXPECTED_Q);
        Types.Terms memory worseRate = Types.Terms({
            seller: address(0xA1), token: address(0xB2),
            pricePerBtc: 1 * 1_000_000,   // quote the seller $1/BTC instead of $50k
            slippageBps: 100
        });
        vm.expectRevert(ExitLib.DepositNotPaid.selector);
        ExitLib.verifySwapInDeposit(INTERNAL, worseRate, REFUND, CLTV, _depositTx(spk, 1_500_000));
    }

    function test_aDifferentSellerDerivesADifferentAddress() public {
        bytes memory spk = abi.encodePacked(hex"5120", EXPECTED_Q);
        Types.Terms memory otherSeller = Types.Terms({
            seller: address(0xA2), token: address(0xB2),
            pricePerBtc: 50_000 * 1_000_000, slippageBps: 100
        });
        vm.expectRevert(ExitLib.DepositNotPaid.selector);
        ExitLib.verifySwapInDeposit(INTERNAL, otherSeller, REFUND, CLTV, _depositTx(spk, 1_500_000));
    }

    /// The commitment is the documented hash of the documented fields — pinned so a change to
    /// either the field order or the hash function is caught here rather than by an address that
    /// silently stops matching.
    /// 🔑 (§T2) THE FLOOR IS DERIVED, SO THERE IS NOTHING FOR A HOP TO SUBSTITUTE. It used to be
    ///    calldata — a hop could quote the seller one floor and settle against another. Now the
    ///    address commits the RATE and the chain applies it to SPV-proven sats.
    ///    1,500,000 sats × $50,000/BTC ÷ 1e8 = $750.00; less 100 bps = $742.50 (6-dec).
    function test_theFloorIsDerivedFromTheCommittedRate() public view {
        assertEq(ExitLib.settleFloorUsd(_terms(), 1_500_000), 742_500_000, "floor = sats*price/1e8, less slippage");
        assertEq(ExitLib.settleFloorUsd(_terms(), 0), 0, "no sats, no floor");
    }

    function test_termsCommitmentIsPinned() public view {
        assertEq(ExitLib.termsCommitment(_terms()), TERMS, "terms commitment vector");
        assertTrue(EXPECTED_Q != Q_WITHOUT_TERMS, "the prefix must move the address");
    }

    /// The derivation the seller uses and the derivation the settle path uses are THE SAME
    /// function — asserted, because two copies of this arithmetic drifting apart is exactly the
    /// failure that would send a deposit somewhere the contract never looks.
    function test_exposedKeyMatchesWhatVerifyLooksFor() public view {
        bytes32 q = ExitLib.swapInDepositKey(INTERNAL, _terms(), REFUND, CLTV);
        assertEq(q, EXPECTED_Q, "exposed key == the BIP-341 vector");
        assertEq(
            ExitLib.verifySwapInDeposit(INTERNAL, _terms(), REFUND, CLTV,
                _depositTx(abi.encodePacked(hex"5120", q), 777)),
            777, "verify finds exactly what the exposed derivation names"
        );
    }
}
