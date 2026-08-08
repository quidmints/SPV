// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {Types} from "../../src/imports/Types.sol";
import {SPVGateway} from "../../src/spv/SPVGateway.sol";
import {BitcoinTx} from "../../src/imports/BitcoinTx.sol";
import {MuSig2Agg} from "../../src/imports/MuSig2Agg.sol";

/// @notice END-TO-END openChannel against a REAL Bitcoin funding tx.
///
///         The fixture (test/btc/open_channel_fixture.json) is produced by
///         `gen_open_channel_fixture.py` driving a LIVE bitcoind regtest node:
///         it builds the protocol's P2WSH 2-of-2 (LP+hop) funding output, funds
///         + confirms it, and shapes the witness-stripped legacy tx, the merkle
///         branch, and the header chain. Here that real data flows through the
///         ACTUAL SPVGateway (header chain + checkTxInclusion) and the ACTUAL
///         BTCChannels.openChannel — closing the gap BTCChannelsAuth.t.sol
///         leaves open (auth is tested there; SPV/funding e2e is tested here).
///
///         To regenerate the fixture (regtest must be up):
///             regtest/gen-fixture.sh
///         That is the ONE generator. `e2e_ffi` used to have a `fixture` sub-command that wrote
///         this same file; it was DELETED 2026-08-02 because the two had diverged — the Python
///         generator now emits 19 opens keyed `s<seed>_<sats>` for `_realOpen`, while the Rust
///         one still wrote a single flat open, so regenerating there would have silently
///         collapsed the fixture and made every lookup revert.

