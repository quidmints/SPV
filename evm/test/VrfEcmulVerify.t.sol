// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {VRF} from "./vendor/VRF_chainlink.sol";

/// @notice (E127) EVALUATION of Chainlink's `_ecmulVerify` / `_linearCombination` as the
///         primitive for verifying `Q == KeyAgg(lpPubkey, hopPubkey)` on-chain.
///
///         ⚠️ WHY NOT A FORK. The owner asked not to trust Etherscan and to check against
///         chain reality. For these functions a fork proves nothing: they are `pure`, so
///         the ground truth is the secp256k1 CURVE, not any deployment. The stronger check
///         — and the one that would have caught crysol's `isOnCurve` bug — is canonical
///         vectors. G, 2G and 3G below are the standard secp256k1 values.
///
///         The source itself came from Chainlink's published npm contracts package,
///         not from a block explorer, and these tests verify its BEHAVIOUR rather than
///         trusting either provenance.
contract VrfEcmulVerifyTest is Test, VRF {
    // Canonical secp256k1 generator and its first two multiples.
    uint256 constant GX  = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 constant GY  = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    uint256 constant G2X = 0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5;
    uint256 constant G2Y = 0x1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A;
    uint256 constant G3X = 0xF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9;
    uint256 constant G3Y = 0x388F7B0F632DE8140FE337E62A37F3566500A99934C2231B6CB9FD7584B8E672;

    function _G()  internal pure returns (uint256[2] memory) { return [GX, GY]; }
    function _G2() internal pure returns (uint256[2] memory) { return [G2X, G2Y]; }
    function _G3() internal pure returns (uint256[2] memory) { return [G3X, G3Y]; }

    /// The vectors themselves must be on the curve, or every test below is vacuous.
    function test_vectors_are_on_curve() public pure {
        assertTrue(_isOnCurve(_G()),  "G on curve");
        assertTrue(_isOnCurve(_G2()), "2G on curve");
        assertTrue(_isOnCurve(_G3()), "3G on curve");
    }

    /// The primitive we would rely on: does it actually verify scalar multiplication?
    function test_ecmulVerify_accepts_correct_products() public pure {
        assertTrue(_ecmulVerify(_G(), 2, _G2()), "2*G == 2G");
        assertTrue(_ecmulVerify(_G(), 3, _G3()), "3*G == 3G");
        // Non-generator base: 2G is a perfectly ordinary point.
        assertTrue(_ecmulVerify(_G2(), 1, _G2()), "1*2G == 2G");
    }

    /// ⚠️ THE CONTROL. A verifier that accepts everything would pass the test above.
    function test_ecmulVerify_rejects_wrong_products() public pure {
        assertFalse(_ecmulVerify(_G(), 2, _G3()), "2*G != 3G");
        assertFalse(_ecmulVerify(_G(), 3, _G2()), "3*G != 2G");
        assertFalse(_ecmulVerify(_G2(), 2, _G3()), "2*2G != 3G");
    }

    /// Its one documented precondition, and the reason a zero scalar is refused:
    /// it would be an ecrecover failure case rather than a false verification.
    function test_ecmulVerify_rejects_zero_scalar() public {
        vm.expectRevert(bytes("zero scalar"));
        this.ecmulVerifyExternal(_G(), 0, _G());
    }

    function ecmulVerifyExternal(uint256[2] memory a, uint256 s, uint256[2] memory p)
        external pure returns (bool) { return _ecmulVerify(a, s, p); }

    /// ⛔ THE CAVEAT THAT DECIDES REUSE. `_linearCombination`'s own comment says it
    ///    "Assumes that all points are on secp256k1 (which is checked in _verifyVRFProof
    ///    below.)" — so lifting it out of VRF's proof path DROPS the on-curve check.
    ///    That is precisely crysol's bug class. This proves the gap is real: an off-curve
    ///    point sails through `_ecmulVerify` unchallenged.
    function test_ecmulVerify_does_NOT_check_the_operands_are_on_curve() public pure {
        uint256[2] memory offCurve = [uint256(1), uint256(1)];   // y²  != x³+7
        assertFalse(_isOnCurve(offCurve), "premise: (1,1) is off-curve");
        // It does not revert; it simply returns a verdict on garbage. Any caller that
        // lifts `_linearCombination` MUST run `_isOnCurve` on every operand itself.
        _ecmulVerify(offCurve, 2, _G2());
    }
}
