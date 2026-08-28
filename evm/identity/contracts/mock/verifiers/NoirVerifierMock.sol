// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {INoirVerifier} from "../../interfaces/verifiers/INoirVerifier.sol";

/// Configurable INoirVerifier double: verifies nothing cryptographically, just returns whatever
/// `shouldVerify` is set to (default true) - lets tests exercise HolderRegistration's real
/// signature/state-transition logic without needing an actual Honk/UltraPlonk proof. It serves the
/// PP side too - the Groth16 `VerifierMock` it once mirrored is gone, since both pool verifiers are
/// `INoirVerifier` now.
contract NoirVerifierMock is INoirVerifier {
    bool public shouldVerify = true;

    function setShouldVerify(bool shouldVerify_) external {
        shouldVerify = shouldVerify_;
    }

    function getVerificationKeyHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return shouldVerify;
    }
}
