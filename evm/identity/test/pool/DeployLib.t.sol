// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {DeployLib} from '../../contracts/pool/lib/DeployLib.sol';

/*
 * DeployLib is Privacy Pools' CREATE2 deterministic-deployment library. I DELETED IT AS DEAD CODE
 * and restored it: nothing references it because NOTHING IS DEPLOYED YET, which is not the same
 * thing. "Unused before deployment" is exactly the wrong inference to act on, and the mistake was
 * to reach for the same reasoning that correctly removed the superseded Groth16 verifiers.
 *
 * It is also load-bearing in a way that only shows up later: a wrong salt yields a DIFFERENT
 * address, and a deterministic deploy that lands somewhere unexpected is discovered by everything
 * downstream pointing at nothing.
 */
contract DeployLibTest is Test {
  address internal constant DEPLOYER = address(0xD3910736);

  /// @notice CreateX's guarded-salt layout: 20-byte deployer, 1 zero byte, 11-byte entropy.
  /// Getting the packing wrong silently changes every deployed address.
  function test_saltLayoutIsDeployerThenZeroThenEntropy() public pure {
    bytes32 s = DeployLib.salt(DEPLOYER, DeployLib.ENTRYPOINT_IMPL_SALT);

    assertEq(address(bytes20(s)), DEPLOYER, 'first 20 bytes must be the deployer');
    assertEq(uint8(s[20]), 0, 'byte 20 must be the zero separator');
    assertEq(bytes11(s << 168), DeployLib.ENTRYPOINT_IMPL_SALT, 'last 11 bytes must be the entropy');
  }

  /// @notice Different deployers must get different addresses, or two deployments collide.
  function test_saltIsDeployerScoped() public pure {
    assertTrue(
      DeployLib.salt(DEPLOYER, DeployLib.SIMPLE_POOL_SALT)
        != DeployLib.salt(address(0xBEEF), DeployLib.SIMPLE_POOL_SALT),
      'salt is not deployer-scoped'
    );
  }

  /// @notice Every predefined salt must be DISTINCT. Two components sharing one would fight for the
  /// same CREATE2 address - the second deploy simply reverts, and only at deploy time.
  function test_allPredefinedSaltsAreDistinct() public pure {
    bytes11[8] memory salts = [
      DeployLib.ENTRYPOINT_IMPL_SALT,
      DeployLib.ENTRYPOINT_PROXY_SALT,
      DeployLib.SIMPLE_POOL_SALT,
      DeployLib.COMPLEX_POOL_SALT,
      DeployLib.WITHDRAWAL_VERIFIER_SALT,
      DeployLib.RAGEQUIT_VERIFIER_SALT,
      DeployLib.IDENTITY_REGISTRY_SALT,
      DeployLib.ESCROW_VERIFIER_SALT
    ];
    for (uint256 i = 0; i < salts.length; i++) {
      for (uint256 j = i + 1; j < salts.length; j++) {
        assertTrue(salts[i] != salts[j], 'two components share a salt - their addresses collide');
      }
    }
  }

  function test_saltIsDeterministic() public pure {
    assertEq(
      DeployLib.salt(DEPLOYER, DeployLib.COMPLEX_POOL_SALT),
      DeployLib.salt(DEPLOYER, DeployLib.COMPLEX_POOL_SALT)
    );
  }
}
