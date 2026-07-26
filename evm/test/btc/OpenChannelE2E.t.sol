// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {Types} from "../../src/imports/Types.sol";
import {SPVGateway} from "../../src/spv/SPVGateway.sol";

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
///           BTC_CLI=.../bitcoin-cli DATADIR=/tmp/btcreg \
///             python3 test/btc/gen_open_channel_fixture.py > test/btc/open_channel_fixture.json
contract OpenChannelE2ETest is Test {
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
        bytes32 payout = keccak256(abi.encode("lp-shutdown-xonly", p.lpPubkey));
        // (B) The LP delegates channel operation to the hop (0xB0B) COLD, once: pins +
        // LOCKS btcRecipientOf[lpEth]=payout and delegatedAuthority[lpEth]=0xB0B. The
        // 4-arg open is then hop-gated (0xB0B) and credits the position to lpEth.
        address lpEth = vm.addr(lpPk);
        bytes memory dsig = _signOpen(lpPk, ch.delegationDigest(address(0xB0B), payout, 1));
        ch.registerDelegation(address(0xB0B), payout, 1, dsig);
        vm.prank(address(0xB0B)); // this hop must == the delegated authority above
        channelId = ch.openChannel(p, rawTx, vm.parseJsonBytes32Array(json, ".merkleBranch"), lpEth);
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
}

contract MockVogue {
    mapping(address => uint) public registered;
    function registerBtcLp(address lpEth, uint sats) external { registered[lpEth] += sats; }
    function unregisterBtcLp(address, uint) external {}
}
