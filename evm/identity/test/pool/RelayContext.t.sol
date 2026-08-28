// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {IEntrypoint} from '../../contracts/pool/interfaces/IEntrypoint.sol';
import {IPrivacyPool} from '../../contracts/pool/interfaces/IPrivacyPool.sol';
import {Constants} from '../../contracts/pool/lib/Constants.sol';

/*
 * Cross-checks the TypeScript `withdrawalContext()` in frontend/identity-wallet/src/pp/relay.ts
 * against the EXACT expression PrivacyPool.validWithdrawal enforces:
 *
 *   proof.context == keccak256(abi.encode(_withdrawal, SCOPE)) % SNARK_SCALAR_FIELD
 *
 * This is the highest-consequence encoding boundary in the withdrawal path. A mismatch does not
 * fail loudly at build time - it produces proofs that are individually expensive to generate and
 * then revert with ContextMismatch on submission, wasting the relayer's gas. `tsc` cannot catch it
 * (the TS side is string-typed ABI), so it is pinned here instead.
 *
 * The expected value below was produced by the TS implementation, not by this test - copying the
 * Solidity output into the assertion would make it tautological.
 */
contract RelayContextTest is Test {
  address internal constant ENTRYPOINT = 0x00000000000000000000000000000000000000e1;
  address internal constant RECIPIENT = 0x00000000000000000000000000000000000000A1;
  address internal constant FEE_RECIPIENT = 0x00000000000000000000000000000000000000f1;
  uint256 internal constant FEE_BPS = 250;
  uint256 internal constant SCOPE = 42;

  /// Emitted by frontend/identity-wallet/src/pp/relay.ts withdrawalContext() for these inputs.
  uint256 internal constant TS_CONTEXT =
    7_948_633_688_262_801_802_494_452_180_195_935_100_535_116_121_924_170_774_747_370_064_017_535_756_814;

  function test_TypeScriptContextMatchesSolidity() public pure {
    IEntrypoint.RelayData memory _relay =
      IEntrypoint.RelayData({recipient: RECIPIENT, feeRecipient: FEE_RECIPIENT, relayFeeBPS: FEE_BPS});

    IPrivacyPool.Withdrawal memory _withdrawal =
      IPrivacyPool.Withdrawal({processooor: ENTRYPOINT, data: abi.encode(_relay)});

    uint256 _solidityContext =
      uint256(keccak256(abi.encode(_withdrawal, SCOPE))) % Constants.SNARK_SCALAR_FIELD;

    assertEq(_solidityContext, TS_CONTEXT, 'TS withdrawalContext() diverged from Solidity');
  }

  /// @notice The RelayData encoding itself must match too - it is nested inside `withdrawal.data`,
  /// so an encoding difference there changes the context without being obvious.
  function test_RelayDataEncodingMatches() public pure {
    IEntrypoint.RelayData memory _relay =
      IEntrypoint.RelayData({recipient: RECIPIENT, feeRecipient: FEE_RECIPIENT, relayFeeBPS: FEE_BPS});
    assertEq(
      abi.encode(_relay),
      hex'00000000000000000000000000000000000000000000000000000000000000a1'
      hex'00000000000000000000000000000000000000000000000000000000000000f1'
      hex'00000000000000000000000000000000000000000000000000000000000000fa',
      'TS encodeRelayData() diverged from Solidity'
    );
  }
}
