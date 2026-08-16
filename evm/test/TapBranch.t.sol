// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MuSig2Agg} from "../src/imports/MuSig2Agg.sol";

/*
 * (§T2) `MuSig2Agg.tapBranch` — the one primitive missing before a swap-in deposit address can
 * commit to more than its refund leaf.
 *
 * WHY THIS IS TESTED AGAINST A SECOND IMPLEMENTATION RATHER THAN AGAINST ITSELF. The obvious test
 * — call `tapBranch` and compare to `taggedHash("TapBranch", ...)` — proves only that the function
 * calls the helper it visibly calls. It would pass just as happily if `taggedHash` itself were
 * wrong, and a wrong tagged hash here does not revert: it produces a well-formed 32 bytes, a
 * well-formed merkle root, and a well-formed Bitcoin address THAT NOBODY WILL EVER PAY. So the
 * expected value below is rebuilt from raw `sha256` per BIP-340's definition
 * (`sha256(sha256(tag) || sha256(tag) || msg)`), which is an independent path to the same number.
 *
 * ⚠️ STILL MISSING, AND BOOKED RATHER THAN GLOSSED: a vector from BIP-341's own test data, or a
 * cross-check against `rust-bitcoin`'s `TapNodeHash`. Both implementations here are ours, so they
 * could be jointly wrong about the TAG STRING while agreeing perfectly on the construction.
 */
contract TapBranchTest is Test {
    bytes32 constant A = keccak256("leaf-a");
    bytes32 constant B = keccak256("leaf-b");

    function _expected(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        (bytes32 lo, bytes32 hi) = x < y ? (x, y) : (y, x);
        bytes32 tag = sha256("TapBranch");
        return sha256(abi.encodePacked(tag, tag, lo, hi));
    }

    /// The construction itself, against the independent rebuild.
    function test_matchesTheBip341Construction() public pure {
        assertEq(MuSig2Agg.tapBranch(A, B), _expected(A, B), "TapBranch construction");
    }

    /// ⚠️ THE PROPERTY THE SORT EXISTS FOR. BIP-341 orders the children lexicographically so a
    /// merkle path need not say which side a sibling was on. If this ever fails, every address
    /// derived from a two-leaf tree is one Bitcoin will not recognise.
    function test_isCommutativeBecauseTheChildrenAreSorted() public pure {
        assertEq(MuSig2Agg.tapBranch(A, B), MuSig2Agg.tapBranch(B, A), "not commutative");
    }

    /// Sorting must not collapse distinct trees: different children, different parent.
    function test_distinctChildrenGiveDistinctParents() public pure {
        bytes32 c = keccak256("leaf-c");
        assertTrue(MuSig2Agg.tapBranch(A, B) != MuSig2Agg.tapBranch(A, c), "collision");
        assertTrue(MuSig2Agg.tapBranch(A, B) != A, "parent equals a child");
        assertTrue(MuSig2Agg.tapBranch(A, B) != B, "parent equals a child");
    }

    /// ⚠️ DOMAIN SEPARATION IS THE WHOLE POINT OF A TAGGED HASH. A branch and a leaf over the same
    /// bytes must differ, or a leaf could be presented as an internal node and a merkle proof
    /// would admit a script that was never committed.
    function test_aBranchIsNotALeaf() public pure {
        bytes memory script = abi.encodePacked(A);
        assertTrue(
            MuSig2Agg.tapBranch(A, A) != MuSig2Agg.tapLeafHash(script),
            "branch and leaf share a domain"
        );
    }

    /// Equal children are legal (a balanced tree padded with a duplicate) and must still sort.
    function test_equalChildren() public pure {
        assertEq(MuSig2Agg.tapBranch(A, A), _expected(A, A), "equal children");
    }

    function testFuzz_commutativeAndSeparated(bytes32 x, bytes32 y) public pure {
        assertEq(MuSig2Agg.tapBranch(x, y), MuSig2Agg.tapBranch(y, x));
        assertEq(MuSig2Agg.tapBranch(x, y), _expected(x, y));
    }
}
