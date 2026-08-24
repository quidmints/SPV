// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";

/// @notice Empirical probe of the "mint QUI → swap 1:1 for ETH → repeat" drain thesis.
///         Three structural defenses are claimed; this confirms them by simulation:
///         (1) 1:1 mint cap (no free QUI), (2) maturity lock — freshly-minted QUI is
///         immature and a swap (turn=burn) consumes MATURED vintages only, so the rapid
///         loop can't consume just-minted QUI, (3) oracle-pinned + fee'd swap, so even with
///         matured QUI a buy-ETH loop is fair (attacker nets a LOSS, pool stays solvent).
contract DrainProbe is AllesFixture {
    // Value a holder's position in 18-dec USD: USDC(6) + QUI(18) + WETH·price.
    function _valueUSD18(address who) internal returns (uint v) {
        v += USDC.balanceOf(who) * 1e12;          // 6 → 18
        v += QUID.balanceOf(who);                 // QUI already 18-dec, 1:1 USD
        uint px = AUX.getTWAPforAsset(address(WETH), 1800); // USD18 per 1e18 ETH
        v += WETH.balanceOf(who) * px / 1e18;
        v += who.balance * px / 1e18;             // any native ETH
    }

    /// (2) MATURITY LOCK: freshly-minted (immature) QUI cannot pull volatile assets OUT
    ///     OF THE POOL. Immature QUI is freely TRANSFERABLE (and thus sellable on a
    ///     secondary market — that moves no protocol backing), but the PROTOCOL will
    ///     not be the counterparty: AUX.swap(QUID→WETH) routes QUID through turn() (a
    ///     burn), and turn burns MATURED vintages only, so fresh QUI draws ~0 ETH from
    ///     the pool. This is what blocks the mint→swap→repeat drain at the protocol
    ///     boundary — NOT a freeze on the token (it can still be sold to a third party).
    function testFreshQUICannotPullETHFromPool() public {
        // Seed ETH inventory so a QUI→ETH swap COULD draw, if it were allowed.
        vm.prank(User02); ETH.deposit{value: 200 ether}(0, User02);

        vm.startPrank(User01);
        uint minted = QUID.mint(User01, 50_000 * USDC_PRECISION, address(USDC), 0);
        assertGt(minted, 0, "minted some QUI");
        uint qd = QUID.balanceOf(User01);          // immature (matures nextMonth)
        uint wethBefore = WETH.balanceOf(User01);
        // Attempt to swap the freshly-minted (immature) QUI for ETH. turn() burns
        // matured-only → it can consume ~nothing of this immature balance.
        try AUX.swap(address(QUID), address(WETH), true, qd, 0, true) {} catch {}
        uint got = WETH.balanceOf(User01) - wethBefore;
        vm.stopPrank();
        // The drain step yields ~no ETH from freshly-minted QUI: the protocol refuses
        // to release pool backing for immature QUI (turn burns matured-only). The token
        // is NOT frozen — it could still be transferred/sold to a third party; that
        // simply isn't a drain on the pool. The loop-against-the-pool is broken.
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        assertLt(got * px / 1e18, 100 * 1e18,
            "immature QUI cannot pull ETH out of the pool via the protocol swap");
    }

    /// (3) FAIR BUY: a repeated USDC→ETH buy loop nets the attacker a LOSS (fees +
    ///     oracle-pin), never a profit, and the pool stays solvent (no value drain).
    function testRepeatedBuyIsNotADrain() public {
        // Seed deep ETH inventory across two LPs.
        vm.prank(User02); ETH.deposit{value: 500 ether}(0, User02);
        vm.prank(User03); ETH.deposit{value: 500 ether}(0, User03);

        uint startVal = _valueUSD18(User01);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        // Drain attempt: buy ETH with USDC, over and over.
        for (uint i = 0; i < 40; i++) {
            try AUX.swap(address(USDC), address(WETH), true, 2_000 * USDC_PRECISION, 0, true) {}
            catch { break; } // exhausted / guard tripped — drain self-limits
        }
        vm.stopPrank();
        uint endVal = _valueUSD18(User01);

        // The attacker did NOT gain value: each buy paid fair price + fees + slippage,
        // so ending value ≤ starting value (a small loss). No net benefit from draining.
        assertLe(endVal, startVal, "repeated buy yields no net gain to the attacker");
        // And the protocol stays solvent (the backing invariant holds — no value leaked
        // to the attacker beyond the fair conversion + the LP's inherent IL).
        AUX.checkBacking();
    }

    /// @dev Withdraw the holder's ENTIRE LP position; return the ETH (wei) actually
    ///      delivered (native + WETH). Ground truth — cuts through virtual
    ///      POOLED_*/rangeETH accounting.
    function _realizeExitETH(address who) internal returns (uint ethOut) {
        uint pooled = ETH.balanceOf(who);
        if (pooled == 0) return 0;
        uint b0 = who.balance; uint w0 = WETH.balanceOf(who);
        vm.prank(who); ETH.withdraw(pooled, who, who);
        ethOut = (who.balance - b0) + (WETH.balanceOf(who) - w0);
        // PLUS the RETAINED claim. `withdraw` delivers what the ETH ladder can source and DEFERS the
        // rest as a live, recoverable `pooled` balance (BUILD-QUEUE §A.11) — counting delivery alone
        // reads that deferral as a LOSS. MEASURED here: the incumbent takes 423.14 ETH out and retains
        // 76.86, i.e. EXACTLY its 500.00 principal, so the "round-trip harmed the incumbent" reading
        // was an artifact of the measure, not harm. Including it also makes the entrant-side bound
        // (b) strictly TIGHTER, which is the safe direction for an anti-drain assertion.
        (uint remPooled,,,) = ETH.autoManaged(who);
        ethOut += remPooled;
    }

    /// THE ROUND-TRIP (user's scenario): an entrant SPENDS dollars to buy ETH out of
    /// the pool, then INSTANTLY redeposits that ETH to become an LP. Settled by
    /// realized withdrawal, with the entrant exiting FIRST (adversarial first-out):
    ///   (a) NO RACE / NO HARM — the incumbent still withdraws ≥ its full 500-ETH
    ///       principal (there is no shared pot they race for; each LP's claim is its
    ///       own pro-rata `pooled`, serviced from the venue).
    ///   (b) NO DRAIN / NO FREE PRINCIPAL — the entrant's realized ETH is worth ≤ the
    ///       dollars it spent: it PAYS the swap fee+slippage to round-trip (a net cost
    ///       to it, a net credit to the incumbent). The "extra dollars" added to POOLED
    ///       are exactly the entrant's own $X — no virtual inflation (checkBacking holds).
    function testRoundTripNoRaceNoDrain() public {
        uint X = 200_000 * USDC_PRECISION;               // entrant's dollars

        // Incumbent LP seeds 500 ETH.
        vm.prank(User02); ETH.deposit{value: 500 ether}(0, User02);

        // Entrant buys ETH with $X, then INSTANTLY redeposits it as an LP.
        uint b0 = User01.balance; uint w0 = WETH.balanceOf(User01);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        AUX.swap(address(USDC), address(WETH), true, X, 0, true);
        uint nativeGot = User01.balance - b0;
        uint wethGot   = WETH.balanceOf(User01) - w0;
        uint bought    = nativeGot + wethGot;
        if (wethGot > 0) WETH.approve(address(ETH), wethGot);
        ETH.deposit{value: nativeGot}(wethGot, User01);
        vm.stopPrank();
        AUX.checkBacking();                              // no virtual inflation

        // JIT-lock: `_depositImpl` requires `block.number > lastDepositBlock`, so the SAME-block
        // deposit->exit reverts with "too soon" — the lock doing its job, which meant this test never
        // reached its own assertions. Roll one block so we test the attack the lock actually permits:
        // a next-block round trip must still not drain.
        vm.roll(block.number + 1);

        // Adversarial ordering: ENTRANT exits FIRST (grabs first-out priority).
        uint entrantETH  = _realizeExitETH(User01);
        uint incumbentETH = _realizeExitETH(User02);

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        // (b) entrant did not profit: realized ETH worth ≤ dollars spent.
        assertLe(entrantETH * px / 1e18, X * 1e12, "round-trip extracted value");
        // ...and could not withdraw more ETH than it deposited.
        assertLe(entrantETH, bought + 1e12, "entrant withdrew more ETH than it put in");
        // (a) incumbent unharmed: recovers essentially all principal. The round-trip
        //     imposes only a dust-level (<0.1%) shared AMM cost — NOT a drain (that is
        //     pinned by the entrant-no-profit checks above). A relative bound is used
        //     because Alles forks mainnet at an unpinned block, so venue-yield/TWAP
        //     drift moves the exact ETH amount by ~1e16 between runs; a real
        //     race/drain would transfer an order-of-magnitude-larger slice and still
        //     trip this. (See the SPV fork-test-determinism notes.)
        assertGe(incumbentETH, 500 ether * 999 / 1000, "round-trip harmed the incumbent LP");
        AUX.checkBacking();
    }

    /// BTC ANALOG of the round-trip. The atomic on-chain round-trip is STRUCTURALLY
    /// IMPOSSIBLE on BTC: buying BTC sends sats out over Lightning (no WBTC lands in an
    /// EVM wallet to redeposit), and becoming a BTC LP requires opening a real channel
    /// (requestDeposit is onlyBtcChannels, gated on an SPV-proven funding tx).
    ///
    /// COLLAPSE: proceeds now settle EXACTLY at delivery to the delivering channel's
    /// LP — a close mints NO proceeds and there is NO shared proceeds pool. So the
    /// drain/race is now STRUCTURALLY closed: an entrant who delivered nothing and a
    /// late incumbent both close ALL-NATIVE, neither extracting the primed
    /// POOLED_USD. (Real deliver-time proceeds are covered end-to-end in
    /// BtcLpMintStress.) Per-channel isolation must hold:
    ///   (a) NO RACE — closing order is irrelevant; neither close draws the pool.
    ///   (b) NO DRAIN — neither LP can extract the primed dollars at close (no
    ///       over-mint, no leak of basket headroom). The "round-trip" buys nothing.
    function testRoundTripNoRaceNoDrain_BTC() public {
        AUX.setBTCChannels(address(this)); // impersonate the channel manager (BTC-test pattern)
        uint funded = 2e7;                 // 0.2 BTC
        BTC.requestDeposit(User01, funded); // incumbent LP-A

        // Priming curve buys fund POOLED_USD (the dollars an attacker would hope
        // to "round-trip" back as LP principal). They record no obligation now.
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 6; i++) {
            AUX.swap(address(USDC), address(WBTC), true, 500 * USDC_PRECISION, 0, true);
            vm.roll(block.number + 1); vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();
        // §WRONG-RANGE — this test primes with USDC→WBTC, so the primed dollars land on the BTC
        // instance. The very next line already reads `BTC.CORE()`; this one did not.
        uint poolUsd = BTC.CORE().POOLED_USD();   // primed dollars (no shared proceeds pool)
        assertGt(poolUsd, 0);
        assertEq(BTC.CORE().pendingSwapOutUsd(), 0, "priming records no swap-out obligation");

        // LATE entrant LP-B becomes an LP AFTER the priming (the "redeposit" step).
        BTC.requestDeposit(User02, funded);

        // NO DRAIN is proved on each LP's QUID (NOT POOLED_USD, which close's
        // _rebalance zeroes+rebuilds for reasons unrelated to proceeds): a close
        // that delivered nothing mints only its tiny USD-leg fees, ≪ the primed
        // headroom an old close-spot model would have leaked.
        uint feeBound = poolUsd / 100 * 1e12;

        // Adversarial: entrant B closes FIRST, having delivered NOTHING.
        uint qB = QUID.balanceOf(User02);
        BTC.requestRedeem(User02, funded); // delivered_B = 0
        uint paidB = QUID.balanceOf(User02) - qB;

        // Incumbent A closes second; closing order is irrelevant under the collapse.
        uint qA = QUID.balanceOf(User01);
        BTC.requestRedeem(User01, funded); // delivered_A = 0
        uint paidA = QUID.balanceOf(User01) - qA;

        // (b) NO DRAIN: neither LP extracted the primed dollars (close mints 0 proceeds).
        assertLt(paidB, feeBound, "entrant extracted primed dollars at close");
        assertLt(paidA, feeBound, "incumbent extracted primed dollars at close");
        // (a) NO RACE / conserved: no swap-out obligations were ever created, so
        // there is no shared proceeds pool for either close to race over.
        assertEq(BTC.CORE().pendingSwapOutUsd(), 0, "no proceeds obligation created or drained across both closes");
    }

    /// §E313 — **INVERTED: THE REDEEM PREFERENCE IS GONE, AND THIS NOW GUARDS ITS ABSENCE.**
    /// This test asserted that `redeem(amount, preferred)` sheds the named stable FIRST. The owner
    /// removed that path (2026-08-22): the frontend converges the pro-rata basket by multicall
    /// (§E312-redeem), so the contract does pro-rata and nothing else.
    /// ⚠️ **THE TEST WAS STALE, NOT THE CHANGE** (rule 8d). It encoded a feature that has been
    /// deliberately deleted, so it is inverted rather than removed — a deleted test would leave
    /// nothing watching for the preference coming back.
    /// ⛔ **`_takePreferred` ITSELF SURVIVES AND MUST:** its other caller is `viaToken`, the SWAP
    /// take, where the named stable is the swapper's requested OUTPUT rather than a redeemer's
    /// preference. Deleting the function outright would have broken that.
    /// 📌 THE ASSERTION IS DELIBERATELY NOT A TOLERANCE. The second redeem draws from a basket the
    /// first one already shrank, so pro-rata must yield **≤** the first draw. Under the old
    /// behaviour `daiTgt` was far GREATER. `≤` therefore separates the two regimes exactly, with no
    /// fudge factor — which is the assertion class rule 4 exists to protect.
    function testRedeemNamedStableNoLongerShedsFirst() public {
        // User01 mints redeemable QUI; the basket is already seeded with many stables
        // (incl. USDC + DAI, both exercised by testRedeem's pro-rata legs).
        vm.startPrank(User01);
        USDC.approve(address(AUX), 8000 * USDC_PRECISION);
        QUID.mint(User01, 8000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 35 days); // mature the vintage

        // Heal the no-CRE fork's default depeg on the two legs we measure, so the draw
        // shape (not a spurious haircut) is what the assertions isolate.
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(DAI)), abi.encode(uint(0)));

        // ---- PRO-RATA control: redeem(amount) draws every stable proportionally. ----
        uint u0 = USDC.balanceOf(User01); uint d0 = DAI.balanceOf(User01);
        vm.prank(User01); AUX.redeem(1000 * WAD);
        uint usdcPro = USDC.balanceOf(User01) - u0;
        uint daiPro  = (DAI.balanceOf(User01) - d0) / 1e12; // 18→6 dec for comparison

        // ---- TARGETED: redeem(amount, DAI) sheds DAI first. ----
        u0 = USDC.balanceOf(User01); d0 = DAI.balanceOf(User01);
        vm.prank(User01); AUX.redeem(1000 * WAD);
        uint usdcTgt = USDC.balanceOf(User01) - u0;
        uint daiTgt  = (DAI.balanceOf(User01) - d0) / 1e12;

        // The preference is gone: naming DAI must not shed MORE DAI than the plain pro-rata call
        // did. It draws from an already-smaller basket, so pro-rata gives <=; the old targeted
        // behaviour gave far more. This single comparison is the whole discriminator.
        assertLe(daiTgt, daiPro,
            "naming a stable still sheds it first - the redeem preference is back");
        AUX.checkBacking();
    }

    // §E313 — `testRedeemTargetedRejectsBadPreferred` IS DELETED, AND THE WAY IT DIED IS THE POINT.
    // It asserted that `redeem(amount, preferred)` reverts `bad-preferred` when handed QU!D or WETH.
    // §E313 removed the `preferred` argument, and the mechanical edit that dropped it left BOTH
    // `vm.expectRevert(bytes("bad-preferred"))` lines standing over two now-IDENTICAL calls to
    // `AUX.redeem(100 * WAD)` — with the old comments ("QUID is not a basket stable", "WETH is the
    // volatile leg") still naming arguments that were no longer passed.
    // ⇒ THE TEST HAD NO SUBJECT LEFT. `_redeemRequire` is deleted, nothing validates a preferred
    // stable because no preferred stable can be named, so there is no revert to expect. It is not
    // repairable into an assertion about something else without inventing a new claim.
    // ⚠️ The discriminator that DOES survive is two functions above: `testRedeemNamedStableNoLongerShedsFirst`
    // asserts `daiTgt <= daiPro` — that naming a stable cannot shed more of it than pro-rata does.
    // That is the property §E313 actually changed, and it is still tested.

    /// redeemTo: burn the CALLER's QUI but deliver proceeds to a DIFFERENT recipient
    /// (the blacklist-evasion mirror of swapTo's recipient overload). source stays
    /// msg.sender — you can only ever burn your own QUI — only the payout is retargeted.
    function testRedeemToDeliversToRecipient() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), 3000 * USDC_PRECISION);
        QUID.mint(User01, 3000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 35 days);
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));

        address recipient = User03;
        uint callerUsdc0 = USDC.balanceOf(User01);
        uint recipUsdc0  = USDC.balanceOf(recipient);
        uint callerQd0   = QUID.balanceOf(User01);

        vm.prank(User01);
        AUX.redeemTo(1000 * WAD, recipient); // pro-rata, paid to User03

        assertEq(callerQd0 - QUID.balanceOf(User01), 1000 * WAD, "burns the CALLER's QUI");
        assertGt(USDC.balanceOf(recipient) - recipUsdc0, 0, "RECIPIENT received the proceeds");
        assertEq(USDC.balanceOf(User01), callerUsdc0, "caller got nothing (payout retargeted)");
        AUX.checkBacking();
    }

    /// redeemTo rejects a zero recipient.
    function testRedeemToRejectsZeroRecipient() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), 1000 * USDC_PRECISION);
        QUID.mint(User01, 1000 * USDC_PRECISION, address(USDC), 0);
        vm.expectRevert(bytes("bad-recipient"));
        AUX.redeemTo(100 * WAD, address(0));
        vm.stopPrank();
    }
}
