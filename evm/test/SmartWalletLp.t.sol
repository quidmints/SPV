// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ExitFixture} from "./btc/ExitFixture.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {Types} from "../src/imports/Types.sol";
import {ChannelLib} from "../src/imports/ChannelLib.sol";

/// @notice A REAL ERC-1271 wallet, not a stub: it validates the signature against a stored
///         owner exactly as a Safe does for a 1-of-1. A stub returning `true` unconditionally
///         would make every assertion below pass while proving nothing.
contract OwnerSignedWallet {
    address public owner;
    constructor(address owner_) { owner = owner_; }
    function setOwner(address o) external { owner = o; }   // owner rotation, as a Safe can
    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        (bytes32 r, bytes32 s_) = (bytes32(sig[0:32]), bytes32(sig[32:64]));
        uint8 v = uint8(sig[64]);
        return ecrecover(digest, v, r, s_) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice (E125-d, rewritten for E157) A SMART-WALLET LP can consent to an open. Before E125-d it
///         could not: every entrypoint used `ECDSA.recover`, and a contract has no key whose
///         signature recovers to its own address, so a Safe-custodied LP was locked out entirely.
///
///         ⚠️ WHAT CHANGED AND WHY THESE TESTS LOOK DIFFERENT: E157 folded `registerDelegation`
///         into `openChannel`, so there is no standing registration left to test. The property is
///         the same and it is now asserted where it actually lives — on the open. `SignatureChecker`
///         means ONE path serves both LP kinds; the second entrypoint existed only because
///         `ECDSA.recover` RETURNS a signer while ERC-1271 can only CONFIRM one.
///
///         ⚠️ HOW THESE ASSERT WITHOUT AN SPV FIXTURE, stated so a green run is not misread: the
///         consent check runs BEFORE the SPV proof, so a VALID signature reverts LATER (on the
///         funding proof) and an INVALID one reverts with `InvalidParam`. **The test is that the
///         revert MOVES.** It does not prove a channel opens — `OpenChannelE2E` does that.
contract SmartWalletLpTest is Test, ExitFixture {
    BTCChannels ch;
    OwnerSignedWallet wallet;
    address ownerAddr; uint ownerPk;

    bytes32 internal payoutKey;
    mapping(address => bytes) internal popFor;   // lpEth -> its proof-of-possession

    /// (E138) Precomputed in setUp, NOT inside `_open`. Building a PoP runs an FFI cheatcode, and
    /// a cheatcode call CONSUMES a pending `vm.expectRevert` — so generating it lazily made every
    /// revert assertion in this file fail with "call didn't revert at a lower depth", pointing
    /// nowhere near the cause. Same trap as `vm.prank` in the arming path.
    function _preparePoPs(address[] memory lps) internal {
        _btcChannels = address(ch);
        payoutKey = payoutKeyOnly(abi.encode("smartwallet-payout"));
        for (uint i; i < lps.length; ++i) popFor[lps[i]] = _popFor(payoutKey, lps[i]);
    }

    function setUp() public {
        ch = new BTCChannels(address(0xCA11), address(0x4006), makeAddr("hop"), makeAddr("hop-fallback"), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
        _btcChannels = address(ch);   // (E138) PoP digest binds this address
        (ownerAddr, ownerPk) = makeAddrAndKey("safe-owner");
        wallet = new OwnerSignedWallet(ownerAddr);
        (address eoaLp, ) = makeAddrAndKey("eoa-lp");
        address[] memory lps = new address[](2);
        lps[0] = address(wallet); lps[1] = eoaLp;
        _preparePoPs(lps);
    }

    function _sign(uint pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _payout() internal view returns (bytes32) { return payoutKey; }

    bytes32 constant Q = bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));

    function _params() internal pure returns (Types.OpenParams memory) {
        return Types.OpenParams({
            fundingBlockHash: bytes32(uint(1)), fundingBlockHeight: 1, fundingTxIndex: 0,
            lpPubkey: hex"02", hopPubkey: hex"03", amountSats: 100_000, fundingTaproot: Q });
    }

    /// ⚠️ **PRANKS AS THE HOP, AND WITHOUT IT THESE TESTS ASSERT NOTHING.** §E185 closed T7 by
    /// putting `_onlyHop()` on `openChannel` — `msg.sender` must be `MAIN_HOP`/`FALLBACK_HOP`.
    /// This helper called it from the test contract, so every open reverted `NotChannelHop`
    /// BEFORE reaching the consent check these tests exist to exercise. They were red, and the
    /// two that use a bare `vm.expectRevert()` would have gone GREEN on the wrong revert —
    /// asserting only that *something* failed. Authority-before-work is the right order for the
    /// contract; the tests simply had not caught up.
    function _open(address lpEth, bytes memory sig) internal {
        bytes32[] memory proof;
        vm.prank(makeAddr("hop"));   // the MAIN_HOP this suite's `setUp` constructs with
        ch.openChannel(_params(), hex"00", proof,
            Types.OpenAuth({ btcRecipient: payoutKey,
                            btcRecipientPoP: popFor[lpEth]}),
            _ladder(Types.ExitArming({prevValues: new uint64[](1), prevScripts: new bytes[](1), cltvDeadline: uint64(block.number + 144), checkpointSats: 0,
                              signedExitTx: hex"00"}))); 
    }

    /// A Safe's ERC-1271 signature is ACCEPTED: the open gets past consent and dies on the funding
    /// proof instead. If 1271 were unsupported this would revert `InvalidParam` right here.
    // ⛔ (§E183 item 1) THE THREE TESTS THAT STOOD HERE ARE DELETED, AND THEY WERE ALREADY VACUOUS.
    // They asserted that an ERC-1271 signature "gets past consent" while a stranger's is "refused AT
    // consent". `openChannel` no longer takes ANY LP signature, so `sig` was unused and BOTH calls
    // took the identical path — the discriminating half discriminated nothing, and both passed on a
    // bare `vm.expectRevert()`. Left in place they would have certified a property that no longer
    // exists, which is worse than no test.
    //
    // 🔴 AND THE CAPABILITY THEY GUARDED IS GONE, DELIBERATELY: `lpEth` is DERIVED from
    // `p.lpPubkey`, so it is necessarily the EOA address of that secp256k1 key. A contract wallet's
    // address comes from CREATE2 and cannot equal it, so A SMART-WALLET LP CAN NO LONGER OPEN A
    // CHANNEL. That is the price of "the LP signs nothing on the EVM" and it should be a decision,
    // not a discovery — see the queue row.

    /// The derivation itself, against a known-answer fixture rather than a round-trip of our own
    /// code: the generator point G is private key 1, so its compressed encoding must derive the
    /// address `vm.addr(1)`. If the parity branch or the keccak input were wrong this fails.
    function test_lpEthIsDerivedFromTheChannelKey() public view {
        bytes memory gCompressed =
            hex"0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        assertEq(ChannelLib.lpEthOf(gCompressed), vm.addr(1), "G must derive private key 1's address");
    }

    /// An `x` with no square root is not a public key. Without this check a caller supplies junk,
    /// gets a junk `y`, and derives an address IT controls — crediting itself for another LP's sats.
    function test_offCurveKeyDerivesNothing() public view {
        // x = 5 is the SMALLEST off-curve x: 5^3+7 = 132 is a non-residue mod p (Euler's
        // criterion). ⚠️ x = 1 is NOT off-curve — 8 IS a residue here — and my first draft of this
        // test asserted it was. The fixture was wrong, not the contract; computing the residue
        // rather than guessing is what caught it.
        bytes memory offCurve =
            hex"020000000000000000000000000000000000000000000000000000000000000005";
        assertEq(ChannelLib.lpEthOf(offCurve), address(0), "off-curve x must derive nothing");
        // A malformed prefix is rejected outright rather than silently treated as even-y.
        bytes memory badPrefix =
            hex"0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
        assertEq(ChannelLib.lpEthOf(badPrefix), address(0), "prefix must be 0x02 or 0x03");
        assertEq(ChannelLib.lpEthOf(hex"02"), address(0), "short key must derive nothing");
    }
}
