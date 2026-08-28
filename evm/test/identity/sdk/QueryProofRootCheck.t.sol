// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {AQueryProofExecutor} from '../../../src/identity/sdk/AQueryProofExecutor.sol';
import {PublicSignalsBuilder} from '../../../src/identity/sdk/lib/PublicSignalsBuilder.sol';
import {PoseidonSMTMock} from '../mocks/state/PoseidonSMTMock.sol';

/// A concrete executor - the base is abstract, and the point is to drive the REAL path.
contract QueryExecutor is AQueryProofExecutor {
    function init(address registrationSMT_, address verifier_) external initializer {
        __AQueryProofExecutor_init(registrationSMT_, verifier_);
    }

    function _buildPublicSignals(
        bytes32,
        uint256,
        bytes memory
    ) internal pure override returns (uint256) {
        return PublicSignalsBuilder.newPublicSignalsBuilder(0, 0);
    }

    function _buildPublicSignalsTD1(
        bytes32,
        uint256,
        bytes memory
    ) internal pure override returns (uint256) {
        return PublicSignalsBuilder.newPublicSignalsBuilder(0, 0);
    }
}

contract UnsafeQueryProxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, '') {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

contract SmtEvidence {
    mapping(bytes32 => bytes32) public statements;

    function addStatement(bytes32 k_, bytes32 v_) external {
        statements[keccak256(abi.encodePacked(msg.sender, k_))] = v_;
    }
}

/*
 * THE PRESENTATION PATH'S ROOT CHECK (sec. 2.18ae).
 *
 * `AQueryProofExecutor.execute*` take `registrationRoot_` FROM THE CALLER and feed it into the
 * public signals a `query_identity` proof is verified against. That is the sec. 2.18k vacuity shape:
 * a proof is perfectly sound about whatever tree the prover chose, so unless the root is checked
 * against a tree the contract trusts, an attacker builds a one-leaf tree containing an invented
 * identity and presents against it.
 *
 * THE CHECK EXISTS - `PublicSignalsBuilder.withIdStateRoot` calls `isRootValid` and reverts
 * `InvalidRegistrationRoot`. It is not in the executor, which is where one looks first.
 *
 * NOTHING EXERCISED IT. The only harness touching this path, `mock/sdk/ProofBuilderTest.sol`, wires
 * a `MockRegistrationSMT` whose `isRootValid` returns TRUE UNCONDITIONALLY - so the guard was
 * inert in every test that existed, and would have stayed green had it been deleted. This suite
 * uses a REAL `PoseidonSMT`.
 *
 * AND IT IS A FOURTH CONSUMER of the `isRootValid` that accepted ANY root on a chain younger than
 * an hour until sec. 2.18o fixed it - so before today this check was vacuous on a fresh chain or L2
 * even with a real SMT behind it.
 */
contract QueryProofRootCheckTest is Test {
    QueryExecutor internal executor;
    PoseidonSMTMock internal smt;

    function setUp() public {
        smt = PoseidonSMTMock(address(new UnsafeQueryProxy(address(new PoseidonSMTMock()))));
        smt.__PoseidonSMT_init(address(this), address(new SmtEvidence()), 80);

        executor = QueryExecutor(address(new UnsafeQueryProxy(address(new QueryExecutor()))));
        executor.init(address(smt), address(0xBEEF));

        vm.warp(1_700_000_000);
    }

    /// THE PROPERTY. A root the registration tree never held must be refused, and refused BEFORE the
    /// verifier is reached - which is what lets this run with no valid proof in existence.
    function test_RejectsARegistrationRootTheTreeNeverHeld() public {
        bytes32 invented_ = bytes32(uint256(0xBAD0));
        assertFalse(smt.isRootValid(invented_), 'precondition: the tree does not know this root');

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicSignalsBuilder.InvalidRegistrationRoot.selector, address(smt), invented_
            )
        );
        executor.executeNoir(invented_, 20_250_101, '', hex'1234');
    }

    /// The same on the TD1 entry point, which is the one the wallet's circuit registry targets.
    function test_RejectsAnInventedRootOnTheTD1Path() public {
        bytes32 invented_ = bytes32(uint256(0xBAD1));

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicSignalsBuilder.InvalidRegistrationRoot.selector, address(smt), invented_
            )
        );
        executor.executeTD1Noir(invented_, 20_250_101, '', hex'1234');
    }

    /// The zero root is the empty-tree sentinel and the default of any unset slot.
    function test_RejectsTheZeroRoot() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PublicSignalsBuilder.InvalidRegistrationRoot.selector, address(smt), bytes32(0)
            )
        );
        executor.executeNoir(bytes32(0), 20_250_101, '', hex'1234');
    }

    /// A root the tree DOES hold gets past the check and on to proof verification - so the guard is
    /// rejecting the root specifically, not failing everything for some unrelated reason.
    function test_AGenuineRootPassesTheRootCheck() public {
        smt.add(bytes32(uint256(7)), bytes32(uint256(7)));
        bytes32 real_ = smt.getRoot();
        assertTrue(smt.isRootValid(real_), 'precondition: the tree knows this root');

        // Reaches the verifier, which is address(0xBEEF) with no code - so it reverts THERE, not on
        // the root. Distinguishing the two is the whole point of this assertion.
        try executor.executeNoir(real_, 20_250_101, '', hex'1234') {
            fail('expected the call to reach the verifier and fail there');
        } catch (bytes memory reason_) {
            bytes4 sel_;
            if (reason_.length >= 4) {
                assembly {
                    sel_ := mload(add(reason_, 32))
                }
            }
            assertTrue(
                sel_ != PublicSignalsBuilder.InvalidRegistrationRoot.selector,
                'a root the tree holds was rejected as invalid'
            );
        }
    }
}
