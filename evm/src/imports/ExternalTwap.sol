// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// Curve's on-pool EMA oracle. Returns a PLAIN PRICE (WAD) of coin `k+1` in units of coin 0 —
/// no ticks, no sqrt price, nothing to decode.
interface ICurveOracle {
    function price_oracle(uint256 k) external view returns (uint256);
    function price_oracle() external view returns (uint256);   // two-coin pools take no index
}

/// @title  ExternalTwap — the INDEPENDENT price observer, restoring what the v4 cut deleted
///
/// @notice **WHY THIS EXISTS.** Before the cut, the observation ring recorded the BAND POOL'S SPOT
///         PRICE — an actual observation of executed trades — and Chainlink was the ANCHOR checking
///         it. Two genuinely different sources, which is what made `twapResolve`'s deviation test and
///         `BasketLib.isManipulated` mean anything.
///
///         Removing the AMM removed the observation. `Core.swap` now writes the ring from
///         `AUX.getTWAPforAsset`, which reads that same ring and anchors to Chainlink — so the ring
///         records a value derived from itself plus Chainlink, and every guard compares one source
///         against a smoothed copy of itself. **Nothing reverts. The guards still run and still
///         compute; they simply lost the ability to disagree.**
///
/// @dev **WHY CURVE AND NOT A UNISWAP TWAP.** A v3 TWAP is tick-cumulative, so reading one means
///      `1.0001^tick` — i.e. `TickMath`, the exact dependency this refactor removed. Curve's
///      `price_oracle()` is a plain WAD price maintained by the pool, so it needs no decoding at
///      all. It is also a genuinely DIFFERENT mechanism from Chainlink's pushed feeds — an EMA over
///      executed trades versus a signed off-chain report — which is what makes the cross-check
///      informative rather than decorative. And we already route every swap leg through these pools,
///      so it adds no new integration surface.
///
/// ⚠️ **AN EMA IS NOT A WINDOWED TWAP, AND THE DIFFERENCE MATTERS FOR THE BOUND.** Curve's oracle
///      decays exponentially toward spot with a pool-configured half-life; it has no explicit window
///      you choose. So its manipulation profile is set by the POOL, not by us — you cannot widen the
///      window to buy safety the way you can with a v3 observation. The deviation bound must be
///      derived against that half-life, not inherited from `TWAP_MAX_DEVIATION_BPS`, which was
///      calibrated for a 30-minute windowed reading.
///
/// ⚠️ **CORRELATED SOURCES ARE ONE SOURCE.** Two stablecoin-quoted ETH pools share a depeg mode:
///      when the stable moves, both move together, in exactly the regime the guard exists for.
///      Relating the volatile legs through ONE BTC↔ETH ratio avoids compounding two USD oracle
///      errors into the number that actually matters. Count correlated readings as one observer.
/// @dev 1inch OffchainOracle — the AGGREGATED spot-rate reader. `useWrappers=false` keeps the lookup
///      on the token as given rather than letting the oracle substitute a wrapper: a substitution
///      would quietly reintroduce the wrapped-asset basis this protocol is removing (§E221).
interface IOffchainOracle {
    function getRate(address srcToken, address dstToken, bool useWrappers)
        external view returns (uint256 weightedRate);
}

library ExternalTwap {
    error DeviationTooWide(uint ours, uint theirs, uint bps);
    error NoExternalPrice();

    /// @notice Curve's EMA price for a pool coin, in WAD.
    /// @param  k  coin index for multi-coin pools (TriCrypto: 1 = WBTC, 2 = WETH against coin0 USDC).
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
        priceWad = FullMath.mulDiv(rate, 10 ** srcDec, 10 ** dstDec);
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
        uint bps = FullMath.mulDiv(hi - lo, 10_000, lo);
        if (bps > maxBps) revert DeviationTooWide(ours, theirs, bps);
    }
}
