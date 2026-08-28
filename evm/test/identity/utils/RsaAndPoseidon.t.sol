// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {RSA} from '../../../src/identity/utils/RSA.sol';
import {Bytes2Poseidon} from '../../../src/identity/utils/Bytes2Poseidon.sol';

/*
 * RSA and Bytes2Poseidon had no tests, and both sit directly under passport verification:
 * CRSASigner / CRSADispatcher / PRSASHAAuthenticator verify signatures with RSA.decrypt, and
 * Bytes2Poseidon turns passport bytes into the field elements the circuits commit to.
 *
 * RSA vector generated independently in Python (Miller-Rabin primes, s = m^d mod n), so this
 * checks the 0x05 modexp plumbing rather than re-deriving the same arithmetic twice.
 */
contract RsaAndPoseidonTest is Test {
  bytes internal constant N =
    hex'd2130e0f0a7800d0227ac746946847f32094f2a6f93777781a0ffba7150bebfd2a966603f8ac2431e895b35083832b4eedcb408b6ebcaee9b826754830052a99';
  bytes internal constant E = hex'010001';
  bytes internal constant S =
    hex'2eb6141873bffeeaf25708911f6836b85e1610f45f86e8a5eb5fff4e3fc7a5ae9d4d0aa9356e48ad102e0d5c3078e3dfc15751b0ced474f1dc526e4667a718ca';
  bytes internal constant M =
    hex'00000000000000000000000000000000000000000000000000000000000000001234567890abcdef1122334455667788990011223344556677889900aabbccdd';

  // ── RSA ──────────────────────────────────────────────────────────────────────────────────

  /// @notice s^e mod n must recover the message. This is the whole of RSA signature verification;
  /// if the precompile plumbing (length prefixes, output buffer) is wrong, every passport fails.
  function test_decryptRecoversTheMessage() public view {
    assertEq(RSA.decrypt(S, E, N), M, 'modexp did not recover m');
  }

  /// @notice A tampered signature must NOT recover the message - otherwise verification would
  /// accept forgeries.
  function test_decryptRejectsATamperedSignature() public view {
    bytes memory bad = S;
    bad[0] = bytes1(uint8(bad[0]) ^ 0x01);
    assertTrue(keccak256(RSA.decrypt(bad, E, N)) != keccak256(M), 'a tampered signature recovered m');
  }

  /// @notice The output is exactly the modulus length - the caller slices a digest out of it, so a
  /// short or long buffer would misalign every subsequent read.
  function test_decryptOutputIsModulusLength() public view {
    assertEq(RSA.decrypt(S, E, N).length, N.length, 'output length != modulus length');
  }

  // ── Bytes2Poseidon ───────────────────────────────────────────────────────────────────────

  /*
   * THE TOP BYTE IS DISCARDED, DELIBERATELY. hash512 reduces each 32-byte word mod 2**248 to fit
   * BN254's ~254-bit field, so inputs differing ONLY in the high byte of a word hash IDENTICALLY.
   *
   * That is not a bug - a 256-bit word cannot be a field element - but it is a property callers
   * must know: this is not a collision-resistant hash over arbitrary 64 bytes, and it must match
   * whatever the circuit does with the same input, or on-chain and in-circuit commitments diverge.
   * Pinned here so a future change cannot quietly alter the reduction.
   */
  function test_hash512DiscardsTheTopByteOfEachWord() public pure {
    bytes memory a = new bytes(64);
    bytes memory b = new bytes(64);
    for (uint256 i = 0; i < 64; i++) {
      a[i] = bytes1(uint8(i + 1));
      b[i] = bytes1(uint8(i + 1));
    }
    b[0] = bytes1(uint8(0xFF)); // top byte of word 0 only
    b[32] = bytes1(uint8(0xFF)); // top byte of word 1 only

    assertEq(
      Bytes2Poseidon.hash512(a),
      Bytes2Poseidon.hash512(b),
      'the mod 2**248 reduction no longer discards the top byte'
    );
  }

  /// @notice ...but ANY other byte must change the hash, or the reduction is eating too much.
  function test_hash512IsSensitiveToEveryOtherByte() public pure {
    bytes memory a = new bytes(64);
    for (uint256 i = 0; i < 64; i++) a[i] = bytes1(uint8(i + 1));
    uint256 base = Bytes2Poseidon.hash512(a);

    for (uint256 pos = 1; pos < 64; pos++) {
      if (pos == 32) continue; // the other discarded top byte
      bytes memory m = new bytes(64);
      for (uint256 i = 0; i < 64; i++) m[i] = a[i];
      m[pos] = bytes1(uint8(uint8(m[pos]) ^ 0x01));
      assertTrue(Bytes2Poseidon.hash512(m) != base, 'a non-top byte did not affect the hash');
    }
  }

  function test_hash512IsDeterministic() public pure {
    bytes memory a = new bytes(64);
    for (uint256 i = 0; i < 64; i++) a[i] = bytes1(uint8(i * 7));
    assertEq(Bytes2Poseidon.hash512(a), Bytes2Poseidon.hash512(a));
  }
}
