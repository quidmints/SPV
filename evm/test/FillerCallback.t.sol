// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IT { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }
interface IV3c { function token0() external view returns (address); }
interface IAuxLite {
    function getStables() external view returns (address[] memory);
    function getTWAPforAsset(address, uint32) external view returns (uint256);
}
interface IDec { function decimals() external view returns (uint8); }
interface IFiller { function onQuidFill(address give, uint256 amt, address want, uint256 owed, bytes calldata d) external; }

/// @notice §SESS-40 — **THE STALENESS PROBLEM DISSOLVES IF NOTHING IS EMBEDDED: INVERT CONTROL.**
///
/// §SESS-39 proved a contract-maker order FILLS. But our conversion paths are **flash-bound**
/// (`LevMath:1605`, `LevManager:625`) — the sale must complete in the SAME transaction as the repay.
/// ⇒ **a posted order cannot serve them, and the reason is ASYNCHRONY, not staleness.** An order is
/// filled later; a flash loan repays now. Fixing the embedded amount would not have fixed that.
///
/// ⭐ **SO DO NOT POST AN AMOUNT — DO NOT POST ANYTHING.** Let the FILLER initiate. We hand over what we
///    are selling inside THEIR transaction, and require that by the end our balance of the wanted asset
///    rose by a floor **we computed before we let go of anything**. Nothing is embedded, so nothing can
///    be stale: the amount is whatever our internal computation just produced, and the price is our own
///    TWAP read in the same instant.
///
/// 🔑 **AND IT IS STRICTLY SAFER THAN TODAY'S `approve`-AND-CALL.** `convertTo` grants the router an
///    allowance and calls it; this TRANSFERS and demands repayment. **No allowance survives the call**,
///    so there is nothing left to drain in a later block — the standing-allowance hazard §SESS-2 flags
///    on `curveExchange` cannot exist in this shape at all.
/// ⚠️ **THE FLOOR IS READ BEFORE THE TRANSFER, DELIBERATELY.** If it were read after the callback, the
///    filler could move the oracle inside their own call and lower the bar they must clear.
contract QuidFillDesk {
    error Short(uint256 got, uint256 owed);
    bool private locked;
    address public immutable AUX;
    constructor(address aux) { AUX = aux; }

    error NotPriced(address token);

    /// @notice USD price of one whole `t`, 1e18-scaled. **FAIL-LOUD, NEVER DEFAULTING.**
    /// 🔴 **THIS EXISTS BECAUSE A FIRST DRAFT USED `_fromUsd` FOR A *WETH* OUTPUT AND GOT PAR.**
    ///    `loanPxUsd18` returns `USD_PX` whenever `assetPriceFeed(token) == 0`, and the fixture does not
    ///    register WETH — so the floor came out **49,875e18 WETH for 50,000 USDC**, wrong by ~2,500x.
    ///    ⚠️ **`_fromUsd`'s own docblock warns this failure is SILENT** (*"every shape and decimal
    ///    typechecks"*), and it reproduced exactly. ⭐ **The tree avoids it by having DIRECTION-SPECIFIC
    ///    floors:** `_stableToWethSor` reads `getTWAPforAsset` DIRECTLY because it knows its output is
    ///    WETH; `_wethStableFloor` uses `_fromUsd` because it knows its output is a dollar stable.
    ///    **They are not interchangeable, and a generic desk must discriminate rather than pick one.**
    /// ⚠️ `getTWAPforAsset` REVERTS `BadAsset()` for a stable, so the roster — not a catch-all default —
    ///    is what says "par". An asset that is neither priced nor on the roster **reverts**, because a
    ///    silent par is precisely the bug above (standing rule 3: fail loud, never clamp).
    function _pxUsd18(address t) internal view returns (uint256) {
        address[] memory st = IAuxLite(AUX).getStables();
        for (uint256 i; i < st.length; ++i) if (st[i] == t) return 1e18;   // roster stable => par
        try IAuxLite(AUX).getTWAPforAsset(t, 1800) returns (uint256 p) {
            if (p == 0) revert NotPriced(t);
            return p;
        } catch { revert NotPriced(t); }
    }

    /// @notice **PARITY — the oracle conversion with NO haircut: what `amt` of `give` is WORTH in
    ///         `want`, before any budget is subtracted.** ⭐ Split out of `floorOracle` so the budget
    ///         invariant can be measured against it (§SESS-48). **ONE formula, two readers** — a test
    ///         that reconstructed parity by dividing the haircut back out would be asserting against
    ///         its own rounding, not against the contract.
    function parity(address give, uint256 amt, address want) public view returns (uint256) {
        uint256 usd18 = (amt * _pxUsd18(give)) / (10 ** IDec(give).decimals());
        return (usd18 * (10 ** IDec(want).decimals())) / _pxUsd18(want);
    }

    /// @notice The USD size of a trade, 1e18 — the argument `_slipBps` is a function of. Exposed so a
    ///         test can ask for the BUDGET at a size without re-deriving the scaling.
    function usdSize(address give, uint256 amt) public view returns (uint256) {
        return (amt * _pxUsd18(give)) / (10 ** IDec(give).decimals());
    }

    /// @notice **THE ORACLE ARM — AND IT CARRIES THE ONLY GUESS IN THE SYSTEM.** Value what we hand over
    ///         in USD, convert at the ORACLE, haircut by `_slipBps`. ⚠️ **`_slipBps` IS A GUESS** — 25 bps
    ///         rising to a 100 bps cap, which this file books as *"12–60x the measured need"* against
    ///         §ROUTE-COST-MEASURED's 1.7–8 bps. Every basis point of it is takeable.
    function floorOracle(address give, uint256 amt, address want) public view returns (uint256) {
        uint256 usd18 = usdSize(give, amt);
        return (parity(give, amt, want) * (10_000 - LevMath._slipBps(usd18))) / 10_000;
    }

    /// @notice ⭐ **THE GUESS-FREE ARM: what this contract could get for itself, MEASURED, no constants.**
    ///         `_selfServableQuote` walks `_quoteOf`'s rows through Curve `get_dy` at the size actually
    ///         being traded. **There is no tolerance, no slip curve and no tuned number in it** — it is a
    ///         live quote or it is 0.
    function floorQuoted(address give, uint256 amt, address want) public view returns (uint256) {
        return LevMath._selfServableQuote(give, amt, want);
    }

    /// @notice The floor actually enforced: **the better of a live quote and the oracle arm.**
    /// 🔑 **THE GUESS ONLY SURVIVES WHERE THERE IS NOTHING TO MEASURE.** Where `_quoteOf` has a row the
    ///    floor is fully derived from live state; where it does not, we fall back to the oracle arm and
    ///    `_slipBps` is doing the work. ⇒ **the remaining guesswork is EXACTLY the volatile leg**, which
    ///    is §SESS-23's finding restated as a bound rather than a caveat.
    /// ⚠️ `max` is the manipulation-safe direction: a reference pushed DOWN falls back to the oracle; one
    ///    pushed UP costs a fill (liveness), never custody.
    function floorFor(address give, uint256 amt, address want) public view returns (uint256) {
        uint256 q = floorQuoted(give, amt, want);
        uint256 o = floorOracle(give, amt, want);
        return q > o ? q : o;
    }

    /// Hand `amt` of `give` to `msg.sender`; require the DERIVED floor of `want` back by the end.
    /// @return owed the floor that was enforced, so a caller can see what it had to beat.
    function fill(address give, uint256 amt, address want, bytes calldata d) external returns (uint256 owed) {
        require(!locked, "reentrant"); locked = true;
        // ⚠️ **DERIVED AND SNAPSHOT BEFORE WE LET GO OF ANYTHING.** Read after the callback, a filler
        //    could move the oracle inside their own call and lower the bar they must clear.
        owed = floorFor(give, amt, want);
        uint256 before = IT(want).balanceOf(address(this));
        IT(give).transfer(msg.sender, amt);                    // no allowance, ever
        IFiller(msg.sender).onQuidFill(give, amt, want, owed, d);
        uint256 got = IT(want).balanceOf(address(this)) - before;
        if (got < owed) revert Short(got, owed);
        locked = false;
    }
}

