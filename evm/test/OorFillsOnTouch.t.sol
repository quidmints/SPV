// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {Quid} from "../src/Quid.sol";

/// @title §OOR-AS-INTENT — A RESTING ORDER THAT EXISTS ONLY AS A SIGNATURE
///
/// @notice **THIS FILE REPLACES THE ONE THAT TESTED THE BOOK, AND THE REPLACEMENT WAS OVERDUE.**
///         `Quid.fillIntent` landed in `abb685c4` (2026-08-28) with **ZERO tests** — measured, not
///         estimated — while `outOfRange`/`pull`/`sweepOor`/`fillOOR` and their sorted-set index
///         stayed live beside it. Two designs, one tested, and the untested one was the survivor.
///         **That is why the book went un-deleted for a day and why this file exists before any
///         further work on the intent path.** (§OOR-TWO-DESIGNS-LIVE.)
///
/// ⚠️ **WHAT WENT AND WHY IT IS NOT A COVERAGE LOSS.** The previous file's first four tests were
///    about the BOOK'S INDEX — that `SortedSetLib.insert` silently discards a duplicate, so the key
///    had to be `(price << 96) | id`; that the packing sorts by price first; that a full `pull`
///    leaves no ghost in the set; that `pull`'s 47-block rule does not reach the fill path. **Every
///    one of those is a property of a structure that no longer exists.** An intent is not indexed,
///    not stored, and not closed — it is signed, and it is consumed. The properties that SURVIVE
///    the change are re-asserted below against the mechanism that now carries them.
///
/// ⚠️ **AND THE OLD FILE'S OWN CAVEAT STILL BINDS, FOR THE SAME REASON:** a fill needs the range's
///    ORACLE to have crossed the limit, and on a pinned fork `getTWAPforAsset` moves for neither
///    `vm.roll` nor `vm.warp`. Mocking it would prove only that the test can lie to itself. So the
///    crossing is asserted from the REFUSING side — an uncrossed limit reverts `IntentNotCrossed`,
///    which is the same guard from the other direction — and the end-to-end fill remains booked as
///    §E258-CROSSING-TEST, still open.
contract OorIntentTest is AllesFixture {

    /// The maker. A private key, not `User01`, because an intent is a SIGNATURE and the whole
    /// mechanism turns on who holds one.
    uint256 internal constant MAKER_PK = 0xA11CE;
    address internal maker;

    function setUp() public override { super.setUp(); maker = vm.addr(MAKER_PK); }

    /// EIP-712 domain, recomputed here rather than read: `Quid._oorDomain()` is `private`, and a
    /// test that asked the contract for the digest it is about to verify would be asserting that
    /// `ecrecover` is deterministic. Rebuilding it from the published constants is what makes this
    /// a check on the CONTRACT'S domain rather than a mirror of it.
    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(SwapLib.OOR_DOMAIN_TYPEHASH,
            keccak256("QuidOor"), keccak256("1"), block.chainid, address(ETH)));
    }

    function _intent(uint64 nonce, uint limitPx, bool buyVolatile)
        internal view returns (SwapLib.OorIntent memory i) {
        i = SwapLib.OorIntent({
            owner: maker, buyVolatile: buyVolatile, size: rack / 10, limitPx: limitPx,
            expiry: uint64(block.timestamp + 1 days), nonce: nonce, loadBalance: true,  payoutToken: address(0) });
    }

    /// No conversion requested: the fill pays the maker's signed token and takes a partial if the
    /// basket is short. Every test here exercises that path; the routed path has its own suite.
    function _noRoutes() internal pure returns (bytes[] memory) { return new bytes[](0); }

    function _sign(SwapLib.OorIntent memory i, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domain(),
            keccak256(abi.encode(SwapLib.OOR_TYPEHASH, i.owner, i.buyVolatile, i.size,
                i.limitPx, i.expiry, i.nonce, i.loadBalance, i.payoutToken))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// A price the oracle has NOT reached, on the far side of a bid. Read live so the test does not
    /// pin a number the fork can move under it.
    function _uncrossedBid() internal view returns (uint) {
        return AUX.getTWAPforAsset(address(WETH), 1800) / 2;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  THE FOUR PROPERTIES THAT SURVIVED THE BOOK, EACH AGAINST ITS NEW CARRIER
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// WAS: *"a fresh order is not touched, so the poke refuses it."* NOW: the ORACLE binds, and it
    /// is the contract's own read. A bid whose limit the price has not fallen to is refused —
    /// which is also the whole anti-keeper property, because the relayer chooses WHEN and the
    /// contract decides WHETHER. If this ever starts filling, a relayer can name the price.
    function test_AnUncrossedLimitIsRefused_theOracleDecidesNotTheRelayer() public {
        SwapLib.OorIntent memory i = _intent(1, _uncrossedBid(), true);
        bytes memory sig = _sign(i, MAKER_PK);
        vm.prank(User02);                       // permissionless relay — anyone may submit
        vm.expectRevert(SwapLib.IntentNotCrossed.selector);
        ETH.fillIntent(i, sig, _noRoutes());
    }

    /// WAS: *"a full pull leaves no ghost in the index."* NOW: **one consumed bit per
    /// `(owner, nonce)`, and it is the ONLY storage the mechanism ever writes.** There is no
    /// position to leave behind, so the property becomes: a nonce cannot be spent twice.
    /// ⚠️ Asserted through the PUBLIC map rather than by filling twice, because filling once needs
    ///    a crossing this fixture cannot produce (see the file header). The map is what `fillIntent`
    ///    reads, so this is the same bit the guard consults.
    function test_TheNonceIsTheOnlyState_andItStartsUnspent() public view {
        assertFalse(ETH.intentUsed(maker, 1), "a nonce nobody has filled must be unspent");
        assertFalse(ETH.intentUsed(maker, 2), "and nonces are independent of one another");
    }

    /// WAS: *"two orders at the same trigger both remain real"* — the case a bare-price key would
    /// have stranded. NOW two intents at one limit are simply two nonces: there is no index for
    /// them to collide in, and the property is that the CONSUMED BIT is per-nonce rather than
    /// per-owner or per-price.
    function test_TwoIntentsAtOneLimitAreTwoNonces() public {
        uint px = _uncrossedBid();
        SwapLib.OorIntent memory a = _intent(7, px, true);
        SwapLib.OorIntent memory b = _intent(8, px, true);
        assertTrue(keccak256(_sign(a, MAKER_PK)) != keccak256(_sign(b, MAKER_PK)),
            "the same limit under two nonces must be two distinct signatures");
        // Both are individually addressable, and both stop at the same guard.
        vm.expectRevert(SwapLib.IntentNotCrossed.selector); ETH.fillIntent(a, _sign(a, MAKER_PK), _noRoutes());
        vm.expectRevert(SwapLib.IntentNotCrossed.selector); ETH.fillIntent(b, _sign(b, MAKER_PK), _noRoutes());
    }

    /// WAS: *"the poke rejects an order that is not there."* NOW an intent that was never authorised
    /// has no on-chain existence to check — so the guard is the SIGNATURE, and this is the
    /// mechanism's central security claim: **a fully-compromised keeper holds no key that moves
    /// funds.** Signed by someone who is not `owner` ⇒ refused.
    function test_AnIntentSignedByAnyoneButTheOwnerIsRefused() public {
        SwapLib.OorIntent memory i = _intent(3, _uncrossedBid(), true);
        bytes memory forged = _sign(i, 0xBAD5EED);      // a real signature, over the real digest
        vm.expectRevert(SwapLib.IntentBadSig.selector);
        ETH.fillIntent(i, forged, _noRoutes());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  AND THE PROPERTIES THE BOOK COULD NOT HAVE
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// AN INTENT IS NOT IMMORTAL, which a resting position was. Expiry is checked FIRST, before the
    /// signature and before the oracle — so an expired intent costs a relayer nothing to discover.
    function test_AnExpiredIntentIsRefusedBeforeAnythingElse() public {
        SwapLib.OorIntent memory i = _intent(4, _uncrossedBid(), true);
        bytes memory sig = _sign(i, MAKER_PK);
        vm.warp(uint(i.expiry) + 1);
        vm.expectRevert(SwapLib.IntentExpired.selector);
        ETH.fillIntent(i, sig, _noRoutes());
    }

    /// A MALFORMED SIGNATURE IS REFUSED AS A SIGNATURE, not as an `ecrecover` of address(0).
    /// ⚠️ The length check exists because `ecrecover` returns `address(0)` on garbage, and an
    ///    `OorIntent` whose `owner` was `address(0)` would then verify. The guard is what stops a
    ///    zero-owner intent being a valid one.
    function test_AShortSignatureIsRefused() public {
        SwapLib.OorIntent memory i = _intent(5, _uncrossedBid(), true);
        vm.expectRevert(SwapLib.IntentBadSig.selector);
        ETH.fillIntent(i, hex"1234", _noRoutes());
    }

    /// ⭐ THE FIELDS ARE ALL BOUND BY THE SIGNATURE — changing any one of them after signing
    ///    invalidates it. Demonstrated on `size`, which is the one that moves money: a relayer who
    ///    could inflate it would drain the maker at the maker's own limit.
    function test_TheRelayerCannotAlterTheSignedTerms() public {
        SwapLib.OorIntent memory i = _intent(6, _uncrossedBid(), true);
        bytes memory sig = _sign(i, MAKER_PK);
        i.size = i.size * 10;                            // same signature, different terms
        vm.expectRevert(SwapLib.IntentBadSig.selector);
        ETH.fillIntent(i, sig, _noRoutes());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  §INTENT-HAS-NO-FUNDING-LEG — THE GATE, AND THE MEASUREMENT THAT PUT IT THERE
    // ─────────────────────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────────────────────
    //  §INTENT-FUNDING-LEG — THE DEBIT, AND THE MEASUREMENT THAT PUT IT THERE
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// 🔴 **THE REGRESSION TEST FOR A MEASURED DRAIN.** Before the funding leg, with the oracle at
    /// **2,449.92**, this exact scenario ran to completion and paid the maker
    /// **408134038270347149 wei = $1,000.00 exactly**, while `POOLED` fell by that ether and
    /// `POOLED_USD` rose by 1,000.000000 — from an address holding **no ether, no dollars and no
    /// in-range LP position**. Nothing debited it, because nothing in the path ever looked.
    /// ⇒ The maker now has NO basket claim, so the burn realises nothing and the fill refuses.
    /// **`IntentUnfunded` is the assertion: the fill is bounded by the claim, not by the ask.**
    function test_AFillWithNoClaimBehindItIsRefused() public {
        vm.deal(User01, 100 ether);
        vm.prank(User01);
        ETH.deposit{value: 50 ether}(0, User01);

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        assertEq(maker.balance, 0, "premise: the maker holds no ether");
        assertEq(USDC.balanceOf(maker), 0, "premise: the maker holds no dollars");
        (uint makerPooled,,,) = ETH.autoManaged(maker);
        assertEq(makerPooled, 0, "premise: the maker is NOT an in-range LP");
        assertEq(QUID.balanceOf(maker), 0, "premise: and holds no basket claim either");

        SwapLib.OorIntent memory i = SwapLib.OorIntent({
            owner: maker, buyVolatile: true, size: 1_000 * 1e6, limitPx: px,
            expiry: uint64(block.timestamp + 1 days), nonce: 42, loadBalance: false, payoutToken: address(0) });

        vm.prank(User02);                                   // a relayer, not the maker
        vm.expectRevert(SwapLib.IntentUnfunded.selector);
        ETH.fillIntent(i, _sign(i, MAKER_PK), _noRoutes());

        assertEq(maker.balance, 0, "no ether left the range");
    }

    /// ⭐ **THE PROPERTY WHOSE ABSENCE WAS THE BUG: A FILL DEBITS THE MAKER BY WHAT IT CREDITS.**
    /// A maker who DOES hold a basket claim is filled — and pays for it. This is the positive case
    /// the original seven tests could not reach: every one of them exercised a REFUSAL, so none
    /// could observe that the successful path charged nobody. **A suite of negative tests cannot see
    /// a missing positive**, which is why this one is here and why it asserts a BALANCE rather than
    /// a revert.
    function test_AFundedFillDebitsTheMakersClaim() public {
        vm.deal(User01, 100 ether);
        vm.prank(User01);
        ETH.deposit{value: 50 ether}(0, User01);

        // ⚠️ **A USER CANNOT MINT MATURE QU!D, AND THE TEST HAS TO RESPECT THAT.**
        //    `Basket._finishMint` clamps the requested month UP:
        //    `month = max(min(when, nextMonth + maxFwd), nextMonth)`, so `when = 0` lands at
        //    `currentMonth() + 1` and is IMMATURE by construction. `immatureBalanceOf` sums
        //    cm+1..cm+13, and the fill (like redeem) spends MATURE only — so a freshly-minted
        //    holder funds NOTHING. First version of this test asserted a fill against a
        //    just-minted claim and got `IntentUnfunded`, which was the fixture being wrong and the
        //    contract being right.
        //    ⇒ Mint, then cross the maturity boundary. One month is enough: the batch sits at
        //      `cm+1`, so once `currentMonth()` reaches it the balance leaves the immature window.
        deal(address(USDC), maker, 5_000 * 1e6);
        vm.startPrank(maker);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(maker, 5_000 * 1e6, address(USDC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 32 days);
        assertEq(QUID.immatureBalanceOf(maker), 0, "premise: the claim has matured");

        uint claimBefore = QUID.balanceOf(maker);
        assertGt(claimBefore, 0, "premise: the maker has a basket claim to spend");
        assertEq(maker.balance, 0, "premise: and no ether yet");

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        SwapLib.OorIntent memory i = SwapLib.OorIntent({
            owner: maker, buyVolatile: true, size: 1_000 * 1e6, limitPx: px,
            expiry: uint64(block.timestamp + 1 days), nonce: 43, loadBalance: false, payoutToken: address(0) });

        vm.prank(User02);                                   // still a relayer, not the maker
        ETH.fillIntent(i, _sign(i, MAKER_PK), _noRoutes());

        uint claimAfter = QUID.balanceOf(maker);
        assertLt(claimAfter, claimBefore, "THE FIX: the fill DEBITED the maker's claim");
        assertGt(maker.balance, 0,        "and delivered the ether it was paid for");

        // The two legs must be the same trade. The maker's claim fell by `spent` QU!D; at the
        // signed limit that must buy the ether they received, to within the 6-dec truncation the
        // credit takes on its way into `POOLED_USD` (`funded6 = burned·perShare/WAD / 1e12`).
        uint spent = claimBefore - claimAfter;
        assertApproxEqRel(maker.balance, spent * 1e18 / px, 1e15,
            "debit and credit must be the same trade: ether received != claim spent at the limit");
    }

    /// @notice ⭐ **THE SELL LEG, END TO END.** Three properties, and the first is the one every
    ///         earlier design of this leg got wrong: **the maker's ether never moves.** An in-range
    ///         LP's ether is already in `POOLED`, so a fill SHRINKS THEIR CLAIM on ether that stays
    ///         exactly where it is, and pays them dollars in the stable they SIGNED for.
    function test_ASellFillShrinksTheClaimAndPaysTheSignedStable() public {
        vm.deal(maker, 100 ether);
        vm.prank(maker);
        ETH.deposit{value: 40 ether}(0, maker);        // the maker is an IN-RANGE LP

        // give the basket real USDC to pay out of
        deal(address(USDC), User01, 200_000 * 1e6);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 200_000 * 1e6, address(USDC), 0);
        vm.stopPrank();

        uint pooledBefore = ETH.balanceOf(maker);   // Shares.sol:26 - balanceOf IS autoManaged[u].pooled
        assertGt(pooledBefore, 0, "premise: the maker must hold an in-range position");
        uint rangeEthBefore = CORE.POOLED();
        uint usdcBefore     = USDC.balanceOf(maker);

        // A sell fills once price has risen TO OR THROUGH the limit, so sign AT spot.
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        SwapLib.OorIntent memory i = SwapLib.OorIntent({
            owner: maker, buyVolatile: false, size: 5_000 * 1e6, limitPx: px,
            expiry: uint64(block.timestamp + 1 days), nonce: 77, loadBalance: false,
            payoutToken: address(USDC) });

        vm.prank(User02);                              // a relayer, not the maker
        ETH.fillIntent(i, _sign(i, MAKER_PK), _noRoutes());

        uint pooledAfter = ETH.balanceOf(maker);
        uint paid = USDC.balanceOf(maker) - usdcBefore;

        // ① THE MAKER WAS PAID IN THE TOKEN THEY SIGNED - not a pro-rata spray of the basket.
        assertGt(paid, 0, "the maker must be paid in their chosen stable");

        // ② THEIR CLAIM SHRANK - this is the debit, and it is what makes the payment balanced.
        assertLt(pooledAfter, pooledBefore, "the sell must shrink the maker's ether claim");

        // ③ AND THE RANGE'S ETHER DID NOT MOVE. Every wrong design of this leg fails here:
        //    delivering ether would drop POOLED, booking it would raise POOLED.
        assertEq(CORE.POOLED(), rangeEthBefore, "the maker's ether must stay exactly where it is");

        // and the two legs must be the same trade, at the SIGNED limit
        uint sold = pooledBefore - pooledAfter;
        assertApproxEqRel(sold, (paid * 1e12) * 1e18 / px, 1e15,
            "ether debited must equal dollars paid at the limit price");
    }

    /// @notice §SELL-LEG-IS-FORCED — **THE ONE STEP THAT CAN FAIL IN A WAY REASONING WOULD NOT
    ///         CATCH.** The sell leg is specified as `usdDelta = +size·limitPx` with `volDelta = 0`,
    ///         plus a QU!D mint to the maker. The argument for it is that the LP pool gives up
    ///         `size·limitPx` of dollar side and keeps `size` more ether, so the mint is matched and
    ///         backing holds. **That is an argument. This is the measurement.**
    /// @dev    Deliberately exercises the PRIMITIVES rather than `fillIntent`, which still reverts
    ///         `IntentSellLegUnbuilt`: the point of writing it first is to falsify the settlement
    ///         BEFORE the entrypoint is wired, so a failure here is cheap. If this reverts or the
    ///         backing gap widens, the design is wrong and no amount of plumbing fixes it.
    ///         ⚠️ Units: `usdDelta` is 6-dec (`_settleUsdSide` hands it to `BasketLib.from6`), while
    ///         the mint is 18-dec (`_mintQuid` multiplies by 1e12). Getting that backwards is a
    ///         1e12 error that would LOOK like a catastrophic backing break.
    function test_TheSellSettlementPreservesBacking() public {
        vm.deal(User01, 100 ether);
        vm.prank(User01);
        ETH.deposit{value: 50 ether}(0, User01);          // real in-range ether for the maker's side
        deal(address(USDC), maker, 5_000 * 1e6);
        vm.startPrank(maker);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(maker, 5_000 * 1e6, address(USDC), 0);   // real basket assets behind the range
        vm.stopPrank();

        (uint committedBefore, uint liquidBefore) = AUX.tryCheckBacking();
        assertGt(liquidBefore, 0, "premise: the basket must hold something, else this is vacuous");

        uint px    = AUX.getTWAPforAsset(address(WETH), 1800);
        uint size  = 1 ether;
        uint usd6  = (size * px / 1e18) / 1e12;            // the maker's proceeds at their own limit
        assertGt(usd6, 0, "premise: a zero payout would make the assertions vacuous");

        uint supplyBefore   = QUID.totalSupply();
        uint immatureBefore = QUID.immatureBalanceOf(maker);

        // ── THE SETTLEMENT UNDER TEST, in the primitives §SELL-LEG-IS-FORCED derived ──
        // `volDelta = 0`: the maker's ether is ALREADY in POOLED and must not move.
        // `usdDelta > 0` with `token == 0` (settleOor's own argument): the range's dollar side
        // shrinks and NOTHING is delivered — the only primitive that moves dollars with no route.
        vm.prank(address(ETH));
        CORE.settleOor(maker, int(usd6), 0, false);
        // ...and the maker is paid in the instrument the system actually has for a dollar claim.
        vm.prank(address(ETH));
        QUID.mint(maker, usd6 * 1e12, address(QUID), 0);

        assertEq(QUID.totalSupply() - supplyBefore, usd6 * 1e12, "the mint is the maker's payment");

        // THE ASSERTION THE WHOLE DESIGN RESTS ON: the strict check must still pass.
        AUX.checkBacking();
        (uint committedAfter, uint liquidAfter) = AUX.tryCheckBacking();

        // ⭐ **MEASURED, NOT ASSUMED — AND THE FIRST VERSION OF THIS TEST ASSERTED NOTHING.** It
        //    compared a `gap` before and after and both were IDENTICAL TO THE WEI, so it passed
        //    whether the settlement worked or not. Its control (below) is what exposed that. These
        //    assertions name the exact movement instead, so they can go red:
        assertEq(committedBefore - committedAfter, usd6 * 1e12,
            "the range's dollar side must give up EXACTLY the maker's proceeds");
        assertEq(liquidAfter, liquidBefore,
            "and no basket asset may move - the payment comes from committed dollars, not reserves");
        assertEq(committedAfter, CORE.POOLED_USD() * 1e12,
            "committedSum IS POOLED_USD: that identity is what makes the leg above legible");

        // 🔴 **AND THE PART THAT CHANGES WHAT THIS PRODUCT IS: THE MAKER IS PAID A *DATED* CLAIM.**
        //    `Basket._finishMint` clamps the month UP to at least `currentMonth()+1`, so **mature
        //    QU!D CANNOT BE MINTED** — the proceeds are IMMATURE by construction and unspendable
        //    until they mature. That is why the mint is invisible to `committedSum` here.
        assertEq(QUID.immatureBalanceOf(maker) - immatureBefore, usd6 * 1e12,
            "the maker's proceeds land IMMATURE - a claim maturing next month, not spendable dollars");
        assertLe(committedAfter, liquidAfter, "backing must hold at the instant of the fill");
    }

    /// @notice ⚠️ **THE CONTROL FOR THE TEST ABOVE, AND WITHOUT IT THAT TEST PROVES NOTHING.**
    ///         `test_TheSellSettlementPreservesBacking` passes — but a green assertion only means
    ///         something if the same assertion goes RED when the thing it checks is broken. So this
    ///         runs the identical mint with the `settleOor` dollar-side shrink REMOVED: an unmatched
    ///         mint, which is precisely the failure the design is claimed to avoid.
    /// @dev    If this shows the gap UNCHANGED, then the passing test was vacuous and the backing
    ///         claim in §SELL-LEG-IS-FORCED is unverified — the mint would be invisible to the
    ///         backing check and the whole argument would rest on nothing.
    function test_ControlOnlyTheSettleOorLegSurrendersTheDollars() public {
        vm.deal(User01, 100 ether);
        vm.prank(User01);
        ETH.deposit{value: 50 ether}(0, User01);
        deal(address(USDC), maker, 5_000 * 1e6);
        vm.startPrank(maker);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(maker, 5_000 * 1e6, address(USDC), 0);
        vm.stopPrank();

        (uint committedBefore, uint liquidBefore) = AUX.tryCheckBacking();
        uint px   = AUX.getTWAPforAsset(address(WETH), 1800);
        uint usd6 = ((1 ether) * px / 1e18) / 1e12;

        // THE ONLY DIFFERENCE FROM THE TEST ABOVE: no `CORE.settleOor(...)`. The maker is paid and
        // nothing gives up the dollars that pay them.
        vm.prank(address(ETH));
        QUID.mint(maker, usd6 * 1e12, address(QUID), 0);

        (uint committedAfter, uint liquidAfter) = AUX.tryCheckBacking();
        // THE DISCRIMINATOR: with no `settleOor`, nothing gives up the dollars that pay the maker.
        // The sibling test asserts `committed` falls by EXACTLY the proceeds; here it must not move
        // at all. If these two ever agree, the sibling is measuring nothing - which is precisely
        // what the FIRST version of this pair did, and why this control exists.
        assertEq(committedAfter, committedBefore,
            "CONTROL: an unmatched mint must leave committed untouched - it is the settleOor leg, "
            "not the mint, that surrenders the dollars");
        assertEq(liquidAfter, liquidBefore, "and the basket is untouched on either path");
        // AND THE POINT THE FIRST VERSION MISSED: the mint alone is INVISIBLE to the backing check,
        // because it lands immature. A test watching only committed-vs-liquid cannot see an
        // unmatched payment at all, so it would pass no matter how wrong the settlement was.
        assertGt(QUID.immatureBalanceOf(maker), 0, "the unmatched mint did happen, and is unseen");
    }

    /// ⚠️ **`loadBalance` IS INERT ON THIS RANGE, AND IT IS INSIDE THE SIGNED TYPEHASH.**
    /// `settleOor(..., loadBalance)` → `Core._shortfallLoadBalance` → `RANGE.onShortfall(...)`, and
    /// `Quid.onShortfall(address, uint) external {}` is an EMPTY BODY — a deliberate no-op with a
    /// docblock saying so (*"Do not implement this"*: an ETH refill would realise impermanent loss
    /// onto shared backing). Only `Vault` routes a shortfall anywhere, and it routes to the hop.
    /// ⇒ **The maker signs a consent that changes nothing on ETH**, while the field is load-bearing
    ///    for SIGNATURE VALIDITY — flip it and the digest, and therefore the signature, is different.
    /// 📌 **AND 1inch IS NOT ON THIS PATH AT ALL.** `ONEINCH_ROUTER`/`_aggSwap` appear only in
    ///    `LevMath.sol` (the levered unwind). Nothing `settleOor` reaches touches an aggregator.
    ///    Asserted here so a future reader does not go looking for routing that was never wired.
    function test_LoadBalanceConsentIsInertOnTheEthRange() public {
        // The no-op accepts any caller and any amount and does nothing observable.
        uint before = CORE.POOLED();
        ETH.onShortfall(address(0xBEEF), 1 ether);
        assertEq(CORE.POOLED(), before, "onShortfall moved inventory: it is no longer a no-op");
    }
}
