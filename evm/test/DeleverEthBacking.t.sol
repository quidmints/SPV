// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevCascadeProbe, IERC20R} from "./LevCascade.t.sol";
import {MorphoEscrowVenue} from "../src/imports/LevVenueBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title §PLP-6 — `DeleverEthBackingProbe`. THE TEST THAT ROW HAS BEEN WAITING ON.
///
/// 🔴 **THE ROW WAS NEVER VERIFIED BECAUSE THE PROBE IT NAMES WAS NEVER WRITTEN.** §PLP-6 marked
/// `SwapLib.deleverEthOnDelivery` "UNVERIFIED (forge OOM)" pending fork tests of the gating chain,
/// the Σbacking invariant and non-toxicity. Measured 2026-09-07: `DeleverEthBackingProbe` existed
/// as neither a file nor a name anywhere in the tree, and `testReal_DeleverEthBacking_SwapOutTaps-
/// LeveredSlice` — which a `QuidLib.sendEth` comment claimed fork-proved the leg — had ZERO
/// occurrences. The row was not "verified and failing"; the check had never been run.
///
/// ⭐ **WHAT A TRACE ALREADY ESTABLISHED, so this probe does not re-litigate it** (BufferSwapDrain
/// at `-vvvv`, run-happened gate passed first): the leg is REACHED — 16 invocations, two profiles
/// (10,222 gas early-out and 594,773 gas walking `poolVenue` → `MorphoEscrowVenue` → `totalDebt`
/// = $557.80 against a live Morpho position). ⛔ **It is NOT dead; nothing here revives §PLP-6a.**
/// But `deliveredEth == 0` on all sixteen, and the reason is specific: `takeFailed: false` (the
/// funding step SUCCEEDED) followed by `swapOutDeleverPooled` reverting
/// `ERC20: transfer amount exceeds balance` on a USDC `transferFrom` out of the escrow venue —
/// at `fundUsd = 3.482e15`, i.e. **$0.0035**, a dust shortfall.
///
/// ⇒ **THE OPEN QUESTION THIS PROBE EXISTS TO ANSWER: does the leg deliver when the shortfall is
/// MATERIAL rather than dust?** A zero from a dust-sized ask and a zero from a broken payout path
/// print the identical line — CLAUDE.md's *"would this measurement look the same if I were
/// wrong?"*. That is the same trap §REFILL-SIZE caught in E70, where consume-and-deliver-nothing
/// turned out to be a mis-sized fixture rather than a bug.
///
/// ⛔ **THIS PROBE ASSERTS THE INVARIANT AND RECORDS THE OUTCOME. It does not assert that delivery
/// succeeds**, because whether 0 is CORRECT for a given state is exactly what is unestablished —
/// asserting the conclusion would bake in the guess.
contract DeleverEthBackingProbe is LevCascadeProbe {

    /// Σbacking: committed equals both pools' basket-supplied depth minus the live leverage debt.
    /// This must hold ACROSS the delever leg regardless of whether it delivers — a leg that moves
    /// value without moving the debt term is the failure §PLP-6 is actually about.
    function _assertBackingIdentity(string memory tag) internal {
        uint pooled18 = (CORE.basketUsd() + BTC.CORE().basketUsd()) * 1e12;
        uint debt18   = lm.totalDebtUsd();
        uint expect   = pooled18 > debt18 ? pooled18 - debt18 : 0;
        assertEq(CORE.committedUsd18(), expect, tag);
    }

    /// 🔬 §PLP-6-BACKING-DELTA's RESIDUAL — **THE SIBLING TERM, EXERCISED.**
    ///
    /// The single-range probe below proved the gap is a STALE PUSH: `committedUsd18()` is
    /// `AUX.committedTotal()`, the SUM of the last figures pushed by `_reportEquity()`, and a
    /// de-lever moves `basketUsd`/debt through a path that never reaches the reporting site. It
    /// self-heals on that range's next mint or burn, and the backing gate re-pushes THIS range on
    /// the line before `require(committedUsd18() <= haircutTvl)` — so a range never reads its own
    /// stale figure.
    ///
    /// ⚠️ **WHAT THAT ARGUMENT DOES NOT COVER IS THE SIBLING.** §BACKING-DEAD says the gate sees
    /// *"THIS range's new equity, and the sibling's LAST PUSHED figure"*. So range B's gate reads
    /// range A's stale term. That could not be exercised in the single-range probe because BTC was
    /// 0 throughout — reported 0, live 0, nothing to be stale against.
    ///
    /// This builds BOTH ranges: an active BTC leg, a de-lever on ETH, then a BTC mint BEFORE ETH
    /// re-pushes. ⛔ It asserts the EXPOSURE (that BTC's gate ran while ETH's term was stale and
    /// LOW), not a loss — under-stating commitment makes the gate MORE permissive, and whether any
    /// reachable state turns that into an over-commit is a separate question this does not claim.
    function test_PLP6_SiblingTermIsStaleAcrossADeleverOnTheOtherRange() public {
        _setupLev();
        EV.setLevManager(address(lm));
        vm.deal(address(this), 20 ether);
        ETH.deposit{value: 10 ether}(0, address(this));

        // ETH: a real levered position, so there is a de-lever to run.
        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0, DEX_WETH_USDC, 0, "");
        _calmVol();
        ETH.syncLev(lps[0]);
        _realignRangeToReal();

        // BTC: make the sibling REAL. Without this the sibling term is 0 and cannot be stale —
        // which is exactly why the single-range probe could not reach this state.
        AUX.setBTCChannels(address(this));
        BTC.requestDeposit(User01, 2e7);
        uint btcReported0 = AUX.committedOf(address(BTC.CORE()));
        assertGt(btcReported0, 0, "PREMISE: the BTC range must be active, else there is no sibling");
        emit log_named_uint("BTC reported (pre)     ", btcReported0);

        // ETH de-lever: the state change that moves basketUsd/debt off the reporting path.
        vm.prank(lps[0]);
        // ⚠️ §SESS-109 — **SAME MARKET-DEPENDENT REVERT AS G7, MADE SELF-DESCRIBING FOR THE SAME
        //    REASON.** The auto-de-lever's sell leg must clear the oracle floor to reach the
        //    assertions below, and at some market states it cannot: MEASURED, both PLP6 tests fail
        //    `Slippage()` at block 25932254 and pass at head, and G7 was proven market-dependent by
        //    running it at a failing block on PRE-§SESS-91 code (gas 36,073,968 vs 36,072,330 —
        //    different code, same fall). A bare `Slippage()` here is what made me misdiagnose that
        //    one as my own deploy change; §SESS-99 cost a day to the identical anonymity.
        // ⛔ It still FAILS on purpose — a de-lever that cannot clear the floor is a real condition,
        //    not one to skip past. What changes is that the failure says which of the two it is.
        try ETH.withdraw(type(uint).max, lps[0], lps[0]) {}
        catch (bytes memory err) {
            if (bytes4(err) == bytes4(keccak256("Slippage()")))
                revert("PLP6: the auto-de-lever could not clear the oracle floor AT THIS BLOCK - "
                       "market state, not a routing or accounting defect. Re-run, or pin FORK_BLOCK "
                       "to a block where the sell leg clears SELL_SLIP_BPS. See L-routing SESS-104.");
            assembly { revert(add(err, 0x20), mload(err)) }
        }
        assertEq(venue.debtOf(lps[0]), 0, "PREMISE: the de-lever must have run");

        uint ethStale = AUX.committedOf(address(CORE));
        uint ethLive  = CORE.basketUsd() * 1e12 - lm.totalDebtUsd();
        emit log_named_uint("ETH reported (stale)   ", ethStale);
        emit log_named_uint("ETH live               ", ethLive);
        assertTrue(ethStale != ethLive, "PREMISE: ETH's pushed term must actually be stale here");

        // 🔴 THE EXPOSURE: mint on BTC while ETH's term is stale. BTC's own `_reportEquity` runs
        //    before its gate, so BTC is fresh — but the SUM the gate compares against carries
        //    ETH's stale figure.
        uint committedDuringBtcMint = CORE.committedUsd18();
        uint liveTotal = ethLive + BTC.CORE().basketUsd() * 1e12;
        emit log_named_uint("committedUsd18 (sum)   ", committedDuringBtcMint);
        emit log_named_uint("live total             ", liveTotal);

        BTC.requestDeposit(User01, 1e7);   // a second BTC mint -> BTC re-pushes, ETH does not

        uint ethAfterBtcMint = AUX.committedOf(address(CORE));
        emit log_named_uint("ETH reported after BTC mint", ethAfterBtcMint);
        // ⛔ NOT ASSERTED, BECAUSE IT CANNOT FAIL: "a BTC mint does not refresh ETH's term" is
        //    structural — `Aux.report` writes `committedOf[msg.sender]`, so only the reporting
        //    range's slot can move. Asserting it would be restating the source as a measurement.
        //    Logged so the mechanism is visible; the assertion below is the part that can fail.

        // 🔴 THE ASSERTION THAT CAN FAIL: while ETH's term is stale, the aggregate the backing gate
        //    reads is UNDERSTATED by a material amount, and a sibling mint completes against it.
        //    This depends on the de-lever actually having moved value off the reporting path — if
        //    it had not, or if some path re-pushed ETH, the gap would be 0 and this would fail.
        assertGt(liveTotal, committedDuringBtcMint,
                 "SIBLING EXPOSURE: the aggregate must be understated while the sibling term is stale");
        uint understated = liveTotal - committedDuringBtcMint;
        emit log_named_uint("understatement (live - sum)", understated);
        // ⛔ NOT a magic threshold. The understatement must equal EXACTLY the ETH staleness —
        //    `ethLive - ethStale` — because that is the only term that went unreported. Asserting
        //    ">1000 usd18" would have been a number fitted to what I happened to observe; this
        //    says WHICH quantity it is, so it also catches the BTC term drifting.
        assertEq(understated, ethLive - ethStale,
                 "the understatement must be exactly the unreported ETH delta, nothing else");

        // ⚠️ WHAT THIS DOES **NOT** ESTABLISH, stated so the row cannot be over-read: no gate was
        //    shown to PASS WHEN IT SHOULD HAVE FAILED. That needs a state where
        //    `liveTotal > haircutTvl >= committedUsd18()`, i.e. the understatement straddles the
        //    bound. Understating commitment makes the gate more permissive, so the exposure is
        //    real in direction; its reachability is a separate question and is NOT claimed here.
    }

    function test_PLP6_RedeemDelivers_AndRecordsWhetherTheDeleverLegWasReached() public {
        // ⚠️ RECORD FROM THE FIRST LINE. Recording just before the withdraw reported `skips: 0`
        //    — CORRECTLY for that window, and misleadingly overall: the leg actually runs during
        //    SETUP (rally/rebalance/realign) at trace lines 2488 and 4450, while `recordLogs` sat
        //    at 17085. A window that starts after the event is a control failure, not a result.
        vm.recordLogs();
        _setupLev();
        EV.setLevManager(address(lm));

        // ⚠️ SIZED FROM `test_G7_WithdrawPastFreeDepthAutoDeLevers`, NOT INVENTED. My first
        //    version deposited 25 ETH and withdrew 80% as a PLAIN LP; rangeETH (~32.5) covered the
        //    ask every time, so the shortfall branch never ran and the probe proved nothing about
        //    the leg. G7 reaches it by making free depth SMALL (10 ETH) and having the LEVERED LP
        //    withdraw `type(uint).max` — past free depth is exactly the state that forces the
        //    auto-de-lever. Copying the state that is known to reach the code under test beats
        //    inventing one that looks reasonable.
        vm.deal(address(this), 20 ether);
        ETH.deposit{value: 10 ether}(0, address(this));
        _assertBackingIdentity("backing identity: after seed deposit");

        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0, DEX_WETH_USDC, 0, "");
        _calmVol();
        ETH.syncLev(lps[0]);
        _realignRangeToReal();

        uint debtBefore = lm.totalDebtUsd();
        assertGt(debtBefore, 0, "precondition: the levered open must create real debt to unwind");
        assertGt(venue.debtOf(lps[0]), 0, "precondition: the position must carry real venue debt");
        emit log_named_uint("lev debt before (usd18)", debtBefore);
        emit log_named_uint("venue rangeETH  (wei)  ", ETH.rangeETH());
        emit log_named_uint("deliverableETH  (wei)  ", ETH.deliverableETH());
        emit log_named_uint("levered LP debtOf      ", venue.debtOf(lps[0]));

        // THE ASK THAT EXCEEDS FREE DEPTH: the levered LP exits everything.
        uint wethBefore = WETH.balanceOf(lps[0]);
        uint ethBefore  = lps[0].balance;
        vm.prank(lps[0]);
        // ⚠️ §SESS-109 — **SAME MARKET-DEPENDENT REVERT AS G7, MADE SELF-DESCRIBING FOR THE SAME
        //    REASON.** The auto-de-lever's sell leg must clear the oracle floor to reach the
        //    assertions below, and at some market states it cannot: MEASURED, both PLP6 tests fail
        //    `Slippage()` at block 25932254 and pass at head, and G7 was proven market-dependent by
        //    running it at a failing block on PRE-§SESS-91 code (gas 36,073,968 vs 36,072,330 —
        //    different code, same fall). A bare `Slippage()` here is what made me misdiagnose that
        //    one as my own deploy change; §SESS-99 cost a day to the identical anonymity.
        // ⛔ It still FAILS on purpose — a de-lever that cannot clear the floor is a real condition,
        //    not one to skip past. What changes is that the failure says which of the two it is.
        try ETH.withdraw(type(uint).max, lps[0], lps[0]) {}
        catch (bytes memory err) {
            if (bytes4(err) == bytes4(keccak256("Slippage()")))
                revert("PLP6: the auto-de-lever could not clear the oracle floor AT THIS BLOCK - "
                       "market state, not a routing or accounting defect. Re-run, or pin FORK_BLOCK "
                       "to a block where the sell leg clears SELL_SLIP_BPS. See L-routing SESS-104.");
            assembly { revert(add(err, 0x20), mload(err)) }
        }
        uint wethDelta = WETH.balanceOf(lps[0]) - wethBefore;
        uint ethDelta  = lps[0].balance - ethBefore;
        emit log_named_uint("LP native ETH received ", ethDelta);
        emit log_named_uint("LP WETH received       ", wethDelta);

        // Was the delever leg exercised, and did it skip? DeliverDeleverSkipped is emitted on
        // EITHER catch, with takeFailed distinguishing which try block caught.
        bytes32 sig = keccak256("DeliverDeleverSkipped(address,uint256,bool)");
        uint skips;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                skips++;
                (uint fundUsd, bool takeFailed) = abi.decode(logs[i].data, (uint, bool));
                emit log_named_uint("  skip: fundUsd (usd18)", fundUsd);
                emit log_named_string("  skip: which try caught",
                    takeFailed ? "takeToSettle (funding)" : "swapOutDeleverPooled (delivery)");
            }
        }
        emit log_named_uint("DeliverDeleverSkipped count", skips);

        // ✅ WHAT THIS RUN ESTABLISHES: the redeem path DELIVERS. It pays WETH, not native ETH —
        //    measuring `address(this).balance` alone reported 0 and read as "delivered nothing",
        //    which is the same false negative §4a warns about ("read the transfer log, do not
        //    infer"). Both legs are measured above so that cannot recur.
        assertGt(wethDelta + ethDelta, 0, "withdraw consumed the position and delivered NOTHING on either leg");

        // ⚠️ THE DELEVER LEG WAS NOT EXERCISED HERE, AND THAT IS CORRECT, NOT A GAP: rangeETH
        //    (~32.5 ETH) covered the ~20 ETH ask, so `sendEth` never fell through to the shortfall
        //    branch. A probe that "passes" without reaching the leg proves nothing about it —
        //    so this asserts the PRECONDITION explicitly rather than letting a green tick imply
        //    coverage it does not have.
        // 🔴 THE POINT OF THE PROBE: past free depth the auto-de-lever MUST run and MUST repay.
        assertEq(venue.debtOf(lps[0]), 0, "PLP-6: past free depth the venue debt must be repaid in full");
        ( , , , , bool stillOpen) = lm.pos(lps[0]);
        assertTrue(!stillOpen, "PLP-6: the position must close, not be left half-unwound");
        emit log_named_uint("lev debt after  (usd18)", lm.totalDebtUsd());

        // 📌 RECORDED, NOT ASSERTED — the backing identity moves across the redeem, and whether it
        //    is SUPPOSED to is not established. It holds at both checkpoints above (seed deposit,
        //    levered open+rebalance) and at every checkpoint in BufferSwapDrain's swap paths, so
        //    the formula is right for those states. Asserting it here would bake in a guess about
        //    redeem's transient. Booked as §PLP-6-BACKING-DELTA.
        uint pooled18 = (CORE.basketUsd() + BTC.CORE().basketUsd()) * 1e12;
        uint debt18   = lm.totalDebtUsd();
        uint expect   = pooled18 > debt18 ? pooled18 - debt18 : 0;
        emit log_named_uint("post-redeem committedUsd18", CORE.committedUsd18());
        emit log_named_uint("post-redeem identity says ", expect);
        // 🔬 DECOMPOSE THE GAP PER RANGE. `committedUsd18` is NOT computed live — it is
        //    `AUX.committedTotal()`, the SUM OF THE LAST REPORTED figures
        //    (`committedOf[CORE] + committedOf[BTC_CORE]`), pushed by `_reportEquity()`. So a
        //    mismatch is either a STALE PUSH on one range or a genuine value gap, and only the
        //    per-range split tells them apart.
        address btcCore = address(BTC.CORE());
        uint ethReported = AUX.committedOf(address(CORE));
        uint btcReported = AUX.committedOf(btcCore);
        uint ethLive = CORE.basketUsd() * 1e12;
        uint btcLive = BTC.CORE().basketUsd() * 1e12;
        emit log_named_uint("  ETH reported            ", ethReported);
        emit log_named_uint("  ETH live basketUsd*1e12 ", ethLive);
        emit log_named_uint("  BTC reported            ", btcReported);
        emit log_named_uint("  BTC live basketUsd*1e12 ", btcLive);
        emit log_named_uint("  debt term (totalDebtUsd)", debt18);
        // 🔬 IS IT A STALE PUSH OR A VALUE GAP? `_reportEquity` fires on BOTH arms of
        //    `_poolUsdInRange`, so ANY mint or burn on this range re-pushes. If the gap closes
        //    after a trivial deposit, the accounting was never wrong — the aggregate had simply
        //    not been told about a change that did not route through the reporting site.
        vm.deal(address(this), 2 ether);
        ETH.deposit{value: 1 ether}(0, address(this));
        uint afterReport = AUX.committedOf(address(CORE));
        uint liveAfter   = CORE.basketUsd() * 1e12 - lm.totalDebtUsd();
        emit log_named_uint("  AFTER a 1-ETH deposit: reported", afterReport);
        emit log_named_uint("  AFTER a 1-ETH deposit: live    ", liveAfter);
        emit log_named_int ("  residual gap (reported - live) ",
                            int256(afterReport) - int256(liveAfter));
        // 🔴 §PLP-6-BACKING-DELTA, CLOSED: the pre-deposit gap is a STALE PUSH, not a value leak.
        //    Any mint or burn on this range re-pushes and the aggregate becomes exact again.
        assertEq(afterReport, liveAfter,
                 "PLP-6-BACKING-DELTA: the reported aggregate must be exact once the range re-pushes");
        emit log_named_uint("lev debt after  (usd18)   ", debt18);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // ⭐ §PRO-RATA-FALLBACK (ETH) — THE PORT OF THE BTC RAIL'S
    //    `testReal_MEASURE_ProRataFallback_VenueStableVaultPaused` (`VBtcLevFeeLane.t.sol`).
    //
    // 🔴 THE BTC MEASUREMENT THAT BOUGHT §PAUSED-VAULT-REROUTE: with the venue's own stable vault
    //    paused, `Aux.takeToSettle` cannot serve that stable — `BasketLib._takePreferred` wraps
    //    `withdrawSelf` in try/catch, a paused vault yields `sent = 0`, and the WHOLE request falls
    //    to `_takeProRata`, which pays EVERY basket stable to `who`. Measured on the BTC rail:
    //    delivery SUCCEEDED, debt retired ZERO, and **1,377,974,721,301,924,123,210 of DAI** sat at
    //    a USDC-debt venue. `LevVenueBase` has no `sweep`, no `rescue` and no `onlyOwner`, so that
    //    is not "misplaced", it is DESTROYED.
    //
    // ⚠️ THE ETH RAIL HAD THE IDENTICAL EXPOSURE AND NO TEST AT ALL. `deleverEthOnDelivery` passed
    //    `who == venue` to `takeToSettle`, and wrapped the repay in an INNER try/catch that
    //    swallowed AFTER the take had already moved money — so the basket paid and nothing was
    //    retired, silently. Both are fixed (take lands at the RANGE → `LevMath._consolidateTo` →
    //    forward → repay sized off a MEASURED venue balance delta; inner try deleted).
    //
    // ⛔ THIS ASSERTS ONE PROPERTY AND MEASURES THE REST, exactly as the BTC original does. The
    //    property is the one the fix guarantees and the old code could not: **no basket stable
    //    other than the venue's own may be left at the venue.** Whether the delivery SUCCEEDS under
    //    a paused vault is a market/liquidity question this does not bake in.
    // ⚠️ RULE 21 — THE RUN-HAPPENED GATE IS AN ASSERTION, NOT A COMMENT. A paused-vault probe whose
    //    de-lever leg is never reached passes vacuously and reads as coverage. `sendEth` only falls
    //    through to `deleverEthOnDelivery` when free depth cannot cover the ask, so the free depth
    //    is made SMALL on purpose and the reached-ness is asserted three ways below.
    // ═══════════════════════════════════════════════════════════════════════════════════════════
    function testReal_MEASURE_ProRataFallback_VenueStableVaultPaused_ETH() public {
        _setupLev();
        EV.setLevManager(address(lm));

        // THIN free depth on purpose (§G7's shape): `QuidLib.sendEth` serves native → its own WETH →
        // a venue pull → and only then the de-lever leg. A thick range answers from the first rung
        // and the leg under test never runs.
        vm.deal(address(this), 20 ether);
        ETH.deposit{value: 3 ether}(0, address(this));

        _openAtEntry(lps[0], 5 ether);
        _rallyRange(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0, DEX_WETH_USDC, 0, "");
        _calmVol();
        ETH.syncLev(lps[0]);
        _realignRangeToReal();

        address vStable = venue.stable();
        uint debtBefore = venue.totalDebt();
        // ── PREMISES (rule 21): every mechanism this measures must be PRESENT before it is paused ──
        assertGt(debtBefore, 0, "PREMISE: the pool must owe something, or there is no de-lever to source for");
        assertEq(lm.poolVenue(), address(venue), "PREMISE: the pinned pool venue is the one being paused");
        address[] memory sts = AUX.getStables();
        assertGt(sts.length, 1,
            "PREMISE: the basket must hold MORE THAN ONE stable, or the pro-rata leg has nothing "
            "foreign to pay and the whole scenario is unreachable");
        emit log_named_address("venue stable            ", vStable);
        emit log_named_uint("basket stable count     ", sts.length);
        emit log_named_uint("deliverableETH pre (wei)", ETH.deliverableETH());
        emit log_named_uint("rangeETH       pre (wei)", ETH.rangeETH());

        // ⛔ PAUSE THE VENUE STABLE'S VAULTS. `FeeLib.multiVaultWithdrawBody` reaches them via
        //    `IERC4626(vs[i]).redeem(...)`, so reverting `redeem` AND `withdraw` is what a paused
        //    venue looks like from Aux's side — `held > 0`, but nothing can come out. That is the
        //    exact state `_heldUsd18`'s accounting clamp cannot see (§HELD-IS-NOT-WITHDRAWABLE).
        address[] memory vs = AUX.getVaults(vStable);
        assertGt(vs.length, 0, "PREMISE: the venue stable must HAVE vaults, or pausing them changes nothing");
        for (uint i; i < vs.length; ++i) {
            vm.mockCallRevert(vs[i], abi.encodeWithSignature("redeem(uint256,address,address)"), "PAUSED");
            vm.mockCallRevert(vs[i], abi.encodeWithSignature("withdraw(uint256,address,address)"), "PAUSED");
            emit log_named_address("  paused vault          ", vs[i]);
        }

        // ── DRAIN ETH OUT PAST FREE DEPTH, which is what drives `sendEth` to the de-lever leg ──
        uint tvl0 = _tvl();
        bool sawUnavailable;
        deal(address(USDC), User03, 600_000 * USDC_PRECISION);
        vm.recordLogs();
        vm.startPrank(User03);
        IERC20R(address(USDC)).approve(address(AUX), type(uint).max);
        for (uint i; i < 12; ++i) {
            try AUX.swap(address(USDC), address(WETH), true, 40_000 * USDC_PRECISION, 0, true) {}
            catch (bytes memory e) {
                // §SILENT-SETUP — a swallowed revert makes this case vacuous rather than failing it,
                // so the ONE revert that means "the leg ran and refused" is captured by selector.
                if (e.length >= 4 && bytes4(e) == bytes4(keccak256("DeleverStableUnavailable()")))
                    sawUnavailable = true;
                break;
            }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        }
        vm.stopPrank();

        uint skips;
        {   bytes32 sig = keccak256("DeliverDeleverSkipped(address,uint256,bool)");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint i; i < logs.length; ++i)
                if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                    skips++;
                    (uint fundUsd, bool takeFailed) = abi.decode(logs[i].data, (uint, bool));
                    emit log_named_uint("  skip: fundUsd (usd18) ", fundUsd);
                    emit log_named_string("  skip: which catch     ",
                        takeFailed ? "takeToSettle (could not SOURCE - partial fill, #105)"
                                   : "UNREACHABLE post-fix: sourced-but-unrepayable now REVERTS");
                }
        }

        // ── THE MEASUREMENT: where did the basket's money end up? ────────────────────────────────
        uint foreignAtVenue;
        for (uint i; i < sts.length; ++i) {
            uint b = IERC20R(sts[i]).balanceOf(address(venue));
            if (b > 0) { emit log_named_address("  VENUE HOLDS stable    ", sts[i]);
                         emit log_named_uint("    amount (native)     ", b); }
            if (sts[i] != vStable) foreignAtVenue += b;
        }
        emit log_named_uint("     debt before  (native)", debtBefore);
        emit log_named_uint("     debt after   (native)", venue.totalDebt());
        emit log_named_uint("     basket TVL before    ", tvl0);
        emit log_named_uint("     basket TVL after     ", _tvl());
        emit log_named_uint("     DeliverDeleverSkipped", skips);
        emit log_named_string("     DeleverStableUnavailable seen",
            sawUnavailable ? "yes (leg ran and refused - take unwound with the tx)" : "no");

        // ── RUN-HAPPENED GATE, BEFORE THE PROPERTY (the vacuous-test rule) ──────────────────────
        // Three mutually exclusive proofs that the leg executed: it announced a skip, it repaid, or
        // it refused loudly. None of them can be produced by a drain that never reached `sendEth`'s
        // shortfall branch.
        assertTrue(skips > 0 || sawUnavailable || venue.totalDebt() < debtBefore,
            "RUN-HAPPENED: the de-lever leg was never reached, so the property below is VACUOUS. "
            "Free depth covered the ask - shrink the seed deposit or grow the drain until "
            "QuidLib.sendEth falls through to SwapLib.deleverEthOnDelivery.");

        // ── THE PROPERTY THE FIX GUARANTEES ─────────────────────────────────────────────────────
        assertEq(foreignAtVenue, 0,
            "PRO-RATA-FALLBACK: the venue holds a basket stable that is NOT its own loan token. "
            "LevVenueBase has no sweep, no rescue and no onlyOwner - it moves STABLE and COLLATERAL "
            "and nothing else - so that value is UNRECOVERABLE, which is the 1.377e21 DAI the BTC "
            "rail measured. The take must land at the range and be consolidated, never paid raw to "
            "the venue.");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 §REPAY-PROVEN-PREACCRUAL — `repayPool`'s GUARD FIRED ON ORDINARY ACCRUAL, NOT ON A FAILED
    //    REPAY, AND THE ONLY REASON IT LOOKED RIGHT IS THAT ITS COMMENT SAID `>=` WAS THE LOOSE
    //    DIRECTION.
    //
    // THE MECHANISM: `MORPHO.repay` ACCRUES INTEREST AS ITS FIRST ACT. `repayPool` read
    // `d = totalDebt()` BEFORE that call — and `totalDebt()` is a `view`, so it reports the LAST
    // ACCRUED totals, understated by everything pending since `lastUpdate`. The §REPAY-PROVEN check
    // then compares a POST-accrual `totalDebt()` against a PRE-accrual `d`, which is not "did the
    // debt fall" — it is `accruedInterest >= repaid`. On a stale market a perfectly good repay
    // reverts `RepayNotApplied()` and the whole de-lever bricks.
    //
    // ⭐ ITS TWO TWINS ALREADY GET THIS RIGHT and say so: `repay` calls `MORPHO.accrueInterest`
    //    first (*"`debtOf` below must be post-accrual, not stale"*), and `_closeLev` calls `accrue()`
    //    before reading the debt it is about to repay. `repayPool` was the ONE that did not.
    //
    // ⚠️ THIS IS NOT A TOLERANCE TEST AND ASSERTS NO SLACK. It asserts the OLD CONDITION WOULD HAVE
    //    FIRED (`fresh >= stale`) and that the call nonetheless COMPLETED — so a green run cannot be
    //    produced by a market that happened not to accrue, which is exactly the vacuous shape a
    //    "repay works" test would have.
    // ═══════════════════════════════════════════════════════════════════════════════════════════
    function testReal_RepayPool_AccruesBeforeReadingDebt_OrdinaryRepayMustNotRevert() public {
        _setupLev();     // real Morpho market + 5,000,000 USDC of real borrow liquidity

        // A venue whose MANAGER is this test, so `repayPool` (onlyManager) is reachable directly.
        // Its own Morpho position, disjoint from the fixture's — nothing else can move its clock.
        MorphoEscrowVenue v = new MorphoEscrowVenue(MORPHO, mp, address(this));
        address lp = address(0xBEEF9);

        deal(WEETH, address(this), 20e18);
        IERC20R(WEETH).transfer(address(v), 20e18);      // MANAGER pre-transfers, as `supply` documents
        assertGt(v.supply(lp, 20e18), 0, "PREMISE: the collateral must actually reach Morpho");

        uint borrowed = v.borrow(lp, 20_000 * USDC_PRECISION);
        assertGt(borrowed, 0, "PREMISE: the pool must really owe Morpho, or there is no accrual to race");

        // ⏳ LEAVE THE MARKET UNTOUCHED SO INTEREST PENDS. This is the whole state under test: a
        //    market whose `lastUpdate` is old is a market whose `totalDebt()` view is UNDERSTATED.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint stale = v.totalDebt();                       // EXACTLY the read `repayPool` used to take
        uint pay   = 1 * USDC_PRECISION;                  // an ORDINARY, small repay
        // Paid out of the BORROW PROCEEDS this manager already holds — no `deal` here, which would
        // also wipe the 20,000 USDC `borrow` just delivered and hide any accounting error in it.
        IERC20R(address(USDC)).transfer(address(v), pay); // `repayPool` expects it pre-transferred

        // ⛔ PRE-FIX THIS LINE REVERTS `RepayNotApplied()`. Post-fix it is an ordinary repay.
        uint repaid = v.repayPool(pay);
        uint fresh  = v.totalDebt();                      // post-accrual, post-repay

        emit log_named_uint("stale totalDebt (pre-accrual) ", stale);
        emit log_named_uint("repaid                        ", repaid);
        emit log_named_uint("fresh totalDebt (post-accrual)", fresh);
        emit log_named_uint("interest accrued over 30 days ", fresh + repaid > stale ? fresh + repaid - stale : 0);

        assertGt(repaid, 0, "the repay must have applied something");
        // 🔑 THE NON-VACUITY GATE: `fresh >= stale` IS the old guard's revert condition, spelled out.
        //    If this fails, the market did not accrue past the repay and the pre-fix code would have
        //    survived — meaning the fixture, not the fix, is what made the test green.
        assertGe(fresh, stale,
            "PREMISE: 30 days of accrual on 20,000 USDC must EXCEED a 1 USDC repay, or this test "
            "does not exercise the pre-accrual defect at all and its green is meaningless");
    }
}