/// An HONEST filler: sources the wanted asset from any venue it likes and repays.
contract GoodFiller is IFiller {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev `repay` is SEPARATE from `owed` on purpose: a control that shorts the desk must short it
    ///      deliberately, not by being insolvent. A first draft asked for 1,000 WETH and so tested the
    ///      FILLER's balance rather than the DESK's floor check — it passed for the wrong reason.
    /// `repayDelta` is signed-ish: 0 = pay exactly the derived floor, N = underpay by N.
    function go(QuidFillDesk desk, address give, uint256 amt, address want, uint256 dexWord, uint256 underpayBy) external {
        desk.fill(give, amt, want, abi.encode(dexWord, underpayBy));
    }
    function onQuidFill(address give, uint256 amt, address want, uint256 owed, bytes calldata d) external {
        (uint256 dex, uint256 underpayBy) = abi.decode(d, (uint256, uint256));
        (bool ok,) = give.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, amt));
        require(ok, "ap");
        (bool k,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP_SELECTOR, uint256(uint160(give)), amt, uint256(1), dex)); k;
        IT(want).transfer(msg.sender, owed - underpayBy);       // pay the DERIVED floor, minus any chosen shortfall
    }
}
/// A SOLVENT filler that pays from its OWN inventory. ⭐ **THIS SEPARATES TWO QUESTIONS THAT WERE
/// TANGLED:** *does the desk ENFORCE its floor* (mechanism) is not *can any venue MEET the floor*
/// (market). Routing through a venue tests both at once, and when the venue cannot meet the floor the
/// mechanism test fails for a reason that has nothing to do with the mechanism.
contract StockedFiller is IFiller {
    function go(QuidFillDesk desk, address give, uint256 amt, address want, uint256 underpayBy) external {
        desk.fill(give, amt, want, abi.encode(underpayBy));
    }
    function onQuidFill(address, uint256, address want, uint256 owed, bytes calldata d) external {
        uint256 underpayBy = abi.decode(d, (uint256));
        IT(want).transfer(msg.sender, owed - underpayBy);
    }
}

