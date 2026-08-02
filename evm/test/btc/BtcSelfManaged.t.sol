// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles, MockSPV} from "../Alles.t.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {SPVGateway} from "../../src/spv/SPVGateway.sol";
import {Types} from "../../src/imports/Types.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Vault} from "../../src/Vault.sol";

/// @notice BTC-pool self-managed boundary orders — `Vault.outOfRangeBtc`/`pullBtc`,
///         the USD-funded BTC twin of the ETH `Vogue.outOfRange`/`pull` path. Mirrors
///         `Alles.testOutOfRangeUSDPosition` on the BTC (USD/WBTC) curve: place a
///         single-sided USD limit order outside range, then pull it back.
contract BtcSelfManagedTest is Alles {
    /// Create a USD-funded boundary order on the BTC curve, then fully pull it.
    function testOutOfRangeBtc_USDPosition() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint balanceBefore = USDC.balanceOf(User01);

        // distance sign mirrors the ETH USD test; the BTC pool ordering is handled
        // inside oorTicks via token1isBTC (same shared geometry).
        uint id = BTC.outOfRangeBtc(rack / 10, address(USDC), 1000, 100);

        assertGt(id, 0, "BTC self-managed position id > 0");
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore - rack / 10,
                          rack / 100, "USDC deducted for the boundary order");

        vm.roll(vm.getBlockNumber() + 1000);
        balanceBefore = USDC.balanceOf(User01);
        BTC.pullBtc(id, 100, address(USDC));
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore, rack / 50,
                          "USDC returned on full pull");
        vm.stopPrank();
    }

    /// USD-funded only: native/WBTC funding is rejected (no BTC user-deposit leg).
    function testOutOfRangeBtc_RejectsNative() public {
        vm.prank(User01);
        vm.expectRevert(Vault.NotAStable.selector);
        BTC.outOfRangeBtc(0, address(0), 1000, 100);
    }

    /// Only the position owner can pull it.
    function testPullBtc_OnlyOwner() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint id = BTC.outOfRangeBtc(rack / 10, address(USDC), 1000, 100);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 1000);
        vm.prank(User02);
        vm.expectRevert(Vault.NotOwner.selector);
        BTC.pullBtc(id, 100, address(USDC));
    }

    // ─── REAL Lightning swap-in e2e — DELIBERATELY HOUSED HERE, not in `Alles.t.sol` ──────────
    // It used to live in `Alles.t.sol`, which **25 contracts inherit**, so a whole-suite run fired
    // the `vm.ffi` orchestrator ~30 TIMES CONCURRENTLY. Each invocation kills, wipes and restarts
    // both LND nodes, so they raced into a half-built harness and every copy returned SKIP. Thirty
    // concurrent runs of one stateful external daemon is not coverage; it is one test plus
    // twenty-nine ways to corrupt it.
    //
    // It lives in an EXISTING `is Alles` contract on purpose. A NEW `is Alles` suite would also
    // have worked for the race, but inheriting `Alles` re-runs all ~112 of its tests — measured:
    // a fresh suite reported 113 tests. So a new file would have traded 29 redundant ffi calls for
    // 112 redundant test instances. Here the orchestrator runs EXACTLY ONCE and nothing is
    // duplicated. A lock was the other option and is worse: it would serialise thirty identical
    // ~40s runs for zero extra coverage.

    /// @notice REAL Lightning swap-in, orchestrated entirely by `forge` via
    ///         vm.ffi: the regtest/ harness spins up bitcoind + two LND nodes +
    ///         an alice->bob channel and performs a GENUINE HTLC payment (alice
    ///         the BTC seller pays bob the hop); bob learns the preimage. We then
    ///         prove ON-CHAIN that the settled paymentHash IS sha256 of that real
    ///         Lightning preimage, drive the REAL BTCChannels.settleSwapIn with
    ///         it (minting QUI to the seller against drawn pool dollars), and that
    ///         replaying the same real hash reverts. Skips cleanly (suite stays
    ///         green) if the harness binaries aren't installed - run once:
    ///           regtest/setup.sh && regtest/setup-ln.sh
    function testSwapIn_RealLightningHTLC() public {
        string[] memory cmd = new string[](2);
        cmd[0] = "bash";
        cmd[1] = string.concat(vm.projectRoot(), "/../regtest/swapin-e2e.sh");
        bytes memory sig = vm.ffi(cmd);
        // Only an explicit READY drives the live assertions. ANY other token -
        // SKIP (binaries not installed), an orchestration-failure marker, or empty
        // output (a partially-available / flaky live harness) - skips cleanly so
        // the suite stays green wherever the bitcoind/LND harness cannot come up.
        // ⚠️ SKIP means ONE thing only: the binaries are not installed. An installed-but-BROKEN
        // harness returns BROKEN and FAILS here. Collapsing the two into a single SKIP token is
        // what hid this test for the whole project: LND's stale-tip bug made every run emit SKIP,
        // indistinguishable from "not installed", so a real breakage looked like a clean skip.
        if (keccak256(sig) == keccak256(bytes("SKIP"))) {
            emit log("regtest/LND binaries absent - run regtest/setup.sh && regtest/setup-ln.sh - skipping");
            vm.skip(true);
            return;
        }
        require(keccak256(sig) == keccak256(bytes("READY")),
            "live LN harness is INSTALLED but BROKEN (see /tmp/quid-swapin-e2e.log). Deliberately NOT skipped.");

        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/test/btc/swapin_fixture.json"));
        uint    sats        = vm.parseJsonUint(j, ".sats");
        bytes32 paymentHash = vm.parseJsonBytes32(j, ".paymentHash");
        bytes memory preimage = vm.parseJsonBytes(j, ".preimage");

        // The settled hash IS sha256 of the real Lightning preimage (the HTLC tie).
        assertEq(sha256(preimage), paymentHash, "paymentHash == sha256(real LN preimage)");

        // Real BTCChannels wired as THE btcChannels (pin-once); hopNode = our addr.
        address hop = makeAddr("hop");
        BTCChannels ch = new BTCChannels(
            _realSPV(), address(AUX), address(ETH), hop);
        AUX.setBTCChannels(address(ch));
        // The USD->BTC swaps deliver BTC to the swapper -> it needs a BTC recipient.
        vm.prank(User03); ch.setBtcRecipient(bytes32(uint(0xB7C)));

        // Fund POOLED_USD_BTC headroom (a swap-in draws the swappers' dollars).
        // MULTI-HOP: a REAL open (not a registerBtcLp shortcut) so `hop` owns an OPEN
        // channel and may therefore attest the swap-in — settleSwapIn's
        // `openChannelsOf[hop] >= 1` gate is the authority binding that replaced the
        // old single trusted hopNode. (This test previously kept the direct
        // registerBtcLp shortcut and only stayed green because the live-harness ffi
        // was SKIPping; with the harness fixed it runs and requires the real open.)
        _openHopChannel(ch, hop, 91, 2e7);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        assertGt(CORE.POOLED_USD_BTC(), 0, "POOLED_USD_BTC funded");

        // No-CRE fork: heal USDC severity to 0 for the realistic healthy case.
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)),
            abi.encode(uint(0)));
        address seller = address(0x5EE7);
        uint usdcBefore   = USDC.balanceOf(seller);
        uint pooledBefore = CORE.POOLED_USD_BTC();
        vm.prank(hop);
        ch.settleSwapIn(seller, sats, address(USDC), paymentHash, 0, false);
        // ETH-parity: the real LN swap-in settles ON-CURVE from existing pooled
        // dollars - the seller receives USDC, NOT minted QUI.
        assertGt(USDC.balanceOf(seller), usdcBefore, "seller received USDC for the real LN swap-in");
        assertLt(CORE.POOLED_USD_BTC(), pooledBefore, "POOLED_USD_BTC drawn down by the curve");
        assertTrue(ch.swapInUsed(paymentHash), "real HTLC hash recorded");

        // Replaying the SAME real hash must revert - one credit per HTLC, ever.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.SwapInReplay.selector);
        ch.settleSwapIn(seller, sats, address(USDC), paymentHash, 0, false);
    }

    // ── CROSS-CHAIN E2E — housed here, NOT in `Alles.t.sol`, for the same reason as the LN test ──
    // It used to live in `Alles.t.sol`, which 25 contracts inherit, so a suite run spawned ~30
    // CONCURRENT `cargo run -p quid-hop` invocations against ONE regtest bitcoind. That is a race,
    // not coverage: they fight over the same chain and the same target/ lock, and every copy
    // degrades to SKIP. Defined once here, the FFI bin runs exactly once per suite run.
    // ── FULL CROSS-CHAIN E2E (real bitcoind/LDK ↔ real SPVGateway/BTCChannels) ──
    //
    // The `e2e_ffi` Rust bin (quid-hop, --features harness) drives a REAL regtest
    // bitcoind + two REAL LDK hop nodes in one shot: fund a 2-of-2 (LP+hop)
    // channel, swap-IN over Lightning, cooperatively close, and emit an
    // ABI-encoded bundle (genesis+headers, funding/close raw legacy txs + SPV
    // merkle proofs, the recovered funding pubkeys, the seller/sats/token/hash of
    // the real HTLC, and the LP's lpAuth over the EXACT openChannelDigest). Here
    // that real data flows through the ACTUAL SPVGateway header chain +
    // BTCChannels.openChannel -> registerBtcLp -> settleSwapIn -> recordClose ->
    // unregisterBtcLp.
    //
    // The bin needs a bitcoind/esplora; without them it CANNOT run, so this test
    // SKIPS cleanly (suite stays green) when the FFI bin or its binaries are
    // absent. CI must provide them (BITCOIND_EXE/ELECTRS_EXE or the download
    // features) for this to execute. Build the bin once:
    //   cargo build -p quid-hop --features harness --bin e2e_ffi
    struct Bundle {
        bytes     genesisHeader;     // 0
        bytes[]   headers;           // 1  (heights 1..=tip)
        uint256   tip;               // 2
        bytes     rawFundingTx;      // 3  (witness-stripped legacy)
        bytes32   fundingBlockHash;  // 4  (BE, as stored)
        uint256   fundingHeight;     // 5
        uint256   fundingTxIndex;    // 6
        bytes32[] fundingMerkleProof;// 7
        bytes     lpPubkey;          // 8  (33-byte)
        bytes     hopPubkey;         // 9  (33-byte)
        uint256   amountSats;        // 10
        bytes32   fundingTaproot;    // 11 the REAL x-only MuSig2 Q of 0x5120||Q
        bytes     lpAuth;            // 12 (r‖s‖v)
        address   seller;            // 13
        uint256   sats;              // 14
        address   token;             // 15
        bytes32   paymentHash;       // 16
        bytes     rawCloseTx;        // 17 (witness-stripped legacy)
        bytes32   closeBlockHash;    // 18 (BE)
        bytes32[] closeMerkleProof;  // 19
        uint256   closeTxIndex;      // 20
    }

    function testCrossChain_FullE2E() public {
        // Predict the BTCChannels CREATE address: after this point we deploy
        // exactly ONE contract (the SPVGateway) before `new BTCChannels`, so the
        // address is this test's current nonce + 1. The bin signs lpAuth over a
        // digest binding THIS address, so it must be known before the FFI call.
        address hop = makeAddr("hop");
        address predictedCh =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        // ── drive the Rust side; capture the ABI bundle ──
        // Invoke the bin via `cargo run` from the quid-ln workspace (so the right
        // toolchain/features apply). Logs go to stderr -> silenced; the `0x…`
        // bundle is the only stdout. On any failure (missing bitcoind / bin), the
        // `|| echo SKIP` keeps the test green.
        string[] memory ffi = new string[](3);
        ffi[0] = "bash";
        ffi[1] = "-c";
        // RUN IT IN DOCKER, not on the host. `quid-cvm` is Linux-only and transitive, so the host
        // `cargo` CANNOT build this bin on macOS — that is why this test skipped for the life of the
        // project. `quid-ln/Dockerfile` is the Linux toolchain and already bakes bitcoind
        // (BITCOIND_EXE), which is exactly what `harness.rs:33` reads first.
        //   Build once:  docker build -t quid-ln:dev quid-ln
        // If the image is absent we emit SKIP (a real "cannot run"); if it is present and the bin
        // FAILS we emit BROKEN and assert below — those are different things and collapsing them is
        // what hid this test in the first place.
        ffi[2] = string.concat(
            "docker image inspect quid-ln:dev >/dev/null 2>&1 || { echo -n SKIP; exit 0; }; ",
            "docker run --rm -v ", vm.projectRoot(), "/../quid-ln:/w -w /w quid-ln:dev ",
            "cargo run --quiet -p quid-hop --features harness --bin e2e_ffi -- ",
            vm.toString(block.chainid), " ", vm.toString(predictedCh),
            " 2>/dev/null || echo -n BROKEN"
        );
        bytes memory out = vm.ffi(ffi);

        if (keccak256(out) == keccak256(bytes("SKIP"))) {
            emit log("quid-ln:dev image absent - build it: docker build -t quid-ln:dev quid-ln");
            vm.skip(true);
            return;
        }
        require(keccak256(out) != keccak256(bytes("BROKEN")) && out.length >= 32,
            "e2e_ffi is RUNNABLE but FAILED (image present). Deliberately NOT skipped.");
        Bundle memory b = abi.decode(out, (Bundle));

        // ── REAL SPVGateway: regtest genesis (height 0) + chain to tip ──
        SPVGateway gw = new SPVGateway();
        gw.__SPVGateway_init(b.genesisHeader, 0, 0);
        gw.addBlockHeaderBatch(b.headers);
        assertEq(gw.getMainchainHeight(), b.tip, "header chain extended to tip");
        assertTrue(gw.isInMainchain(b.fundingBlockHash), "funding block on mainchain");
        assertTrue(gw.isInMainchain(b.closeBlockHash),   "close block on mainchain");

        // ── REAL BTCChannels at the predicted address; hopNode = our hop ──
        BTCChannels ch = new BTCChannels(
            address(gw), address(AUX), address(ETH), hop);
        require(address(ch) == predictedCh, "BTCChannels address prediction off");
        AUX.setBTCChannels(address(ch));

        // ── openChannel: real funding tx + SPV proof + LP's lpAuth ──
        // (p/payout scoped away after the open to keep the stack shallow.)
        bytes32 channelId;
        {
            Types.OpenParams memory p = Types.OpenParams({
                fundingBlockHash:   b.fundingBlockHash,
                fundingBlockHeight: uint64(b.fundingHeight),
                fundingTxIndex:     b.fundingTxIndex,
                lpPubkey:           b.lpPubkey,
                hopPubkey:          b.hopPubkey,
                amountSats:         b.amountSats,
                // Use the REAL Q from the bundle (the live funding output is 0x5120||Q
                // where Q is the genuine MuSig2 aggregate; the synthetic _taprootQ
                // stand-in only matches the synthetic-funding fixtures, not a real tx).
                fundingTaproot:     b.fundingTaproot
            });
            // Realistic btcRecipientOf: a full 32-byte x-only shutdown key. NOTE: the
            // REAL coop-close guard (_lpFinalBalance validating the actual LDK close
            // output `0x5120||shutdownKey`) is exercised end-to-end by quid-bridge's
            // driver_e2e `channel_lifecycle_open_then_close_on_real_evm`, where the Rust
            // channel_driver registers btcRecipientOf FROM the LP's real shutdown script
            // and closes with the real tx. This e2e_ffi bundle variant asserts only the
            // retire/no-mint invariant (>=0), so the synthetic key just needs to be a
            // proper key, not a hash160 in a slot.
            bytes32 payout = keccak256(abi.encode("lp-shutdown-xonly", p.lpPubkey));
            // (B) The LP delegates channel operation to `hop` COLD, once. The bundle's
            // `lpAuth` field now carries the DELEGATION signature over
            // delegationDigest(hop, payout, 1) (the e2e_ffi bin signs that digest instead
            // of the retired per-open openChannelDigest). registerDelegation recovers
            // lpEth from the sig and pins+LOCKS btcRecipientOf[lpEth]=payout +
            // delegatedAuthority[lpEth]=hop; openChannel is then gated on the hop caller.
            address lpEth = ECDSA.recover(ch.delegationDigest(hop, payout, 1), b.lpAuth);
            ch.registerDelegation(hop, payout, 1, b.lpAuth);
            vm.prank(hop); // openChannel is hop-gated: only the delegated hop may submit
            channelId =
                ch.openChannel(p, b.rawFundingTx, b.fundingMerkleProof, lpEth);
        }

        // The lpAuth signer owns the credited BTC position.
        ( , , address lpEth, , uint8 status,) = ch.channels(channelId);
        assertEq(status, 0, "channel OPEN");
        (uint pooledOpen,,,) = BTC.autoManagedBTC(lpEth);
        assertEq(pooledOpen, b.amountSats, "openChannel credits the BTC pool position");

        // ── fund POOLED_USD_BTC headroom (a swap-in draws swapper dollars) ──
        vm.prank(User03); ch.setBtcRecipient(bytes32(uint(0xB7C)));
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        assertGt(CORE.POOLED_USD_BTC(), 0, "POOLED_USD_BTC funded");

        // No-CRE fork: heal USDC severity for the healthy case.
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)),
            abi.encode(uint(0)));

        // ── settleSwapIn: the REAL Lightning HTLC hash settles the seller ──
        {
            uint usdcBefore = USDC.balanceOf(b.seller);
            vm.prank(hop);
            ch.settleSwapIn(b.seller, b.sats, address(USDC), b.paymentHash, 0, false);
            assertGt(USDC.balanceOf(b.seller), usdcBefore, "seller paid USDC for the real swap-in");
            assertTrue(ch.swapInUsed(b.paymentHash), "real HTLC hash recorded");
        }

        // Replaying the SAME real hash must revert.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.SwapInReplay.selector);
        ch.settleSwapIn(b.seller, b.sats, address(USDC), b.paymentHash, 0, false);

        // ── recordClose: the REAL cooperative-close tx + SPV proof retires it ──
        uint qBefore = QUID.balanceOf(lpEth);
        vm.prank(makeAddr("hop")); // recordClose is participant-gated (hop or lpEth)
        ch.recordClose(channelId, b.rawCloseTx, b.closeBlockHash,
            b.closeMerkleProof, b.closeTxIndex);
        (uint pooledClose,,,) = BTC.autoManagedBTC(lpEth);
        assertEq(pooledClose, 0, "recordClose retires the BTC pool position");
        // Proceeds (if any delivered) are paid as QUID at close.
        assertGe(QUID.balanceOf(lpEth), qBefore, "close pays the LP's proceeds as QUID");
    }
}
