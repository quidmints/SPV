
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {ICurveOracle, IOffchainOracle} from "./Interfaces.sol";

import {IAggregatorV3} from "./Interfaces.sol";

// §RING-SIZE — 256, DERIVED FROM WHAT IS ACTUALLY ASKED FOR. 65,535 was Uniswap v3's MAXIMUM
// CARDINALITY, inherited wholesale; 1024 was an intermediate pass -- a round number, not a measured
// one. The requirement, measured:
//   • the ring advances AT MOST once per block (a same-timestamp write only updates `lastPrice`),
//     so a 1800s window needs 1800/12 = 150 observations, worst case.
// (The second requirement was `ringVariance`'s `cardinality >= 3`; that estimator is deleted —
//  §NO-GAMEABLE-BOUND — and it was subsumed by the 150 anyway, so the number is unchanged.)
// 256 covers the 150 with ~70% headroom (3,072s ≈ 51 min of one-per-block history) and keeps
// `index`/`cardinality` inside `uint16`. Raise it only when a LONGER window is actually requested:
// the number follows the requirement, not the other way round.
//
// ⚠️ THE LOAD-BEARING CLAIM IS "THE ONLY WINDOW REQUESTED IS 1800", AND A GREP FOR LITERALS DOES
// NOT ESTABLISH IT -- two indirections hide the value: `LevBase.TWAP_WINDOW` and
// `LevMath.TWAP_WIN_M` are both 1800, and `LevMath.WbtcCfg.twapWindow` is a STRUCT FIELD (any
// value) whose construction sites are ALL in `BtcLevManager` and ALL pass `TWAP_WINDOW`.
// ⇒ Re-check that ZERO before trusting this number again. If a config field ever exceeds 3,072s the
// ring silently covers less span than the window requests, and `twapResolve`'s Chainlink
// cross-check becomes the only thing bounding the answer -- a backstop, not a substitute.
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
/// ⚠️ ONE RING PER `Core` INSTANCE, LENGTH `RING = 256` — `Core` declares exactly one `ObsState`
/// and one `Observation[RING]`. The discriminator between the ETH and BTC rings is the ADDRESS,
/// not a field (§ISBTC-SPLIT). ⛔ Do not restore *"Core runs TWO independent rings … each a
/// `Observation[65535]` array"*: both numbers were wrong, and the address is invisible to a
/// reader who trusts the header instead.
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
    ///    ⚠️ It only fires above a FUNCTION — `Core`'s `FLOW_DECAY` docblock carries one above a
    ///    VARIABLE and compiles, which is why the pattern looks safe until it is not.
    /// §V4-CUT — A RING SEEDER, NOTHING ELSE: seed `lastPrice` from the reference price and open
    /// the ring. It used to build a PoolKey/PoolId and call `pm.initialize`; with no PoolManager
    /// those became write-only vestigia and went, along with `VANILLA_*` / `POOL_ID_VANILLA_*`.
    /// ⚠️ §E253-mock also deleted `deployMocks` and Core's four per-pool mocks. ⛔ Do not restore
    /// *"the ~3.9 KB of `mock` creation-code lives in THIS library's bytecode"* — it makes anyone
    /// sizing this library wrong by ~3.9 KB, and there is no `mock` string left in this file.
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
    /// ⚠️ NO REFERENCE POOL IS READ AND NONE EXISTS: `slot0`, `IPoolManager`, `PoolKey` and
    /// `StateLibrary` have ZERO CODE occurrences in `evm/src` — every remaining hit is a comment,
    /// so grep by structure, not by name. ⛔ Do not restore *"the reference pools are still READ,
    /// deliberately"*, *"the orientation probes are CONSUMED HERE"*, or *"`wbtc` is passed in"* —
    /// all three described `prepRefs`, and `_feed18` applies the ×1e10 lift from a bool.
    /// @notice Deploy-time seed price for each range, read from CHAINLINK.
    /// @dev    §V4-ZERO — the seed price comes from CHAINLINK, not from a reference pool. Nothing
    ///         in `src/` needs `IPoolManager`, `PoolKey`, `PoolIdLibrary`, `Currency` or
    ///         `StateLibrary` any more, and the deploy config carries no `PoolKey` field.
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



    // ═══ §E318 — `ExternalTwap` FOLDED IN: 88 lines of oracle reads beside the library that
    // already owns oracle concerns and shares its only src consumer (`Core`). ═══
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
    /// ⚠️ SPOT, NOT A TWAP — no window, so manipulable within a block. It is an INDEPENDENT
    ///    OBSERVATION for cross-checking only; never SIZE anything from it.
    /// 📌 UNWIRED, ON PURPOSE — SPRINT.md §V-DOLLARS. `oneInchRateWad` and `curvePriceWad` have
    ///    ZERO call sites in `evm/src`; they were unwired before the §E318 fold and are unwired
    ///    after it. ⛔ **This is a deliberately preserved gap, not an ordinary unused helper — do
    ///    not let an "unwired code gets deleted" sweep eat it.** They are the NON-CIRCULAR
    ///    external price source that §E222's circularity (`Core` reading the ring's own TWAP
    ///    back as an anchor) needs. `internal`, so the gap costs no deployed bytes. Whoever
    ///    wires them also owns the agreement check that consumes them; none exists yet.
    function oneInchRateWad(address oracle, address src, address dst, uint8 srcDec, uint8 dstDec)
        internal view returns (uint priceWad) {
        uint rate = IOffchainOracle(oracle).getRate(src, dst, false);
        if (rate == 0) revert NoExternalPrice();
        priceWad = SoladyMath.fullMulDiv(rate, 10 ** srcDec, 10 ** dstDec);
        if (priceWad == 0) revert NoExternalPrice();
    }



}
