// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../src/BTCChannels.sol";

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

/// @notice (E125-d) A SMART-WALLET LP can register a delegation. Before this, it could not:
///         both entrypoints used `ECDSA.recover`, and a contract has no key whose signature
///         recovers to its own address — so a Safe-custodied LP was locked out entirely.
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

    function test_smartWalletLp_canRegisterDelegation() public {
        bytes32 d = ch.delegationDigest(address(0xB0B), _payout(), 1);
        ch.registerDelegationFor(address(wallet), address(0xB0B), _payout(), 1, _sign(ownerPk, d));
        assertEq(ch.delegatedAuthority(address(wallet)), address(0xB0B), "wallet's hop is delegated");
        assertEq(ch.btcRecipientOf(address(wallet)), _payout(), "wallet's payout key is pinned");
        assertEq(ch.delegationVersion(address(wallet)), 1, "version recorded");
    }

    /// ⚠️ THE CONTROL. Everything above passes for an implementation that ignores the signature
    ///    entirely. This is the property that matters: naming an account you cannot sign for
    ///    must fail — otherwise anyone could bind any LP's position to a hop they control.
    function test_cannotRegisterForAnAccountYouCannotSignFor() public {
        (, uint strangerPk) = makeAddrAndKey("stranger");
        bytes32 d = ch.delegationDigest(address(0xB0B), _payout(), 1);
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        ch.registerDelegationFor(address(wallet), address(0xB0B), _payout(), 1, _sign(strangerPk, d));
    }

    /// ERC-1271 validity is STATEFUL — the property that gives a smart-wallet LP revocation an
    /// EOA cannot have. The same bytes that verified before owner rotation must fail after.
    function test_ownerRotationRevokesAPreSignedRegistration() public {
        bytes32 d = ch.delegationDigest(address(0xB0B), _payout(), 2);
        bytes memory sig = _sign(ownerPk, d);
        (address newOwner,) = makeAddrAndKey("rotated-owner");
        wallet.setOwner(newOwner);
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        ch.registerDelegationFor(address(wallet), address(0xB0B), _payout(), 2, sig);
    }

    /// The EOA path is untouched — that is the whole point of adding rather than widening.
    function test_eoaPathStillWorksUnchanged() public {
        (address lp, uint lpPk) = makeAddrAndKey("eoa-lp");
        bytes32 d = ch.delegationDigest(address(0xB0B), _payout(), 1);
        ch.registerDelegation(address(0xB0B), _payout(), 1, _sign(lpPk, d));
        assertEq(ch.delegatedAuthority(lp), address(0xB0B), "EOA delegation unchanged");
    }
}