/// A HOSTILE filler: takes the asset and returns nothing.
contract ThiefFiller is IFiller {
    function go(QuidFillDesk desk, address give, uint256 amt, address want) external {
        desk.fill(give, amt, want, "");
    }
    function onQuidFill(address, uint256, address, uint256, bytes calldata) external {}
}

contract FillerCallbackTest is AllesFixture {
    address constant WETHA = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDTA = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant P_USDC_WETH = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    /// Uniswap V3 `QuoterV2` — simulates a swap and returns the output. **A VENUE, NAMED; NOT A PRICE,
    /// FROZEN.** §SESS-48 uses it so the budget invariant is measurable at any pin.
    address constant QUOTER_V2    = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant DAIA         = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant P_USDC_USDT = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    QuidFillDesk desk;

    function _mkDesk() internal { desk = new QuidFillDesk(address(AUX)); }

    function _word(address pool, address tin) internal view returns (uint256 w) {
        w = (uint256(1) << 253) | uint256(uint160(pool));
        if (IV3c(pool).token0() == tin) w |= (uint256(1) << 247);
    }

    /// ⭐ ①a — **THE GUESS-FREE CASE.** USDC→USDT has a `_quoteOf` row, so the floor is a LIVE Curve
    ///    quote at the traded size: no tolerance, no slip curve, no tuned constant anywhere in it.
    function test_DerivedFloor_IsFullyMeasuredWhereAQuoteExists() public {
        _mkDesk();
        uint256 amt = 50_000e6;
        uint256 q = desk.floorQuoted(address(USDC), amt, USDTA);
        uint256 o = desk.floorOracle(address(USDC), amt, USDTA);
        uint256 f = desk.floorFor(address(USDC), amt, USDTA);
        emit log_named_uint("USDC->USDT quoted (measured)", q);
        emit log_named_uint("USDC->USDT oracle (guessed) ", o);
        emit log_named_uint("USDC->USDT floor ENFORCED   ", f);
        assertGt(q, 0, "no live quote - this pair cannot demonstrate a guess-free floor");
        assertEq(f, q > o ? q : o, "the enforced floor must be the better of the two arms");
        assertGt(q, o, "the MEASURED arm must beat the guessed one, else the guess is still binding");
        emit log_named_uint("bps of guesswork REMOVED", (q - o) * 10_000 / q);
    }

    /// 🔴 ①b — **AND WHERE NO QUOTE EXISTS, THE GUESS IS WHAT BINDS.** USDC→WETH has no `_quoteOf` row
    ///    (§SESS-23: the self-servable venues were deleted), so `_slipBps` is doing the work. This
    ///    asserts that fact rather than letting it hide.
    function test_DerivedFloor_TheGuessSurvivesOnlyOnTheVolatileLeg() public {
        _mkDesk();
        uint256 amt = 50_000e6;
        assertEq(desk.floorQuoted(address(USDC), amt, WETHA), 0,
            "a WETH quote appeared - RE-OPEN: the volatile leg's guesswork may now be removable");
        uint256 o = desk.floorOracle(address(USDC), amt, WETHA);
        assertEq(desk.floorFor(address(USDC), amt, WETHA), o, "with no quote the oracle arm must bind");
        emit log_named_uint("USDC->WETH floor (oracle+slip)", o);
    }

    /// @dev One fee tier. `QuoterV2` SIMULATES the swap, so it does not move state and cannot perturb
    ///      what the rest of the suite reads. Non-`view` by design, hence no `staticcall`.
    ///      Returns 0 when the tier has no pool or cannot fill — a missing venue is not an error.
    function _quoteTier(address tin, address tout, uint256 amtIn, uint24 fee) internal returns (uint256) {
        (bool ok, bytes memory r) = QUOTER_V2.call(abi.encodeWithSelector(
            bytes4(keccak256("quoteExactInputSingle((address,address,uint256,uint24,uint160))")),
            tin, tout, amtIn, fee, uint160(0)));
        return (ok && r.length >= 32) ? abi.decode(r, (uint256)) : 0;
    }

    /// @dev ⭐ **THE BEST REACHABLE VENUE, ACTUALLY SEARCHED — because "best" is the whole claim.**
    ///      Quoting ONE tier and calling it the best assumes the answer, and at size the answer moves
    ///      between tiers: impact grows with depth-relative size, so the cheap-fee/thin pool that wins
    ///      at $50k can lose to a dear-fee/deep one at $1M. **A `need` measured against a venue we
    ///      could have beaten is not the market's cost, it is our own search's cost** — and it would
    ///      make `_slipBps` look insufficient for a shortfall that is really a routing failure.
    ///      ⚠️ This is the §SESS-45 argument (score the venue, do not assume it) arriving inside a test.
    /// 🔴 **AND IT IS NOT A HYPOTHETICAL — SEARCHING ONLY DIRECT POOLS MANUFACTURED A FALSE LIVENESS
    ///    DEFECT, TWICE, AT TWO PINS.** Direct-only put `need` at 51–52 bps against a 50 bps budget and
    ///    reported the floor as unmeetable. **The 2-hop through the USDT hub returns ~23 bps MORE**
    ///    (measured at `25919955`: direct best `399.365`, hub 2-hop `400.282`, parity `401.497`), which
    ///    drops `need` to ~30 bps and clears the budget with room. ⇒ **the shortfall was my own
    ///    search's, exactly as the paragraph above warns.** Standing rule 13: the dismissal needed the
    ///    same evidence as the finding, and it got it.
    function _bestDirect(address tin, address tout, uint256 amtIn) internal returns (uint256 best) {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10000];
        for (uint256 i; i < tiers.length; ++i) {
            uint256 q = _quoteTier(tin, tout, amtIn, tiers[i]);
            if (q > best) best = q;
        }
    }

    /// @dev **Mirrors `plan_route`'s own shape — direct, else two hops through the hub — so the number
    ///      this returns is a route the protocol can actually take, not an abstract market best.**
    function _quoteBestVenue(address tin, address tout, uint256 amtIn) internal returns (uint256 best) {
        best = _bestDirect(tin, tout, amtIn);
        address[2] memory hubs = [USDTA, DAIA];
        for (uint256 i; i < hubs.length; ++i) {
            if (hubs[i] == tin || hubs[i] == tout) continue;
            uint256 mid = _bestDirect(tin, hubs[i], amtIn);
            if (mid == 0) continue;
            uint256 q = _bestDirect(hubs[i], tout, mid);
            if (q > best) best = q;
        }
    }

    /// ⭐ §SESS-48 — **THE BUDGET INVARIANT, MEASURED LIVE AT WHATEVER BLOCK WE ARE ON.**
    ///
    /// 🔴 **WHAT THIS REPLACES, AND WHY RE-BASING IT WOULD HAVE BEEN THE WRONG FIX.** The previous
    ///    assertion pinned two WETH amounts read at `FORK_BLOCK=25800000`
    ///    (`21381863684901085264` @ $50k, `425331345107636521215` @ $1M) and asserted the floor could
    ///    **not** be met. That is a MEASUREMENT wearing an assertion's clothes: WETH is priced in
    ///    dollars, so both constants go stale the moment ETH moves, and the test must fail whenever
    ///    the basis moves **in either direction**. At `25919850` the floor cleared by ~6.3% and it
    ///    went red for being RIGHT. Standing rule 4: updating the constant makes it pass and leaves
    ///    the question exactly where it was — one more pin's worth of green.
    ///
    /// ⭐ **THE INVARIANT IS ONE SENTENCE: the budget must cover what the best reachable venue
    ///    actually costs us.** Basis, venue fee and price impact do not need to be separated — the
    ///    floor does not care which of them took the money, only that the total fits the budget:
    /// ```
    ///   need   = (parity - bestVenueOut) * 10_000 / parity     // what the market takes, bps
    ///   budget = _slipBps(usdSize)                             // what we allow, bps
    ///   invariant: budget >= need
    /// ```
    /// ✅ **NOTHING IN IT IS FROZEN.** `parity` is the oracle read this block, `bestVenueOut` is a live
    ///    `QuoterV2` simulation at the traded size, and `budget` is read from the contract rather than
    ///    restated. ⇒ it is falsifiable at ANY pin, which is the property the old shape lacked.
    /// ⚠️ **AND IT FAILS IN THE DIRECTION THAT MATTERS.** A budget that does not cover the market is a
    ///    LIVENESS defect — the floor rejects an honest best-venue fill — so a red here is a real
    ///    finding about `_slipBps`, never about the block. **`need` is clamped at 0 when the venue
    ///    beats parity outright**, because a venue better than the oracle costs us nothing and must
    ///    not be read as negative slippage the budget has to "cover".
    /// 📌 The complementary bleed question (**how much of the budget is unused**) is logged, not
    ///    asserted: §SESS-23 owns it, and asserting a ceiling here would re-freeze a market reading
    ///    through the back door — the exact defect being removed.
    function test_TheSlipBudgetMustCoverWhatTheBestVenueActuallyCosts() public {
        _mkDesk();
        uint256[2] memory sizes = [uint256(50_000e6), uint256(1_000_000e6)];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amt = sizes[i];
            uint256 par    = desk.parity(address(USDC), amt, WETHA);
            uint256 best   = _quoteBestVenue(address(USDC), WETHA, amt);   // searched, not assumed
            uint256 budget = LevMath._slipBps(desk.usdSize(address(USDC), amt));
            uint256 need   = best >= par ? 0 : (par - best) * 10_000 / par;

            emit log_named_uint("--- size (USDC, 6dec)      ", amt);
            emit log_named_uint("parity  (oracle, no cut)   ", par);
            emit log_named_uint("best venue out (live V3)   ", best);
            emit log_named_uint("need   bps (basis+fee+imp) ", need);
            emit log_named_uint("budget bps (_slipBps)      ", budget);

            assertGt(par,  0, "parity is zero - the oracle arm is not wired, the check would be vacuous");
            assertGt(best, 0, "no live venue quote - this cannot measure the market, do not read a pass");
            assertGe(budget, need,
                "LIVENESS: _slipBps does not cover the best venue's real cost at this size - the floor "
                "rejects an honest fill. This is a finding about the BUDGET, not about the block.");
            emit log_named_uint("headroom bps (budget-need) ", budget - need);
        }
    }

    /// ⭐ ② THE THREE CONTROLS, RE-RUN AGAINST THE **DERIVED** FLOOR (not a parameter).
    ///    Uses $1M, where `_slipBps` (50 bps) exceeds the measured oracle/pool gap (~28 bps) so an
    ///    honest fill can clear. At $50k it cannot — see the test above, which is the finding.
    function test_Control_HonestFillerPaysTheDerivedFloor() public {
        _mkDesk();
        uint256 amt = 1_000_000e6;
        deal(address(USDC), address(desk), amt);
        uint256 owed = desk.floorFor(address(USDC), amt, WETHA);
        StockedFiller f = new StockedFiller();
        deal(WETHA, address(f), owed * 2);
        f.go(desk, address(USDC), amt, WETHA, 0);
        emit log_named_uint("derived floor  ", owed);
        emit log_named_uint("desk WETH held ", IT(WETHA).balanceOf(address(desk)));
        assertGe(IT(WETHA).balanceOf(address(desk)), owed, "desk was not paid its DERIVED floor");
        assertGt(owed, 0, "a zero floor would make this vacuous");
        assertEq(IT(address(USDC)).balanceOf(address(desk)), 0, "desk must have handed over the input");
    }

    function test_Control_AThievingFillerReverts() public {
        _mkDesk();
        uint256 amt = 50_000e6;
        deal(address(USDC), address(desk), amt);
        ThiefFiller t = new ThiefFiller();
        vm.expectRevert();
        t.go(desk, address(USDC), amt, WETHA);
        assertEq(IT(address(USDC)).balanceOf(address(desk)), amt, "the revert must return the input");
    }

    /// 🔴 One wei short of the DERIVED floor. The filler is SOLVENT and chooses to underpay, which is
    ///    the only construction that tests the DESK rather than the filler's balance.
    function test_Control_OneWeiShortOfTheDerivedFloorReverts() public {
        _mkDesk();
        uint256 amt = 1_000_000e6;
        deal(address(USDC), address(desk), amt);
        uint256 owed = desk.floorFor(address(USDC), amt, WETHA);
        StockedFiller f = new StockedFiller();
        deal(WETHA, address(f), owed * 2);
        vm.expectRevert(abi.encodeWithSelector(QuidFillDesk.Short.selector, owed - 1, owed));
        f.go(desk, address(USDC), amt, WETHA, 1);
        assertEq(IT(address(USDC)).balanceOf(address(desk)), amt, "the revert must return the input");
    }
}
