// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAux} from "./imports/Interfaces.sol";

/// @title  LevOracles — the Morpho `IOracle` price sources DeployL1_s deploys INLINE for the
///         lev-overlay markets that CANNOT pre-exist the stack (they price through AUX / are
///         markets only QU!D creates), promoted verbatim from their fork-proof tests.
/// @notice Correct-by-construction deploy: `MORPHO_VBTC_ORACLE` can never be a pre-supplied env
///         address — it prices vBTC through `Aux.getTWAPforAsset`, and AUX is deployed inside the
///         same broadcast. Same for the two INVERSE short-market oracles (no live USDC-collateral
///         WETH/WBTC-loan market exists on mainnet — verified via the Morpho API, 2026-07-21).
///         The long weETH/WETH markets are NOT here: those join the LIVE deep Morpho markets
///         (their battle-tested oracles are the env defaults in DeployL1_s).

interface IChainlinkFeed { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }

/// @notice No usable price. These are Morpho `IOracle` implementations, so MORPHO calls them — which
///         makes the failure mode a security decision, not a style one (BUILD-QUEUE §A.13/§A.25):
///           • RETURNING 0 would have Morpho value collateral at zero ⇒ EVERY position instantly
///             liquidatable ⇒ irreversible value destruction.
///           • PANICKING (division by zero) reverts Morpho's calls too, but with an undiagnosable
///             `Panic(0x12)` and after burning all forwarded gas.
///         REVERTING with a named error is the safe failure: Morpho cannot price, so new borrows and
///         liquidations halt, and everything RESUMES once the feed recovers. A frozen market is
///         recoverable; a mass liquidation at a false zero is not.
error NoPrice();

/// @notice REAL Morpho IOracle for the vBTC/USDC market (collateral→loan, 1e36-scaled), from the SAME live
///   source the manager values vBTC through: `getTWAPforAsset(WBTC)` (USD18 per 1e18-raw, WBTC-lifted ×1e10).
///   vBTC is 8-dec sats: `sats · twap / 1e18 = USD18`; Morpho wants `sats · price / 1e36 = USDC6 = USD18/1e12`
///   ⇒ price = twap × 1e6. Fork-proven (incl. real Morpho seizure off this price) in test/VBtcLevFeeLane.t.sol.
contract RealRateBtcMorphoOracle {
    address public immutable AUX;
    address public immutable WBTC;
    constructor(address aux, address wbtc) { AUX = aux; WBTC = wbtc; }
    function price() external view returns (uint256) {
        uint256 twap = IAux(AUX).getTWAPforAsset(WBTC, 1800);
        if (twap == 0) revert NoPrice();   // 0 would value all vBTC collateral at zero — see NoPrice
        return twap * 1e6;
    }
}

// ⛔ (E189) THE TWO **INVERSE** (SHORT-LEG) ORACLES ARE DELETED — `InverseRateBtcMorphoOracle`
// and `InverseRateMorphoOracle`. Both served the SHORT leg, which is gone (CLAUDE.md lists it
// among the removed mechanisms), and neither was referenced anywhere in `src/` or `script/` —
// only `RealRateBtcMorphoOracle` is deployed (`DeployL1_s.sol:41`). Standing rule 1: no
// unreachable code.
//
// 🔑 AND THIS REMOVES THE LAST ETH/USD CHAINLINK DEPENDENCY IN THE PROTOCOL. `InverseRateMorphoOracle`
// was the only live-looking consumer of an ETH/USD feed, and it was wiring nothing. What
// remains is exactly the intended posture (owner, 2026-08-12):
//
//   • the two volatile legs relate to each other through ONE BTC↔ETH relation — never through
//     two USD legs, which would compound two independent oracle errors into the one ratio that
//     actually matters, and would double-count dollar risk;
//   • the DOLLAR side comes from the basket itself, whose peg is already monitored by
//     `FeeLib.liveDepegBps` — a CIRCUIT BREAKER, not a price source, which defers on a stale
//     feed rather than inflicting a haircut;
//   • so Chainlink is never asked "what is ETH worth" — only "is the dollar still a dollar".
//
// ⚠️ Morpho adapters are the one place a USD leg can be forced on us: a market pairing USDC
// against WETH demands a collateral→loan price in ITS terms. That is a property of the external
// venue, not of our design, and it must not leak back into internal pricing.
