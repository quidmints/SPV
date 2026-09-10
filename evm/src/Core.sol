
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Aux} from "./Aux.sol";
import {Vault} from "./Vault.sol";
import {Basket} from "./Basket.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {OracleLib, RING} from "./imports/OracleLib.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";



// §E5 — the shared per-range premium sink (rule 2: ONE declaration, in the canonical file).
import {ILevEquity, ICore} from "./imports/Interfaces.sol";
// §E21: IERC20Min had TWO declarations (here and imports/ILevVenue.sol), then
// one home in ILevVenue.sol; §E296 folded that file into Interfaces.sol, so the one home is there.
import {IERC20Min} from "./imports/Interfaces.sol";
import {Types, BtcVaultPinned} from "./imports/Types.sol";  // §E299: file-level errors


/// @dev Live total leverage debt (USD 1e18) of a pinned LevManager, read through
///      `ILevEquity.totalDebtUsd` — the debt-funded buffer that `committedUsd18` subtracts from
///      in-range USD to recover the pure equity claim (buffer == debt).

/// @dev Live total GROSS levered collateral in NATIVE units — the LOCKED-INVENTORY basis for the well skew's
///      scarcity term. `POOLED` already carries the full 2× gross buffer as tokenless range depth, so the
///      deliverable native reservoir = poolVol − gross (subtracting DEBT, ~1×, would leave one equity leg of
///      phantom inventory in the scarcity signal). Read through `ICore.levGrossNative`, so whatever the
///      per-manager spelling is stays behind the range interface.

