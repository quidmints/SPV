
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {ICurveOracle, IOffchainOracle} from "./Interfaces.sol";

import {BasketLib} from "./BasketLib.sol";
import {IAggregatorV3} from "./Interfaces.sol";

// §RING-SIZE — 256, DERIVED FROM WHAT IS ACTUALLY ASKED FOR. 65,535 was Uniswap v3's MAXIMUM
// CARDINALITY, inherited wholesale; 1024 was an intermediate pass -- a round number, not a measured
// one. The requirement, measured:
//   • the ring advances AT MOST once per block (a same-timestamp write only updates `lastPrice`),
//     so a 1800s window needs 1800/12 = 150 observations, worst case;
//   • `ringVariance` needs only `cardinality >= 3` (`:269`), subsumed entirely by that.
// 256 covers the 150 with ~70% headroom (3,072s ≈ 51 min of one-per-block history) and keeps
// `index`/`cardinality` inside `uint16`. Raise it only when a LONGER window is actually requested:
// the number follows the requirement, not the other way round.
//
// ⚠️ THE CLAIM "THE ONLY WINDOW REQUESTED IS 1800" IS THE LOAD-BEARING ONE, AND A GREP FOR LITERALS
// DOES NOT ESTABLISH IT -- two indirections hide the value and both were resolved before this landed:
//   • `TWAP_WINDOW` (`LevBase:37`) = 1800 and `TWAP_WIN_M` (`LevMath:341`) = 1800;
//   • `WbtcCfg.twapWindow` is a STRUCT FIELD, i.e. potentially any value -- but all three
//     construction sites (`BtcLevManager:318/327/347`) pass `TWAP_WINDOW`.
// So no caller asks for more than 1800s. A config field that COULD exceed 3,072s is the thing to
// re-check before trusting this number again: if one ever does, the ring silently covers less span
// than the window requests, and `twapResolve`'s Chainlink cross-check is then the only thing
// bounding the answer -- a backstop, not a substitute.
//
// ⚠️ THE WIN IS LAYOUT, NOT GAS: unwritten storage slots cost nothing, so 65,535 never paid rent.
// What it DID do was reserve 65,535 slots, pushing every later variable past slot 65,541 and making
// the harness's raw-slot arithmetic absurd.
// FILE-LEVEL because an array length must be a compile-time constant visible at the declaration
// site, and `Core` declares the ring too.
uint256 constant RING = 256;