contract OpenChannelE2ETest is Test {
    /// (E130) Deterministic VALID x-only key — `0x5120||k` must be spendable, and ~half of
    /// arbitrary 32-byte values are not curve points. Grind, as real keygen does.
    function _validXOnly(bytes memory seed) internal pure returns (bytes32 k) {
        k = keccak256(seed);
        while (!BitcoinTx.isValidXOnlyKey(k)) k = keccak256(abi.encodePacked(k));
    }

    // Minimal Vogue: openChannel credits the LP's BTC pool position.
    MockVogue vogue;

    function setUp() public {
        vogue = new MockVogue();
    }

    /// Sign an open digest in its own frame (keeps the test's stack shallow).
    function _signOpen(uint pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Build the SPV header chain from REAL regtest headers in its own frame
    /// (returns the gw; parse locals stay confined here).
    function _buildChain(string memory json) internal returns (SPVGateway gw) {
        gw = new SPVGateway();
        gw.__SPVGateway_init(vm.parseJsonBytes(json, ".genesisHeader"), 0, 0); // regtest genesis, height 0
        gw.addBlockHeaderBatch(vm.parseJsonBytesArray(json, ".headers"));      // blocks 1..tip
        uint tip = vm.parseJsonUint(json, ".tip");
        assertEq(gw.getMainchainHeight(), tip, "header chain extended to tip");
        assertTrue(gw.isInMainchain(vm.parseJsonBytes32(json, ".fundingBlockHashBE")),
            "funding block on mainchain");
        // The funding block must have >= MIN_CONFIRMATIONS (6) on top.
        assertGe(tip - vm.parseJsonUint(json, ".fundingHeight"), 6, "funding block has >=6 confirmations");
    }

    /// Deploy BTCChannels + drive the real open (funding tx + SPV proof + lpAuth)
    /// in its own frame; returns only what the assertions need.
    function _openFromFixture(string memory json, SPVGateway gw)
        internal
        returns (BTCChannels ch, bytes32 channelId, address lpEth)
    {
        bytes memory hopPubkey = vm.parseJsonBytes(json, ".hopPubkey");
        // The hop's BTC pubkey is fixed at deploy; LP's is per-channel.
        ch = new BTCChannels(
            address(gw), address(0xA17), address(vogue), address(0xB0B));

        Types.OpenParams memory p = Types.OpenParams({
            fundingBlockHash:   vm.parseJsonBytes32(json, ".fundingBlockHashBE"),
            fundingBlockHeight: uint64(vm.parseJsonUint(json, ".fundingHeight")),
            fundingTxIndex:     vm.parseJsonUint(json, ".txIndex"),
            lpPubkey:           vm.parseJsonBytes(json, ".lpPubkey"),
            hopPubkey:          hopPubkey,
            amountSats:         vm.parseJsonUint(json, ".amountSats"),
            fundingTaproot:     vm.parseJsonBytes32(json, ".fundingTaproot")
        });

        // LP authorizes (owns the channel regardless of who relays). lpAuth is an
        // ECDSA sig over openChannelDigest; the recovered signer is the owner.
        uint lpPk;
        (lpEth, lpPk) = makeAddrAndKey("lp");
        channelId = _submitOpen(ch, json, p, lpPk);
    }

    /// Sign + submit the open in its own frame (rawTx/lpAuth/payout confined here).
    function _submitOpen(BTCChannels ch, string memory json, Types.OpenParams memory p, uint lpPk)
        internal
        returns (bytes32 channelId)
    {
        bytes memory rawTx = vm.parseJsonBytes(json, ".rawFundingTx");
        // Realistic btcRecipientOf: a full 32-byte x-only shutdown key distinct from the
        // funding material. This test asserts channel state at open only (no close/splice),
        // so the key is registered but not guard-validated — it must still be a proper key.
        bytes32 payout = _validXOnly(abi.encode("lp-shutdown-xonly", p.lpPubkey));
        // (B) The LP delegates channel operation to the hop (0xB0B) COLD, once: pins +
        // LOCKS btcRecipientOf[lpEth]=payout and delegatedAuthority[lpEth]=0xB0B. The
        // 4-arg open is then hop-gated (0xB0B) and credits the position to lpEth.
        address lpEth = vm.addr(lpPk);
        bytes memory dsig = _signOpen(lpPk, ch.delegationDigest(address(0xB0B), payout, 1));
        ch.registerDelegation(address(0xB0B), payout, 1, dsig);
        vm.prank(address(0xB0B)); // this hop must == the delegated authority above
        channelId = ch.openChannel(p, rawTx, vm.parseJsonBytes32Array(json, ".merkleBranch"), lpEth);
    }

    /// (E122) THE HAND-OVER GATE, on a REAL channel — the coverage `BTCChannelsFallback.t.sol`
    /// could not provide, because `_authorizedHopForChannel` needs a live channel and this is
    /// the only fixture that opens one against a real funding tx + SPV proof.
    ///
    /// Asserts the boundary EXACTLY, because the condition is strict `>`: at precisely
    /// `lastHeartbeat + FALLBACK_STALENESS_BLOCKS` the fallback must still be refused, and only
    /// one block later may it act. An off-by-one here would hand the channel over an entire
    /// block early, and no other test would notice.
    function test_E122_fallbackTakesOverOnlyAfterStaleness() public {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/test/btc/open_channel_fixture.json"));
        SPVGateway gw = _buildChain(json);
        (BTCChannels ch, bytes32 channelId,) = _openFromFixture(json, gw);

        (, uint lpPk) = makeAddrAndKey("lp");     // same LP the fixture opened with
        address fb = makeAddr("fallbackHop");
        address primary = address(0xB0B);

        // The LP names its fallback (version 2 — the open used 1).
        ch.registerFallback(fb, 2, _signOpen(lpPk, ch.fallbackDigest(fb, 2)));
        assertEq(ch.fallbackAuthority(vm.addr(lpPk)), fb, "fallback registered");

        // FRESH: the clock was seeded at open, so the fallback has no standing yet.
        vm.prank(fb);
        vm.expectRevert(BTCChannels.NotDelegatedHop.selector);
        ch.emitDeadManExit(channelId, uint64(block.number + 144), 50_000, hex"00");

        // The primary heartbeats, refreshing the clock.
        vm.prank(primary);
        ch.emitDeadManExit(channelId, uint64(block.number + 144), 50_000, hex"00");
        assertEq(ch.lastHeartbeatBlock(channelId), uint64(block.number), "primary set the clock");

        // EXACTLY at the window: still refused (strict `>`).
        vm.roll(block.number + ch.FALLBACK_STALENESS_BLOCKS());
        vm.prank(fb);
        vm.expectRevert(BTCChannels.NotDelegatedHop.selector);
        ch.emitDeadManExit(channelId, uint64(block.number + 144), 50_000, hex"00");

        // One block past: the fallback takes over, and refreshes the clock itself.
        vm.roll(block.number + 1);
        vm.prank(fb);
        ch.emitDeadManExit(channelId, uint64(block.number + 144), 50_000, hex"00");
        assertEq(ch.lastHeartbeatBlock(channelId), uint64(block.number), "fallback took over");

        // And the primary is NOT locked out by the hand-over — it can resume.
        vm.prank(primary);
        ch.emitDeadManExit(channelId, uint64(block.number + 144), 50_000, hex"00");
    }

    function test_openChannel_realRegtestFundingTx() public {
        // §9b/SIMPLE-TAPROOT: funding output is a real P2TR `0x5120||Q` (the MuSig2
        // key-path aggregate), NOT a P2WSH 2-of-2. The fixture is regenerated from a
        // LIVE bitcoind regtest open+coop-close via:
        //   cargo run -p quid-hop --features harness --bin e2e_ffi -- fixture \
        //     evm/test/btc/open_channel_fixture.json
        // The real funding tx + SPV proof + the byte-matched `fundingTaproot` flow
        // through the real SPVGateway + BTCChannels.openChannel.
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/test/btc/open_channel_fixture.json"));

        SPVGateway gw = _buildChain(json);
        (BTCChannels ch, bytes32 channelId, address lpEth) = _openFromFixture(json, gw);

        // Channel written, credited to the LP signer, with the funded sats.
        uint amount = vm.parseJsonUint(json, ".amountSats");
        (uint amountSats,, address ownerEth,, uint8 status,) = ch.channels(channelId);
        assertEq(amountSats, amount, "channel records funded sats");
        assertEq(ownerEth, lpEth, "channel owned by the lpAuth signer");
        assertEq(status, 0, "status OPEN");
        assertEq(ch.totalSatsLocked(), amount, "sats locked tracked");
        // BTC pool position credited to the LP for the locked sats.
        assertEq(vogue.registered(lpEth), amount, "registerBtcLp credited the LP");
    }

    /// (E147-g) THE ASSERTION WHOSE ABSENCE COST A WHOLE INVESTIGATION.
    ///
    /// The fixture's `fundingTaproot` MUST be the MuSig2 2-of-2 of its own recorded
    /// `lpPubkey`/`hopPubkey`. For every fixture this repo ever had it was NOT: the generator
    /// asked bitcoind for an unrelated `getnewaddress bech32m` and recorded THAT output key,
    /// while emitting two other wallet pubkeys as the channel keys. **The three had no
    /// relationship at all** — 0 of 19 entries satisfied this — and nothing noticed, because
    /// the contract only byte-matched `0x5120||Q` and never asked where Q came from.
    ///
    /// ⚠️ IT MUST BE ASSERTED **HERE**, NOT INSIDE A MONEY-PATH GUARD. When the KeyAgg check
    ///    was first wired into `_verifySplice`, this defect surfaced as "every real splice
    ///    reverts" — a liveness failure that read as a broken contract and got the (correct)
    ///    check reverted. A generator drift belongs in the fixture's own test, where it fails
    ///    as "the fixture is wrong" instead of "the protocol is wrong".
    function test_fixture_fundingTaproot_is_the_2of2_of_its_own_pubkeys() public view {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/test/btc/open_channel_fixture.json"));
        // The top-level entry the E2E open actually consumes.
        assertEq(
            MuSig2Agg.computeOutputKey(
                vm.parseJsonBytes(json, ".lpPubkey"), vm.parseJsonBytes(json, ".hopPubkey")),
            vm.parseJsonBytes32(json, ".fundingTaproot"),
            "fundingTaproot is not KeyAgg(lpPubkey, hopPubkey)"
        );
        // ...and every funded output in `opens`, so a partially-regenerated fixture (keys from
        // one run, transactions from another — the exact shape of the original defect) fails.
        // Iterate `bySeed` by its KEYS. Neither `.opens.length` nor `.opens[*].field` is a
        // valid forge json path -- both error with "must return exactly one JSON value" --
        // and `parseJsonKeys` is the one that enumerates without a hardcoded count, so a
        // fixture that grows or shrinks is still fully covered.
        string[] memory keys = vm.parseJsonKeys(json, ".bySeed");
        assertGt(keys.length, 0, "fixture carries no bySeed entries");
        for (uint i = 0; i < keys.length; ++i) {
            string memory at = string.concat(".bySeed.", keys[i]);
            assertEq(
                MuSig2Agg.computeOutputKey(
                    vm.parseJsonBytes(json, string.concat(at, ".lpPubkey")),
                    vm.parseJsonBytes(json, string.concat(at, ".hopPubkey"))),
                vm.parseJsonBytes32(json, string.concat(at, ".fundingTaproot")),
                string.concat(keys[i], ": fundingTaproot is not the 2-of-2 of its pubkeys")
            );
        }
    }
}

contract MockVogue {
    mapping(address => uint) public registered;
    function registerBtcLp(address lpEth, uint sats) external { registered[lpEth] += sats; }
    function unregisterBtcLp(address, uint) external {}
}
