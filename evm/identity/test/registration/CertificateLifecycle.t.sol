// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registration2} from "../../contracts/registration/Registration2.sol";
import {StateKeeper} from "../../contracts/state/StateKeeper.sol";
import {PoseidonSMT} from "../../contracts/state/PoseidonSMT.sol";

/*
 * THE CERTIFICATE PATHS HAD NO COVERAGE AT ALL (sec. 2.18gz).
 *
 * `Registration2` holds the ICAO certificate lifecycle and, until today, NOTHING instantiated it -
 * 56 test files, zero of them. `PassportVerifierRegistry.t.sol` covered the verifier registry; this
 * covers `registerCertificate` / `revokeCertificate`, which are the other half.
 *
 * WHAT IS WORTH PINNING HERE, and it is not the happy path.
 *
 * `revokeCertificate` takes no signature, has no owner check, and is callable by anyone. That looks
 * alarming and is CORRECT: it forwards to `StateKeeper.removeCertificate`, which is `onlyRegistration`
 * and requires `expirationTimestamp > 0 && < block.timestamp`. So the operation is permissionless
 * precisely BECAUSE its precondition is objectively checkable on-chain - an expiry is a fact the
 * contract can read, not a judgment somebody must make. Cleanup of expired state needs no authority.
 *
 * ⚠️ **THAT IS THE PROPERTY MOST LIKELY TO BE "FIXED" BY MISTAKE.** A reviewer seeing an unguarded
 * external revoke will reach for `onlyOwner`, which would reintroduce an authority for a predicate
 * that does not need one. These tests exist so that change fails loudly rather than looking tidy.
 *
 * NO MOCKS: real `Registration2`, real `StateKeeper`, real `PoseidonSMT`.
 */
contract UnsafeTestProxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

contract CertificateLifecycleTest is Test {
    Registration2 internal registration;
    StateKeeper internal stateKeeper;

    address internal owner = address(this);
    address internal stranger = address(0xDECAF);

    uint256 internal constant TREE_DEPTH = 80;
    bytes32 internal constant ICAO_ROOT = keccak256("ICAO_MASTER_ROOT_FIXTURE");

    function setUp() public {
        stateKeeper = StateKeeper(_proxy(address(new StateKeeper())));
        PoseidonSMT registrationSmt = PoseidonSMT(_proxy(address(new PoseidonSMT())));
        PoseidonSMT certificatesSmt = PoseidonSMT(_proxy(address(new PoseidonSMT())));

        registrationSmt.__PoseidonSMT_init(address(stateKeeper), address(0), TREE_DEPTH);
        certificatesSmt.__PoseidonSMT_init(address(stateKeeper), address(0), TREE_DEPTH);

        stateKeeper.__StateKeeper_init(
            owner, address(registrationSmt), address(certificatesSmt), ICAO_ROOT
        );

        registration = Registration2(_proxy(address(new Registration2())));
        registration.__Registration_init(address(stateKeeper));

        // AUTHORISE IT WITH THE KEEPER. `onlyRegistration` is an ALLOWLIST, not a type check -
        // deploying a Registration2 and pointing it at the keeper is not enough, the keeper must be
        // told about it. Without this every call fails "StateKeeper: not a registration", which is
        // how this setUp was wrong the first time and is worth stating: the two contracts know each
        // other in BOTH directions, and only one of them is established by the initializer.
        string[] memory keys = new string[](1);
        keys[0] = "REGISTRATION";
        address[] memory vals = new address[](1);
        vals[0] = address(registration);
        stateKeeper.updateRegistrationSet(
            StateKeeper.MethodId.AddRegistrations, abi.encode(keys, vals)
        );
    }

    function _proxy(address impl) private returns (address) {
        return address(new UnsafeTestProxy(impl));
    }

    /// Revoking something that was never registered must fail on the EXPIRY rule, not on a lookup.
    /// `expirationTimestamp == 0` is indistinguishable from "unknown", and the guard covers both -
    /// which is why the condition is `> 0 &&` rather than just `< block.timestamp`.
    function test_revokingAnUnknownCertificateReverts() public {
        vm.expectRevert("StateKeeper: certificate is not expired");
        registration.revokeCertificate(keccak256("never registered"));
    }

    /// ⚠️ PERMISSIONLESS BY DESIGN. A stranger gets the SAME revert as the owner - the expiry rule,
    /// not an authorisation one. If this ever fails with an ownership error, someone has added an
    /// authority to a predicate that has on-chain ground truth and does not need one.
    function test_revocationIsGatedOnExpiryNotOnCaller() public {
        vm.prank(stranger);
        vm.expectRevert("StateKeeper: certificate is not expired");
        registration.revokeCertificate(keccak256("never registered"));
    }

    /// The keeper's own entrypoint is NOT public: only the registration contract may reach it, so
    /// the expiry rule cannot be bypassed by calling the keeper directly.
    function test_theKeeperRefusesDirectRemoval() public {
        vm.prank(stranger);
        vm.expectRevert();
        stateKeeper.removeCertificate(keccak256("anything"));
    }

    /// `registerCertificate` resolves a dispatcher by `dataType` FIRST. With none registered the call
    /// cannot proceed, which is what stops an unknown certificate format reaching the ICAO check.
    function test_registerWithoutADispatcherReverts() public {
        Registration2.Certificate memory cert;
        cert.dataType = keccak256("NO_SUCH_DISPATCHER");

        Registration2.ICAOMember memory member;
        member.publicKey = hex"1234";
        member.signature = hex"5678";

        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert();
        registration.registerCertificate(cert, member, proof);
    }

    /// The ICAO root the keeper was initialised with is what `registerCertificate` compares against.
    /// Pinning it here means a change to that plumbing shows up as a failure in this file rather
    /// than as an unexplained "invalid icao proof" somewhere downstream.
    function test_theKeeperHoldsTheIcaoRootRegistrationChecksAgainst() public view {
        assertEq(stateKeeper.icaoMasterTreeMerkleRoot(), ICAO_ROOT, "icao root plumbing");
    }
}
