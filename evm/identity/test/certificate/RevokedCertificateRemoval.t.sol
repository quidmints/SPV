// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {StateKeeper} from '../../contracts/state/StateKeeper.sol';
import {EscrowFixtureBase} from '../registry/EscrowFixtureBase.sol';

/*
 * A CERTIFICATE REVOKED BEFORE ITS EXPIRY CAN BE REMOVED (TODO.md sec. 2.18ev).
 *
 * UNTIL THIS EXISTED IT COULD NOT BE, BY ANYONE. `removeCertificate` requires
 * `expirationTimestamp < block.timestamp`, so a compromised CSCA stayed usable for every passport it
 * had signed until the calendar caught up - years, for a country signing key. Certificate revocation
 * is the mechanism that CONTAINS a key compromise, and containment was waiting on expiry.
 *
 * KEYED ON THE PUBLIC KEY, not a serial. CRLs list `(issuer, serial)`, but this contract and the
 * circuits both key certificates by `getCertificateKey(publicKey)` - and the ICAO master list
 * carries the certificates themselves, so serial resolves to key OFF-CHAIN and only the key is
 * published on it. That is the difference between this and the sanctions predicate (2.18et): here
 * the identifier exists on both sides.
 *
 * ⚠️ WHAT THIS IS NOT: authority-free. The root is owner-set, exactly like `icaoMasterTreeMerkleRoot`.
 * The ICAO workflow verifies ICAO's own CMS signature but has no on-chain write path, so both roots
 * are typed in today. This makes revocation POSSIBLE; it does not make it trustless.
 */
contract RevokedCertificateRemovalTest is EscrowFixtureBase {
  /// The owner `EscrowFixtureBase` initialises the keeper with.
  address internal constant OWNER = address(0xA11CE);

  bytes32 internal constant CERT_A = bytes32(uint256(0xAAAA));
  bytes32 internal constant CERT_B = bytes32(uint256(0xBBBB));

  function setUp() public {
    _setUpStateKeeper();
    // Registered and NOT expired - the case that had no removal path at all.
    sk.addCertificate(CERT_A, block.timestamp + 365 days);
  }

  /// A two-leaf tree, so the proof is a real sibling rather than an empty array against a root that
  /// happens to equal the leaf - which would pass while proving nothing.
  function _rootAndProof(bytes32 leaf, bytes32 sibling)
    internal
    pure
    returns (bytes32 root, bytes32[] memory proof)
  {
    proof = new bytes32[](1);
    proof[0] = sibling;
    root = leaf < sibling
      ? keccak256(abi.encodePacked(leaf, sibling))
      : keccak256(abi.encodePacked(sibling, leaf));
  }

  /// THE GAP, pinned: an unexpired certificate cannot be removed by the old path, by anyone.
  function test_anUnexpiredCertificateCannotBeRemovedTheOldWay() public {
    vm.expectRevert('StateKeeper: certificate is not expired');
    sk.removeCertificate(CERT_A);
  }

  /// THE CLAIM: with a proof against the anchored set it can be - and by a stranger.
  function test_aProvenRevokedCertificateIsRemovedByAnyone() public {
    (bytes32 root, bytes32[] memory proof) = _rootAndProof(CERT_A, CERT_B);
    vm.prank(OWNER);
    sk.changeRevokedCertificatesRoot(root);

    vm.prank(address(0xDEAD)); // the proof is the authorisation, not a role
    sk.removeRevokedCertificate(CERT_A, proof);

    vm.expectRevert('StateKeeper: certificate is not registered');
    sk.removeRevokedCertificate(CERT_A, proof);
  }

  /*
   * NON-VACUITY. Without these, a function that ignored its proof would pass everything above.
   */
  function test_aCertificateNotInTheSetIsRefused() public {
    (bytes32 root, ) = _rootAndProof(CERT_A, CERT_B);
    vm.prank(OWNER);
    sk.changeRevokedCertificatesRoot(root);

    bytes32[] memory wrong = new bytes32[](1);
    wrong[0] = bytes32(uint256(0xCCCC));
    vm.expectRevert('StateKeeper: certificate is not proven revoked');
    sk.removeRevokedCertificate(CERT_A, wrong);
  }

  /// A zero root DISABLES the path rather than accepting every proof - the safe direction for a root
  /// that has not been established yet.
  function test_aZeroRootDisablesRemovalRatherThanAcceptingAnything() public {
    bytes32[] memory empty = new bytes32[](0);
    vm.expectRevert('StateKeeper: no revocation root');
    sk.removeRevokedCertificate(CERT_A, empty);
  }

  /// An unregistered certificate cannot be "removed" even with a valid proof, or the event would
  /// announce a removal that never happened.
  function test_anUnregisteredCertificateIsRefused() public {
    (bytes32 root, bytes32[] memory proof) = _rootAndProof(CERT_B, CERT_A);
    vm.prank(OWNER);
    sk.changeRevokedCertificatesRoot(root);

    vm.expectRevert('StateKeeper: certificate is not registered');
    sk.removeRevokedCertificate(CERT_B, proof);
  }

  /// ONLY THE OWNER SETS THE ROOT - the same authority as the ICAO master root, no more and no less.
  function test_onlyTheOwnerMaySetTheRevocationRoot() public {
    vm.prank(address(0xDEAD));
    vm.expectRevert();
    sk.changeRevokedCertificatesRoot(bytes32(uint256(9)));
  }
}
