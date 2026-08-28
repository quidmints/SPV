// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IPassportDispatcher} from "../../interfaces/dispatchers/IPassportDispatcher.sol";
import {PECDSASHA1Authenticator} from "../authenticators/PECDSASHA1Authenticator.sol";
import {Bytes2Poseidon} from "../../utils/Bytes2Poseidon.sol";

contract PECDSASHA1Dispatcher is IPassportDispatcher, Initializable {
    using Bytes2Poseidon for bytes;

    address public authenticator;

    function __PECDSASHA1Dispatcher_init(address authenticator_) external initializer {
        authenticator = authenticator_;
    }

    /**
     * @notice Authenticate the ECDSA passport. Decode the pubkey and signature.
     */
    function authenticate(
        bytes memory challenge_,
        bytes memory passportSignature_,
        bytes memory passportPublicKey_
    ) external view returns (bool) {
        // BOUNDS BEFORE THE RAW READS (sec. 2.18ag). The four `mload`s below take fixed
        // offsets into caller-supplied arrays without consulting their lengths, so a short signature
        // or key silently pulls ADJACENT MEMORY into `r/s/x/y` - the same shape as the X509
        // out-of-bounds read in sec. 2.18m.
        //
        // NOT KNOWN TO BE EXPLOITABLE: whatever lands there still has to satisfy ECDSA verification
        // against the recovered key, and an attacker who could place a working tuple in adjacent
        // memory could simply pass it directly. That is an argument for it being low severity, NOT
        // for leaving a read unbounded - the reasoning holds only while nothing downstream changes.
        if (passportSignature_.length < 64 || passportPublicKey_.length < 64) {
            return false;
        }

        uint256 r_;
        uint256 s_;
        uint256 x_;
        uint256 y_;

        assembly {
            r_ := mload(add(passportSignature_, 32))
            s_ := mload(add(passportSignature_, 64))

            x_ := mload(add(passportPublicKey_, 32))
            y_ := mload(add(passportPublicKey_, 64))
        }

        return PECDSASHA1Authenticator(authenticator).authenticate(challenge_, r_, s_, x_, y_);
    }

    /**
     * @notice Get the passport challenge to be used in active authentication. The challenge is the last 8 bytes
     * of the identity key.
     */
    function getPassportChallenge(
        uint256 identityKey_
    ) external pure returns (bytes memory challenge_) {
        challenge_ = new bytes(8);

        for (uint256 i = 0; i < challenge_.length; ++i) {
            challenge_[challenge_.length - i - 1] = bytes1(uint8(identityKey_ >> (8 * i)));
        }
    }

    /**
     * @notice Get the ECDSA passport public key internal representation.
     */
    function getPassportKey(bytes memory passportPublicKey_) external pure returns (uint256) {
        return passportPublicKey_.hash512();
    }
}
