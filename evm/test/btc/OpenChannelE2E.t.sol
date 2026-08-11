// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ExitFixture} from "./ExitFixture.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";
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

contract OpenChannelE2ETest is Test, ExitFixture {
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
        return _openFromFixture(json, gw, bytes32(0));
    }

    function _openFromFixture(string memory json, SPVGateway gw, bytes32 payoutOverride)
        internal
        returns (BTCChannels ch, bytes32 channelId, address lpEth)
    {
        bytes memory hopPubkey = vm.parseJsonBytes(json, ".hopPubkey");
        // The hop's BTC pubkey is fixed at deploy; LP's is per-channel.
        // (E164) This file operates the channel as 0xB0B, so that address must BE `MAIN_HOP` —
        // authority is a global immutable pair now, not per-channel state.
        ch = new BTCChannels(address(gw), address(vogue), address(0xB0B), address(0xFA11), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
        _btcChannels = address(ch);   // (E138) PoP digest binds this address

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
        channelId = _submitOpen(ch, json, p, lpPk, payoutOverride);
    }

    /// Sign + submit the open in its own frame (rawTx/lpAuth/payout confined here).
    /// @param payoutOverride when non-zero, pin THIS as `btcRecipientOf` instead of the derived
    ///        shutdown key. A SHRINK splice's withdrawal output pins to `btcRecipientOf`, so a
    ///        test driving the fixture's real splice must pin the key that splice actually pays.
    function _submitOpen(BTCChannels ch, string memory json, Types.OpenParams memory p, uint lpPk,
                         bytes32 payoutOverride)
        internal
        returns (bytes32 channelId)
    {
        bytes memory rawTx = vm.parseJsonBytes(json, ".rawFundingTx");
        // Realistic btcRecipientOf: a full 32-byte x-only shutdown key distinct from the
        // funding material. This test asserts channel state at open only (no close/splice),
        // so the key is registered but not guard-validated — it must still be a proper key.
        bytes32 payout = payoutOverride != bytes32(0)
            ? payoutOverride
            : payoutKeyOnly(abi.encode(p.lpPubkey));
        // (E157) One transaction: the LP signs for THIS channel (hop 0xB0B, this payout, this Q,
        // this size) and the hop submits that consent WITH the open. It pins + LOCKS
        // btcRecipientOf[lpEth]=payout and credits the position to lpEth.
        address lpEth = vm.addr(lpPk);
        bytes memory dsig = _signOpen(lpPk,
            ch.openAuthDigest(address(0xB0B), payout));
        // (E128) Built BEFORE the prank: `signedExitFull` runs an FFI cheatcode, and a cheatcode
        // call CONSUMES a pending prank — as a call argument it would send `openChannel` from the
        // test contract instead of 0xB0B, and the LP signature would fail to recover.
        Types.ExitArming memory arm_ = _armRegtest(p, rawTx, json, payout);
        // (E138) `mkAuth` is a second FFI caller now (the payout PoP) — same hoist, same reason.
        Types.OpenAuth memory auth_ = mkAuth(lpEth, payout, dsig);
        bytes32[] memory branch_ = vm.parseJsonBytes32Array(json, ".merkleBranch");
        vm.prank(address(0xB0B)); // must be the hop the LP signed for
        channelId = ch.openChannel(p, rawTx, branch_, auth_, _ladder(arm_));
    }

    /// (E128) Arm the REGTEST channel with a genuinely signed exit. Its keys come from the
    /// fixture's own label convention (`quid-fixture-{lp,hop}-{seed}-{sats}`), the funding output
    /// is LOCATED rather than assumed to be vout 0 (a real tx has change), and the txid is the
    /// INTERNAL-order double-SHA — not the fixture's byte-reversed `fundingTxidDisplay`.
    function _armRegtest(
        Types.OpenParams memory p, bytes memory rawTx, string memory json, bytes32 payout
    ) private returns (Types.ExitArming memory) {
        uint seed = vm.parseJsonUint(json, ".seed");
        uint32 vout = ChannelLib.locateChannelOutput(
            rawTx, p.lpPubkey, p.hopPubkey, p.fundingTaproot, p.amountSats);
        return Types.ExitArming({
            prevValues: new uint64[](1), prevScripts: new bytes[](1),
            cltvDeadline: 900_000, checkpointSats: 0,
            signedExitTx: signedExitFull(
                string.concat("quid-fixture-lp-", vm.toString(seed), "-", vm.toString(p.amountSats)),
                string.concat("quid-fixture-hop-", vm.toString(seed), "-", vm.toString(p.amountSats)),
                sha256(abi.encodePacked(sha256(rawTx))), vout, p.amountSats,
                abi.encodePacked(hex"5120", payout), 900_000, 1_000)
        });
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
        (uint amountSats, , address ownerEth, , uint8 status, ) = ch.channels(channelId);
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

    /// (E147-i) THE FIRST TEST EVER TO DRIVE `splice()` FROM REAL BITCOIN DATA.
    ///
    /// Its absence is the direct cause of E147: the E129 KeyAgg gate was wired, went green on
    /// fixtures that built `Q` with `MuSig2Agg` itself, and would have REJECTED EVERY REAL
    /// SPLICE in production — funds stuck in channels that could neither grow nor shrink.
    /// Nothing could have caught that except exercising the real splice path.
    ///
    /// The fixture's splice is a SHRINK: 20,000,000 -> 15,000,000 sats, withdrawing 5,000,000
    /// to `payoutScript`. Since E147-g it is a GENUINE 2-of-2 key-path spend of the funding
    /// output (the generator holds the aggregate secret), which it never was before.
    function test_splice_realRegtestShrink() public {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/test/btc/open_channel_fixture.json"));
        SPVGateway gw = _buildChain(json);

        // A shrink's withdrawal output pins to `btcRecipientOf`, so pin the key the fixture's
        // splice actually pays: `payoutScript` is `0x5120||key`, so drop the 2-byte prefix.
        bytes memory payoutSpk = vm.parseJsonBytes(json, ".splice.payoutScript");
        assertEq(payoutSpk.length, 34, "payoutScript is not a 34-byte P2TR spk");
        bytes32 payoutKey;
        assembly { payoutKey := mload(add(payoutSpk, 34)) }   // bytes 2..33
        assertTrue(BitcoinTx.isValidXOnlyKey(payoutKey), "fixture payout key is off-curve");
        // (E138) The key must be one WE HOLD THE SECRET FOR, or `openChannel` cannot be given the
        // proof-of-possession it now demands. It used to be `0x11…11` — on-curve, and owned by
        // nobody. Deriving it here from the label the Python generator bakes in turns the two
        // generators agreeing into an ASSERTION rather than an assumption: regenerate the fixture
        // against a different key and this fails at the compare, not somewhere inside the splice.
        assertEq(payoutKeyForLabel("quid-regtest-splice-payout-1"), payoutKey,
            "fixture splice payout != the key this harness can sign for");

        (BTCChannels ch, bytes32 channelId,) = _openFromFixture(json, gw, payoutKey);
        (uint before, , , , , ) = ch.channels(channelId);
        assertEq(before, vm.parseJsonUint(json, ".amountSats"), "channel opened at the funded size");

        // The splice keeps the SAME 2-of-2 -- a splice does not re-key the channel.
        Types.OpenParams memory sp = Types.OpenParams({
            fundingBlockHash:   vm.parseJsonBytes32(json, ".splice.spliceBlockHashBE"),
            fundingBlockHeight: uint64(vm.parseJsonUint(json, ".splice.spliceHeight")),
            fundingTxIndex:     vm.parseJsonUint(json, ".splice.spliceTxIndex"),
            lpPubkey:           vm.parseJsonBytes(json, ".lpPubkey"),
            hopPubkey:          vm.parseJsonBytes(json, ".hopPubkey"),
            amountSats:         vm.parseJsonUint(json, ".splice.newAmountSats"),
            fundingTaproot:     vm.parseJsonBytes32(json, ".fundingTaproot")
        });
        vm.prank(address(0xB0B));   // the delegated authority registered at open
        ch.splice(channelId, sp, vm.parseJsonBytes(json, ".splice.spliceRawTx"),
                  vm.parseJsonBytes32Array(json, ".splice.spliceMerkleBranch"), 0);

        (uint afterSats, , , , , ) = ch.channels(channelId);
        assertEq(afterSats, vm.parseJsonUint(json, ".splice.newAmountSats"),
            "channel resized to the spliced amount");
        assertLt(afterSats, before, "this fixture splice is a SHRINK");
        assertEq(before - afterSats, vm.parseJsonUint(json, ".splice.withdrawSats"),
            "the size drop equals the withdrawn sats");
        // ⚠️ ASSERT ON WHAT THE VAULT WAS TOLD, not only on the channel struct the splice
        //    itself rewrote — a resize that never reached the LP's position would otherwise
        //    look identical here.
        (, , address lpOwner, , , ) = ch.channels(channelId);
        assertEq(vogue.resizedShrinkSats(lpOwner), vm.parseJsonUint(json, ".splice.withdrawSats"),
            "the vault was told the same shrink the splice performed");
        assertEq(vogue.registered(lpOwner), vm.parseJsonUint(json, ".splice.newAmountSats"),
            "the LP position tracks the resized channel");
    }
}

contract MockVogue {
    mapping(address => uint) public registered;
    function registerBtcLp(address lpEth, uint sats) external { registered[lpEth] += sats; }
    function unregisterBtcLp(address, uint) external {}
    // (E147-i) The SHRINK leg of a splice calls this. Its absence made
    // `test_splice_realRegtestShrink` revert with a bare `EvmError: Revert` — a missing mock
    // method is indistinguishable from a contract bug at the call site, which is why the
    // shrink amounts are RECORDED here and asserted in the test rather than merely swallowed.
    mapping(address => uint) public resizedShrinkSats;
    mapping(address => uint) public resizedPayoutSats;
    function resizeBtcLp(address lpEth, uint shrinkSats, uint lpPayoutSats, uint) external {
        resizedShrinkSats[lpEth] += shrinkSats;
        resizedPayoutSats[lpEth] += lpPayoutSats;
        registered[lpEth] -= shrinkSats;
    }
}
