// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../src/BTCChannels.sol";
import {AttestedHopRegistry, IDcapAttestation} from "../src/AttestedHopRegistry.sol";
import {Types} from "../src/imports/Types.sol";

/// @notice Focused coverage for the openChannel sig-recovery FRONT-RUN FIX.
///         We exercise the auth digest + signature recovery in isolation —
///         these run BEFORE the SPV/funding-tx validation, so we don't need a
///         real funding-tx fixture to prove the security property:
///
///           the channel is credited to the SIGNER of lpAuth, never to
///           msg.sender, so a relayer/front-runner cannot steal the mint.
///
///         End-to-end openChannel (valid SPV proof → channel written) is
///         covered by the Phase-B funding-tx fixture (separate, pending).
contract BTCChannelsAuthTest is Test {
    BTCChannels ch;

    function setUp() public {
        // Minimal deploy. Constructor is (spv, aux, vogue, hopNode); we only call
        // the view digest + the recovery path, which don't depend on them.
        ch = new BTCChannels(
            address(0xCA11),                 // spv (unused on the recovery path)
            address(0xA17),                  // aux
            address(0x4006),                 // vogue (unused on the recovery path)
            address(0xB0B)                   // hopNode
        );
    }

    function _params() internal view returns (Types.OpenParams memory p) {
        p = Types.OpenParams({
            fundingBlockHash:   bytes32(uint256(1)),
            fundingBlockHeight: 800000,
            fundingTxIndex:     3,
            lpPubkey:           hex"02aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
            hopPubkey:          hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0",
            amountSats:         100_000,
            fundingTaproot:     bytes32(uint256(0x7a))
        });
    }

    /// (#77) The attested-hop gate: pin-once, and once pinned a non-attested submitter can't become a shared-pool
    /// hop. The gate fires FIRST in openChannel (before any SPV/funding validation), so dummy funding data is fine.
    /// The DCAP verifier is external SGX infra never invoked on the not-attested path, so address(0) suffices here.
    function test_hopRegistry_gates_open_and_pins_once() public {
        AttestedHopRegistry reg = new AttestedHopRegistry(IDcapAttestation(address(0)), address(0x5AFE));
        // OFF by default (permissionless-open bootstrap). Pin it to turn the gate ON.
        ch.setHopRegistry(address(reg));
        // PIN-ONCE — a second set (even same addr, or to 0) reverts, so a later compromised owner can't disable it.
        vm.expectRevert(bytes("pinned"));
        ch.setHopRegistry(address(reg));
        vm.expectRevert(bytes("pinned"));
        ch.setHopRegistry(address(0));
        // A non-attested submitter (this contract; never attested in `reg`) can no longer open a channel.
        bytes32[] memory proof;
        vm.expectRevert(bytes("hop !attested"));
        // (B) 4-arg open (lpEth is the position owner). The registry gate
        // (_requireAttested) fires FIRST — before the delegation check — so this reverts
        // "hop !attested" regardless of whether a delegation exists.
        ch.openChannel(_params(), hex"00", proof, address(0xdEAD));
    }

    function test_digest_binds_chain_and_contract() public view {
        Types.OpenParams memory p = _params();
        bytes memory rawTx = hex"0200000001deadbeef";
        bytes32 d = ch.openChannelDigest(p, rawTx, address(0xB0B));
        // Recompute the expected digest exactly as the contract does.
        bytes32 expected = keccak256(abi.encode(
            keccak256("BTCChannels.openChannel.v2"),
            block.chainid,
            address(ch),
            keccak256(rawTx),
            keccak256(abi.encode(p)),
            address(0xB0B)
        ));
        assertEq(d, expected, "digest must bind tag+chainid+contract+tx+params+hop");
    }

    function test_digest_changes_with_params() public view {
        Types.OpenParams memory p = _params();
        bytes memory rawTx = hex"0200000001deadbeef";
        bytes32 d1 = ch.openChannelDigest(p, rawTx, address(0xB0B));
        p.amountSats = 999_999; // tamper
        bytes32 d2 = ch.openChannelDigest(p, rawTx, address(0xB0B));
        assertTrue(d1 != d2, "param tamper must change digest");
    }

    function test_digest_changes_with_funding_tx() public view {
        Types.OpenParams memory p = _params();
        bytes32 d1 = ch.openChannelDigest(p, hex"0200000001deadbeef", address(0xB0B));
        bytes32 d2 = ch.openChannelDigest(p, hex"0200000001deadbe00", address(0xB0B)); // tamper tx
        assertTrue(d1 != d2, "funding-tx tamper must change digest");
    }

    /// The core property: whoever signs the digest is the recovered owner —
    /// independent of who would submit the tx. We verify recovery matches the
    /// signer and NOT an arbitrary front-runner.
    /// The value the Rust hand-rolled encoder asserts against, verbatim from
    /// `quid-ln/quid-hop/src/evm_codec.rs::open_params_abi_matches_solidity`. It is a
    /// CONSTANT, but it is not a number picked to make this pass — it is the OTHER SIDE
    /// of a cross-language contract, and the whole point of the test is that the two
    /// sides must agree. If `Types.OpenParams` gains, drops, reorders or retypes a
    /// field, this test fails and that is the correct signal: the Rust encoder — which
    /// builds the calldata every real channel-open is submitted with, and whose lpAuth
    /// digest hashes exactly this encoding — has gone stale and would sign the wrong
    /// bytes.
    bytes32 constant RUST_OPENPARAMS_STRUCT_HASH =
        0xe5055c9a1fe82c0decd8413a97eb6579ded9e16299921d8cdf96d12078c52b2b;

    /// GROUND TRUTH for the Rust evm_codec ABI mirror
    /// (quid-hop open_params_abi_matches_solidity): keccak256(abi.encode(p)) for a fixed
    /// 7-field taproot OpenParams, pinning the Rust encoder byte-exact to Solidity's
    /// abi.encode. Field values below are the SAME fixture the Rust test builds.
    ///
    /// ⚠️ `lpPubkey` HERE IS DELIBERATELY NOT A CURVE POINT, AND MUST NOT BE "FIXED".
    ///    (E129-b) A sweep that replaced every off-curve compressed pubkey in `test/` with a
    ///    real one changed this byte too and broke the pin — the hash moved, and the failure
    ///    reads as "the Rust encoder went stale" when nothing about Rust had changed. Nothing
    ///    on this path decompresses: the test is `pure`, it calls no contract, and the KeyAgg
    ///    gate lives in `_verifySplice`, not the open. The only property these bytes need is
    ///    being IDENTICAL to `evm_codec.rs`'s fixture. Changing them requires regenerating the
    ///    Rust constant in the SAME commit, or the two sides disagree silently — which is the
    ///    exact failure this test exists to catch.
    ///
    /// This used to only `emit` the hash — it was a one-way broadcast that could print
    /// anything at all and still report PASS, so the pin existed only in Rust and only
    /// as long as somebody remembered to re-run this by hand and copy the number over.
    function test_openparams_abi_ground_truth() public pure {
        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   bytes32(hex"1111111111111111111111111111111111111111111111111111111111111111"),
            fundingBlockHeight: 800001,
            fundingTxIndex:     0,
            lpPubkey:           hex"020102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            hopPubkey:          hex"03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0",
            amountSats:         1_000_000,
            fundingTaproot:     bytes32(hex"2222222222222222222222222222222222222222222222222222222222222222")
        });
        bytes32 h = keccak256(abi.encode(p));

        // PREMISE: the pinned hash must actually COVER all seven fields. A hash match is
        // only a byte-exactness proof if every field feeds it — if one were dropped from
        // the encoding (or added to the struct but left out of `abi.encode`'s reach), a
        // matching hash would be a partial-coverage coincidence and the Rust encoder
        // could disagree on that field forever without either side noticing. Each
        // tamper is applied to a fresh copy and reverted, so the SAFETY check below
        // still sees the untouched fixture.
        _assertFieldIsCovered(p, h, 0); // fundingBlockHash
        _assertFieldIsCovered(p, h, 1); // fundingBlockHeight
        _assertFieldIsCovered(p, h, 2); // fundingTxIndex
        _assertFieldIsCovered(p, h, 3); // lpPubkey
        _assertFieldIsCovered(p, h, 4); // hopPubkey
        _assertFieldIsCovered(p, h, 5); // amountSats
        _assertFieldIsCovered(p, h, 6); // fundingTaproot

        // SAFETY: Solidity and Rust must produce the identical struct hash.
        assertEq(h, RUST_OPENPARAMS_STRUCT_HASH,
            "keccak256(abi.encode(OpenParams)) drifted from the Rust evm_codec ground truth");
    }

    /// Tamper exactly one field of a COPY of `p` and require the struct hash to move.
    function _assertFieldIsCovered(Types.OpenParams memory p, bytes32 h, uint field) internal pure {
        Types.OpenParams memory t = Types.OpenParams({
            fundingBlockHash:   p.fundingBlockHash,
            fundingBlockHeight: p.fundingBlockHeight,
            fundingTxIndex:     p.fundingTxIndex,
            lpPubkey:           p.lpPubkey,
            hopPubkey:          p.hopPubkey,
            amountSats:         p.amountSats,
            fundingTaproot:     p.fundingTaproot
        });
        if      (field == 0) t.fundingBlockHash   = bytes32(uint256(p.fundingBlockHash) ^ 1);
        else if (field == 1) t.fundingBlockHeight = p.fundingBlockHeight + 1;
        else if (field == 2) t.fundingTxIndex     = p.fundingTxIndex + 1;
        else if (field == 3) t.lpPubkey           = hex"02a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
        else if (field == 4) t.hopPubkey          = hex"03b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b3";
        else if (field == 5) t.amountSats         = p.amountSats + 1;
        else                 t.fundingTaproot     = bytes32(uint256(p.fundingTaproot) ^ 1);
        require(keccak256(abi.encode(t)) != h, "PREMISE: a field is NOT covered by the pinned struct hash");
    }

    function test_recovered_signer_is_the_lp_not_the_submitter() public {
        Types.OpenParams memory p = _params();
        bytes memory rawTx = hex"0200000001deadbeef";
        bytes32 d = ch.openChannelDigest(p, rawTx, address(0xB0B));

        (address lp, uint256 lpPk) = makeAddrAndKey("lp");
        (address attacker,)        = makeAddrAndKey("attacker");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lpPk, d);
        // ecrecover the same way the contract's ECDSA.recover does.
        address recovered = ecrecover(d, v, r, s);

        assertEq(recovered, lp, "recovered == LP signer");
        assertTrue(recovered != attacker, "front-runner cannot be the owner");
    }
}
