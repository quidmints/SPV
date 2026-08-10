// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
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
contract SmartWalletLpTest is Test {
    BTCChannels ch;
    OwnerSignedWallet wallet;
    address ownerAddr; uint ownerPk;

    function setUp() public {
        ch = new BTCChannels(address(0xCA11), address(0x4006));
        (ownerAddr, ownerPk) = makeAddrAndKey("safe-owner");
        wallet = new OwnerSignedWallet(ownerAddr);
    }

    function _sign(uint pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _payout() internal pure returns (bytes32) {
        // A real x-only curve point (G.x) — `_registerBtcRecipient` rejects off-curve keys.
        return bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));
    }

    bytes32 constant Q = bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));

    function _params() internal pure returns (Types.OpenParams memory) {
        return Types.OpenParams({
            fundingBlockHash: bytes32(uint(1)), fundingBlockHeight: 1, fundingTxIndex: 0,
            lpPubkey: hex"02", hopPubkey: hex"03", amountSats: 100_000, fundingTaproot: Q });
    }

    function _open(address lpEth, bytes memory sig) internal {
        bytes32[] memory proof;
        ch.openChannel(_params(), hex"00", proof,
            Types.OpenAuth({lpEth: lpEth, btcRecipient: _payout(), lpSig: sig}),
            Types.ExitArming({cltvDeadline: uint64(block.number + 144), checkpointSats: 0,
                              signedExitTx: hex"00"}));
    }

    /// A Safe's ERC-1271 signature is ACCEPTED: the open gets past consent and dies on the funding
    /// proof instead. If 1271 were unsupported this would revert `InvalidParam` right here.
    function test_smartWalletLp_consentIsAccepted() public {
        bytes32 d = ch.openAuthDigest(address(this), _payout(), Q, 100_000);
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
        bytes32 d = ch.openAuthDigest(address(this), _payout(), Q, 100_000);
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
        bytes32 d = ch.openAuthDigest(address(this), _payout(), Q, 100_000);
        bytes memory sig = _sign(ownerPk, d);
        wallet.setOwner(address(0xDEAD));           // the Safe rotates owners
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        _open(address(wallet), sig);                // the same bytes no longer verify
    }
}