/// @title  OracleLib — the per-pool V4 TWAP observation ring, extracted from
///         Core to free its deployed bytecode under EIP-170.
///
/// There are TWO `Core` INSTANCES (ETH/USD and BTC/USD) and EACH RUNS ONE RING — an
/// `Observation[RING]` array plus an `ObsState` scalar trio. The write + observe/interpolate logic
/// is range-agnostic, so it lives here ONCE and Core passes its own `storage` refs in. `external`
/// library functions run via DELEGATECALL in Core's storage context, so this engine is deployed
/// once and shared — saving Core's bytecode.
/// ⚠️ THIS SAID *"Core runs TWO independent rings … each is a `Observation[65535]` array"*, AND BOTH
/// NUMBERS WERE WRONG IN THE SAME SENTENCE. §ISBTC-SPLIT gave each instance ONE ring (`Core.sol:58`
/// declares exactly one `ObsState` and one `Observation[RING]`), and §RING-SIZE took the length to
/// `RING = 256`. The discriminator between the two rings is now the ADDRESS, not a field — which is
/// the whole point of the split, and is invisible to a reader trusting this header.
library OracleLib {
    /// §TICK-REMOVAL (2026-08-15) — THE RING STORES PLAIN PRICE, NOT TICKS AND NOT SQRT-PRICES.
    /// Both encodings are leaving the tree, and every consumer of this ring already wanted a price:
    /// `twapBody` converted tick→sqrt→price on EVERY read (21 of the 28 live `TickMath` calls in
    /// `src`), and the skew consumes `r.px`. Storing the price directly deletes the whole round trip,
    /// the `int56` walks, and the per-read orientation flag — orientation is resolved ONCE at write.
    /// `uint192` is ample: the BTC leg's usd18 price carries the ×1e10 WBTC lift (~6.3e32) and an
    /// elapsed-seconds accumulator over a decade (~3e8) reaches ~2e41, against a 6.3e57 ceiling.
    /// ⚠️ A SECOND §RING-SIZE BLOCK STOOD HERE QUOTING **1024** AND *"~3.4 HOURS"*, WHICH IS THE
    /// INTERMEDIATE SIZE, NOT THE LIVE ONE. `RING = 256` is declared at file scope forty lines above
    /// with its own derivation, and the two blocks disagreed by 4x on the one number a reader comes
    /// here for. Deleted rather than corrected: an array length has exactly one declaration site
    /// (`RING`), so a prose copy of it can only ever go stale again — and this one had, silently,
    /// while reading as the authoritative note because it sits on the struct.
    struct Observation {
        uint32 blockTimestamp;
        uint192 priceCumulative;
        bool initialized;
    }
    /// Per-pool ring scalars (grouped so the helpers take one storage ref).
    struct ObsState { uint lastPrice; uint16 cardinality; uint16 index; }   // §DE-TICK: uniform width

    /// @dev Append the current price to the ring (or just update lastPrice if a
    ///      same-timestamp write already happened this block).
    function writeObservation(
        Observation[RING] storage obs, ObsState storage st, uint price
    ) external {
        uint32 blockTimestamp = uint32(block.timestamp);
        uint16 idx = st.index;
        Observation memory last = obs[idx];

        if (last.blockTimestamp == blockTimestamp) {
            st.lastPrice = price;
            return;
        }
        uint32 dt = blockTimestamp - last.blockTimestamp;
        uint192 priceCumulative = last.priceCumulative
            + uint192(uint256(st.lastPrice) * dt);

        uint16 nextIdx = uint16((idx + 1) % RING);
        uint16 card = st.cardinality;
        if (nextIdx >= card && card < uint16(RING)) {
            st.cardinality = nextIdx + 1;
        }
        obs[nextIdx] = Observation({
            blockTimestamp: blockTimestamp,
            priceCumulative: priceCumulative,
            initialized: true});
        st.index = nextIdx; st.lastPrice = price;
    }

    function observe(
        Observation[RING] storage obs, ObsState storage st,
        uint32[] calldata secondsAgos
    ) external view returns (uint192[] memory priceCumulatives) {
        priceCumulatives = new uint192[](secondsAgos.length);
        uint32 time = uint32(block.timestamp);
        Observation memory latest = obs[st.index];
        Observation memory oldest = _getOldest(obs, st);
        uint lastPrice = st.lastPrice;

        for (uint i = 0; i < secondsAgos.length; i++) {
            uint32 target = time - secondsAgos[i];
            if (secondsAgos[i] == 0) {
                uint32 dt = time - latest.blockTimestamp;
                priceCumulatives[i] = latest.priceCumulative
                    + uint192(uint256(lastPrice) * dt);
            } else if (target <= oldest.blockTimestamp) {
                // Bootstrap-only edge: target predates the oldest observation.
                // Revert — callers should wait until the ring covers their
                // TWAP window.
                revert("twap: pre-history");
            } else if (target >= latest.blockTimestamp) {
                uint32 dt = target - latest.blockTimestamp;
                priceCumulatives[i] = latest.priceCumulative
                    + uint192(uint256(lastPrice) * dt);
            } else {
                priceCumulatives[i] = _interpolate(obs, st, target, oldest, latest);
            }
        }
    }

    function _getOldest(Observation[RING] storage obs, ObsState storage st)
        internal view returns (Observation memory) {
        uint16 card = st.cardinality;
        if (card == 1) return obs[0];
        uint16 oldestIdx = (st.index + 1) % card;
        Observation memory oldest = obs[oldestIdx];
        if (!oldest.initialized) return obs[0];
        return oldest;
    }

    function _interpolate(
        Observation[RING] storage obs, ObsState storage st,
        uint32 target, Observation memory oldest, Observation memory latest
    ) internal view returns (uint192) {
        uint16 card = st.cardinality;

        // §DEDUP-INTERPOLATE (2026-08-18) — the two branches DIFFERED ONLY IN WHICH PAIR OF
        // OBSERVATIONS THEY READ. Both then computed the same three deltas and ran byte-identical
        // arithmetic, and solc had been reporting that as three shadowed declarations for as long
        // as the duplicate existed: the warning was the SYMPTOM, the duplicated tail was the defect.
        // Now the branch PICKS the pair and one computation serves both.
        Observation memory before_;
        Observation memory later_;
        if (card <= 2) {
            before_ = oldest;
            later_  = latest;
        } else {
            uint16 oldestIdx = (st.index + 1) % card;
            if (!obs[oldestIdx].initialized) oldestIdx = 0;

            uint16 lo = 0; uint16 hi = card - 1;
            while (lo < hi) {
                uint16 mid = lo + (hi - lo + 1) / 2;
                if (obs[(oldestIdx + mid) % card].blockTimestamp <= target) lo = mid;
                else hi = mid - 1;
            }
            before_ = obs[(oldestIdx + lo) % card];
            later_  = obs[(oldestIdx + lo + 1) % card];
        }

        uint32 totalDelta = later_.blockTimestamp - before_.blockTimestamp;
        if (totalDelta == 0) return before_.priceCumulative;
        uint32 targetDelta = target - before_.blockTimestamp;
        uint192 cumulativeDelta = later_.priceCumulative - before_.priceCumulative;
        // Widen to 256-bit for the multiply-before-divide: across a long observation gap (a quiet
        // market then a swap/reseat), cumulativeDelta·targetDelta overflows int56 (~3.6e16) even
        // though the interpolated RESULT fits int56. Compute in 256-bit, cast back.
        return before_.priceCumulative + uint192(
            uint256(cumulativeDelta) * uint256(targetDelta)
                / uint256(totalDelta));
    }

    /// ⛔ NEVER WRITE AN AT-PREFIXED TAG NAME INSIDE DOCBLOCK PROSE — THIS FILE BROKE THE BUILD
    ///    ON IT, AND IT IS THE THIRD TIME TODAY (twice in `FeeLib`, once here). solc parses an
    ///    at-word as a natspec TAG wherever it appears, not only at line start, and backticks do
    ///    NOT escape it — the tag name absorbs the closing backtick. The error is
    ///    `Documentation tag ... not valid for functions` pointing at the docblock''s FIRST line,
    ///    so it names neither the offending word nor its line. Spell them out: "the dev tag".
    ///    ⚠️ It only fires above a FUNCTION — `Core.sol:190` carries one above a VARIABLE and
    ///    compiles, which is why the pattern looks safe until it is not.
    /// ⚠️ THE dev-TAG BLOCK THAT STOOD HERE DESCRIBED A FUNCTION THAT NO LONGER EXISTS, IN THE PRESENT
    /// TENSE, DIRECTLY ABOVE THE THREE-LINE BODY BELOW: *"Deploy Core's four per-pool mocks here …
    /// so the ~3.9 KB of `mock` creation-code lives in THIS library's bytecode."* §E253-mock deleted
    /// the mocks and `deployMocks` with them — there is no `mock` string left in this file and no
    /// caller anywhere in `evm/src`, `evm/script` or `evm/test`. Read as current it says `seedRing`
    /// deploys four ERC20s, which would make anyone sizing this library's bytecode wrong by ~3.9 KB.
    /// §V4-CUT — THIS IS A RING SEEDER NOW, AND THE NAME SAYS SO. It used to assemble a lex-sorted
    /// PoolKey, derive its PoolId, align a reference tick to the grid and call `pm.initialize` so v4
    /// would host the range. Nothing calls the PoolManager any more, so the pool was never created --
    /// which made the PoolKey, the PoolId and the `volMock > usdMock` ordering all write-only
    /// vestigia of a pool that does not exist. `VANILLA_*` and `POOL_ID_VANILLA_*` went with them.
    /// What actually mattered was always these three lines: seed `lastPrice` from the reference
    /// price and open the ring.
    function seedRing(ObsState storage st, Observation[RING] storage obs, uint refPrice)
        external {
        st.lastPrice = refPrice;
        st.cardinality = 1;
        obs[0] = Observation({ blockTimestamp: uint32(block.timestamp),
            priceCumulative: 0, initialized: true });
    }

    /// 🔴 §DE-TICK, KEPT AS THE RECORD OF A LIVE UNIT BUG THIS FUNCTION'S SHAPE EXISTS TO PREVENT.
    /// The predecessor (`prepRefs`) handed back two reference pools' `slot0` TICKS, and `initPool`
    /// converted them to a sqrt price to initialise our own v4 pool at the same ratio. That pool
    /// went away, so the tick travelled straight into `st.lastPrice` through a `uint(int(refTick))`
    /// cast -- seeding the ring with a TICK reinterpreted as a WAD price, which for a NEGATIVE tick
    /// is ~2^256. MEASURED: `poolStats()` returned 1.157e77 and every fixture's setUp died one step
    /// later on an arithmetic underflow. A tick and a price are both `uint` after the cast, so
    /// nothing objected. ⇒ Returning a PRICE, in the same scaling `twapResolve` uses, is what makes
    /// that class unconstructible rather than merely fixed.
    /// ⚠️ THREE CLAIMS THAT STOOD HERE WERE FALSE AND ONE CONTRADICTED THE dev-TAG SIX LINES BELOW.
    /// They described `prepRefs`, not this function: *"`wbtc` is passed in rather than read here"*
    /// (there is no `wbtc` parameter — the signature is `(ethFeed, btcFeed)`, and `_feed18` applies
    /// the ×1e10 lift from a bool); *"the orientation probes are CONSUMED HERE now"* (there are no
    /// probes, and no pool to orient); and *"the reference pools are still READ, deliberately"* —
    /// which §V4-ZERO below flatly denies, and a grep confirms: **zero occurrences of `slot0`,
    /// `IPoolManager`, `PoolKey` or `StateLibrary` anywhere in `evm/src`.** The paragraph recording
    /// the deleted PoolManager approvals went with them; it documented `prepRefs`'s body.
    /// @notice Deploy-time seed price for each range, read from CHAINLINK.
    /// @dev    §V4-ZERO — was `prepRefs`, which read `slot0` from two UNISWAP V4 REFERENCE POOLS and
    ///         was the last thing in `src/` needing `IPoolManager`, `PoolKey`, `PoolIdLibrary`,
    ///         `Currency` and `StateLibrary`. Five v4 types and a `PoolKey` field on the deploy
    ///         config, so a range could learn its starting price ONCE.
    ///
    ///         Chainlink is where that price comes from at RUNTIME anyway: `SwapLib.twapResolve`
    ///         anchors every internal TWAP against `assetPriceFeed[asset]` and falls back to it
    ///         outright when the internal reading is unusable. Seeding from the anchor the protocol
    ///         already trusts is strictly more consistent than seeding from a third-party pool
    ///         nobody here validates.
    ///
    ///         SCALING MIRRORS `twapResolve` EXACTLY, and must: `ans * 10**(18-d)`, then the ×1e10
    ///         WBTC lift that closes the 8↔18-decimal gap. Copied from there rather than
    ///         re-derived -- getting it wrong seeds the ring ten orders of magnitude out.
    function seedPrices(address ethFeed, address btcFeed)
        external view returns (uint priceETH, uint priceBTC) {
        priceETH = _feed18(ethFeed, false);
        priceBTC = _feed18(btcFeed, true);
    }

    function _feed18(address feed, bool isWbtc) private view returns (uint) {
        (, int256 ans, , , ) = IAggregatorV3(feed).latestRoundData();
        require(ans > 0, "seed feed");
        uint8 d = IAggregatorV3(feed).decimals();
        require(d <= 18, "seed dec");
        uint p = uint(ans) * (10 ** (18 - d));
        return isWbtc ? p * 1e10 : p;
    }


    /// @notice §E59 — REALIZED TICK VARIANCE FROM THE **STORED OBSERVATIONS**, not a wall-clock grid.
    ///
    /// WHY THIS EXISTS. The previous estimator sampled `observe` every `THETA_STEP` seconds, but the
    /// ring only advances ON A SWAP and `observe` LINEARLY INTERPOLATES between stored points.
    /// Linear interpolation has ZERO SECOND DERIVATIVE, so every sample inside one inter-swap gap
    /// returned the same average tick and the variance came out EXACTLY 0 — however violently price
    /// had moved. MEASURED: a drain that took `POOLED` from 400 to 0.00097 ETH reported 0.
    ///
    /// Sampling the ring itself removes the interpolation entirely: every point is a REAL price
    /// update, so a gap contributes one observation rather than a run of identical fabrications.
    /// Intervals are UNEVEN by nature, so each return is normalised by its OWN elapsed time and the
    /// annualisation uses the MEASURED span — no fixed step to mis-match the swap cadence.
    ///
    /// Returns RELATIVE-return variance per second (WAD). (It said "tick-variance"; §TICK-REMOVAL
    /// retired the ticks and the body's own notes say so — the name outlived the quantity.)
    /// The span is not returned because it is redundant (it is 0 exactly when this is).
    ///
    /// 🔴 §E346-ZERO — **THIS FUNCTION RETURNS 0 FOR SEVEN DISTINCT REASONS AND THE CALLER CANNOT
    /// TELL THEM APART. SIX ARE "COULD NOT ESTIMATE"; THE SEVENTH IS "ESTIMATED, AND IT IS ZERO".**
    /// The docstring used to assert the seventh does not exist ("0 means UNKNOWN — too few real
    /// updates — NOT calm"), and `SwapLib`'s `sigmaSqWad == 0` guard still repeats that claim in
    /// stronger words. It is false. Enumerated against the body, in the order they are reached:
    ///   1. `card < 3 || n < 3`      — too few slots.
    ///   2. `m < 2` (⇒ `card < 4`)   — too few DISTINCT samples. §E345 measured that this, not
    ///                                 `card >= 2`, is the real threshold, and the two-short gap was
    ///                                 a live defect.
    ///   3. `!lo.initialized`        — an unwritten slot inside the window.
    ///   4. `lo.blockTimestamp >= hi.blockTimestamp` — non-advancing timestamps.
    ///   5. `rate == 0`              — the OLDER interval is the divisor. ⚠️ NOT a sample-count
    ///                                 condition; `SwapLib`'s enumeration omits it entirely.
    ///   6. `newest <= oldest`       — the measured span collapsed.
    ///   7. **`acc == 0` — A GENUINELY FLAT RING.** Constant price ⇒ `priceCumulative` advances by
    ///      exactly `P` per second ⇒ every interval `rate == P` exactly (the division is exact) ⇒
    ///      every `ret[i] == 0`, `mean == 0`, and the §E63 drift term `mean*mean == 0` too. This is
    ///      a REAL MEASUREMENT of a REAL zero, and it is REACHABLE.
    ///
    /// ⛔ **DO NOT "FIX" THIS WITH THE §E88 ONE-WEI FLOOR THAT `Core.anchorVarianceWad` USES. IT IS
    ///    BOTH UNSAFE AND INERT, AND THE INERTNESS IS WHAT MAKES IT DANGEROUS TO TRY.**
    ///   • UNSAFE: **this ring is PERMISSIONLESS.** `Core.pushObservation` is `external` with no
    ///     auth, bounded only to ±`OBS_PUSH_MAX_BPS` (50 bps) of the Chainlink anchor — and a
    ///     CONSTANT price is trivially inside that bound. So exit 7 is not merely reachable, it is
    ///     cheaply ATTACKER-CONSTRUCTIBLE. Flooring it to 1 would hand that attacker a free
    ///     "declare the market calm" primitive: `SwapLib`'s `if (sigmaSqWad == 0) return
    ///     UNKNOWN_VARIANCE_SKEW` stops firing and the 3% unknown-variance drain charge switches
    ///     off. That is EXACTLY the §E345 attack, re-entering through the floor instead of through
    ///     the deleted `cardinality >= 2` sentinel.
    ///   • INERT: the floor could not even reach the caller. `Core.realizedVarianceWad` scales this
    ///     by `mulDiv(raw, 31536000, 1e18)`, and **`mulDiv(1, 31536000, 1e18) == 0`** — every raw
    ///     below 31,709,791,984 truncates away. So the floor would be silently annihilated one frame
    ///     up: a fix that looks landed, changes nothing, and leaves the next reader believing the
    ///     ambiguity is resolved. (That threshold is annualised σ² = 1e-18, i.e. σ = 1e-9 — one part
    ///     per billion — so the truncation window IS the exact-zero case and hides no real reading.)
    ///
    /// ✅ **THE AMBIGUITY IS ALREADY RESOLVED, AND NOT HERE — IT IS RESOLVED AT THE SEAM, BY §E345.**
    ///    `Core.realizedVarianceWad` returns `max(ringLeg, anchorVarianceWad())`. Under a `max` the
    ///    ring's honest zero and its could-not-estimate zero contribute IDENTICALLY — nothing — so
    ///    the six-vs-one distinction is not observable at the only consumer, BY CONSTRUCTION. The
    ///    Chainlink anchor is the leg that carries the §E88 floor, and it can, because Chainlink is
    ///    not attacker-writable. **The ring may move σ² only UPWARD, i.e. only in the direction that
    ///    costs whoever writes it.** Making this function's zero self-describing would therefore buy
    ///    a distinction nothing is allowed to act on, at the price of the vector above.
    /// ⇒ A signature change (returning a `bool measured`) is the ONLY way to surface it, it is not
    ///   warranted for the reason just given, and it would be a cross-file arity change — which in
    ///   this tree reports as a bare `Error: Error writing output JSON.` with no file, line or
    ///   symbol. Left deliberately unresolved, and documented so it is not re-opened a fourth time.
    function ringVariance(Observation[RING] storage obs, ObsState storage st, uint n)
        external view returns (uint varPerSecWad)
    {
        uint card = st.cardinality;
        if (card < 3 || n < 3) return 0;
        if (n > card) n = card;

        // Walk back n stored points from the newest, newest-first, differencing as we go.
        //
        // §TICK-REMOVAL — THE 1e9 LIFT IS GONE WITH THE TICKS. §E59 added it because truncating to
        // WHOLE TICKS zeroed every difference on a ~20-tick range. A usd18 price carries 18 decimals
        // natively, so sub-basis-point movement survives without any rescaling, and omitting the
        // lift keeps `d*d` far inside uint256.
        //
        // Variance of consecutive RELATIVE returns, sample-corrected.
        // §TICK-REMOVAL — THE RETURN IS NOW RELATIVE *EXPLICITLY*, WHICH IS WHAT KEEPS σ²'s UNITS
        // AND LEAVES Γ UNTOUCHED. A tick difference was ALREADY a relative return in disguise (1
        // tick = 1 bp), which is precisely why `Core.realizedVarianceWad` multiplied by
        // 1e10 = 1e-8 (tick²→relative²) × 1e18 (WAD). Taking the relative return of a plain price
        // makes that conversion unnecessary rather than merely moving it, so the 1e10 goes with the
        // ticks and the ANNUALIZED NUMBER KEEPS ITS MAGNITUDE AND MEANING.
        //
        // §E213 — ONE ARRAY, NOT TWO, AND THE ARITHMETIC IS UNCHANGED. The per-interval average
        // PRICE used to be materialised in full and differenced in a second loop, but a return
        // needs only its own interval and the one before it, so a single scalar carries the whole
        // dependency. The prices are an INTERMEDIATE, never a result — nothing downstream reads
        // them. Folding the difference into the walk also retires `dt`, `spanSecs`, `prev` and the
        // separate mean-summing loop, and yields `Σ ret` for free. Same operations in the same
        // order on the same values ⇒ BIT-IDENTICAL output; this is a locals change, not a maths one.
        uint m = n - 2;                             // returns = intervals − 1
        if (m < 2) return 0;
        int[] memory ret = new int[](m);
        int sum;                                    // Σ ret, accumulated in the same pass
        uint32 newest; uint32 oldest;
        {
            uint16 idx = st.index;
            Observation memory hi = obs[idx];
            newest = hi.blockTimestamp;
            uint prevRate;                          // the previous interval — the only one still live
            for (uint i = 0; i < n - 1; i++) {
                uint16 lo_i = uint16((uint(idx) + card - 1 - i) % card);
                Observation memory lo = obs[lo_i];
                if (!lo.initialized || lo.blockTimestamp >= hi.blockTimestamp) return 0;
                uint rate = uint(hi.priceCumulative - lo.priceCumulative)
                          / uint(hi.blockTimestamp - lo.blockTimestamp);
                if (i != 0) {
                    if (rate == 0) return 0;        // the OLDER interval is the divisor
                    int r = (int(prevRate) - int(rate)) * 1e18 / int(rate);   // WAD relative return
                    ret[i - 1] = r;
                    sum += r;
                }
                prevRate = rate;
                hi = lo;
                oldest = lo.blockTimestamp;
            }
        }
        if (newest <= oldest) return 0;
        int mean = sum / int(m);
        uint acc;
        for (uint i = 0; i < m; i++) {
            int d = ret[i] - mean;
            acc += uint(d * d);
        }
        acc /= (m - 1);
        // §E63 — SECOND MOMENT, NOT CENTRAL SECOND MOMENT: add the DRIFT back in.
        //
        // `acc` alone is the variance ABOUT THE MEAN, and a range walking STEADILY one way has every
        // difference equal ⇒ every deviation 0 ⇒ variance EXACTLY 0. That is arithmetically right
        // and economically wrong: a monotone walk carries real inventory risk while measuring as
        // perfectly calm. MEASURED: 16 swaps moving the tick −1 read 0; only a −2 move registered.
        // Four memory policies (latch / erase / decay / widen) all failed trying to REMEMBER a
        // number that was correctly zero — the number itself was the wrong quantity.
        //
        // The drift () was already computed and discarded. Squaring it back in costs no extra loads
        // and no constant, and gives E[x²] = Var + E[x]² — the drift AND the wobble, which is what
        // an inventory-risk measure has to price.
        acc += uint(mean * mean);   //  is the drift term computed above
        // Per-second. The caller annualises with the MEASURED span rather than a fixed step.
        // `acc` is (WAD relative return)^2 = relative^2 * 1e36, so the caller divides by 1e18 ONCE
        // to land on WAD relative variance — replacing the old `* 1e10 / 1e18`.
        varPerSecWad = acc / uint(newest - oldest);   // the measured span; `newest > oldest` above
    }

    // ═══ §E318 — `ExternalTwap` FOLDED IN: 88 lines of oracle reads beside the library that
    // already owns oracle concerns and shares its only src consumer (`Core`). ═══

    error DeviationTooWide(uint ours, uint theirs, uint bps);
    error NoExternalPrice();

    /// @notice Curve's EMA price for a pool coin, in WAD.
    /// @param  k  Curve indexes coin `k+1` against coin 0 — so on a 3-coin pool ordered (0 USDC,
    ///            1 WBTC, 2 WETH) it is **k=0 → WBTC/USDC, k=1 → WETH/USDC**, and k=2 REVERTS.
    ///            🔴 CORRECTED 2026-08-17: this said "1 = WBTC, 2 = WETH", which is off by one.
    ///            Wiring ETH from it returns **WBTC's** price — measured `price_oracle(0)` =
    ///            $64,280.15 vs `price_oracle(1)` = $1,906.53 — a 34x error that reverts nothing
    ///            and prices everything. Verified against `coins()` on-chain, not inferred.
    ///
    /// @dev  DEVIATION BOUND: DERIVE IT AGAINST THIS POOL'S HALF-LIFE, DO NOT INHERIT
    ///       `TWAP_MAX_DEVIATION_BPS`. Measured `ma_time() = 600s`. Our internal reading is a
    ///       **1800s window**, whose average lags spot by ~900s; a 600s EMA lags by ~600s. So the two
    ///       legitimately diverge on a **~300s lag difference**, which at 60% annualised vol is
    ///       **~18.5 bps (1σ)** — i.e. ~37 bps at 2σ, ~56 bps at 3σ. **`TWAP_MAX_DEVIATION_BPS` is
    ///       500 bps**, calibrated as "manipulation territory" for a 30-minute window: against a
    ///       10-minute EMA that is **~27σ**, so it would never fire and the check would be
    ///       decorative. A bound for this source belongs in the 37–74 bps range and must be restated
    ///       if the pool's `ma_time` changes — it is the POOL's parameter, not ours.
    function curvePriceWad(address pool, uint256 k) internal view returns (uint priceWad) {
        priceWad = ICurveOracle(pool).price_oracle(k);
        if (priceWad == 0) revert NoExternalPrice();
    }

    /// @notice Curve's EMA price for a two-coin pool (no index argument).
    function curvePriceWad(address pool) internal view returns (uint priceWad) {
        priceWad = ICurveOracle(pool).price_oracle();
        if (priceWad == 0) revert NoExternalPrice();
    }

    /// @notice 1inch OffchainOracle (`0x0AdDd25a…F9B8`) — the AGGREGATED spot rate, in WAD.
    ///
    /// @dev **IT ANSWERS THIS FILE'S OWN OBJECTION.** The header warns *"CORRELATED SOURCES ARE ONE
    ///      SOURCE… Count correlated readings as one observer."* A single Curve pool IS one venue
    ///      with one depeg mode, so it fails that test on its own terms; the OffchainOracle
    ///      aggregates across many. **VERIFIED INDEPENDENT, NOT ASSUMED (2026-08-16):** `oracles()`
    ///      returns 14 registered oracles with WETH/ETH connector types — the DEX-wrapper pattern,
    ///      not a feed reader — and decisively, **it DISAGREES with Chainlink**; were it reading
    ///      Chainlink the two would be identical. It also keeps the property that ruled out a v3
    ///      TWAP: `getRate` is a PLAIN RATE, so no `TickMath` returns.
    ///
    /// @dev **SCALING DERIVED, NOT GUESSED.** `getRate` is defined on RAW units:
    ///      `dstRaw = srcRaw · rate / 1e18`, so
    ///      `price = rate · 10^srcDec / (1e18 · 10^dstDec)` and `priceWad = rate · 10^srcDec / 10^dstDec`.
    ///      **PINNED vs CHAINLINK, SAME BLOCK:** WETH→USDC `rate = 1,877,080,514` ⇒ `$1,877.08` vs
    ///      ETH/USD `$1,878.54` (0.08%).
    ///
    /// 🔴 **DO NOT USE THIS FOR THE BTC CROSS.** There is no wrapper-free BTC spot on-chain at all —
    ///    native BTC has no EVM presence — so `getRate(WETH, WBTC)` prices WRAPPED BTC and would
    ///    reimport the basis §E221 exists to delete. **Measured: 1inch ETH/WBTC vs Chainlink ETH/BTC
    ///    differ by 4.29 bps, and WBTC/BTC is 3.91 bps — the gap IS the wrapper.** Price BTC from the
    ///    Chainlink ETH/BTC cross; the wrapped reading is a CROSS-CHECK ONLY, where its disagreement
    ///    is a direct measurement of the WBTC basis and therefore a depeg DETECTOR.
    ///
    /// ⚠️ SPOT, NOT A TWAP — no window, so manipulable within a block. Use it as the independent
    ///    observation `requireAgrees` cross-checks; never to SIZE anything (see that function).
    function oneInchRateWad(address oracle, address src, address dst, uint8 srcDec, uint8 dstDec)
        internal view returns (uint priceWad) {
        uint rate = IOffchainOracle(oracle).getRate(src, dst, false);
        if (rate == 0) revert NoExternalPrice();
        priceWad = SoladyMath.fullMulDiv(rate, 10 ** srcDec, 10 ** dstDec);
        if (priceWad == 0) revert NoExternalPrice();
    }

    /// @notice Reject when two independent prices disagree by more than `maxBps`.
    /// @dev    **SYMMETRIC BY CONSTRUCTION.** The deviation is measured against the SMALLER of the
    ///         two, so neither source is privileged. An asymmetric test — always dividing by "ours"
    ///         — lets a manipulated external reading pass more easily in one direction than the
    ///         other, which is the direction an attacker gets to choose.
    /// @dev    ⚠️ THIS IS A CAPACITY-STYLE CHECK, NOT A TOLERANCE INPUT. It compares two prices and
    ///         REFUSES; it must never be used to SIZE anything. Sizing from a live external read is
    ///         the trap `Interfaces.sol:74-77` records — manipulation widens the guard exactly when
    ///         it needs to hold.
    function requireAgrees(uint ours, uint theirs, uint maxBps) internal pure {
        if (ours == 0 || theirs == 0) revert NoExternalPrice();
        (uint lo, uint hi) = ours < theirs ? (ours, theirs) : (theirs, ours);
        uint bps = SoladyMath.fullMulDiv(hi - lo, 10_000, lo);
        if (bps > maxBps) revert DeviationTooWide(ours, theirs, bps);
    }

}
