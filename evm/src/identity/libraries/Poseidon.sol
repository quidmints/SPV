// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
 * EXTERNAL (DELEGATECALL) POSEIDON, DELIBERATELY - reverted from the `*Inline` libraries 2026-08-04.
 *
 * The inline variants are `internal`, so their assembly is COPIED INTO EVERY CALL SITE. Measured, that
 * is what made 18 contracts exceed the EIP-170 24,576-byte limit - and a contract over that limit
 * CANNOT BE DEPLOYED AT ALL, so it is not a trade-off, it is a blocker:
 *
 *                       inlined            external
 *   HolderStateKeeper   53,431 (over)      15,140
 *   StateKeeper         50,044 (over)      11,740
 *   PoseidonSMT         38,374 (over)      10,178
 *   contracts over EIP-170:  18                 0
 *
 * WHAT INLINING BOUGHT, measured in `test/libraries/PoseidonInlineGas.t.sol`: **4,186 gas per hash,
 * 12%** (29,043 inline vs 33,229 external) - not the ~91% an older note claimed, because the cost is
 * Poseidon's permutation and not the call. Twelve percent on hashing does not buy undeployable
 * contracts.
 *
 * The `inline/` libraries are KEPT, and are not dead: `PoseidonInlineGas.t.sol` and
 * `PoseidonInlineDifferential.t.sol` pin both the gas delta and per-arity equivalence against these
 * upstream ones, so the numbers above cannot drift back into prose.
 */

import {PoseidonT2} from "poseidon-solidity/PoseidonT2.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";
import {PoseidonT5} from "poseidon-solidity/PoseidonT5.sol";
import {PoseidonT6} from "poseidon-solidity/PoseidonT6.sol";

library PoseidonUnit1L {
    function poseidon(uint256[1] memory inputs_) internal pure returns (uint256) {
        return PoseidonT2.hash([inputs_[0]]);
    }
}

library PoseidonUnit2L {
    function poseidon(uint256[2] memory inputs_) internal pure returns (uint256) {
        return PoseidonT3.hash([inputs_[0], inputs_[1]]);
    }
}

library PoseidonUnit3L {
    function poseidon(uint256[3] memory inputs_) internal pure returns (uint256) {
        return PoseidonT4.hash([inputs_[0], inputs_[1], inputs_[2]]);
    }
}

library PoseidonUnit4L {
    function poseidon(uint256[4] memory inputs_) internal pure returns (uint256) {
        return PoseidonT5.hash([inputs_[0], inputs_[1], inputs_[2], inputs_[3]]);
    }
}

library PoseidonUnit5L {
    function poseidon(uint256[5] memory inputs_) internal pure returns (uint256) {
        return PoseidonT6.hash([inputs_[0], inputs_[1], inputs_[2], inputs_[3], inputs_[4]]);
    }
}
