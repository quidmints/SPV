// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {ICurveOracle, IOffchainOracle} from "./Interfaces.sol";

library ExternalTwap {
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
    ///       decorative. A bound for this source belongs in the 37–74 bps band and must be restated
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
