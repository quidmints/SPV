// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AttestedHopRegistry, IDcapAttestation} from "../src/AttestedHopRegistry.sol";

/// @notice Stand-in for the audited Automata on-chain DCAP verifier. It does NOT
///         verify anything — it returns a caller-configured (success, output) so
///         the test can exercise the REGISTRY's whitelist / key-binding / gating
///         logic in isolation. The real verifier is plugged in by address at
///         deploy; only its OUTPUT OFFSETS need pinning against its version.
contract MockDcap is IDcapAttestation {
    bool public ok = true;

    function setOk(bool v) external {
        ok = v;
    }

    /// Build an output whose layout matches AttestedHopRegistry._parse:
    ///   [0x00..0x20)  MRENCLAVE
    ///   [0x20..0x40)  reportData[0..32]  (the TLS pk half — unused here)
    ///   [0x40..0x60)  reportData[32..64] with the 20-byte EVM addr in the top bytes
    function _output(bytes32 mrenclave, address bound) internal pure returns (bytes memory) {
        return abi.encodePacked(
            mrenclave,
            bytes32(0),
            bytes32(uint256(uint160(bound)) << 96)
        );
    }

    // The registry passes the raw quote through; we ABI-decode our own crafted
    // (mrenclave, bound) out of it so each test can pick them per-case.
    function verifyAndAttestOnChain(bytes calldata rawQuote)
        external
        view
        returns (bool, bytes memory)
    {
        (bytes32 mrenclave, address bound) = abi.decode(rawQuote, (bytes32, address));
        return (ok, _output(mrenclave, bound));
    }
}

contract AttestedHopRegistryTest is Test {
    MockDcap dcap;
    AttestedHopRegistry reg;

    address governance = address(0x5AFE); // the Safe
    address hop = address(0xB0B);
    bytes32 goodMr = keccak256("honest-build-v1");
    bytes32 badMr = keccak256("rogue-build");

    function setUp() public {
        dcap = new MockDcap();
        reg = new AttestedHopRegistry(IDcapAttestation(address(dcap)), governance);
        vm.prank(governance);
        reg.setMrenclave(goodMr, true);
    }

    // A quote that the mock will turn into (mrenclave, bound-addr).
    function _quote(bytes32 mrenclave, address bound) internal pure returns (bytes memory) {
        return abi.encode(mrenclave, bound);
    }

    // --- happy path -----------------------------------------------------------

    function test_register_whitelisted_binds_caller() public {
        assertFalse(reg.isAttested(hop));
        vm.prank(hop);
        reg.registerHop(_quote(goodMr, hop));
        assertTrue(reg.isAttested(hop));
        assertEq(reg.hopMrenclave(hop), goodMr);
    }

    // --- the pool-protecting rejections ---------------------------------------

    function test_reject_non_whitelisted_measurement() public {
        vm.prank(hop);
        vm.expectRevert(AttestedHopRegistry.MeasurementNotAllowed.selector);
        reg.registerHop(_quote(badMr, hop)); // valid quote, wrong code
    }

    function test_reject_key_binding_mismatch() public {
        // Quote attests an enclave bound to a DIFFERENT address than the caller —
        // i.e. someone replaying another hop's quote. Must not attest the caller.
        vm.prank(hop);
        vm.expectRevert(AttestedHopRegistry.KeyBindingMismatch.selector);
        reg.registerHop(_quote(goodMr, address(0xBEEF)));
    }

    function test_reject_invalid_quote() public {
        dcap.setOk(false);
        vm.prank(hop);
        vm.expectRevert(AttestedHopRegistry.QuoteInvalid.selector);
        reg.registerHop(_quote(goodMr, hop));
    }

    // --- governance: measurement whitelist ------------------------------------

    function test_only_governance_sets_measurement() public {
        vm.prank(hop);
        vm.expectRevert(AttestedHopRegistry.NotGovernance.selector);
        reg.setMrenclave(badMr, true);
    }

    function test_dewhitelist_instantly_disables_every_hop_running_it() public {
        vm.prank(hop);
        reg.registerHop(_quote(goodMr, hop));
        assertTrue(reg.isAttested(hop));

        // A measurement later found vulnerable is de-whitelisted; the hop is
        // disabled WITHOUT touching its record (covers the whole fleet at once).
        vm.prank(governance);
        reg.setMrenclave(goodMr, false);
        assertFalse(reg.isAttested(hop));
    }

    function test_revoke_single_hop() public {
        vm.prank(hop);
        reg.registerHop(_quote(goodMr, hop));
        assertTrue(reg.isAttested(hop));

        vm.prank(governance);
        reg.revokeHop(hop);
        assertFalse(reg.isAttested(hop));
    }

    function test_governance_handoff() public {
        address newGov = address(0xC0FFEE);
        vm.prank(governance);
        reg.setGovernance(newGov);
        assertEq(reg.governance(), newGov);

        // old governance can no longer act
        vm.prank(governance);
        vm.expectRevert(AttestedHopRegistry.NotGovernance.selector);
        reg.setMrenclave(badMr, true);
    }

    // --- upgrade path (the reason we keep a Safe, not renounce) ----------------

    function test_safe_can_whitelist_a_new_build_for_upgrade() public {
        bytes32 v2 = keccak256("honest-build-v2");
        vm.prank(governance);
        reg.setMrenclave(v2, true);

        // a hop running the new reproducible build registers under v2
        vm.prank(hop);
        reg.registerHop(_quote(v2, hop));
        assertTrue(reg.isAttested(hop));
    }
}
