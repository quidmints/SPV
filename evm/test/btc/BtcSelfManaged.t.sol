// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture, MockSPV} from "../Alles.t.sol";
import {BTCChannels} from "../../src/BTCChannels.sol";
import {SPVGateway} from "../../src/spv/SPVGateway.sol";
import {Types} from "../../src/imports/Types.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Vault} from "../../src/Vault.sol";

/// @notice BTC-pool self-managed boundary orders — `Vault.outOfRangeBtc`/`pullBtc`,
///         the USD-funded BTC twin of the ETH `Quid.outOfRange`/`pull` path. Mirrors
///         `Alles.testOutOfRangeUSDPosition` on the BTC (USD/WBTC) curve: place a
///         single-sided USD limit order outside range, then pull it back.
contract BtcSelfManagedTest is AllesFixture {
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
        // ⚠️ READ AND CHECK THE VECTOR **BEFORE** THE SKIP BRANCH. Until 2026-08-06 this read sat
        // BELOW it, which made the committed pair unreadable in BOTH configurations: a machine
        // WITHOUT the harness returned at SKIP and never opened the file, and a machine WITH it had
        // just had the file overwritten by the ffi run. So the value in git was never the value under
        // test. `swap.sh` now writes the `.local.` sibling instead, leaving the committed vector as a
        // stable offline case that every machine checks on every run.
        string memory local     = string.concat(vm.projectRoot(), "/test/btc/swapin_fixture.local.json");
        string memory committed = string.concat(vm.projectRoot(), "/test/btc/swapin_fixture.json");
        // ⚠️ ALWAYS check the COMMITTED vector, not "whichever file we happen to read". A stale
        // `.local.` left by an earlier run would otherwise shadow it on a machine where the
        // harness is now absent — and the committed vector going unchecked is the exact defect
        // this whole change exists to fix.
        {
            string memory jc = vm.readFile(committed);
            assertEq(sha256(vm.parseJsonBytes(jc, ".preimage")),
                     vm.parseJsonBytes32(jc, ".paymentHash"),
                     "committed offline vector is a genuine sha256 pair");
        }
        bool haveLive = vm.exists(local);
        string memory j = vm.readFile(haveLive ? local : committed);
        uint    sats        = vm.parseJsonUint(j, ".sats");
        bytes32 paymentHash = vm.parseJsonBytes32(j, ".paymentHash");
        bytes memory preimage = vm.parseJsonBytes(j, ".preimage");

        // The settled hash IS sha256 of the real Lightning preimage (the HTLC tie). Reachable on
        // every machine now — off the harness it proves the committed vector is a genuine pair
        // rather than hand-edited bytes, which is the whole reason to keep one in git.
        assertEq(sha256(preimage), paymentHash, "paymentHash == sha256(real LN preimage)");

        if (keccak256(sig) == keccak256(bytes("SKIP"))) {
            emit log("regtest/LND binaries absent - run regtest/setup.sh && regtest/setup-ln.sh - skipping live leg");
            vm.skip(true);
            return;
        }
        require(keccak256(sig) == keccak256(bytes("READY")),
            "live LN harness is INSTALLED but BROKEN (see /tmp/quid-swapin-e2e.log). Deliberately NOT skipped.");
        require(haveLive, "harness reported READY but wrote no swapin_fixture.local.json");

        // Real BTCChannels wired as THE btcChannels (pin-once); hopNode = our addr.
        address hop = makeAddr("hop");
        // (M1#1) MockSPV, not `_realSPV()`. What this test is FOR is the live Lightning HTLC —
        // its name says so — and a buffered credit now needs a PARKED balance, which needs a
        // grow-splice the gateway will accept. The real gateway only knows the fixture's recorded
        // headers, and no splice fixture exists for this pair. Real-SPV inclusion is covered by
        // the proven-swap-in and deposit-proof tests; what moves here is coverage those already
        // hold. ▶️ Restoring it needs a splice added to the fixture generator (booked).
        BTCChannels ch = new BTCChannels(address(new MockSPV()), address(ETH), makeAddr("hop"), makeAddr("hop-fallback"), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
        _btcChannels = address(ch);   // (E138) PoP digest binds this address
        AUX.setBTCChannels(address(ch));
        // The USD->BTC swaps deliver BTC to the swapper -> it needs a BTC recipient.
        _setRecipient(address(ch), abi.encode(uint(0xB7C)), User03);

        // Fund POOLED_USD headroom (a swap-in draws the swappers' dollars).
        // MULTI-HOP: a REAL open (not a requestDeposit shortcut) so `hop` owns an OPEN
        // channel and may therefore attest the swap-in — settleSwapIn's
        // `openChannelsOf[hop] >= 1` gate is the authority binding that replaced the
        // old single trusted hopNode. (This test previously kept the direct
        // requestDeposit shortcut and only stayed green because the live-harness ffi
        // was SKIPping; with the harness fixed it runs and requires the real open.)
        // (M1#1) open AND park: a buffered credit spends SPV-proven sats.
        _parkSats(ch, hop, 91, 2e7, 2e7);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        assertGt(CORE.POOLED_USD(), 0, "POOLED_USD funded");

        // No-CRE fork: heal USDC severity to 0 for the realistic healthy case.
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)),
            abi.encode(uint(0)));
        address seller = address(0x5EE7);
        uint usdcBefore   = USDC.balanceOf(seller);
        uint pooledBefore = CORE.POOLED_USD();
        uint parkedBefore = ch.provenSatsAvailable(hop);
        vm.prank(hop);
        ch.settleSwapInBuffered(seller, sats, address(USDC), paymentHash, 0, false);
        // ETH-parity: the real LN swap-in settles ON-CURVE from existing pooled
        // dollars - the seller receives USDC, NOT minted QUI.
        assertGt(USDC.balanceOf(seller), usdcBefore, "seller received USDC for the real LN swap-in");
        assertLt(CORE.POOLED_USD(), pooledBefore, "POOLED_USD drawn down by the curve");
        assertLt(ch.provenSatsAvailable(hop), parkedBefore, "the credit drew the proven buffer down");

        // (M1#1) IDEMPOTENCY, which is what the hash is FOR now: re-submitting the same HTLC —
        // a daemon retry or a restart — must not credit the seller twice or drain the hop's
        // buffer twice. The BOUND is a different property, asserted where it can actually fire
        // (`test_M1_1_CannotCreditBeyondWhatWasProven`): it triggers on `consumed`, so a request
        // above the balance is a no-op when the pool converts less, and asserting it here would
        // only be testing the pool's depth.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.SwapInReplay.selector);
        ch.settleSwapInBuffered(seller, sats, address(USDC), paymentHash, 0, false);
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
    // BTCChannels.openChannel -> requestDeposit -> settleSwapIn -> recordClose ->
    // requestRedeem.
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
        // (E166-4) The channel's pre-signed dead-man exit, produced by the Rust harness
        // with BOTH LDK-derived funding halves — the Solidity side cannot sign for these
        // keys, which is why the stub `hex"00"` could never have worked.
        bytes     signedExitTx;      // 21
        uint256   exitCltvDeadline;  // 22
        uint256   exitCheckpointSats;// 23
        // (§SPRINT-B4) the second rung — `_armLadder` rejects a single window, so the
        // harness pre-signs two exits at distinct deadlines (funding_height +144 / +288).
        bytes     signedExitTx2;     // 24
        uint256   exitCltvDeadline2; // 25
    }

    /// (E166-4) Own FRAME — building this arming inline blew the legacy stack
    /// (`Stack too deep` at `cltvDeadline`), and the house fix here is a frame, never
    /// `via_ir` (CLAUDE.md build-environment rules).
    /// (§SPRINT-B4) Two rungs; the checkpoint rides on the first (the ladder takes the max,
    /// and both attest the same balance).
    function _ladderFromBundle(Bundle memory b)
        private pure returns (Types.ExitArming[] memory)
    {
        Types.ExitArming[] memory set = new Types.ExitArming[](2);
        set[0] = Types.ExitArming({
            prevValues: new uint64[](1),
            prevScripts: new bytes[](1),
            cltvDeadline: uint64(b.exitCltvDeadline),
            checkpointSats: b.exitCheckpointSats,
            signedExitTx: b.signedExitTx
        });
        set[1] = Types.ExitArming({
            prevValues: new uint64[](1),
            prevScripts: new bytes[](1),
            cltvDeadline: uint64(b.exitCltvDeadline2),
            checkpointSats: b.exitCheckpointSats,
            signedExitTx: b.signedExitTx2
        });
        return set;
    }

    function testCrossChain_FullE2E() public {
        // Predict the BTCChannels CREATE address: after this point we deploy
        // exactly ONE contract (the SPVGateway) before `new BTCChannels`, so the
        // address is this test's current nonce + 1. The bin signs lpAuth over a
        // digest binding THIS address, so it must be known before the FFI call.
        address hop = makeAddr("hop");
        address predictedCh =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        // (E166-4) THE PAYOUT KEY IS CHOSEN HERE AND HANDED TO THE HARNESS.
        //
        // 🔴 The exit must pay `btcRecipientOf`, because `verifyDeadManExit` counts only
        // outputs to that script. The harness was paying the LP's FUNDING key, so the
        // contract counted ZERO and refused with `ExitUnderpaysCheckpoint` — the §E165-b
        // guard doing exactly its job on a harness that lied about what it delivered.
        // ⚠️ Derived from a FIXED label, not from `b.lpPubkey`: the bundle does not exist
        // yet, so deriving it from the bundle would be circular.
        bytes32 e2ePayout = payoutKeyOnly(abi.encode("e2e-payout"));

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
            " ", vm.toString(e2ePayout),
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
        BTCChannels ch = new BTCChannels(address(gw), address(ETH), makeAddr("hop"), makeAddr("hop-fallback"), bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798)));
        _btcChannels = address(ch);   // (E138) PoP digest binds this address
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
            bytes32 payout = e2ePayout;   // (E166-4) the key the signed exit pays
            // (E157) The LP's consent rides WITH the open — no prior registerDelegation tx.
            // ⚠️ `lpEth` is RECOVERED FROM the fixture's signature rather than checked against a
            // known address, which is the pattern this test already used. It means the consent
            // check passes by construction here, so THIS test does not prove LP authentication —
            // `SmartWalletLp` does. What it proves is the SPV/channel machinery downstream, on
            // real regtest data, and that is why the fixture did not need regenerating.
            address lpEth = ECDSA.recover(
                ch.openAuthDigest(hop, payout), b.lpAuth);
            // (E138) Built BEFORE the prank — `mkAuth` derives the payout PoP over FFI, and a
            // cheatcode call consumes a pending prank.
            Types.OpenAuth memory auth_ = mkAuth(p.lpPubkey, payout);
            vm.prank(hop);
            channelId =
                ch.openChannel(p, b.rawFundingTx, b.fundingMerkleProof, auth_,
                    _ladderFromBundle(b));
        }

        // The lpAuth signer owns the credited BTC position.
        (, , address lpEth, , uint8 status, ) = ch.channels(channelId);
        assertEq(status, 0, "channel OPEN");
        (uint pooledOpen,,,) = BTC.autoManaged(lpEth);
        assertEq(pooledOpen, b.amountSats, "openChannel credits the BTC pool position");

        // ── fund POOLED_USD headroom (a swap-in draws swapper dollars) ──
        _setRecipient(address(ch), abi.encode(uint(0xB7C)), User03);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        assertGt(CORE.POOLED_USD(), 0, "POOLED_USD funded");

        // No-CRE fork: heal USDC severity for the healthy case.
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)),
            abi.encode(uint(0)));

        // ── settleSwapIn: the REAL Lightning HTLC hash settles the seller ──
        {
            // (M1#1) THIS E2E KEEPS ITS REAL SPV GATEWAY — it asserts real header-chain
            // properties above, which is what it is for — and that means it cannot PARK: a park
            // is a grow-splice, and no splice fixture exists for this bundle. So the credit here
            // asserts the BOUND rather than a payout: an unparked hop cannot credit at all, in
            // the most realistic setting the suite has. The paid-seller path is covered by
            // `testSwapIn_RealLightningHTLC` and the stress suite.
            // ▶️ To assert the payout here too, the fixture generator needs to emit a splice.
            vm.prank(hop);
            vm.expectRevert(BTCChannels.InsufficientProvenSats.selector);
            ch.settleSwapInBuffered(b.seller, b.sats, address(USDC), b.paymentHash, 0, false);
        }



        // ── (#114/E107) DEAD-MAN RETIRE PATH, on the REAL SPV-proven tx ──
        // Without `recordDeadManExit` a CLTV exit is unrecordable: recordClose sends any
        // nonzero-locktime tx to the force branch, and that branch demands isCommitmentTx
        // (nLockTime 0x20 + nSequence 0x80) which deadman_exit.rs can never satisfy (block-height
        // locktime 0x00, ENABLE_LOCKTIME_NO_RBF 0xFF). The LP would recover its BTC and leave the
        // EVM counting gone-BTC as backing.
        // ⚠️ COVERAGE IS PARTIAL AND SAYS SO: the three REJECT branches run here against genuine
        // SPV data; the ACCEPT branch cannot, because no harness produces a CLTV-locked exit tx
        // spending the funding UTXO. Do not read a green run as proof the happy path works.
        Types.OpenParams memory cp_ = _closeParams(b.lpPubkey, b.hopPubkey);
        // (E156) THIS USED TO ASSERT `NoDeadManExit` — "none emitted yet". That state no longer
        // exists: `openChannel` arms the exit, so a channel is never un-escaped. The assertion is
        // inverted into the invariant that replaced it. It matters because the fleet holds BOTH
        // funding halves; if it died before the old heartbeat's first tick, NOBODY could ever have
        // signed an exit, and the LP's sats were unreachable forever.
        // (E165) The single `deadManDeadline` became a SET: the LP pre-signs a ladder at open, so
        // "is this channel armed" is membership, not equality.
        // (E166-4) THE DEADLINE IS THE HARNESS'S, NOT `Alles`'s CONSTANT. This asserted
        // `EXIT_DEADLINE_ALLES` (900_000), which is what the *synthetic* Alles armings use —
        // but this channel is armed from the Rust bundle, whose deadline is a real regtest
        // height. The assertion passed only while the arming was a stub that never verified.
        // (§E233-ladder) Read through `armedNow`, which hashes the channel's CURRENT funding outpoint —
        // the map is keyed on the outpoint now, so this asserts "armed for the scope the channel is
        // actually in", which is the only form of the claim that stays true across a splice.
        assertTrue(armedNow(address(ch), channelId, uint64(b.exitCltvDeadline)),
                   "openChannel ARMS the pre-signed exit ladder");

        // (E166-4) A REFRESH MUST CARRY A REAL SIGNED EXIT TOO. This passed a `hex"00"`
        // stub, which `_armDeadManExit` now rejects with `BufferOverflow` — the same stub
        // problem as the open, one call later. Re-arming the SAME bundle exit is legitimate:
        // `emitDeadManExit` supersedes rather than accumulating, so a refresh to an already
        // armed deadline is a no-op that still exercises the whole verification path.
        vm.prank(hop);
        ch.emitDeadManExit(channelId, cp_, _ladderFromBundle(b)[0]);

        // (E155) PERMISSIONLESS. This asserted `NotLP` when the hop submitted. That gate is gone:
        // its stated basis was "the same reasoning recordClose gives for participant-gating", and
        // E153 deleted that reasoning. The assertion is deliberately that the hop now reaches the
        // SUBSTANTIVE check (`NotDeadManExit` — locktime 0 != deadline) rather than being turned
        // away at the door: reverting for a DIFFERENT reason is what distinguishes a removed gate
        // from a renamed one. Retiring is safe from any caller because the payout is pinned to
        // btcRecipientOf inside the signed bytes — and it must not depend on the LP showing up, or
        // an absent LP leaves the EVM counting BTC that has provably left the 2-of-2.
        vm.prank(hop);
        vm.expectRevert(BTCChannels.NotDeadManExit.selector);
        ch.recordDeadManExit(channelId, cp_, b.rawCloseTx, b.closeBlockHash, b.closeMerkleProof, b.closeTxIndex);

        // ⚠️ (E166-4) THIS ASSERTION ENCODED A STALE CHECK ORDER AND ONLY PASSED WHILE THE
        // ARMING WAS A STUB. `recordDeadManExit` tests the ARMED DEADLINE first
        // (`exitArmedAt[channelId][extractLocktime(tx)]`) and only then the keys, so a tx
        // whose locktime was never armed — this real coop close — can NEVER reach
        // `ChannelKeysMismatch`. It is refused earlier, and refusing earlier is correct.
        // The swapped pair is still exercised; what changed is which guard legitimately
        // fires first. (Reaching the key check would need an ARMED tx with an SPV proof,
        // and the harness never broadcasts the exit, so no such proof exists here.)
        vm.prank(lpEth);
        vm.expectRevert(BTCChannels.NotDeadManExit.selector);
        ch.recordDeadManExit(channelId, _closeParams(b.hopPubkey, b.lpPubkey),
            b.rawCloseTx, b.closeBlockHash, b.closeMerkleProof, b.closeTxIndex);

        vm.prank(lpEth);                                          // real coop close: locktime 0 != deadline
        vm.expectRevert(BTCChannels.NotDeadManExit.selector);
        ch.recordDeadManExit(channelId, cp_, b.rawCloseTx, b.closeBlockHash, b.closeMerkleProof, b.closeTxIndex);

        // ⛔ (E166-4) THE STALE-CLOSE BLOCK IS REMOVED — IT WAS PASSING VACUOUSLY, AND
        // §E165-b MAKES ITS PREMISE UNREACHABLE.
        //
        // It armed a DELIBERATELY OVERSTATED `checkpointSats` (via a `hex"00"` stub that
        // never verified) and then asserted `recordClose` reverts `StaleClose`. Since
        // §E165-b, `_armDeadManExit` captures what the signed bytes actually PAY and
        // refuses `paid < checkpointSats` — so **an overstated checkpoint can no longer be
        // armed at all.** The scenario is unrepresentable, which is the guarantee working.
        //
        // ⚠️ AND IT COULD NEVER HAVE BEEN REACHED HONESTLY HERE: the real exit pays
        // `amountSats − fee` while the real coop close pays the full `amountSats`, so the
        // close always pays MORE than an honestly-armed checkpoint and `StaleClose` cannot
        // fire. Tripping it needs a balance that FELL after arming (a splice-out), which
        // this fixture does not contain.
        //
        // ⇒ The guard still deserves coverage — with a constructed splice-out scenario, in
        // its own test. Booked rather than faked: a green assertion that only passed
        // because the arming was never verified is worse than no assertion.

        // ── recordClose: the REAL cooperative-close tx + SPV proof retires it ──
        uint qBefore = QUID.balanceOf(lpEth);
        vm.prank(lpEth); // LP-submitted: proves the stale-close waiver (E153: no longer gated)
        ch.recordClose(channelId, cp_, b.rawCloseTx, b.closeBlockHash,
            b.closeMerkleProof, b.closeTxIndex);
        (uint pooledClose,,,) = BTC.autoManaged(lpEth);
        assertEq(pooledClose, 0, "recordClose retires the BTC pool position");
        // Proceeds (if any delivered) are paid as QUID at close.
        assertGe(QUID.balanceOf(lpEth), qBefore, "close pays the LP's proceeds as QUID");
    }
}
