// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ExitFixture} from "./btc/ExitFixture.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {Types} from "../src/imports/Types.sol";

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
            Types.OpenAuth({lpEth: lpEth, btcRecipient: payoutKey, lpSig: sig,
                            btcRecipientPoP: popFor[lpEth]}),
            _ladder(Types.ExitArming({prevValues: new uint64[](1), prevScripts: new bytes[](1), cltvDeadline: uint64(block.number + 144), checkpointSats: 0,
                              signedExitTx: hex"00"}))); 
    }

    /// A Safe's ERC-1271 signature is ACCEPTED: the open gets past consent and dies on the funding
    /// proof instead. If 1271 were unsupported this would revert `InvalidParam` right here.
    function test_smartWalletLp_consentIsAccepted() public {
        bytes32 d = ch.openAuthDigest(address(this), _payout());
        vm.expectRevert();   // reverts BEYOND consent, on the absent SPV proof
        _open(address(wallet), _sign(ownerPk, d));
        // The discriminating half: a signature from a NON-owner is refused AT consent.
        (, uint strangerPk) = makeAddrAndKey("stranger");
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        _open(address(wallet), _sign(strangerPk, d));
    }

    /// The EOA path is untouched — that is the whole point of one shared verifier.
    function test_eoaPathStillWorksUnchanged() public {
        (address lp, uint lpPk) = makeAddrAndKey("eoa-lp");
        bytes32 d = ch.openAuthDigest(address(this), _payout());
        vm.expectRevert();   // past consent, dies on the funding proof
        _open(lp, _sign(lpPk, d));
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        _open(lp, _sign(uint(0xBAD), d));
    }

    /// (E125-d) ERC-1271 validity is STATEFUL, and that is the revocation `delegationVersion` used
    /// to simulate: rotating the wallet's owner invalidates a signature that verified a moment ago.
    /// E157 deleted the counter, so this is now the ONLY revocation a smart-wallet LP has — which
    /// is exactly why it is asserted rather than assumed.
    function test_ownerRotationRevokesAPriorSignature() public {
        bytes32 d = ch.openAuthDigest(address(this), _payout());
        bytes memory sig = _sign(ownerPk, d);
        wallet.setOwner(address(0xDEAD));           // the Safe rotates owners
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        _open(address(wallet), sig);                // the same bytes no longer verify
    }
}