/// @notice ONE range per instance, with INDEPENDENT USD accounting. Two instances are deployed —
/// an ETH/USD one and a BTC/USD one (`DeployLib`) — and neither can see the other's dollars: a swap
/// that inflates this instance's `POOLED_USD` does not touch the sibling's. The only shared bound is
/// the SUM: each instance PUSHES its own equity to `Aux` (`_reportEquity`) and every in-range USD add
/// then requires `committedUsd18() <= haircutTvl`, enforced in `_poolUsdInRange`'s mint arm. BTC's
/// share of that total is demand-driven within the ≤TVL invariant (no separate allocation cap).
/// Resting boundary orders are deliberately NOT in `POOLED_USD` until they fill — see `settleOor`.
contract Core {

    /// This instance's oracle ring — the engine lives in OracleLib (delegatecall), so the structs
    /// come from there. Neither field is read externally; only the pooled getters (kept) are.
    /// §ISBTC-SPLIT — ONE RING PER INSTANCE, so there is nothing to select. A single contract
    /// holding BOTH ranges' rings reserved two `Observation[RING]` arrays per deployment and used
    /// exactly one, and needed a pair of accessors to pick between them. With one of each, both
    /// fields are read directly and no accessor stands between a caller and the ring.
    OracleLib.ObsState internal obsState;
    OracleLib.Observation[RING] internal observations;



    /// @notice §#12 — BASKET-SUPPLIED quoting depth for THIS range (6-dec). The split #12 is named
    ///         for: `POOLED_USD` tracks what is IN the curve and moves on every swap; this tracks
    ///         what the BASKET owns of it. `committedUsd18` is derived from THIS, so the backing
    ///         gate stops counting an LP's sale proceeds as a basket commitment.
    ///         ⚠️ IT IS NOT SWAP-INVARIANT, and reading it as "basket adds and burns only" is the
    ///         mistake §E230-PHANTOM cost. `_poolUsdInRange` credits it on the MINT arm only when
    ///         `basketLeg` is set (a swapper's dollars are not basket-owned), but DEBITS it on the
    ///         burn arm unconditionally — a burn cannot choose which dollars leave. `absorbPaidUsd`
    ///         re-anchors it outright.
    /// §ISBTC-SPLIT — one instance, one asset.
    uint public basketUsd;
    /// @notice This range's in-range USD slice (6-dec). `POOLED_USD - basketUsd` is the LP-owned
    ///         increment the venue prices as LP backing.
    uint public POOLED_USD;
    /// @notice This range's in-range VOLATILE inventory in NATIVE units (wei for ETH, sats for BTC)
    ///         — the token leg `_handleDelta` moves, and what `poolStats` reports as `liquidity`.
    uint public POOLED;

    /// @notice Committed BASKET USD (both pools, 18-dec) — the single `committed ≤ TVL` term + LP surplus sizing.
    /// The full-2× range holds the LP's equity AND a debt-funded buffer in ONE `POOLED_USD` slice (no separate
    /// counter). The buffer's USD equals the LP's OWN debt exactly (gross−net = debt/px ⇒ bufUsd = debt), so the
    /// pure equity claim is `in-range USD − leverage debt`, with the debt read LIVE from the pinned LevManagers.
    /// Live (not a stale segregation counter) so accrued borrow interest shrinks committed the instant it accrues —
    /// correctly, because the levered LP's real equity is collateral−debt and DOES shrink with interest (the lost
    /// value went to the venue, not the basket, so total claims stay ≤ backing). Reading debt live keeps the
    /// "committed == in-range USD − live debt" fold identity drift-free BY CONSTRUCTION (no counter to desync —
    /// see BufferSwapDrain.t.sol). Floored PER RANGE so ETH debt never eats BTC equity. Centralized ×1e12 scale.
    /// §#12: committed is the BASKET's contribution net of live leverage debt — NOT the curve
    /// inventory. A swap that ADDS dollars moves `POOLED_USD` and leaves `basketUsd` alone
    /// (`basketLeg` is false), so it cannot inflate committed; a swap that REMOVES them debits the
    /// basket's share too, because a burn cannot choose which dollars leave (§E230-PHANTOM).
    /// §ISBTC-SPLIT — THE SUM MOVED TO THE SHARED ACCOUNTANT, AND IT HAD TO.
    /// This was `_rangeEquityUsd18(false) + _rangeEquityUsd18(true)` — one contract adding up both
    /// ranges because one contract WAS both ranges. With two instances neither can see the other, and
    /// two instances each gating against the FULL TVL would DOUBLE-COMMIT the same backing without
    /// reverting. `Aux` holds the joint figure; each instance pushes only its own.
    function committedUsd18() public view returns (uint) {
        return AUX.committedTotal();
    }

    /// @notice Push THIS instance's equity to the shared accountant. PUSH, not pull, and at the
    ///         moment the equity changes — a sum of per-range figures is only meaningful if every
    ///         term is on the same clock, which is §A.16b one level up. A lazy pull would let the
    ///         bound pass against a total that was never simultaneously true.
    /// @dev    §RANGEBACKING-FOLD — reports to `AUX` DIRECTLY. The range talks to Aux; there is no
    ///         intermediary contract holding two numbers on their behalf.
    function _reportEquity() internal { AUX.report(_rangeEquityUsd18()); }

    /// @dev THIS range's equity USD (18-dec): the BASKET's contribution less this range's live
    ///      leverage debt, floored at 0. ⚠️ The basis is `basketUsd`, NOT `POOLED_USD` — the LP-owned
    ///      increment sitting in the curve is not a basket commitment and must not be gated as one.
    /// ⛔ §FLOOR-IS-FAIL-SAFE — **DO NOT "FIX" THE `: 0` INTO A SIGNED NET FIGURE.** It looks like a
    ///    clamp that hides information, and the instinct is that a range whose debt EXCEEDS its
    ///    basket contribution should report a NEGATIVE claim rather than zero. Work out which way
    ///    that moves the bound before touching it — I got it backwards first:
    ///      `Aux.committedTotal()` is `committedOf[CORE] + committedOf[BTC_CORE]`, a plain SUM, and
    ///      the gate is `committedUsd18() <= haircutTvl`. Flooring a would-be NEGATIVE term at 0
    ///      makes this range's contribution LARGER than the signed truth ⇒ the SUM is LARGER ⇒ the
    ///      gate is **HARDER** to pass. The floor reads TIGHTER than reality, never looser.
    ///    ⇒ Allowing a negative would let a debt-heavy range OFFSET its sibling and hand it headroom
    ///      that does not exist — on the one bound that stops both ranges over-committing the same
    ///      basket. That is the failure direction, and it is what the "fix" would introduce.
    function _rangeEquityUsd18() internal view returns (uint) {
        uint pooled18 = basketUsd * 1e12;   // §#12: BASKET contribution
        uint debt18 = _levDebtUsd18();
        return pooled18 > debt18 ? pooled18 - debt18 : 0;   // floor: fail-SAFE, see above
    }

    /// @notice THIS instance's NET equity USD (18-dec). Was `btcRangeEquityUsd18`, which existed so
    ///         `SwapLib._sharedScarcityWad` could subtract one range from the total to learn what the
    ///         OTHER holds. That subtraction now lives in `RangeBacking.otherThan`, derived from the
    ///         SAME total the solvency bound uses — so the amplifier and the gate cannot disagree
    ///         about the denominator, which two independent computations eventually would.
    function rangeEquityUsd18() external view returns (uint) { return _rangeEquityUsd18(); }

    /// @dev THIS range's total leverage debt (18-dec), read live from the pinned LevManager (0 if
    ///      unset, and 0 before the Vault pin lands). ONE indirection for both instances:
    ///      `RANGE.levManager()` — the BTC range answers it with the Vault's `LEV_MANAGER`, the ETH
    ///      range with `QuidLib.levManager(aux)`. Core never learns which is which.
    ///      FAIL-SAFE: `totalDebtUsd` iterates the open-LP book (external venue reads); a revert there must NOT
    ///      brick `committedUsd18` (the backing gate on every swap/mint/redeem). On failure we subtract 0 debt,
    ///      which only RAISES committed ⇒ a STRICTER gate + LOWER redeemable — conservative, never over-issue.
    ///      Mirrors `rangeETH`'s try/catch over the same LevManager reads.
    function _levDebtUsd18() internal view returns (uint) {
        if (address(BTC) == address(0)) return 0;
        address mgr = RANGE.levManager();
        if (mgr == address(0)) return 0;
        try ILevEquity(mgr).totalDebtUsd() returns (uint d) { return d; } catch { return 0; }
    }


    /// @notice Sum of UNDELIVERED on-chain swap-out obligations, in 6-dec USD.
    /// `+= usd` at requestSwapOutOnchain (the swapper's payment, owed to whichever
    /// LP delivers), `-= usd` at deliverSwapOutOnchain (paid exact to that LP) or
    /// at settleSwapIn reversal (obligation cancelled). This is the ONLY
    /// proceeds-side counter: per-channel exit P&L settles EXACTLY at delivery
    /// (the recorded per-obligation usd), so there is no global delivered/proceeds
    /// pool, no rate, and no clamp — and thus no cross-channel proceeds race.
    /// It exists solely as the swap-in solvency gate, and that gate lives in
    /// `SwapLib` (`POOLED_USD() < pendingSwapOutUsd()` ⇒ `SwapInDrainsProceeds`),
    /// not here: a swap-in may draw at most the FREE reserve
    /// `POOLED_USD − pendingSwapOutUsd`, so undelivered proceeds owed to LPs
    /// can never be drained out from under them.
    /// INVARIANT: every `+= x` is matched by a `-= x` on BOTH the deliver and the
    /// reverse path, and `x` never exceeds the USD actually pulled into the pool.
    uint public pendingSwapOutUsd;

    // ─────────────────────────────────────────────────────────────────────
    // Adaptive inventory-skew inputs — the swap-flow EWMA.
    //
    // The skew curve (SwapLib.skewWad) prices scarce volatile inventory UP on the
    // swap-OUT (well) path, re-admitting the BENIGN inventory-rebalancing arber that
    // oracle-only pricing killed alongside toxic LVR (a swap must never price off the oracle alone:
    // that is a free option to the taker and the LVR it feeds is exactly what the range fee exists to price).
    // Its adaptive TARGET = "the buffer needed to serve normal flow" is an EWMA of
    // two-sided swap volume — decayed by `FeeLib.decPow` over `FLOW_DECAY` (48h half-life),
    // NO governance constant, the market's own volume sets it. Bumped by every swap's USD
    // notional in `swap` (range + well both route through it). Read DECAYED via
    // flowEwmaUsd(). One register per instance.
    struct Flow { uint128 vol; uint64 ts; }   // vol: 6-dec USD EWMA · ts: last touch
    /// ⛔ §E55 — ONE FLOW REGISTER, AND A SECOND "SLOW" LEG MUST NOT BE RE-ADDED. A fast/slow pair
    /// read as `min(fast, slow)` cannot bind: both legs are fed the FULL notional and both are
    /// decaying SUMS, so a slower decay retains MORE ⇒ `slow >= fast` at every ratio ⇒ the min is
    /// identically the fast leg. One register is therefore the whole estimator, and no second decay
    /// constant is needed to make it adaptive.
    uint internal constant FLOW_DECAY   = 999759352855809024; // per-min → 48h half-life (0.5^(1/2880)). The well's flow-EWMA / inventory-skew target wants a wide, manipulation-resistant memory. (The Aux redeem-fee `baseRate`, a separate 12h register, was REMOVED — QU!D has no peg-arb loop; this 48h flow decay is unrelated and stays.)
    uint internal constant FLOW_MAX_MIN = 525600000;          // decay-exponent cap (Liquity)

    /// @notice Retained range market-making premium per pool, as a DECAYED EWMA (6-dec USD) — the
    ///         θ NUMERATOR source (#107/D3). Deliberately the SAME `Flow` struct, the SAME
    ///         `FLOW_DECAY` (48h) and the SAME read/bump helpers as the swap-volume register:
    ///         premium accrues on exactly the same swap events and wants exactly the same memory,
    ///         so a THIRD decay constant would be an unjustified magic number. This is a SECOND
    ///         consumer of the ONE 48h window, not a merge of two windows.
    Flow internal _prem;   // §ISBTC-SPLIT: one per instance

    /// @dev ONE decay implementation, shared by EVERY `Flow` register here (`_flow`, `_prem`,
    ///      `_redeemFlow`). Decay the stored value over elapsed whole minutes.
    function _decayed(Flow storage f) internal view returns (uint) {
        return _decayedBy(f, 1);
    }

    /// @dev `slowN`-fold slower decay: the SAME curve evaluated over `mins/slowN`, so the half-life
    ///      is `slowN ×` the fast one. One decay implementation, one constant, an integer ratio.
    ///      ⚠️ Every live caller passes `slowN = 1` (through `_decayed`); there is no slow leg. The
    ///      ratio form is what makes that a stated choice rather than a hidden assumption.
    function _decayedBy(Flow storage f, uint slowN) internal view returns (uint) {
        if (f.ts == 0) return f.vol;
        uint mins = (block.timestamp - f.ts) / 60 / slowN;
        return Math.mulDiv(f.vol, FeeLib.decPow(FLOW_DECAY, mins, FLOW_MAX_MIN), 1e18);
    }

    /// @dev Decay-then-add into an EWMA register. Saturates at uint128 (unreachable in practice).
    function _bumpEwma(Flow storage f, uint usd6) internal {
        uint v = _decayed(f) + usd6;
        f.vol = v > type(uint128).max ? type(uint128).max : uint128(v);
        f.ts  = uint64(block.timestamp);
    }







    /// @notice This pool's decayed RETAINED-PREMIUM EWMA (6-dec USD) — the range's realized
    ///         market-making earnings over the trailing ~48h window. θ's numerator (#107/D3):
    ///         the compensation the range actually receives for bearing IL. Reserve `avgYield` is
    ///         deliberately NOT part of this — that number sizes how much QUI to mint up front and
    ///         has nothing to do with how big the range should be (user, 2026-07-26); the dollar leg
    ///         earns the reserve baseline whether it is ranged or idle (`spec.md`), so reserve yield
    ///         is not marginal compensation for IL risk and must not inflate the risk budget.
    function premiumEwmaUsd() public view returns (uint) {
        return _decayed(_prem);
    }

    /// @notice Aggregate leverage claim on this pool (6-dec USD) — the well's
    ///         DISTINCT "leverage demand" signal. Levered LPs both lock current volatile
    ///         (shrinking deliverable inventory) AND will draw/return it (raising demand),
    ///         so it enters the skew scarcity on BOTH sides. Reuses the live
    ///         LevManager debt total already read for committedUsd18 — no new aggregate.
    function levClaimUsd6() public view returns (uint) {
        return _levDebtUsd18() / 1e12;
    }


    /// @notice This range's aggregate levered GROSS collateral in NATIVE units (wei for ETH, sats for BTC), read
    ///         live from the range manager (0 before the Vault pin lands). The well skew's LOCKED-INVENTORY
    ///         basis: `POOLED` already pairs in the full 2× gross buffer as tokenless range depth, so the true
    ///         deliverable reservoir is `poolVol − gross`. Kept NATIVE (not USD) so SwapLib converts it with the
    ///         SAME `base`/1e30 scale it already applies to poolVol — one price, one unit. DISTINCT from the debt
    ///         basis (`levClaimUsd6`, ~1×), which stays on the demand/target side of the skew (the net-equity leg
    ///         self-heals via bounded de-lever, so only the debt leg is an uncovered forward claim on the reservoir).
    ///         FAIL-SAFE: a revert in the venue-iterating read must not brick the swap; the range manager's own
    ///         read returns 0 on failure (the skew merely relaxes toward the base oracle curve — this is the
    ///         pricing signal, not a hard backing gate).
    function levGrossNative() public view returns (uint) {
        if (address(BTC) == address(0)) return 0;
        return RANGE.levGrossNative();
    }

    /// @notice §E59/§E345 — annualized realized variance (WAD) for THIS range, the **MAX of two
    ///         legs**: the observation ring and the Chainlink anchor. The well skew's live-vol
    ///         steepness input (steeper premium in higher vol, matching a native-BTC MM's real
    ///         cost), and θ's denominator.
    ///         §E59 is why the ring leg is read from STORAGE rather than through `observe`: the old
    ///         estimator was a round trip (Core → QuidLib → back into Core) sampling `observe` on a
    ///         wall-clock grid, and that grid was the bug — `observe` INTERPOLATES between stored
    ///         points and linear interpolation has zero second derivative, so any stretch quieter
    ///         than the sample interval measured EXACTLY 0 however far price moved.
    ///         **0 means UNKNOWN, NEVER "calm"** — `SwapLib.skewWad`'s σ² sentinel charges the
    ///         `UNKNOWN_VARIANCE_SKEW` ceiling on it and theta fails open, and both readers agree on
    ///         that. ⚠️ IT IS THE SENTINEL, NOT `_maxWellSkew`, THAT CHARGES THE CEILING — and the two
    ///         DISAGREE, which is §E352: `_maxWellSkew` is an additive BASE that reads σ² == 0 as
    ///         `spliceFloor` (0 on ETH), and the two flush arms resolve AHEAD of the sentinel, so on
    ///         those branches the permissive answer wins. See the §E352 block in `SwapLib.skewWad`. ⚠️ 0 requires BOTH legs to be
    ///         unmeasured, and they reach it differently: the ring by having too little history, the
    ///         anchor by `_varDt.vol == 0` (never sampled). Do not gloss it as "too few ring
    ///         updates" — see the enumeration in the body.
    function realizedVarianceWad() external view returns (uint) {
        // 9 ring points → 8 intervals → **7** returns, and the count is what decides whether the
        // estimate exists at all. A return is the ratio of two CONSECUTIVE INTERVAL RATES, so `n`
        // points give `n-1` intervals and `n-2` returns — `ringVariance` says exactly that
        // (`uint m = n - 2; // returns = intervals − 1`) and refuses below `m < 2`. ⚠️ Reading this
        // as "8 returns" makes the `card >= 4` threshold §E345 measured look like `card >= 3`, i.e.
        // under-states by one the ring depth needed before σ² can be non-zero — the same one-short
        // arithmetic that made the deleted `cardinality >= 2` sentinel report "measured, and calm"
        // for a ring that had measured nothing.
        // §TICK-REMOVAL — THE 1e10 WENT WITH THE TICKS, AND THE UNITS ARE UNCHANGED. It was never
        // a tuning constant: a tick is 1 bp, so tick²→relative² is 1e-8 and WAD is 1e18, giving
        // exactly 1e-8 × 1e18 = 1e10. `ringVariance` now returns (WAD relative return)² per second,
        // i.e. relative²·1e36, so ONE division by 1e18 lands on WAD relative variance — same
        // magnitude, same meaning ⇒ Γ (`SwapLib.GAMMA_WAD`) needs NO recalibration.
        uint v = Math.mulDiv(OracleLib.ringVariance(observations, obsState, 9),
                            31536000, 1e18);          // per-sec → annualized
        // §E88 — ZERO IS NOW RESERVED FOR "UNMEASURED", AND ONLY THAT.
        //
        // It used to mean TWO things at once: *"the ring is unpopulated, we have not measured"* AND
        // *"we measured, and it is genuinely zero"*. Downstream (`skewWad`/`sellSkew`) reads `σ² == 0`
        // as UNMEASURED and conservatively charges the ceiling — correct for the first meaning,
        // WRONG for the second, because a genuinely calm market has genuinely low adverse selection
        // and should be charged accordingly, not the 3% maximum.
        //   No threshold on σ² can separate them: it is an IDENTIFIABILITY problem, not a tuning one
        //   — the same one E56 hit when a zero flow-EWMA could not tell a DEAD pool from a NEW one.
        //   The fix there was a SECOND, independent signal already in storage, and it is the same
        //   here: the ring's own `cardinality` says whether we have looked, which no value of the
        //   variance itself can. A populated ring that computes a true zero returns 1 wei, so the
        //   two states are distinguishable downstream at ZERO extra storage, calls, or gas on the
        //   money path, and the E59 sentinel keeps its exact meaning for the case it was written for.
        //
        // 🔴 §E345 — THAT SENTINEL IS DELETED, AND ITS THRESHOLD WAS WRONG BY TWO IN THE DIRECTION
        // THAT MATTERS. `cardinality >= 2` was meant to say "we have looked", but `ringVariance`
        // cannot produce an estimate until `cardinality >= 4`: it needs `card >= 3` AND `m = n-2 >= 2`
        // with `n = min(9, card)`. So for `cardinality` ∈ {2,3} this returned 1 — *"measured, and
        // genuinely calm"* — for a ring that had measured NOTHING. That is exactly the sentinel error
        // §E59 named (a value meaning "no data" consumed as if it meant "none of the thing"),
        // reintroduced inside the function whose job is to resolve it. ⚠️ AND NO ATTACKER WAS NEEDED
        // TO REACH IT: `seedRing` leaves `cardinality` at 1 and `_observeIfSourced` writes once per
        // swap, so TWO ordinary swaps in distinct blocks land in the window — at which point
        // `skewWad`'s `if (sigmaSqWad == 0) return UNKNOWN_VARIANCE_SKEW` stops firing and the flat
        // 3% unknown-variance charge on a drain silently becomes the §E216 depletion term alone.
        //   ⭐ THE FIX IS NOT `>= 4`. Re-tuning the threshold leaves TWO functions that must agree
        //   about what "measured" means, which is the drift this one already lost. `ringVariance`
        //   has other honest-zero exits too (`!initialized`, non-advancing timestamps, `rate == 0`),
        //   and no cardinality test can see them. Deleting the guess and falling through to a SECOND
        //   REAL MEASUREMENT resolves the ambiguity with data instead of with a manufactured 1.
        //
        // ⭐ MAX, NOT RING-PREFERRED, AND THE MONOTONICITY IS THE POINT. Both consumers move
        // CONSERVATIVELY as σ² rises — `skewWad` charges a wider spread, and `QuidLib.derivedThetaWad`
        // (Merton `avgYield/(K·σ²)`) deploys LESS depth. Taking the max therefore leaves whoever
        // feeds the ring able to move σ² only UPWARD, i.e. only in the direction that costs them.
        // Today that is the Chainlink anchor itself (`observationSource` is unset), but the guard is
        // written for the pinned-source case: preferring the ring whenever it is non-zero would hand
        // a source the profitable direction back — it could not suppress to 0 any more, but it could
        // still pin a low non-zero reading UNDER the anchor's, which is the same drain-for-cheap
        // trade with one extra step.
        // ⚠️ Residual, named rather than implied: a pinned source can still INFLATE σ² and widen the
        // spread other traders pay. ⛔ NOTHING ON THIS PATH BOUNDS THAT — the deviation argument
        // is 0 and the pinned-source branch applies no check at all. What bounds it is that
        // inflation is the direction an attacker pays for rather than profits by.
        //
        // 0 from BOTH still means UNMEASURED and still charges the ceiling — the fail-conservative
        // default is unchanged, and it is now the ONLY thing 0 can mean.
        //
        // §E346-ZERO — WHY THE RING LEG GETS NO §E88 FLOOR, WRITTEN DOWN SO IT IS NOT "FIXED".
        // `anchorVarianceWad` floors a measured zero at 1 wei and the ring leg conspicuously does
        // not, which reads like an oversight. It is not, and BOTH halves of the reason are needed:
        //   • THE FLOOR WOULD BE INERT HERE. The `mulDiv(·, 31536000, 1e18)` above truncates every
        //     raw below **31,709,791,984** to 0, so a `return 1` inside `ringVariance` never
        //     survives to this line — a fix that looks landed and changes nothing. (The anchor leg's
        //     floor works precisely because it is applied AFTER its own scaling, not before.)
        //   • AND IT WOULD BE UNSAFE. `ringVariance` genuinely computes 0 on a FLAT ring (constant
        //     price ⇒ every interval rate identical ⇒ every return 0), and a flat ring is the
        //     ORDINARY state here rather than an adversarial one: `_observeIfSourced` writes the
        //     Chainlink anchor, which is flat BETWEEN rounds, so every swap inside one round writes
        //     the same price. Flooring it would restore the §E345 attack through a new door: σ² reads
        //     "measured, calm", `skewWad`'s `sigmaSqWad == 0` guard stops firing, and the 3%
        //     unknown-variance drain charge switches off — off an unmoved feed, for free.
        // ⇒ The `max` below is what actually resolves it: the ring's honest zero and its
        //   could-not-estimate zero contribute IDENTICALLY (nothing), so the distinction is not
        //   observable here BY CONSTRUCTION. Full seven-exit enumeration at `OracleLib.ringVariance`.
        // ✅ CROSS-FILE HAND-OFF TAKEN 2026-08-23: `SwapLib`'s `sigmaSqWad == 0` guard (§E346-ZERO,
        //   just above `_maxWellSkew`'s scarcity branch) no longer claims `realizedVarianceWad` calls
        //   `ringVariance` DIRECTLY, and now enumerates all seven exits. Guard unchanged — 0 from
        //   both legs really is unmeasured. ⛔ Do not restore "None of them means measured, and calm".
        uint a = anchorVarianceWad();
        return v > a ? v : a;
    }

    /// @notice §E345 — annualized realized variance (WAD) of the CHAINLINK ANCHOR, from the two
    ///         `Flow` registers `_sampleAnchorVariance` feeds. 0 = never sampled (UNMEASURED);
    ///         1 wei = sampled and computed zero, which is the §E88 floor doing the job it was
    ///         written for, now on a series that was actually observed.
    /// @dev    UNITS, CHECKED RATHER THAN ASSUMED, because this must land on the same basis as the
    ///         ring leg it is maxed against. `_varSq` accumulates `r²/1e18` where `r` is a WAD
    ///         relative return, so its unit is a WAD squared-return; `_varDt` accumulates plain
    ///         seconds. The ratio is WAD variance PER SECOND — precisely what `ringVariance` returns
    ///         after its own `/1e18` — and one multiplication by 31,536,000 annualizes it. Γ
    ///         (`SwapLib.GAMMA_WAD`) needs no recalibration for the same reason §TICK-REMOVAL did not.
    function anchorVarianceWad() public view returns (uint) {
        uint dt = _varDt.vol;
        if (dt == 0) return 0;                        // never sampled ⇒ UNMEASURED, charge the ceiling
        uint v = Math.mulDiv(_varSq.vol, 31536000, dt);
        return v == 0 ? 1 : v;                        // sampled, computed zero ⇒ the §E88 floor
    }

    /// @notice §E345 — fold one Chainlink-anchor observation into the variance registers. Called
    ///         once per swap, beside `_observeIfSourced`, and deliberately NOT from `px`.
    ///
    /// @dev ⛔ IT MUST NOT READ `px`, EVEN THOUGH `px` IS THE ANCHOR TODAY. `Core.swap`'s `px` is
    ///      `AUX.getTWAPforAsset`, which returns the RING's TWAP and only falls through to Chainlink
    ///      while the ring is unusable — which is the state today and is exactly the state this
    ///      change exists to end. Sampling `px` would therefore work now and quietly become
    ///      self-referential the moment a ring source is pinned, which is the §E222 trap the call
    ///      site's own comment warns about one line up. The extra read is the price of that not
    ///      happening.
    ///
    /// @dev THE NUMERATOR IS PER-ROUND WHILE THE DENOMINATOR IS PER-SWAP, AND THAT SPLIT IS WHAT
    ///      MAKES THIS ESTIMATOR HONEST RATHER THAN MERELY CHEAP. §E343 measured Chainlink ETH/USD at
    ///      57.3 updates/day with a 20.5-min median gap, and its central finding was that the series
    ///      must be read PER ROUND: *"read on a fixed grid, the gaps ARE flat and σ² collapses; read
    ///      per round, every sample is a move that already cleared the 0.5% deviation trigger."*
    ///      Swaps arrive far faster than rounds, so `Σr²` must not be padded with a zero for every
    ///      swap that observes the SAME round — and it is not: `r` is differenced against `_varPx`,
    ///      which advances only when the anchor MOVES, so a repeated price adds nothing to the
    ///      numerator however many swaps see it. Its quiet seconds DO reach `Σdt`, which is correct —
    ///      a market that did not move is information, not an absence of it.
    ///      ⛔ Do not "restore" an early return on `px == prev` ABOVE the `dt` computation: that is
    ///      the shape §E345-ANCHOR removed, and the note in the body says what it broke.
    ///
    /// @dev EVERY FAILURE DEGRADES TO UNMEASURED, NONE REVERTS — the same rule `_observeIfSourced`
    ///      states one function down: a dead or stale feed makes `twapResolve` return 0 here, the
    ///      registers stand still, and the ceiling sentinel prices the ignorance. THE READ MUST NOT
    ///      BE ABLE TO HALT THE RANGE.
    function _sampleAnchorVariance() internal {
        // `price = 0` returns the RAW anchor: §A.13 made a zero price fall THROUGH to Chainlink
        // rather than short-circuit past it, so this reuses the tested reader — with its decimals
        // handling and its ×1e10 WBTC lift — instead of adding a second `latestRoundData` to Core.
        // That reuse is not tidiness: hand-rolling the scaling is how an 8↔18 decimal gap becomes a
        // price ten orders of magnitude out, which `seedRing`'s header records happening once already.
        // maxDevBps = 0 because THERE IS NO INTERNAL PRICE TO DEVIATE FROM here: the price argument
        // below is 0, so `twapResolve`'s `diff` equals `ext18` and the deviation test trips for any
        // bound under 10000 - 0 and the deleted 50 are arithmetically identical on this path.
        (uint px,) = SwapLib.twapResolve(
            AUX.assetPriceFeed(ASSET), 0, VOL_DECIMALS != 18, 0, 1 days);
        if (px == 0) return;                          // no fresh anchor ⇒ nothing to sample
        uint prev = _varPx;
        // 🔴 §E345-ANCHOR — THE `px == prev` EARLY RETURN MOVED **BELOW** `dt`, AND THAT IS THE FIX.
        // It read *"the anchor has not moved ⇒ no new information"*, which is false: a price that did
        // NOT move IS information — it is a zero return, exactly what a calm market contributes to
        // realized variance. Because `_varDt` only advanced on a MOVE, `anchorVarianceWad`'s own floor
        // (`return v == 0 ? 1 : v;  // sampled, computed zero ⇒ the §E88 floor`) was UNREACHABLE: dt
        // was non-zero only when the price moved, in which case v was non-zero too. A floor guarding a
        // case its own gate prevented.
        // ⇒ §E345 deleted the `cardinality >= 2` sentinel precisely because it conflated *"we have not
        //   looked"* with *"we looked and it is calm"* — and this reintroduced that conflation one level
        //   down, inside the leg added to resolve it. The §E59 sentinel error via the fix for it.
        // The calm sample below accumulates REAL SECONDS against a ZERO squared return, so σ² reads
        // *measured, and genuinely calm* (floored to 1 wei) instead of *unmeasured* (0 ⇒ charge the
        // ceiling). Decay is exponential in ELAPSED MINUTES and composes across sub-intervals, so
        // bumping more often does not decay `_varSq` faster over the same wall-clock.
        // FIRST sample carries no return: there is nothing to difference against, and `_varSq.ts` is
        // still 0, so an elapsed time computed from it would be the whole unix epoch. Bumping both
        // registers with 0 sets that `ts` through the SAME helper every later sample uses, rather
        // than writing the timestamp by hand in a second place that could then disagree with it.
        if (prev == 0) {
            _varPx = px;
            _bumpVar(0, 0);
            return;
        }
        uint dt = block.timestamp - _varSq.ts;
        // ⚠️ SAME BLOCK ⇒ RETURN WITHOUT ADVANCING `_varPx`, WHICH IS THE OPPOSITE OF WHAT THE FIRST
        // version did. Advancing it here and skipping the accumulation would DISCARD this move's
        // return while still letting its elapsed seconds reach the denominator through the next
        // sample — a one-sided loss that biases σ² DOWNWARD, i.e. toward the cheap-drain reading this
        // whole change exists to remove. Keeping `prev` defers the move intact to the next block.
        if (dt == 0) return;
        // CALM: real elapsed seconds, zero squared return. `_varPx` is deliberately NOT re-assigned —
        // it already equals `px`, so there is nothing to advance and no second writer to disagree.
        if (px == prev) { _bumpVar(0, dt); return; }
        _varPx = px;
        uint lo = px < prev ? px : prev;
        uint r = (px < prev ? prev - px : px - prev) * 1e18 / lo;   // |relative return|, WAD
        _bumpVar((r * r) / 1e18, dt);                 // squared return (back on WAD) + its seconds
    }

    /// @dev §E348 — BUMP BOTH VARIANCE REGISTERS THROUGH **ONE** DECAY EVALUATION, AND MAKE THE
    ///      SHARED CLOCK TRUE BY CONSTRUCTION RATHER THAN BY CALL ORDER.
    ///
    ///      GAS. This was `_bumpEwma(_varSq, …); _bumpEwma(_varDt, …);`, and each of those calls
    ///      `_decayed` → `_decayedBy` → **`FeeLib.decPow`, which is a `public` library function and
    ///      therefore a DELEGATECALL** — with a binary-exponentiation loop inside it. The two calls
    ///      took IDENTICAL arguments (`FLOW_DECAY`, the same `mins`, `FLOW_MAX_MIN`) and `decPow` is
    ///      `pure`, so one of the two delegatecalls was pure waste on every anchor-moving swap.
    ///
    ///      ⭐ AND IT IS A CORRECTNESS HARDENING, WHICH IS THE HALF WORTH KEEPING. `anchorVarianceWad`
    ///      is a RATIO of these two registers (`_varSq.vol · 31536000 / _varDt.vol`), and it reads
    ///      them RAW — which is only sound because both were last decayed by the SAME factor, so the
    ///      factor cancels. That was true only because the two `_bumpEwma` calls happened to sit
    ///      adjacent in one transaction: an invariant maintained by call ORDER, which a later edit
    ///      could separate with nothing failing loudly. σ² would then drift by the ratio of two
    ///      decay factors — a plausible-but-wrong number on the drain-charge path, i.e. exactly the
    ///      silent class §A.16b names ("numerator and denominator must share a reconciliation
    ///      clock"). One writer that touches both registers with one factor makes the divergence
    ///      UNCONSTRUCTIBLE instead of merely unlikely (standing rule 17).
    ///
    ///      BIT-IDENTICAL: `_decayedBy(f, 1)` is `mulDiv(f.vol, decPow(FLOW_DECAY, mins, cap), 1e18)`
    ///      with `mins = (block.timestamp − f.ts) / 60`, and `_varSq.ts == _varDt.ts` always — they
    ///      are written ONLY here, always as a pair, in one transaction, and both start at 0. The
    ///      `ts == 0` arm returns the register unscaled, which `factor = 1e18` reproduces exactly.
    function _bumpVar(uint sqInc, uint dtInc) private {
        uint ts = _varSq.ts;                          // ONE clock for both registers
        uint factor = 1e18;                           // ts == 0 ⇒ no decay, matching `_decayedBy`
        if (ts != 0) factor = FeeLib.decPow(FLOW_DECAY, (block.timestamp - ts) / 60, FLOW_MAX_MIN);
        _decayInto(_varSq, factor, sqInc);
        _decayInto(_varDt, factor, dtInc);
    }

    /// @dev Apply an ALREADY-COMPUTED decay factor and add. Mirrors `_bumpEwma`'s uint128 saturation
    ///      exactly; it differs only in taking the factor rather than deriving it, so the caller can
    ///      derive it once for a pair of registers that share a clock.
    function _decayInto(Flow storage f, uint factor, uint inc) private {
        uint v = Math.mulDiv(f.vol, factor, 1e18) + inc;
        f.vol = v > type(uint128).max ? type(uint128).max : uint128(v);
        f.ts  = uint64(block.timestamp);
    }

    /// @notice (well) Cumulative scarcity-premium the skew has RETAINED as backing, per
    ///         pool — the withheld fraction of a swap-out's USD when the pool is BTC/ETH-scarce
    ///         (the swapper pays above oracle for scarce inventory; the difference is
    ///         retained for LPs). ⚠️ HISTORICAL NOTE: this said the premium "STAYS in the basket as pure LP
    ///         backing (NAV)" — true pre-§E5, and the source of the §E42 leak. §E5 made it an LP CLAIM
    ///         (`creditSkewPremium`), and §E42-netting moves its BACKING into the POOLED mirror to match, so
    ///         it is no longer quoted as QU!D redeemability. Tracked + evented here so the LP-retained skew profit is
    ///         auditable P&L — the running total the fleet's self-funding JIT refill captures FOR the LPs.
    ///         (The old swapper-facing refill BONUS was REMOVED: refill is a self-funding fleet op — JIT
    ///         Morpho-flash BTC → creditSwapIn → repay, gas via #87 — so paying a separate bonus to the refiller
    ///         was redundant; the premium accrues to LPs directly, no payout.)
    ///         Units = the swap-out's USD driving amount for that pool (6-dec).
    uint public skewPremium;
    event SkewPremiumRetained(uint256 premiumUsd, uint256 cumulative);

    /// @notice Record a scarcity-premium retained on a swap-out. ONE direct caller,
    ///         `SwapLib.retainSkewPremium` — which is the whole LP fee lane, reached from
    ///         `swapToBody` (Aux) and `creditSwapOutBody` (Vault). Same onlyUs seam as `Core.swap`.
    ///         No-op on a flush pool (premium == 0).
    /// @notice §PREMIUM-READABLE — cumulative skew premium retained in VOLATILE units (wei), i.e. the
    ///         part of a sell-leg swapper's ether that `SwapLib.retainSkewPremium` deducted before Core
    ///         ever booked it. Zero on the drain legs, whose premium is dollars.
    /// ⛔ **A COUNTER, NOT A BOOKING.** It moves no value and changes no mirror. §E42-DENOM tried to make
    ///    `POOLED` count this and it was measured WRONG — `rangeETH` already counts the WETH at Aux, so
    ///    adding it to `POOLED` double-counts (GAP grew by exactly the premium and three tests broke).
    ///    This exists because the quantity was UNREADABLE, which is what stopped the real identity being
    ///    assertable: `POOLED` is low by exactly this, and nothing exposed by how much.
    uint256 public retainedEthPremium;

    function recordSkewPremium(uint256 premiumUsd, uint256 premiumNative) external onlyUs {
        retainedEthPremium += premiumNative;   // counter only — see above; no mirror is touched
        if (premiumUsd == 0) return;
        uint256 cum;
        // §E5 — the counters below are an AUDIT RECORD (asserted by
        // testGrindRemoval_DrainPaysRetainedSkewPremium); the CREDIT is what actually reaches LPs.
        // Without it the premium accrues to basket backing, which prices QU!D and not LP shares.
        skewPremium += premiumUsd; cum = skewPremium;   // §ISBTC-SPLIT: both arms were identical
        // ONE call site, dispatched by address: `Quid` and `Vault` expose the same
        // `creditSkewPremium` signature, so this is a single encode instead of one per branch.
        RANGE.creditSkewPremium(premiumUsd);
        // §E42-netting — PUT THE BACKING WHERE THE CLAIM IS. The credit above creates an LP claim;
        // these are the dollars that back it, and until now they were the ONLY fee whose backing
        // stayed in general basket assets. Every other fee leaves its backing in the POOLED mirror
        // on purpose (BtcLib:56 — "the sats stay in POOLED by design: the guard exists so
        // creating the CLAIM does not remove its BACKING"), and `redeemableBody` nets that mirror.
        // MEASURED (§E42, 6 x 500 USDC): swappers paid 3,000.000000 into the basket while the
        // mirror rose only 2,993.999901 — the 6.000099 gap was the premium, quoted as QU!D
        // redeemability while owed to LPs. Folding it in closes the gap AT SOURCE, so redeemable
        // needs no premium-specific subtraction and no claimed/unclaimed counter to keep in sync:
        // the mirror already falls as LPs draw. Each instance does this for its own range, so the
        // two are symmetric without either knowing which asset it is.
        POOLED_USD += premiumUsd;
        // Also fold it into the decaying RATE register (#107/D3). The cumulative counters above
        // are monotonic totals — useless as a yield; θ needs a rate, which is what this provides.
        _bumpEwma(_prem, premiumUsd);
        emit SkewPremiumRetained(premiumUsd, cum);
    }


    /// @notice Refund a swap's UNFILLED input remainder (amount − consumed) to the swapper. An inventory-
    ///         bounded partial takes the full input up front but only `consumed` drives the swap; this returns
    ///         the difference so the swapper never overpays for a partial (mirror of the vBTC partial-burn).
    ///         Real stable from Aux via AUX.take (checkBacking = solvency). onlyUs — the swap bodies route
    ///         through Core since Core is `us`; the retained scarcity premium is NOT refunded.
    function refundUnfilled(address token, uint amount, address to) external onlyUs {
        if (amount != 0 && to != address(0)) AUX.take(to, amount, token, 0);
    }

    /// §ISBTC-SPLIT — WHAT THIS INSTANCE IS, held as FACTS rather than as a flag. Each of the four
    /// fields below is something the contract knows about ITSELF, resolved once; none of them is a
    /// parameter threaded through calls. That distinction is the point of the split — a runtime
    /// boolean selecting between two behaviours IS the hand-rolled polymorphism being removed,
    /// whereas an instance knowing its own asset is what having instances MEANS.
    /// ⛔ Let a REAL asymmetry differ (ETH pays out ether; BTC settles via a Lightning cooperative
    /// close), and never reintroduce a selector to pick between two paths that should have been one.
    /// §ISBTC-SPLIT — the volatile side's decimals (18 ether / 8 sats), READ FROM THE ASSET in the
    /// constructor because the token already knows. Held as a NUMBER because that is what actually
    /// differs; `VOL_DECIMALS != 18` is what tells `twapResolve` to apply WBTC's ×1e10 lift.
    uint8 public immutable VOL_DECIMALS;
    /// §ISBTC-SPLIT — THIS RANGE'S RISK PROFILE, resolved once at construction. `SwapLib` used to
    /// take a `bool isBTC` solely to choose between two constants; the instance owns which pair
    /// applies, so it hands over the NUMBERS. BTC locks capital through ~1hr of confirmations and
    /// pays an on-chain splice fee; ETH settles in ~one block with neither.
    /// §ISBTC-SPLIT — THIS INSTANCE'S VOLATILE ASSET, passed to the constructor and never chosen at
    /// runtime. The money-path sites that price against it (`getTWAPforAsset`, `assetPriceFeed`)
    /// read this slot, instead of making an EXTERNAL CALL into Aux to fetch WBTC-or-WETH and then
    /// branching between two constants.
    address public ASSET;
    /// §ISBTC-SPLIT — THIS INSTANCE'S RANGE MANAGER, held as ONE `ICore` handle: `Quid` on the ETH
    /// instance, `Vault` on the BTC one. Every money-path hand-off to the range (`deliverVolatile`,
    /// `creditSkewPremium`, `levManager`, `onShortfall`, …) goes through it with no asset test.
    ICore public RANGE;

    /// §V4-CUT — THE RANGE'S RANGE, now OURS to store. It used to live inside the v4 position, which
    /// is why re-ranging required burning and re-adding liquidity. With inventory held directly the
    /// range is a PRICING PARAMETER: moving it changes what we quote against, not what we hold.
    /// §DE-TICK — the range's bounds are PRICES (USD per volatile, WAD), not ticks. Under inventory
    /// the range is a pricing parameter, and a price bound is what every consumer actually wanted:
    /// the tick grid only ever existed so v4 could index many positions on a shared curve.
    /// §ONE-ANCHOR — was `LOWER_PRICE` + `UPPER_PRICE`. The two were ALWAYS
    /// `updateBounds(anchor, RANGE_DELTA)` of one another -- `lower = p·(1−δ)`, `upper = p·(1+δ)`,
    /// symmetric about a SINGLE price -- so they were two slots holding one number, and two that
    /// could drift apart if anything ever wrote one without the other. The anchor is the spot at the
    /// LAST REPACK, not the live price, so it is still a snapshot; just one instead of two.
    /// Deriving is CHEAPER than storing: two `mulDiv`s beat a cold SLOAD, and a repack writes one
    /// slot instead of two.
    uint public RANGE_ANCHOR;



    // ⛔ ABSENT BY DECISION, SO THEIR ABSENCE IS NOT AN OVERSIGHT — do not re-add:
    //  • §E253-mock — `mocks()`. A production getter whose only caller was a TEST
    //    (`UnificationControls._mockDust`), reporting a quantity that is structurally zero.
    //  • §ISBTC-SPLIT — the `if (IS_BTC) x; else x;` selectors. Both arms were IDENTICAL once
    //    `POOLED`/`POOLED_USD` became one field per instance; the branch decided nothing.
    //  • `_addPooledUsd` / `_subPooledUsd` / `_addPooledTok` / `_subPooledTok` — one-line wrappers
    //    over two plain state variables. They existed to select `POOLED_ETH` vs `POOLED_BTC`; the
    //    v4 cut collapsed each pair to ONE variable, so they became a name in front of `+=`.
    //
    // ⚠️ BUT THE `-= Math.min(a, X)` CLAMPS AT THE TWO SUBTRACTION SITES STAY, AND ARE NO LONGER
    // DECORATIVE. v4's flash accounting used to REVERT an inconsistent subtraction at unlock; with
    // the pool gone that cross-check is gone, so the clamp is the only thing between an accounting
    // error and a silently wrong `POOLED`. It is also the FIRST thing to revisit if pooled state
    // ever disagrees with the basket (§V4-REMOVAL-POOLED-STATE) — a clamp does not announce itself.

    Aux AUX; Basket BASKET; Vault BTC;

    /// @notice The BTC Vault, pinned on BOTH instances (post-deploy, like Quid's btcChannels) since
    /// the Vault is deployed after Core. Three uses, all of them here: it is admitted to `onlyUs` so
    /// it can drive this engine (modLP / repack / settleOor / swap), `btcThetaBacking` reads its
    /// `totalShares()`+`totalBuffer()`, and a zero pin is the "not wired yet" test the leverage reads
    /// short-circuit on. It is NOT how this instance learns which asset it is — that is `ASSET`.
    
    
    // BTC is pinned in its OWN setter, not setup(), because Vault is deployed AFTER Core
    // (Vault takes Core's address at construction, so it can't exist when setup() runs). The
    // one-shot pin makes a re-point impossible even before ownership is renounced — defence in
    // depth on the deploy path; a generic "already-set" error would also work, but the specific
    // one is self-documenting at the revert site.

    function setBtcVault(address b) external {
        require(msg.sender == DEPLOYER, "403");   
        if (address(BTC) != address(0)) 
            revert BtcVaultPinned();
        BTC = Vault(payable(b));
        // §ISBTC-SPLIT: the BTC instance's range manager IS the Vault, and this is the first moment
        // it exists (Vault takes Core's address at construction, so it cannot be pinned in setup).
        if (address(RANGE) == address(0)) RANGE = ICore(b);   // §ISBTC-ZERO: the second pin, no flag needed
    }
    /// @notice Public linkage getter — the deploy-finalize assert cross-checks
    ///         Core's BTC-vault pin against Aux's owner-set view.
    function btc() external view returns (address) { return address(BTC); }

    /// @notice The MONOTONIC retained-premium counter for one pool (6-dec USD). §E56 — its value is
    ///         not the point; being CUMULATIVE is. A decayed EWMA cannot tell a DEAD pool from a NEW
    ///         one (both read 0), and `sellSkew`'s refusal must treat those oppositely. A pool that
    ///         has never traded cannot have accrued any premium, so this disambiguates them.
    /// @dev    ONE consumer: `SwapLib`'s `skewPremiumCum() > 0` shed-path test. It is an accessor
    ///         rather than a direct read of the public `skewPremium` getter because the caller asks a
    ///         question ("has this range ever traded?") that must keep its answer if the counter is
    ///         ever restructured. Same trade as E32 — put the code where the room is.
    function skewPremiumCum() external view returns (uint) {
        return skewPremium;
    }

    /// @notice BTC range theta-numerator: the native IL-bearing backing = aggregate locked sats (lpShares,
    ///         net) + gross debt-funded buffer (totalBuffer). The BTC analogue of (rangeETH + totalBuffer)
    ///         on ETH. ONE source of truth for the BTC θ clamp — `BtcLib.addLiqChannel` reads it (plus
    ///         THIS add's sats) and hands it to the shared `SwapLib.addLiqBody`, so an add and a reseat
    ///         throttle on the SAME real capital -- NEVER the
    ///         disjoint WBTC-donation `rangeBTC` pool (that mis-base collapsed the range whenever donations were
    ///         thin, the opposite of what scarcity should do). 0 if no BTC vault wired.
    function btcThetaBacking() external view returns (uint) {
        return address(BTC) == address(0) ? 0 : BTC.totalShares() + BTC.totalBuffer();
    }

    /// @dev §CORE-ONLYUS — THE CHECK IS A `private view`; THE MODIFIER STAYS THE GATE. A modifier
    ///      body is INLINED AT EVERY USE SITE (11 today; 18 when the figures below were taken), so
    ///      three SLOADs + a revert string inline cost one copy each. One routine + N calls
    ///      instead, measured at the time as **907 bytes** (24,472 → 23,565), taking
    ///      `Core`'s EIP-170 margin from 104 to **1,011** — it sat at 28 and was FROZEN for
    ///      additions, which is why §E42's premium fix had to route via `Aux.ethVenue()`.
    ///      Semantics identical: the check still runs before every guarded body, at every site.
    ///      (CLAUDE.md 8c, measured independently on `BTCChannels` by a concurrent thread.)
    ///      VERIFIED against a same-worktree control, only this change differing: both arms
    ///      4,400 passed / 1 failed / 2 skipped — the failure pre-existing, the skips environmental.
    /// §DEDUP-RANGE — ONE field for the range manager. A second field holding the same address is
    /// the shape CLAUDE.md records as having planted three bugs in the EthVenue split: the call
    /// site reads correctly while the ASSIGNMENT points somewhere else.
    ///   • BTC: `setup(v4, 0, …)` pinned `RANGE` to the **ETH** range manager, so the BTC engine's
    ///     `onlyUs` admitted a FOREIGN range. `Quid` holds ONE `Core` handle and no BTC-core
    ///     reference, so it never used that privilege — an unexercised grant, which is the kind that
    ///     survives review because nothing fails when you remove it and nothing fails when you don't.
    /// ⇒ `RANGE` is THIS instance's range manager on BOTH: ETH `RANGE = v4`, BTC `RANGE = Vault` (pinned
    ///   in `setBtcVault`). Gating on it is identical for ETH and strictly TIGHTER for BTC.
    function _onlyUs() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(RANGE)
             || msg.sender == address(BTC), "403");
    }

    modifier onlyUs { _onlyUs(); _; } bytes internal constant ZERO_BYTES = bytes("");

    /// @notice The deployer — the ONLY address that may run `setup`/`setBtcVault`, the authority-wiring pins
    ///         that admit RANGE/AUX/BASKET/BTC into `onlyUs`. Captured at construction so a hostile
    ///         party can't FRONT-RUN an un-pinned wiring call in the deploy window and inject a malicious
    ///         `onlyUs` member (Core isn't Ownable; this is the immutable analog of the owner-gate the
    ///         siblings Basket.setBtcVault / Aux.setEthVenue already carry).
    address immutable DEPLOYER;
    /// §ISBTC-ZERO — THE INSTANCE IS DESCRIBED BY FACTS, NOT BY A FLAG, AND NO FLAG MAY COME BACK.
    /// Two instances are deployed, one ETH and one BTC, and each is told directly what it is: the
    /// ASSET, and the risk profile that goes with it. There is nothing left to select at runtime and
    /// nothing to get wrong at a call site. `VOL_DECIMALS` is not even passed — it is READ FROM THE
    /// ASSET, because the token already knows (WETH 18, WBTC 8), one fewer number a deployer can
    /// mistype. ⛔ A settable identity flag would reintroduce the runtime selector this removed.
    /// @dev §RISK-IS-ONE-PROFILE — THE TWO RISK NUMBERS TRAVEL AS ONE `SwapLib.Risk`, never as two
    ///      loose parameters. They are not independent: every deploy passes either
    ///      `(ETH_CONF_FRAC_WAD, 0)` or `(CONF_FRAC_WAD, SPLICE_FLOOR)`, and `SwapLib` already
    ///      declares exactly those two pairings as `ethRisk()` / `btcRisk()`. Two parameters that
    ///      always co-vary are one parameter wearing a disguise, and the disguise is what lets a
    ///      deployer pair ETH's one-block settlement window with BTC's 0.2% splice floor — a
    ///      mispricing no compiler could object to. As a profile that combination cannot be spelled.
    ///      ⚠️ NOT derived from the asset here, deliberately: Core would have to ask which asset it
    ///      is, and inferring it from `VOL_DECIMALS` (8 vs 18) is the same class of mistake as
    ///      reading a stable's decimals off its slot index. The profile is deploy-time
    ///      CONFIGURATION, which is the one place a per-instance constant honestly belongs.
    constructor(address asset_) {
        DEPLOYER = msg.sender;
        ASSET        = asset_;
        VOL_DECIMALS = IERC20Min(asset_).decimals();
    }

    /// @param _range            this instance's range manager (`Quid` on ETH). ZERO on the BTC
    ///                          instance, which pins the Vault later in `setBtcVault`.
    /// @param _aux              Aux (settlement adapter)
    /// @param _basket           Basket (settlement target)
    /// @param seedPrice         This range's reference price at deploy (WAD USD per unit volatile),
    ///                          read from CHAINLINK by the DEPLOYER (`OracleLib.seedPrices`) and
    ///                          passed in — it seeds the ring, and nothing else reads it.
    function setup(address _range, address _aux, address _basket, uint seedPrice)
        external { require(msg.sender == DEPLOYER, "403");   
        // auth-wiring pin (deployer only) anti-frontrun
        // §DEDUP-RANGE — the once-only pin is gated on `AUX`, NOT on `RANGE`: `_range` is
        // legitimately zero on the BTC instance, so a zero `RANGE` cannot mean "not set up yet".
        require(address(AUX) == address(0), "!");   // once only

        AUX = Aux(payable(_aux));
        // §ISBTC-ZERO: the RANGE is whatever the deployer pins here. The ETH range (Quid) exists by
        // now; the BTC range (Vault) is deployed AFTER Core and pins later via `setBtcVault`, so a
        // zero here is not an error -- it is the second-pin case, and no flag distinguishes them.
        if (_range != address(0)) RANGE = ICore(_range);
        BASKET = Basket(_basket);

        // §V4-CUT — ONE INSTANCE, ONE RING, ONE LINE, AND THE REFERENCE READ IS NOT CORE'S JOB.
        // ⛔ Do not move a price read back in here. The seed is needed exactly ONCE and the caller
        // already has it: `DeployLib` calls `OracleLib.seedPrices(ethFeed, btcFeed)` — CHAINLINK, not
        // a pool — and passes the result as `seedPrice`. Reading it here would force Core to hold
        // venue handles for a deploy-time lookup, which is what made this contract keep LOOKING like
        // it traded on a pool long after it stopped. The ongoing venue-vs-Chainlink cross-check lives
        // where the GUARD lives, not in the range engine.
        // There is no pool to initialise either: seeding the ring is the whole job.
        OracleLib.seedRing(obsState, observations, seedPrice);
    }

    /// @notice Draw down the BTC pool's committed USD side when an on-chain
    ///         swap-out delivery pays the LP its exact proceeds. `usd6` is 6-dec.
    function drawPooledUsdBtc(uint usd6) external onlyUs {
        // ⛔ FAIL-LOUD, not silent-clamp. TWO callers, both pairing this draw with a mint/clear of the
        // SAME amount: `BtcLib.settleDelivered` (mints QUI for the full `exactUsd`) and
        // `SwapLib.deleverOnDelivery` (`drawPooledUsdBtc(deLeverUsd6)` + `subPendingSwapOut`).
        // ⚠️ Was "the sole caller" until 2026-08-23 — a `Math.min` here under-draws and leaves that
        // excess QUI unbacked. `exactUsd ≤ pendingSwapOutUsd ≤ POOLED_USD` makes checked math never
        // underflow in correct operation; if it does, the settlement reverts rather than diverging.
        POOLED_USD -= usd6;
    }

    /// @notice Record a new undelivered on-chain swap-out obligation's USD
    ///         (at requestSwapOutOnchain). The matching `subPendingSwapOut` fires
    ///         on EITHER delivery (paid to the LP) or reversal (settleSwapIn).
    function addPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd += usd6;
    }

    /// @notice Clear an obligation's USD when it is delivered (paid exact to the
    ///         LP) or reversed. FAIL-LOUD, matching its sibling `drawPooledUsdBtc`
    ///         above — the two take the same argument in the same transaction
    ///         (`BtcLib.settleDelivered`) and must not disagree on discipline.
    ///         Every clearing path subtracts EXACTLY what its request added:
    ///         delivery is one-LP-per-slice with the swapId consumed
    ///         (`BTCChannels._settleSwapOutSlice`), and the de-lever split is a
    ///         partition — `Vault._resize` hands `resize` the remainder
    ///         `exactUsd - delevUsd`, `delevUsd` clamped to `[0, exactUsd]`, so
    ///         `SwapLib.deleverOnDelivery`'s round-UP moves the SPLIT POINT and
    ///         never the total. ⛔ A clamp here could only hide an understated
    ///         reserve, which overstates free USD and lets the pool commit
    ///         capacity it owes. Checked math surfaces that.
    function subPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd -= usd6;
    }

    // ─── External entrypoints ─────────────────────────────────────────
    /// @notice This range's in-range LP move, BOTH LEGS. `delta` is the volatile side in the
    /// instance's native unit (wei on ETH, sats on BTC); `deltaUSD` is the USD side, 6-dec.
    /// @notice full-2× range op. The debt-funded buffer leg folds into `POOLED_USD` like any in-range USD;
    ///         `committedUsd18` recovers equity by subtracting live leverage debt. There is no separate
    ///         buffer parameter, and no separate buffer counter.
    /// §V4-CUT — the range TAKES WHAT IT IS GIVEN, because inventory has no range to fit. A curve
    /// decides how much of each leg it can absorb at the current price and hands back an unplaceable
    /// remainder; holding inventory directly, both legs enter in full.
    /// ⚠️ `sent` IS THEREFORE ALWAYS 0, and it is a refund, not a status. A caller that credits the
    /// refund back is consistent (there is nothing to credit), but one that reads a zero refund as
    /// "the add failed" would be wrong — that is the line to check when wiring callers.
    /// §DE-TICK — there is no price or bounds argument: those described WHERE in a curve the
    /// liquidity had to land, and carrying them would cost calldata on every call to describe a
    /// placement that no longer happens.
    /// 🔴 §E231-MODLP-DIRECTION — THE ARGUMENTS ARE SIGNED, AND THAT IS THE FIX.
    ///
    /// This took `uint delta, uint deltaUSD` and built `Delta(-int256(deltaUSD), -int256(delta))`:
    /// **both legs ALWAYS negative, i.e. always ENTERING.** A removal had no way to say so, so every
    /// caller that BURNS depth was accounted as if it were ADDING it — `POOLED` grew on a withdraw.
    /// Measured: `testDepositImmediateWithdraw` deposits 10 ETH, withdraws 5, and asserts
    /// `pooledBeforeWithdraw - POOLED()`; POOLED came back at 1.509e19, HIGHER than before, so the
    /// subtraction underflowed. The test is right and the accounting was wrong.
    ///
    /// ⚠️ THE HAZARD IS HAND-BUILDING A `Delta` AND FIXING ITS SIGN FROM THE PATH IN FRONT OF YOU.
    /// A curve RETURNED signed deltas and so answered "which way did value move?" for free; assembling
    /// the struct here means the answer has to be supplied, and hardcoding it to "enters" is correct
    /// for the deposit path and silently wrong for every burn path.
    ///
    /// ⇒ Callers pass the sign, under the SAME convention `Delta` and `swap` already use —
    /// **positive LEAVES the pool, negative ENTERS it**. That is this file's own stated rule
    /// ("SIGN CARRIES DIRECTION … one value, one meaning — no companion flag that can disagree with
    /// it"), and following it deletes the negation here rather than adding a boolean beside it.
    /// @dev 🔴 §BURN-RELEASES-NO-USD — A LEAVING MOVE THAT PASSES `deltaUSD = 0` RELEASES NO DOLLARS,
    ///      AND THIS IS AN OPEN DEFECT, NOT A CONVENTION. `_settleUsdSide` no-ops on a zero delta, so
    ///      `basketUsd` never falls and `committedUsd18()` ratchets upward, tightening the backing
    ///      gate permanently. Callers must pass BOTH legs on a burn; `levBurnAll` passes the RECORDED
    ///      `levBufferUsd[lp]`, which is exact by construction, and that is the shape to copy.
    ///      ⛔ The obvious fix — DERIVING the USD leg here from the volatile one — was built and
    ///      REVERTED; the body says what it broke. Read that before rebuilding it.
    ///
    /// ⚠️ `keep` IS `deltaUSD == 0` HERE, AND IT IS INERT — SAY SO RATHER THAN READ MEANING INTO IT.
    ///   `keep` gates only `if (!keep && token != address(0))`, and this function hardcodes
    ///   `token = address(0)`, so neither value of it can change what happens. A zero `deltaUSD`
    ///   therefore carries no second meaning: it is an omission wearing the look of a choice.
    ///
    /// ⚠️ THIS IS THE IN-RANGE PATH, and it is the ONLY kind there is: `_handleDelta` has no
    ///   out-of-range mode any more — the flag that selected one is deleted, see its docblock.
    ///   Entering moves (`delta < 0`) must supply both legs because they are depositing both.
    function modLP(int256 delta, int256 deltaUSD, address sender)
        public onlyUs returns (uint sent) {
        // 🔴 §MODLP-DERIVE REVERTED 2026-08-25 — IT MADE AN LP RESIDUAL UNCOLLECTABLE.
        // Deriving the USD leg for a leaving move was correct about the MIRROR and wrong about the
        // CLAIM: releasing the increment proportionally on the first exit left `incrPre == 0`, so a
        // SECOND exit found no weETH to offramp AND no increment to pay, and `_withdraw` skipped both
        // branches. MEASURED (`test_SETTLE_LvrResidualIsDeferralNotLeak`): 400 ETH in, 375.63
        // delivered, **24.32 ETH of shares left and the second redeem a COMPLETE NO-OP** — pooled
        // unchanged, 0 ETH, 0 QU!D. The LP could not collect.
        // ⇒ AN UNCOLLECTABLE RESIDUAL IS WORSE THAN THE `committed` OVER-REPORT IT FIXED, so the
        //   `committed`-never-falls defect is RESTORED here deliberately and stays booked
        //   (§BURN-RELEASES-NO-USD). **The real fix must release the mirror AND keep the residual
        //   payable — those are two requirements, and I shipped one.**
        // ⚠️ Standing rule 18 in its own terms: this WAS the better-shaped fix (root, not clamp) and
        //   it was still not the best SOLUTION, because "best" includes not breaking a second
        //   property. A root fix that trades one defect for a worse one is not a root fix.
        Delta memory d = Delta(deltaUSD, delta);
        _handleDelta(d, deltaUSD == 0, sender, address(0), true);
        sent = 0;   // nothing is refused, so nothing comes back
    }



    /// @notice §E258 — settle ONE filled boundary order, both legs, at the order's own price.
    /// @dev    THIS SETTLES ON THE IN-RANGE PATH, AND THAT IS THE POINT rather than an oversight.
    ///         (It used to say `inRange = true` here; that flag is deleted.) A resting
    ///         order has no on-chain footprint at all until it fills (§OOR-BOOK-DELETED: they are
    ///         signed intents), so it cannot inflate the in-range depth every LP claim is priced
    ///         against. Filling it is the moment its funded side JOINS that depth and the other side
    ///         leaves it — exactly what a swap does — so it settles on the in-range path, and the
    ///         two states stay disjoint with no window in which the order counts twice.
    ///         `token` is `address(0)`: a fill's USD leg is either taken into the pool or paid out
    ///         through `AUX.take`, and only the burn branch reads a payout token.
    /// @param loadBalance the ORDER OWNER's load-balance consent, captured when they placed the
    ///        order (`Types.SelfManaged.loadBalance`). ⭐ **AN OOR FILL IS A SWAP AND MUST BE
    ///        LOAD-BALANCED LIKE ONE.** Before this it called `_handleDelta` and stopped, so a fill
    ///        that drew the range into shortfall left it there — the same trade routed through
    ///        `swap()` would have run the shortfall check and, on BTC, emitted the hop request. Two
    ///        paths that move the SAME inventory disagreed about whether depth gets restored.
    ///        ⚠️ Consent is still the owner's and is still per-trade (§E308); it is read from the
    ///        order rather than from an address flag, which is the same principle one step earlier
    ///        in time.
    function settleOor(address owner, int256 usdDelta, int256 volDelta, bool loadBalance)
        external onlyUs {
        _handleDelta(Delta(usdDelta, volDelta), false, owner, address(0));
        if (loadBalance) _shortfallLoadBalance(owner);
    }

    /// @dev §OOR-LOADBALANCE — THE SHORTFALL BLOCK, EXTRACTED SO THE TWO CALLERS CANNOT DIVERGE.
    ///      It was inline in `swap` and absent from `settleOor`; sharing it is what makes "an OOR
    ///      fill respects the same load-balance as an in-range swap" true by construction rather
    ///      than by two copies staying in step. Threshold (1%) and trigger are identical across
    ///      pools; only the remediation differs (`Quid.onShortfall` is a deliberate no-op, `Vault`
    ///      routes to `AUX.btcShortfall`).
    function _shortfallLoadBalance(address sender) private {
        uint totalSharesPool = RANGE.sharesForShortfall();
        uint pooledTok = RANGE.realInventory();
        if (pooledTok < totalSharesPool) {
            uint shortfall = totalSharesPool - pooledTok;
            if (shortfall * 100 >= totalSharesPool) {
                RANGE.onShortfall(sender, shortfall);   // ETH: a deliberate no-op -- see ICore
            }
        }
    }

    /// @notice This range's swap: settled at the oracle against inventory, one price for the whole
    ///         size. The shortfall signal is ASYNC (an in-frame refill is unsafe — it re-enters Aux
    ///         on half-settled backing), and it is the range manager that acts on it:
    ///         `Vault.onShortfall` routes to `AUX.btcShortfall` because we cannot mint WBTC.
    /// @dev    ⚠️ THE ETH SIDE HAS NO REFILL PATH, AND ITS `onShortfall` IS A DELIBERATE NO-OP —
    ///         read that as designed, not as unwired. `_shortfallLoadBalance` runs the SAME threshold
    ///         and trigger on both instances; only the remediation differs.
    /// @param loadBalance  the SWAPPER's consent to trigger the shortfall load-balance. It routes
    ///        through the SOR/hop and can add MEV/slippage to their OWN fill, so it is theirs to
    ///        decide -- and it is a PARAMETER OF THE SWAP, not a stored per-address flag: consent
    ///        belongs to the trade it affects, not to the address that once set it.
    /// @param recipient WHERE THE OUTPUT GOES. §E90 — this parameter was named `sender`, and its
    ///        only use is `_handleDelta(..., who, ...)`, whose `who` feeds
    ///        `RANGE.deliverVolatile(amount, who)`. It is a DESTINATION, never a payer. The one
    ///        caller (`BasketLib.routeSwap`) passes `p.recipient`, so the behaviour was always right and
    ///        the NAME was the defect: a future caller reading `sender` would pass `msg.sender` and
    ///        deliver the output to the swapper instead of the intended recipient. Renamed rather
    ///        than commented, because the next reader will trust the signature over any note.
    function swap(address recipient,
        bool inputIsUsd, address token, uint amount, bool loadBalance)
        onlyUs public returns (uint out) {

        // ═══════════════ §V4-CUT — SETTLE AT ORACLE, BOUNDED BY INVENTORY ═══════════════
        // No unlock, no callback, no curve traversal, no price discovery. ONE price for the whole
        // size. ⛔ The skew is deliberately NOT folded into this rate: we restore 1:1 from the inside
        // via Curve, so there is no arbitrageur to pay a spread to. The skew is an ATTRIBUTION KEY
        // for the realised restoration cost, never a charge applied here — and `_fillDelta` says the
        // same thing a second time, because it was violated once.
        //
        // UNITS — CHECKED, NOT ASSUMED, because a 1e12 slip here mis-scales every swap. The
        // observation ring's stored `lastPrice` and `AUX.getTWAPforAsset` are the SAME basis: WAD USD
        // per unit volatile. `_observeIfSourced` writes plain WAD prices into the ring and
        // `SwapLib.twapBody` reads them back, so the TWAP below needs no conversion of its own.
        // `BasketLib.convert` carries the 6↔18 bridge and is the SAME conversion `routeSwap` already
        // uses — deriving a second one here is how the §A.50/C2 asymmetry happened.
        //
        // SIGN CONVENTION — ONE rule, carried by the VALUE, so the legs cannot silently invert:
        //   ⇒ POSITIVE = leaves the pool (we pay out) · NEGATIVE = enters the pool (we take in).
        //   `Delta` names its legs `usd` and `vol`, so there is no ordering flag to disagree with,
        //   and `_settleUsdSide`/`_handleDelta` read the sign directly.
        //
        // ⚠️ THERE IS NO PRICE LIMIT ARGUMENT, AND NOTHING IS MISSING. A curve needed one because
        // crossing the range edge cost ZERO and bricked the range
        // (`PooledUsdRepackMatrix::testMatrix_S6`); the inventory bound in `_fillDelta` is a PHYSICAL
        // limit instead, and an edge that does not exist cannot be crossed.
        // OWN FRAME (`via_ir = false`). The fill's locals -- price, leg ordering, inventory bound,
        // partial-fill re-derivation -- are computed in `_fillDelta` and only a struct pointer and
        // `out` come back. Inlining them here blows the stack at `_handleDelta`, twice measured.
        // This is the same idiom `_handleDelta`'s own settle legs use ("each leg settles in its own
        // frame -- legacy stack, no via_ir crutch"). Do not inline for readability; it will not compile.
        uint px = AUX.getTWAPforAsset(ASSET, 1800);
        Delta memory delta;
        (delta, out) = _fillDelta(inputIsUsd, amount, px);

        // ⚠️ FOUR THINGS HAPPEN AFTER THE FILL AND ALL FOUR ARE LOAD-BEARING. A version of this that
        // computed the delta and did nothing with it — no settlement, no observation, no flow bump —
        // compiled cleanly and reverted nothing. Numbered so a later edit cannot drop one silently.

        // (1) OBSERVATION — an INDEPENDENT read, deliberately NOT the `px` above. `_observeIfSourced`
        // fetches its own price (the pinned source, or the Chainlink anchor when none is pinned) and
        // writes it to the ring as a plain WAD price; the ring has stored plain price since
        // §TICK-REMOVAL, so there is no conversion anywhere on this path.
        _observeIfSourced();   // §E222: an independent OBSERVATION -- never `px`, which READ this ring
        // §E345 — AND THE VARIANCE SAMPLE, WHICH IS A DIFFERENT QUESTION WITH A DIFFERENT SOURCE.
        // The line above needs a source INDEPENDENT of Chainlink because the ring feeds `twapResolve`'s
        // deviation test, and two sources that cannot disagree are one source (§E222). σ² is a property
        // of ONE series, so that rule does not reach it — and the anchor is the series nobody but
        // Chainlink can write, which makes it the SAFER one to measure rather than merely an
        // admissible one. Both calls sit here because this is the one seam every range and well swap
        // routes through, the same argument that makes (3) below the single flow-bump point.
        _sampleAnchorVariance();

        // (2) SETTLEMENT. Without this `POOLED_USD`/`POOLED` never move and nobody is paid.
        _handleDelta(delta, false, recipient, token);

        // (3) FLOW EWMA — LOAD-BEARING, AND ITS ABSENCE WOULD HAVE BEEN SILENT. `flowEwmaUsd` decays
        // with no replenishment if this is missing, and it is the swap half of `skewTargetUsd()`,
        // which is what `skewWad`/`sellSkew` read as `target`. At `target == 0` `sellSkew` RETURNS 0,
        // so every sell goes exempt from the imbalance charge — looking exactly like a skew that
        // simply never fires. Every range and well swap routes through here, so this remains the ONE
        // bump point for SWAP flow (a redemption unwind has its own, `bumpRedeemFlow`).
        {
            int256 usdLeg = delta.usd;
            uint usd6 = uint(usdLeg < 0 ? -usdLeg : usdLeg);
            if (usd6 != 0) {
            }
        }

        // (4) §OOR-BOOK-DELETED — THERE IS NOTHING TO SWEEP. This called
        // `RANGE.sweepOor(px, MAX_FILLS_PER_SWAP)` to emulate v4's tick traversal for resting
        // orders. The emulation was never the property: it was capped at four fills, needed an
        // unincentivised poke for the rest, and — because `book.lastSweptPx` advanced
        // unconditionally — DROPPED any order the cap or a short pool skipped, out of every future
        // sweep (§OOR-WATERMARK-DROPS-ORDERS). Resting orders are now signed intents with zero
        // on-chain footprint until they fill (`Quid.fillIntent`), so a swap has no book to walk.
        // ⛔ Do not re-add a sweep here without re-adding the book, and read
        //    §OOR-TWO-DESIGNS-LIVE before doing either.

        // §E347 — THE CONSENT GATE MOVES **ABOVE** THE TWO READS IT GOVERNS. `loadBalance` was the
        // right-hand operand of the `&&` below, so `sharesForShortfall()` and `realInventory()` —
        // two external `view` calls into the range manager — were made on EVERY swap and their
        // results discarded whenever the swapper had opted out. `realInventory()` is not a cheap
        // getter on the ETH side: it aggregates the AAVE / ether.fi venue positions, so an opted-out
        // swap was paying for a multi-venue traversal it had already declined to act on.
        // ⚠️ IT IS ALSO A LIVENESS FIX, AND THAT IS THE HALF WORTH KEEPING. Those reads reach
        // external venues, so a paused or reverting venue made `realInventory()` revert — and
        // because the call sat OUTSIDE the consent test, that revert bricked EVERY swap, including
        // the ones that wanted nothing to do with the load-balance. `_observeIfSourced` and
        // `_sampleAnchorVariance` both state the rule this restores: A READ MUST NOT BE ABLE TO HALT
        // THE RANGE. Opting out now genuinely opts out of the venue dependency, not merely of its
        // consequence.
        // Semantics are otherwise identical: both operands are pure reads and `&&` already
        // short-circuited, so no state and no ordering changes — only who pays for the reads.
        // ⚠️ `return out;`, NOT a bare `return;` — solc 0.8.30 rejects the bare form here (6777,
        // "Return arguments required") and the fill result is already in `out` from `_fillDelta`
        // above, so naming it is both required and the honest statement of what the early exit
        // yields: an opted-out swap returns its fill, having declined only the load-balance.
        if (!loadBalance) return out;

        // The shortfall arb. Both sides bootstrap symmetrically: at deploy inventory and shares are
        // both 0, so the trigger cannot fire until LPs join via `modLP`, which grows both in
        // lockstep. Keeping the comparison GROSS-to-GROSS or NET-to-NET is the range manager's job,
        // not this frame's — `Vault.sharesForShortfall` adds `totalBuffer` because its `totalShares`
        // is NET while `POOLED` is gross, and ETH's `rangeETH`-vs-`totalShares` pair is already
        // balanced. See `_shortfallLoadBalance` for the threshold and the two remediations.
        _shortfallLoadBalance(recipient);
    }



    /// @notice Move THIS range's anchor. Also absorbs what `reseat` did — the body was identical.
    /// §V4-CUT — REPACKING MOVES NO TOKENS. Once liquidity settles against inventory, the range is
    /// a PRICING PARAMETER, not a custody boundary: the range holds what it holds, and re-ranging
    /// only changes the bounds we price against. So the whole operation is ONE storage write plus a
    /// price read — there is nothing to burn and nothing to re-add.
    /// ⛔ `POOLED_USD` AND `POOLED` ARE NOT ZEROED HERE, AND MUST NEVER BE. Clearing them and
    /// rebuilding from a re-added position was correct while the POSITION was the inventory; with
    /// inventory held directly, zeroing would delete the range's holdings on a bookkeeping operation.
    /// ⚠️ AND NO FEES ARE HARVESTED HERE — there is no accrual to harvest, not an omission. The
    /// charge is the SKEW PREMIUM, taken in the fill (§E311 deleted the flat 420 ppm), and it
    /// compounds into `POOLED_USD` at swap time.
    /// §DE-TICK — there are no liquidity or bounds parameters: they described a position being
    /// burned and re-added, and keeping them as ignored arguments would cost calldata on every
    /// repack to describe an operation that no longer happens.
    /// §V4-CUT — RETURNS THE PRICE ALONE, and the caller-side fee plumbing went with the tuple:
    /// `SwapLib.Rebalanced` no longer carries fee/delta fields for `BtcLib`/`QuidLib` to read into
    /// `feeIncrements`. ⚠️ A return-value deletion is not finished until the STRUCT that carried it
    /// is checked — the callers compiled and the zeros stayed correct, so nothing announced the
    /// leftovers.
    /// @dev §ONE-ANCHOR — takes the ANCHOR, not the two bounds it implies. The caller computed those
    ///      as `updateBounds(spotPrice, RANGE_DELTA)` and already held `spotPrice`, so passing the
    ///      pair meant sending a derived value and reconstructing its source. Reconstructing it as
    ///      the midpoint would be LOSSY: `p·(10000±δ)/10000` truncates on each leg, so the recovered
    ///      anchor drifts a wei and every bound derived from it drifts with it. One argument, exact,
    ///      and the derivation lives in exactly one place.
    function repack(uint anchorPrice) public onlyUs returns (uint price) {
        RANGE_ANCHOR = anchorPrice;
        price = AUX.getTWAPforAsset(ASSET, 1800);
        _observeIfSourced();   // §E222: `price` is RETURNED for pricing; the ring records an independent read
    }


    // ⛔ (§V4-CUT) `collectFees()` DELETED — it returned `(0, 0)` and its own comment scheduled
    //    this: *"returns (0,0) rather than being deleted only while its callers still destructure
    //    the pair; the JIT branches in QuidLib/BtcLib go with it in the caller pass."* That pass is
    //    this one. What it used to do — drain v4's fee accrual into `feesPerShare` before every
    //    bookmark update — defended against a depositor capturing fees it had not earned, because
    //    v4 fees sat OUTSIDE `POOLED_*` and NAV did not reflect them. Under compounding the premium
    //    is inside `_pricingBacking()` at swap time, and `USD_FEES` is bookmarked per LP, so the
    //    window it guarded cannot open. ⚠️ NOT to be confused with `Vault.collectFees()`, which is
    //    the LIVE, LP-facing claim entrypoint and is untouched.


    /// §V4-CUT — ⛔ THE PAIR TRAVELS AS ONE MEMORY POINTER, AND MUST KEEP DOING SO. Two `int256`
    /// parameters add a stack slot per call site and blow the limit (`via_ir = false`); CLAUDE.md's
    /// remedy verbatim is locals into struct fields, because one memory pointer costs less stack
    /// than two values. Do NOT "simplify" it back into two arguments — it will not compile.
    /// §DE-TICK — THE FIELDS ARE NAMED FOR WHAT THEY HOLD, not for a token ordering, and that is
    /// what makes the ordering question unaskable. A lex-ordered `(amount0, amount1)` pair has to be
    /// ENCODED by a "which slot is the volatile one" flag at every producer and DECODED by it again
    /// at every consumer — an encode/decode pair around a struct WE own, with no external ordering
    /// left to agree with. Worse, such a flag derives from the lex order of deployed ADDRESSES, so it
    /// varies with deployment nonce: the same code could put the USD leg in either slot on two
    /// different deploys.
    struct Delta { int256 usd; int256 vol; }

    /// @dev The 5-arg form: `basketLeg = false`. Used by `swap` and `settleOor`.
    function _handleDelta(Delta memory d, 
        bool keep, address who, address token) internal {
        _handleDelta(d, keep, who, token, false);
    }

    /// ⛔ **THERE IS NO `inRange` FLAG, AND RE-ADDING ONE IS A DESIGN DECISION, NOT A RESTORE.**
    ///      It was a parameter threaded from here into `_settleUsdSide`, gating four operations —
    ///      two on `POOLED`, two on `_poolUsdInRange`. Every call site passed `true`, so all four
    ///      `false` arms were unreachable; §OOR-BOOK-DELETED had orphaned the out-of-range path
    ///      that once passed `false`, and §OOR-AS-INTENT's replacement does not go through here.
    ///      The guards are now unconditional, which is what the code always did.
    ///      ⚠️ If an intent fill ever needs the out-of-range behaviour, it needs a NEW decision
    ///      about what that behaviour is — the deleted arms encoded the OLD book's semantics and
    ///      are not a specification for the new one. Do not resurrect them from git as if they
    ///      were.
    /// @dev `basketLeg` is TRUE only where the USD leg IS the basket's own contribution — `modLP`,
    ///      i.e. an `addLiq`/burn. A swap or an OOR fill passes FALSE, so it moves the mirror
    ///      (`POOLED_USD`) without CREDITING `basketUsd` on the mint arm. ⚠️ The burn arm debits
    ///      `basketUsd` either way; see §E230-PHANTOM in `_poolUsdInRange`.
    ///      Each leg settles in its OWN frame: the USD leg is the big one, with `_poolUsdInRange`
    ///      under it, and keeping it out of this frame is what holds the legacy stack under the
    ///      limit. Naming the legs is also what removed the per-leg re-derivation of which was which.
    function _handleDelta(Delta memory d, bool keep,
        address who, address token, bool basketLeg) internal {
        _settleUsdSide(d.usd, keep, who, token, basketLeg);
        int256 tokDelta = d.vol;
        if (tokDelta > 0) {
            uint tokAmount = uint(tokDelta);
            POOLED -= Math.min(tokAmount, POOLED);   // clamp: see the ABSENT BY DECISION note
            // ⚠️ THE ASYMMETRY IS REAL AND IT LIVES IN THE RANGE MANAGER, NOT IN A FLAG HERE:
            // `Quid.deliverVolatile` sends real ether, `Vault.deliverVolatile` is a no-op because the
            // BTC range settles by Lightning cooperative close rather than an on-chain transfer. One
            // of the four known-REAL asymmetries. ⛔ Do not "unify" the two into a transfer here.
            if (who != address(0)) RANGE.deliverVolatile(tokAmount, who);   // BTC: no-op (LN close)
        } else if (tokDelta < 0) {
            uint tokAmount = uint(-tokDelta);
            POOLED += tokAmount;
        }
    }

    /// @dev USD-leg of `_handleDelta`, under the SIGN convention: delta>0 LEAVES the pool (draw the
    ///      mirror down, then pay the taker through `AUX.take`); delta<0 ENTERS it (pool it under the
    ///      backing invariant). Both directions go through `_poolUsdInRange` when in range.
    ///      ⚠️ NOT "under the BTC share cap": the `btcShareBps` median-vote cap was REMOVED in §H
    ///      (2026-07) — `SwapLib`'s "BTC allocation cap REMOVED" note is the only mention left.
    ///      There is NO per-range cap and NO fixed ETH/BTC split: the ONLY shared bound is the SUM
    ///      (`committedUsd18() <= haircutTvl`), so either range may draw the whole free surplus if
    ///      the other is not using it. Neither side is limited to a share, still less to the
    ///      MINIMUM of the two.
    /// ⚠️ THE USD LEG HAS NO TOKEN OF ITS OWN, and nothing here mints or burns one. `AUX.take` below
    /// is where value actually moves; everything else on this path is accounting.
    function _settleUsdSide(int256 usdDelta, bool keep,
        address who, address token, bool basketLeg) private returns (uint usdAmount) {
        if (usdDelta > 0) {
            usdAmount = uint(usdDelta);
            _poolUsdInRange(usdAmount, false, basketLeg);
            if (!keep && token != address(0))
                // §A.50/C2 — UNITS: `usdAmount` is the 6-dec USD leg; `AUX.take` wants the payout
                // token's NATIVE units. Every other `take`/`takeToSettle` site converts too
                // (`BasketLib.from6` / `BasketLib.scaleTokenAmount`), and the CREATE side scales via
                // `LevMath.scaleTo6`. ⛔ Drop this and the round trip is ASYMMETRIC — an 18-dec
                // redeemer is paid 1e12x too little, and `minOut` cannot catch it because
                // `Core.swap` returns the 6-dec delta, a different basis than delivery.
                AUX.take(who, BasketLib.from6(usdAmount, token), token, 0);
        } else if (usdDelta < 0) {
            usdAmount = uint(-usdDelta);
            _poolUsdInRange(usdAmount, true, basketLeg);
        }
    }

    /// @dev In-range USD pooling (own frame — keeps `_settleUsdSide` off the stack limit). The
    ///      full-2× buffer is NOT split off into a counter of its own: the WHOLE `usdAmount` moves
    ///      `POOLED_USD`, and `committedUsd18` recovers the equity claim by subtracting live leverage
    ///      debt. The ≤TVL backing gate is checked against that live EQUITY, so the debt-funded
    ///      buffer consumes no basket-USD headroom — and reading the debt live rather than keeping a
    ///      segregation counter is what makes that drift-free (there is nothing to desync).
    function _poolUsdInRange(uint usdAmount, bool mint, bool basketLeg) private {
        if (mint) {
            (uint[16] memory _d, ,, uint depegLoss) = AUX.get_deposits();
            // Depeg-at-par fix: gate against the SOLVENCY haircut — par TVL minus the LIVE depeg loss (the
            //   PERMANENT value loss of a depegged stable). NOT the deliverability haircut (illiquidLoss): that is
            //   the normal, ever-present lending-utilization slice (own − withdrawable-now; the GHO reserve sits
            //   ~78% utilized at rest), which is SOLVENT and only defers per-redemption — subtracting it here
            //   would treat routine utilization as a backing loss and block the range from committing at all
            //   (proven: it reverts test_BankRun / RedeemConservation with no depeg). Redeem subtracts illiquid to
            //   DEFER a single withdrawal; the standing solvency gate must not. depegLoss == 0 in normal
            //   operation ⇒ byte-identical to the old par gate; it only tightens under an ACTUAL depeg.
            uint haircutTvl = _d[15] > depegLoss ? _d[15] - depegLoss : 0;
            POOLED_USD += usdAmount;
            if (basketLeg) basketUsd += usdAmount;   // §ISBTC-SPLIT: both arms were identical
            // 🔴 §BACKING-DEAD — THE PUSH THAT MAKES THE GATE BELOW MEAN ANYTHING. `_reportEquity`
            // existed, was documented as PUSH-not-pull, and HAD NO CALLERS -- so
            // `RangeBacking.committedOf` was never written, `total()` was permanently 0, and this
            // `require` compared `0 <= haircutTvl`: ALWAYS TRUE. The bound that stops both ranges
            // over-committing the same basket could not bind. It must run BEFORE the require, so
            // the gate sees THIS range's new equity, and the sibling's last pushed figure.
            _reportEquity();
            require(committedUsd18() <= haircutTvl, "backing");
        } else {
            POOLED_USD -= Math.min(usdAmount, POOLED_USD);   // clamp: see the ABSENT BY DECISION note
            // §#12/E28-r — THE HAZARD THIS ARM IS CHECKED AGAINST, and it is checked below rather
            // than avoided here. The USD leg is ONE undivided balance holding basket dollars AND the
            // LP-owned increment, so a rule that debits the BASKET leg first inflates
            // `POOLED_USD - basketUsd` — the increment read as LP backing — by the whole released
            // basket slice, i.e. phantom backing paid to whoever withdraws next. Measured on a FULL
            // exit: basket floored to 0 against a 25.200001 residue, that entire residue then
            // mispriced as LP equity. ⇒ Any rule adopted here must be shown not to GROW the
            // increment in any regime; the `min` below is chosen because it cannot.
            //
            // 🔴 §E230-PHANTOM — THE `if (basketLeg)` GUARD IS DELETED FROM THIS BRANCH, AND ITS
            // ABSENCE IS THE WHOLE FIX. The guard is CORRECT on the mint arm above: dollars arriving
            // from a swapper are not basket-owned, so they must not grow the basket's claim. It is
            // WRONG here, because a burn does not get to choose which dollars leave. The USD leg is
            // one undivided balance; when `usdAmount` leaves it, basket dollars and the LP increment
            // leave in the range's CURRENT ratio no matter who took them. Gating the release on
            // `basketLeg` meant a SWAP drained `POOLED_USD` while `basketUsd` stood still.
            //
            // MEASURED (BackingGateSplit, and reproduced independently): across eight 1-ETH swaps
            // `committed` never moved -- 188,375.647057 every iteration -- while `POOLED_USD*1e12`
            // fell 1,882.965293 per swap, so the gap grew linearly and the phantom equalled EXACTLY
            // the swapper's USDC out. Headroom eroded at the same rate, making OverCommitted a
            // matter of volume: 63,625.456 / 1,882.965 ≈ 34 swaps.
            //
            // ⇒ IT DROVE `basketUsd` ABOVE `POOLED_USD`, WHICH IS NOT A TOLERANCE QUESTION BUT AN
            // IMPOSSIBLE STATE: the basket cannot own more of the USD leg than the leg contains, and
            // `_pricingBacking` reads `POOLED_USD - basketUsd` as LP backing, so the surplus was
            // phantom in the other direction from the one E28-r fixed. Same defect, same remedy,
            // one arm further along -- which is why the fix is to DELETE a condition rather than add
            // a clamp. A clamp here would have pinned the symptom (`basketUsd = min(basketUsd,
            // POOLED_USD)`) and left the divergence generating it (standing rule 17).
            //
            // ⚠️ The gate only began refusing this because it was FIXED: `_reportEquity` had no
            // callers, so `total()` was 0 and the require compared `0 <= haircutTvl` -- always true.
            // The drift had been accumulating silently the whole time; arming the bound exposed it.
            uint b = basketUsd;
            // §BURN-RELEASE-CONFLICT — TWO CALLERS SHARE THIS ARM AND `min` SERVES BOTH, which is
            // why there is no `basketLeg` split here. `modLP` (a WITHDRAWAL) passes TRUE and has
            // ALREADY sized `usdAmount` as the basket's own share, so releasing it in full leaves the
            // LP increment `POOLED_USD - basketUsd` unchanged; a swap passes FALSE and is the case
            // §E230-PHANTOM measured. `min` also covers "the whole leg left" — `b <= POOLED_USD`, so
            // when `usdAmount` covers the whole pre-decrement `POOLED_USD` it returns `b` — one
            // branch instead of a nested pair.
            // 🔴 §COMMITTED-DRIFTS-UP — WHY THIS IS `min` AND NOT PROPORTIONAL. **A PROPORTIONAL
            //    RELEASE UNDER-DEBITS BY EXACTLY `usdAmount × increment / POOLED_USD`, AND THAT IS
            //    THE WHOLE DRIFT** — it shipped, and it was measured out by
            //    aligning the REAL basket outflow (`Aux::take`) against the `committed` delta, swap
            //    by swap:
            //      take 2,517.927747 → committed −2,517.927747  shortfall 0        (incr 0)
            //      take 2,442.389915 → committed −2,441.156324  shortfall 1.233591 (74.278/147,116)
            //      take 2,442.389915 → committed −2,439.903530  shortfall 2.486385 (147.304/144,750)
            //    Predicted and observed agree to three decimals, and the FIRST swap matches to the
            //    wei because `b == P` there — the one point where the two arms are algebraically the
            //    same. The divergence starts at precisely the swap they stop agreeing.
            //    ⇒ The shortfall accumulates monotonically into `committed > totalLiquid`, which
            //    `Aux._checkBacking` refuses — blocking EVERY drain path (redemption, arb, LP
            //    withdraw) after a bounded number of swaps. In production: "redemptions worked for a
            //    while, then stopped."
            // ⭐ **THE INCREMENT GROWS FOR A CORRECT REASON, WHICH IS WHY THIS ACCELERATES.** The fee
            //    mint (`basketLeg = false` on the MINT arm) adds to `POOLED_USD` without adding to
            //    `basketUsd` — fees are LP-owned, not basket-owned, so that is right. But a growing
            //    increment makes the proportional under-debit grow with it.
            // ⇒ **DEBIT WHAT ACTUALLY LEFT.** `_settleUsdSide` pays the swapper
            //    `BasketLib.from6(usdAmount, token)` out of the basket, so the basket's claim must
            //    fall by `usdAmount` — capped at what it owns.
            // ⚠️ **`min` IS ALSO THE EXHAUSTION-CORRECT ANSWER, so §E28-r needs no separate branch.**
            //    When `usdAmount > b` the basket owns less than the payout: `b → 0` and
            //    `POOLED_USD -= usdAmount`, so the increment FALLS by `usdAmount − b` — the LP
            //    increment funding the remainder, which is exactly what happened. It cannot grow the
            //    increment in any regime, which is what §E28-r's note feared.
            // ⛔ AND IT SUBSUMES THE "pre-decrement `POOLED_USD` <= `usdAmount`" BRANCH:
            //    `b <= POOLED_USD` makes `min`
            //    return `b` exactly there. Three branches become one.
            uint out_ = b < usdAmount ? b : usdAmount;
            basketUsd = b - out_;               // §ISBTC-SPLIT: both arms were identical
            // The burn side moves equity DOWN. Reporting here keeps the accountant on the same
            // clock as the mint side -- a sum of per-range figures is only meaningful if every term
            // is current (§A.16b one level up), which is why this is a push at the moment of change.
            _reportEquity();
        }
    }

    /// @notice The venue just SETTLED `lpOwned6` as the range's remaining LP-owned USD leg — it paid the
    ///         rest out in QU!D, so the BASKET now owns that slice of the mirror. Re-anchors `basketUsd`
    ///         to `POOLED_USD - lpOwned6` instead of leaving it to whatever the burn happened to release.
    /// @dev    WHY THIS EXISTS. `POOLED_USD - basketUsd` is the number `_pricingBacking` reads as LP
    ///         equity, so it must equal what the venue actually still owes. It cannot, if both sides move
    ///         independently: the venue pays a SHARE-proportional slice (`served/lpShares`) while the burn
    ///         removes a LIQUIDITY-proportional one (`served/rangeEth`), and the two differ by exactly the
    ///         amount the range's own trading has skewed it away from 1:1. Measured on the LVR probe with a
    ///         367.9-ETH range against 400 shares: 636.44 USD of a 60,000 increment, 8 bps of LP value,
    ///         evaporating into an accumulator nobody reconciled. Netting it here makes the identity exact
    ///         rather than approximately right, and it is the BASKET's leg that moves because the QU!D was
    ///         minted against basket backing.
    /// @dev    The floor is not a safety clamp: `lpOwned6 > POOLED_USD` means the venue believes it owes
    ///         more LP-owned dollars than the curve mirror holds, which the SUBTRACTION would silently wrap.
    function absorbPaidUsd(uint lpOwned6) external onlyUs {
        uint pooled = POOLED_USD;
        uint base = pooled > lpOwned6 ? pooled - lpOwned6 : 0;
        basketUsd = base;                           // §ISBTC-SPLIT: both arms were identical
    }

    /// §V4-CUT — THE LAST TWO v4 READS, NOW ANSWERED FROM OUR OWN STATE.
    /// These asked Uniswap's singleton for the spot price and the position's size. We hold both now:
    /// the price is the oracle the fill settles at, and the "position" is the range's own inventory.
    /// `liquidity` reports `POOLED` — the range's volatile holding — because that is what the callers
    /// actually want (how much depth is there), and it was only ever v4 liquidity units because v4
    /// was the custodian.
    /// 🔴 §V4-CUT — `priceWad` IS A PLAIN PRICE, NOT A SQRT PRICE, AND THE NAME IS THE GUARD.
    /// Changing the VALUE while keeping a sqrt-flavoured name and type once left every sqrt-space
    /// consumer computing garbage with nothing reverting; the rename turned that silent wrong answer
    /// into a compile error at every call site. ⛔ Anyone reintroducing sqrt space here must move the
    /// CONSUMERS to price space instead — the sqrt source is gone, so reconstructing one would be
    /// inventing a number to feed math that should not need it.
    /// §DE-TICK — NO PARAMETERS, NO int24, NO uint160. There is no per-range position to look up, so
    /// bounds would be ignored arguments; and a price has no reason to be 160 bits, which every
    /// consumer was paying a cast for. Plain `uint` throughout.
    /// §BOOTSTRAP — RETURNS THE RING'S `lastPrice`, NOT AN 1800s TWAP. Reading a 30-minute average
    /// here was wrong on three counts, and the third broke the deploy outright:
    ///   • SEMANTICS: `poolStats` is the range's CURRENT price and inventory. A TWAP is a different
    ///     quantity, and the consumers that need one ask for it BY NAME (`getTWAPforAsset`) -- the
    ///     swap path already does, so nothing loses manipulation resistance here.
    ///   • COST: it made a frequently-read `view` perform an external CALL into Aux for a number
    ///     this contract already has in its own storage.
    ///   • BOOTSTRAP: at deploy the ring holds ONE observation stamped `now`, so a read 1800s back
    ///     has no history and reverts `twap: pre-history`. That is what `Quid.setup` hit, and it
    ///     took every fixture's setUp down with it.
    /// `lastPrice` is seeded in `OracleLib.seedRing` from the CHAINLINK-derived price the deployer
    /// passes to `setup` (`OracleLib.seedPrices`), and updated by every observation write, so it is
    /// defined from the first block and never needs history.
    function poolStats() public view returns (uint priceWad, uint liquidity) {
        priceWad = obsState.lastPrice;
        liquidity = POOLED;
    }



    /// @dev §V4-CUT — the fill, in its OWN FRAME so `swap` stays under the stack limit.
    ///      Settles AT ORACLE against inventory: one price, no traversal, no discovery.
    ///      UNITS: `px` is WAD USD per unit volatile — the SAME basis as the observation ring's
    ///      stored price and `getTWAPforAsset`. `convert` carries the 6<->18 bridge and is the same
    ///      conversion `routeSwap` uses; a second one here is how the §A.50/C2 asymmetry happened.
    ///      SIGN: positive leaves the pool, negative enters it — the same rule `Delta` and `swap` use.
    function _fillDelta(bool inputIsUsd, uint amount, uint px)
        private view returns (Delta memory d, uint out) {
        // §DE-TICK — THE CALLER SAYS WHICH SIDE IT IS PAYING (`inputIsUsd`), a fact about the TRADE,
        // rather than a direction flag that only means something against a lex-ordered token pair.
        out = BasketLib.convert(amount, px, inputIsUsd);
        // 🔴 FIRM QUOTE (owner) — THE IMBALANCE CHARGE IS IN THE PRICE, NOT TRUED UP AFTERWARDS.
        // The seam is BUILT FOR a solver counterparty (1inch / Khalani), one that has ALREADY
        // committed a price to its end user: there is nobody to bill later and no relationship to
        // bill through, so a quote adjustable after the fact is unusable in a route.
        // ⚠️ THIS LINE USED TO READ *"We feed 1inch / Khalani"* AS A LIVE FACT. **No solver is
        // integrated today** — nothing in the tree routes to either. The requirement is a DESIGN
        // CONSTRAINT held open on purpose (an aggregator must be able to arrive without us changing
        // the settlement model), not an integration to point at. It is still binding; do not weaken
        // it on the ground that nobody is routing yet, and do not cite it as evidence of traffic. ⛔ Do not reach for an
        // estimate-plus-true-up design, or for a ledger to true up against: the quote we hand a
        // solver is the price, and there is no second settlement in which to correct it.
        // ⚠️ THIS IS NOT THE SPREAD THAT WAS REMOVED. The skew was rejected as compensation paid to
        // arbitrageurs we do not need, and that reasoning still holds — we restore 1:1 ourselves.
        // What is charged here is OUR COST OF DOING THE TRADE, recovered on a price we commit to.
        // Same formula, different economic role.
        // §E279 — THE SKEW IS **NOT** APPLIED HERE, AND THIS IS THE SECOND STATEMENT OF THAT RULE.
        // `swap`'s own docstring already says *"the skew is deliberately NOT folded into
        // this rate … never a charge applied here"* — and until 2026-08-22 the line below did
        // exactly that, so the contract contradicted itself and every swapper paid TWICE.
        // ⛔ THE DUPLICATE WAS REAL. The input reaching this frame has ALREADY been scaled by
        // `(1−s)`: `SwapLib.retainSkewPremium` subtracts the premium from `r.amount` before
        // `routeSwap` derives `pooled` from it. Re-scaling `out` here realised `s + s'·(1−s)`,
        // where `s'` is the skew RE-EVALUATED on the reduced amount — strictly below `(1−s)²`, and
        // equal to it only in the Δ→0 limit. Only `s` was ever credited to LPs, so the excess sat
        // in the pool as UNATTRIBUTED backing.
        // ⚠️ **ITS LIVE MAGNITUDE ON THIS PATH WAS ZERO WHEN §E279 SAID 5.91% — THE ROW'S FIGURE IS
        // WRONG.** That figure assumes `s` is the flat `UNKNOWN_VARIANCE_SKEW` (3e16) sentinel, but on
        // a flush range `wellSkew` returns `_maxWellSkew = σ²·confFrac/8 + spliceFloor` — an ADDITIVE
        // BASE, not a cap (§E79; nothing is compared against it) — and at σ² = 0 with ETH's
        // `spliceFloor == 0` that base is **0**, the §E278 hole. Zero charged twice is still zero.
        // ⚠️ **AND THAT ZERO IS NO LONGER THE WHOLE FLUSH STORY.** §ZERO-REVENUE and §E352-DEPLETION
        // added the σ²-FREE `_depletion(inv0, inv1)` (≤ 2.1 bps, scaled by the fraction drained) to
        // BOTH flush arms, so on ETH the flush charge is 0 only for a swap that removes NO inventory.
        // The double-charge would therefore have bitten on any real drain, not merely on BTC.
        // It bites hardest where the base is non-zero: BTC (`SPLICE_FLOOR = 2e15` ⇒ 0.2% realised as
        // 0.3996%) and EVERY asset the moment a source is pinned and σ² goes positive (§E222).
        // ⇒ **So this was a live defect ARMED BY A FUTURE FIX**: closing §E222 would have silently
        // doubled the ETH drain charge. Measured, not argued — the seven `DrainAtomicity` controls
        // that read `0 <= 0` are the same zero, and they fail identically without this change.
        // ⭐ WHY THE CUT BELONGS HERE AND NOT AT `retainSkewPremium` (the row's own warning):
        // that function is the ONLY caller of `recordSkewPremium`, i.e. the entire LP fee lane
        // (§E280), AND its `r.amount -= premium` is what sizes the swap-out leg's `usd6` proceeds
        // and the swapper's `refundUnfilled` remainder. Deleting it would pay the premium to the
        // delivering LP as proceeds while still crediting it, which is the same defect mirrored.
        // ⇒ THE CHARGE IS STILL IN THE PRICE — the firm-quote requirement above is about WHEN the
        // charge is fixed, not which leg carries it. It is fixed pre-fill on the INPUT, so the
        // quote a solver receives is still committed and never trued up afterwards.
        // ⚠️ THE PREMISE THAT MAKES THIS SAFE, AND IT MUST BE RE-RUN IF A CALLER IS ADDED:
        // `BasketLib.routeSwap` is the ONLY call site of this `onlyUs` `swap` in the tree, and all
        // three of ITS callers are accounted for — `SwapLib._finishSwap` (both legs charge in its
        // own drain/fill arms), `SwapLib._swapOutSettle` (charged in `_swapOutPrep`), and
        // `SwapLib._swapInSettle`, the refill leg, which settles FLAT at the honest oracle BY
        // DESIGN and was the one path this line charged with no `retainSkewPremium` at all.
        // DRAIN vs FILL, kept for the reader because the producers still encode it: buying volatile
        // drains the scarce side (`wellSkew`, A&S pole — you CAN run out); selling into us grows
        // inventory (`sellSkew`, linear — you cannot run out of surplus).
        // §E311 — THE FLAT 420 ppm IS GONE. Owner: *"there is no 420 ppm, it's always the skew
        // premium."* It was here only because v4 charged it (`OracleLib:180` set `k.fee = 420` as the
        // pool tier); the two reasons §E226 gave for keeping it are both false in this tree — the LP
        // fee lane is `recordSkewPremium` → `Quid.creditSkewPremium` (§E280), and the anti-grinding
        // bound `w >= 1 - fee/C` it cited is computed by `SwapLib.requireNonAbusable`, which has ZERO
        // production callers: it gates nothing on the fill path.
        // ⭐ WHAT IT WAS, BY THE FLAT FEE'S OWN DERIVATION: A DOUBLE CHARGE. `DEPLETION_RATE_WAD` is
        // 210 ppm because a drain of D from balance creates 2·D·px of idle inventory, so
        // 210 ppm × 2·D·px == 420 ppm × D·px (§E48) — the depletion term inside the skew is the
        // inventory-proportional form of THIS charge, and levying both was charging it twice.
        // ⚠️ BE EXACT ABOUT THE REVENUE. This comment previously read *"draining flow pays exactly
        // what it paid"*, and that is FALSE: draining flow now pays ROUGHLY HALF what the code
        // charged before, i.e. the intended charge ONCE. The 420 was retained in `POOLED_*` and DID
        // reach LPs by compounding, so this IS a real reduction against the code AS IT STOOD — it is
        // only "free" against the derivation, which never authorised levying it twice. Saying
        // otherwise made a fee cut read as a no-op, which is how a revenue change ships unnoticed.
        // ⇒ And flow that RESTORES balance now pays no flat toll at all, which is the point: the
        // curve tilts to price inventory, so the trade that un-tilts it should not be taxed for it.
        // BOUNDED BY WHAT WE HOLD. At oracle price with no curve, nothing else stops a drain: the
        // traversal used to run out of liquidity, this runs out of inventory. Partial fill, never a
        // revert — `minOut` upstream carries the caller's tolerance.
        uint held = inputIsUsd
            ? (POOLED)              // paying out volatile
            : (POOLED_USD);     // paying out USD
        if (out > held) {
            out = held;
            amount = BasketLib.convert(out, px, !inputIsUsd);   // re-derive input for a partial
        }
        d = inputIsUsd ? Delta(-int256(amount), int256(out))    // USD in, volatile out
                       : Delta(int256(out), -int256(amount));   // volatile in, USD out
    }

    /// @notice The ring's INDEPENDENT observation source for THIS instance, pinned once by the
    ///         deployer. ⚠️ `address(0)` DOES NOT MEAN "no observations": `_observeIfSourced` then
    ///         falls back to the CHAINLINK ANCHOR and the ring fills from that (§OBSERVATION-SOURCE-
    ///         UNSET, which is the deployed configuration — no script calls `setObservationSource`).
    ///         What a zero costs is INDEPENDENCE, not liveness.
    ///
    /// @dev §E222 — WHY THE RING NEEDED A SOURCE AT ALL. Both ring writes used to pass
    ///      `AUX.getTWAPforAsset(ASSET, 1800)`, which READS this ring via `twapBody`→`observe` and
    ///      then anchors to Chainlink. The ring therefore recorded a value derived from ITSELF plus
    ///      Chainlink: `twapResolve`'s deviation test and `BasketLib.isManipulated` were comparing
    ///      one source against a smoothed copy of itself. Nothing reverted — the guards still ran and
    ///      still computed; they had simply lost the ability to DISAGREE. Before the v4 cut the ring
    ///      recorded the POOL'S SPOT PRICE, a real observation of executed trades, with Chainlink as
    ///      the anchor checking it. Removing the AMM removed the observation, not the anchor.
    ///
    /// @dev WHAT AN ADMISSIBLE ETH SOURCE LOOKS LIKE, since none is pinned today. 1inch's
    ///      OffchainOracle is the measured candidate — aggregated spot across many venues, verified
    ///      on-chain (not assumed) to DISAGREE with Chainlink by 0.08% on ETH/USD, which is exactly
    ///      what makes a second source a source rather than an echo. ⛔ It is NOT pinned, and the
    ///      body says why: `getRate` costs more gas than a block holds. Whatever is pinned must
    ///      return a PLAIN WAD price, because nothing here decodes anything else.
    ///
    /// 🔴 BTC instance: DELIBERATELY UNSET, AND THE CHECK IS DELETED RATHER THAN POINTED AT A
    ///      WRAPPER. 1inch can only quote `getRate(WBTC, USDC)` — WRAPPED BTC — and there is no
    ///      wrapper-free BTC spot on-chain at all, because native BTC has no EVM presence. Observing
    ///      WBTC would import the wrapper's basis and, far worse, make a WBTC DEPEG
    ///      INDISTINGUISHABLE FROM BITCOIN MOVING: custodial failure arriving dressed as price, which
    ///      σ², the skew and liquidation would each read as a market event.
    ///      ⚠️ A WRONG GUARD IS WORSE THAN NO GUARD — a vacuous one reports nothing you can act on,
    ///      a wrong one reports something you WILL act on. With no source the ring is fed the
    ///      Chainlink anchor instead, so the deviation test has nothing independent to disagree with
    ///      and simply never fires. That is honest: we cannot observe BTC independently, so we do
    ///      not pretend to.
    ///      ▶️ If a wrapper-free BTC source ever exists it is pinned HERE, and the check is written
    ///      against it fresh — never revived from history.
    address public observationSource;

    /// @dev The exact call to make on `observationSource`, pinned WITH it. Empty = no source.
    ///      Kept as calldata rather than a hardcoded selector because the read shape is the SOURCE's
    ///      (Curve takes a coin index, a feed takes none), and hardcoding one venue's shape is how a
    ///      rejected pool's index survives into its replacement.
    bytes public OBS_CALLDATA;

    /// @notice §E320-SSRN — **SIGNED NET FLOW, 6-dec USD. THE COMPANION TO `flowEwmaUsd`, WHICH IS UNSIGNED.**
    ///
    /// Lyons & Viswanath-Natraj (SSRN 3508006) model peg restoration as `θ̇s = ω(p−1)`, where `θs` is
    /// the share of wealth using the coin as the VEHICLE into a risky asset, and their empirical
    /// instrument for it is signed order flow — `OF = Σ V·(1[buy] − 1[sell])` (their eq. 25),
    /// reconstructed from three exchanges' tape with a taker-side flag. **We produce the same
    /// quantity as a by-product of settling a swap, and until now we deleted its sign one line after
    /// computing it:** `swap`'s flow bump takes `uint(usdLeg < 0 ? -usdLeg : usdLeg)` and feeds the
    /// magnitude to `_bumpFlow`. `skewPremium` is likewise `+=` only. So a range being drained and
    /// one being refilled were INDISTINGUISHABLE in stored state — the two conditions that call for
    /// opposite responses.
    ///
    /// SIGN — inherited from the delta convention above ("POSITIVE = leaves the pool"), NOT chosen
    /// here, so the two cannot drift apart:
    ///   • `> 0` — USD left the pool: the user was PAID dollars, having sold the volatile leg to us.
    ///     Volatile → basket travel, i.e. **net buying pressure on the stable side** (their +OF).
    ///   • `< 0` — USD entered the pool: the user BOUGHT the volatile leg with dollars.
    ///     Basket → volatile travel (their −OF).
    /// It is therefore the paper's sign convention exactly, and `netFlowUsd` rising is the state in
    /// which their Table 7 measures the LARGEST price impact (β 35.07 at a premium vs 9.19 at parity).
    ///
    /// ⚠️ THIS IS AN INSTRUMENT, NOT A PRICE. Nothing reads it on the money path and nothing should
    /// until the mapping is derived on OUR balance sheet — their risky asset sits OUTSIDE the reserve
    /// and ours sits INSIDE it, so travel changes the basket's COMPOSITION rather than its size and
    /// their eq. (15) cannot be lifted. It earns its slot under standing rule 3 because the failure it
    /// exposes is SILENT: a basket draining steadily in one direction reads, today, exactly like a
    /// balanced one.
    /// ⚠️ DECLARED LAST ON PURPOSE. `DrainAtomicity._flowTs` reads Core slots 262/263 (`_flow`,
    /// `_prem`) by RAW INDEX, and its own guard says a stale slot does NOT fail — `vm.load` reads the
    /// wrong variable and the test passes while measuring something else. Appending keeps every
    /// existing slot fixed. **Do not move this declaration up.**

    /// @notice §SESS-18 — the REDEMPTION-unwind flow EWMA, kept SEPARATE from `_flow` on purpose.
    /// ⚠️ **APPENDED, for the same reason `netFlowUsd` above is:** `DrainAtomicity._flowTs` reads Core
    ///    slots **262/263** (`_flow`, `_prem`) by RAW INDEX and its guard does NOT fail on a stale slot,
    ///    so a shifted layout would let that test pass while measuring the wrong variable. Appending
    ///    keeps both fixed — asserted, not assumed, by `forge inspect Core storageLayout`.

    /// @notice §E345 — σ² MEASURED OFF THE CHAINLINK ANCHOR, ON A SERIES NO TRADER CAN SHAPE.
    ///
    /// ⚠️ APPENDED, FOR THE REASON THE BLOCK DIRECTLY ABOVE GIVES. `netFlowUsd` is declared last on
    /// purpose and these three go AFTER it; every pre-existing slot keeps its index, so the raw-slot
    /// reads in `DrainAtomicity` still name the variables they think they name.
    ///
    /// WHY NOT THE RING (this is the whole finding, and §E343 only got half of it). §E343 established
    /// that σ² needs no INDEPENDENT source — variance is a property of one series, so §E222's
    /// two-sources-must-be-able-to-disagree rule is scoped to the deviation guard and does not reach
    /// here. That is true and it is not the binding reason. The binding reason is TRUST: the ring is
    /// written from whatever `observationSource` names, and that pin is a standing grant to shape the
    /// series σ² is computed from. The anchor has no writer we do not ALREADY trust for the settle
    /// price itself, so sourcing σ² from it REMOVES the write access rather than adding a guard
    /// against its use (rule 17).
    ///   ⛔ AND A ±BPS BAND ON THE RING WOULD NOT SUBSTITUTE FOR THAT, WHICH IS THE PART THAT IS EASY
    ///   TO GET WRONG: such a band constrains the LEVEL of each write against a fresh anchor. σ² is a
    ///   property of the SECOND differences, and a writer can track the anchor's level inside a tight
    ///   band while emitting a smooth series whose return variance is near zero. Bounding where the
    ///   series IS says nothing about how much it SHAKES.
    ///   ⚠️ The attack that motivates this is the CHEAP-SKEW one, and it is worth stating because it
    ///   does not look like an attack: feeding the ring a stream of in-range values makes σ² small-
    ///   but-MEASURED, which REPLACES the ceiling sentinel with a floor-ish number. The attacker buys
    ///   a cheap drain by being helpful. Reading that as a WBTC-basis problem and gating only the BTC
    ///   instance was the earlier, wrong diagnosis — it is a WRITABILITY problem and it applies to the
    ///   larger range too.
    ///
    /// THE ESTIMATOR IS TWO EXISTING REGISTERS, NOT NEW MATHS. `Flow` + `_bumpEwma` + `FLOW_DECAY`
    /// already implement "decay-then-add with a 48h half-life"; running the SAME helper over squared
    /// returns and over their elapsed seconds gives Σw·r² and Σw·Δt with IDENTICAL weights (both are
    /// bumped at the same instants from the same `ts`), so the ratio is a time-weighted realized
    /// variance per second with no third decay constant to justify.
    ///   ⚠️ THE READ DELIBERATELY DOES NOT CALL `_decayed`. Both registers carry the same `ts` and the
    ///   same constant, so a decay applied at read time CANCELS in the ratio — calling it would cost
    ///   two `decPow` walks to divide a number by itself. A quiet spell therefore does not corrupt the
    ///   estimate and does not fade it either; only a new sample moves it.
    Flow internal _varSq;   // vol = Σ decayed squared anchor returns (WAD) · ts = last sample taken
    Flow internal _varDt;   // vol = Σ decayed seconds spanned by those samples · ts = the same instant
    uint internal _varPx;   // the anchor price at the last sample (0 = never sampled)

    function setObservationSource(address src, bytes calldata call_) external {
        require(msg.sender == DEPLOYER, "403");
        require(observationSource == address(0), "!");
        observationSource = src; OBS_CALLDATA = call_;
    }

    /// 🔴 THE TWO STANDING PROHIBITIONS BELOW OUTLIVED `OBS_PUSH_MAX_BPS`, WHICH WAS DELETED
    ///      as inert (it bound nothing: both call sites passed `price = 0`). They are about the
    ///      RING, not about that constant's value, so they moved here — onto the ring's only
    ///      writer — rather than going with it.
    /// @dev ⛔ **DO NOT RE-ADD A PERMISSIONLESS PUSH ENTRYPOINT.** One existed, bounded by a ±50 bps
    ///      band against a fresh anchor, and the band could never constrain what it was there for: a
    ///      cumulative-price ring exists to make an ENDOGENOUS, atomically manipulable price safe by
    ///      forcing an attacker to HOLD a manipulated price across the window, and BOTH premises are
    ///      gone — no pool discovers a price here, and `_observeIfSourced` writes a feed no trader can
    ///      move within a block. A level band also says nothing about σ², which is a property of the
    ///      PATH. Anything pushed by an untrusted party is a standing grant to shape the variance
    ///      series; see the §E345 block at `_varSq`.
    ///      ⛔ **AND THE SENTENCE THAT JUSTIFIED THAT PUSH — *"a ring sourced from [Chainlink] would
    ///      measure σ² ≈ 0 through real volatility"* — IS REFUTED BY MEASUREMENT (§E343, 2026-08-23)
    ///      AND MUST NOT BE RESTORED.** It is a reasoned assertion; §E343 sampled 60 consecutive
    ///      ETH/USD rounds via `getRoundData` on an archive endpoint and got **57.3 updates/day,
    ///      20.5-min median gap, 0.53% median absolute move, implied annualised σ = 95.5%** — the
    ///      right order for ETH, not ≈ 0. **The flat-line intuition fails because it assumes a
    ///      WALL-CLOCK sample: read on a fixed grid, the gaps ARE flat and σ² collapses; read
    ///      PER ROUND, every sample is a move that already cleared the 0.5% deviation trigger.**
    ///      ⚠️ I expected the trigger to starve the estimate by censoring quiet periods. It does
    ///      not — the 61-min heartbeat forces an update through them, so quiet times are sampled
    ///      and the censoring bias is bounded rather than open-ended.
    ///      ⇒ **CONSEQUENCE FOR ANYONE SIZING THIS WORK: σ² NEEDS NO INDEPENDENT SOURCE.** §E222's
    ///      independent-source rule is scoped to `twapResolve`'s deviation test and
    ///      `BasketLib.isManipulated` — guards that need two sources able to DISAGREE. σ² is a
    ///      property of ONE series, so estimating it from the anchor is not the self-reference
    ///      §E222 forbids. Reading that refuted sentence as "Chainlink cannot feed σ²" is what sends
    ///      the next builder back to an off-chain keeper, whose CADENCE is the one manipulation a
    ///      level band does not bound at all.
    ///
    /// @dev THE READ MUST NOT BE ABLE TO HALT THE RANGE. `OracleLib.oneInchRateWad` reverts on a
    ///      zero/failed read, and this sits on the SWAP path — using it directly would turn an
    ///      oracle outage into "every swap and repack reverts", trading a silent measurement fault
    ///      for a hard liveness one. So the call is a raw `staticcall` and ANY failure (revert, short
    ///      return, zero) simply SKIPS the write: the ring goes stale, σ² decays to unmeasured, and
    ///      the same §E213 sentinel prices at the ceiling. Degrade to unmeasured, never halt.
    ///      `getRate` is defined on RAW units (`dstRaw = srcRaw·rate/1e18`), so
    ///      `priceWad = rate · 10^srcDec / 10^dstDec`; USDC is 6-dec.
    function _observeIfSourced() internal {
        address src = observationSource;
        // 🔴 §OBSERVATION-SOURCE-UNSET — THE RING FEEDS ITSELF FROM THE CHAINLINK ANCHOR WHEN NO
        // EXTERNAL SOURCE IS PINNED. `setObservationSource` has ZERO non-test callers and no deploy
        // script calls it, so this returned immediately in PRODUCTION and `obsState.lastPrice` NEVER
        // ADVANCED. One unset address froze `poolStats()` (curve spot measured 11% off the oracle),
        // froze `_corePrice()` (so `soldFractionWad` read 0 after a 20% rally and IL was never
        // recognised), and left `ringVariance` empty — which is why σ² read UNMEASURED forever and
        // §E345/§E352 both spent their effort arguing about what "unmeasured" should COST instead of
        // asking why nothing was measuring.
        // ⇒ THE ANCHOR IS ALREADY HERE. `_sampleAnchorVariance` reads it with this exact call, and
        //   `price = 0` returns the RAW feed — INDEPENDENT of the ring, which is the one property an
        //   observation source must have. §E345's "must not read `px`" warns against the RING's own
        //   TWAP (`AUX.getTWAPforAsset`); a raw feed read is the sanctioned path, not the banned one.
        // ⚠️ NOT Curve's on-pool EMA (§E232's original pick): the only pool carrying ETH/USD is
        //   TriCrypto, which is removed from this codebase entirely — as a venue AND as a read.
        //   And NOT 1inch's `getRate`: §E232 measured it at 31.7M gas, past a whole block.
        if (src == address(0)) {
            // maxDevBps = 0 because THERE IS NO INTERNAL PRICE TO DEVIATE FROM here: the price argument
            // below is 0, so `twapResolve`'s `diff` equals `ext18` and the deviation test trips for any
            // bound under 10000 - 0 and the deleted 50 are arithmetically identical on this path.
            (uint anchorPx,) = SwapLib.twapResolve(
                AUX.assetPriceFeed(ASSET), 0, VOL_DECIMALS != 18, 0, 1 days);
            if (anchorPx != 0) _writeObservationPrice(anchorPx);
            return;
        }
        // (§E232) CURVE'S ON-POOL EMA, NOT 1inch's AGGREGATOR — because the aggregator DOES NOT FIT
        // IN A BLOCK. `getRate` stood here and iterates all fourteen registered DEX oracles and
        // their connectors, so one "observation" was a full multi-venue aggregation: **31,722,803
        // gas against a 30M limit**, i.e. every swap and repack on this path exceeded an entire
        // block. `price_oracle(k)` is a single storage read of the pool's own EMA — a few thousand
        // gas — and returns a PLAIN WAD price, so there is nothing to decode and no scaling step to
        // get wrong.
        //
        // ⚠️ INDEX 1 IS DERIVED, NOT GUESSED. Curve prices coin `k+1` in units of coin 0, and this
        // pool's ordering was read from the chain: USDC=0, WBTC=1, WETH=2. So `price_oracle(1)` is
        // coin2/coin0 = **WETH in USDC**, which is already USD·1e18 — `VOL_DECIMALS` scaling would
        // DOUBLE-COUNT. A wrong index here reads WBTC/USDC and prices ETH at the BTC price, which is
        // why `CurveObserverIsCheapAndSane` asserts against Chainlink rather than trusting this note.
        //
        // ⚠️ AND THE INDEPENDENCE CLAIM IS WEAKER THAN 1inch's — SAY SO RATHER THAN INHERIT IT.
        // `OracleLib`'s header argues "correlated sources are one source" and that a single Curve
        // pool is one venue with one depeg mode, which is TRUE and is why 1inch was chosen. It is
        // also moot: an aggregation that cannot be called is not a source at all. This is one venue,
        // genuinely different in MECHANISM from Chainlink's pushed feeds (an on-pool EMA of executed
        // trades), and that is what the deviation test needs to mean anything.
        // 🔴 NO SOURCE IS PINNED (see `DeployLib`), so this body does not run today. The SELECTOR
        //    and any index belong TO THE CHOSEN SOURCE and must be decided WITH it — a pool index is
        //    meaningless without the pool, and carrying a previous pool's `1` forward would silently price
        //    ETH as WBTC on any pool ordered differently. Left as a raw call so the next source
        //    supplies its own encoding rather than inheriting a rejected pool's.
        (bool ok, bytes memory out) = src.staticcall(OBS_CALLDATA);
        if (!ok || out.length < 32) return;
        uint priceWad = abi.decode(out, (uint));
        if (priceWad != 0) _writeObservationPrice(priceWad);
    }



    function _writeObservationPrice(uint price) internal {
        OracleLib.writeObservation(observations, obsState, price);
    }

    /// @notice §E63 — ONE observe, over the ONE ring this instance owns. Two externals with
    ///         identical bodies differing only in which ring they read cost two selectors, two
    ///         dispatch entries and two copies of the call frame for one behaviour; with one ring per
    ///         instance there is nothing left to pick between, so the fields are passed directly.
    /// @dev    Keeping the body HERE rather than relocating it is measured, not assumed: moving small
    ///         bodies out of Core has come out WORSE three times (−73, −207, −471) because the caller
    ///         pays the call overhead. Not client-facing — `tools/check-client-abis.py` has ZERO
    ///         references to this name, and the only caller in the tree is `SwapLib.twapBody`.
    function observe(uint32[] calldata secondsAgos)
        external view returns (uint192[] memory) {
        return OracleLib.observe(observations, obsState, secondsAgos);
    }
}
