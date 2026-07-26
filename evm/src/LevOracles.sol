// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  LevOracles — the Morpho `IOracle` price sources DeployL1_s deploys INLINE for the
///         lev-overlay markets that CANNOT pre-exist the stack (they price through AUX / are
///         markets only QU!D creates), promoted verbatim from their fork-proof tests.
/// @notice Correct-by-construction deploy: `MORPHO_VBTC_ORACLE` can never be a pre-supplied env
///         address — it prices vBTC through `Aux.getTWAPforAsset`, and AUX is deployed inside the
///         same broadcast. Same for the two INVERSE short-market oracles (no live USDC-collateral
///         WETH/WBTC-loan market exists on mainnet — verified via the Morpho API, 2026-07-21).
///         The long weETH/WETH markets are NOT here: those join the LIVE deep Morpho markets
///         (their battle-tested oracles are the env defaults in DeployL1_s).

interface IAuxTwap { function getTWAPforAsset(address asset, uint32 period) external view returns (uint256); }
interface IChainlinkFeed { function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }

/// @notice REAL Morpho IOracle for the vBTC/USDC market (collateral→loan, 1e36-scaled), from the SAME live
///   source the manager values vBTC through: `getTWAPforAsset(WBTC)` (USD18 per 1e18-raw, WBTC-lifted ×1e10).
///   vBTC is 8-dec sats: `sats · twap / 1e18 = USD18`; Morpho wants `sats · price / 1e36 = USDC6 = USD18/1e12`
///   ⇒ price = twap × 1e6. Fork-proven (incl. real Morpho seizure off this price) in test/VBtcLevFeeLane.t.sol.
contract RealRateBtcMorphoOracle {
    address public immutable AUX;
    address public immutable WBTC;
    constructor(address aux, address wbtc) { AUX = aux; WBTC = wbtc; }
    function price() external view returns (uint256) {
        return IAuxTwap(AUX).getTWAPforAsset(WBTC, 1800) * 1e6;
    }
}

/// @notice INVERSE Morpho oracle for the BTC down-side SHORT market {collateral: USDC (6-dec), loan: WBTC (8-dec)}.
///   Morpho wants `collateralAmount(6d) · price / 1e36 = loanValue in WBTC-raw`. With `twap = getTWAPforAsset(WBTC)`
///   (USD18 per 1e18-raw, WBTC-lifted ×1e10 ⇒ plain USD/WBTC = twap/1e28): 1 USDC-raw (1e6) = 1e36/twap WBTC-raw
///   ⇒ price = 1e66 / twap. (Sanity: BTC=$60k ⇒ twap=6e32 ⇒ $1 = 1.67e-5 WBTC. ✓) Fork-proven in
///   test/VBtcLevFeeLane.t.sol.
contract InverseRateBtcMorphoOracle {
    address public immutable AUX;
    address public immutable WBTC;
    constructor(address aux, address wbtc) { AUX = aux; WBTC = wbtc; }
    function price() external view returns (uint256) {
        return 1e66 / IAuxTwap(AUX).getTWAPforAsset(WBTC, 1800);
    }
}

/// @notice INVERSE Morpho IOracle for the ETH SHORT leg's market {collateral: USDC (6-dec), loan: WETH (18-dec)}.
///   `price()` = collateral→loan, 1e36-scaled: `collateral·price/1e36` = loan units ⇒ for 1 USDC (=$1) that is
///   `1e18/ethUsd` wei, so `price = 1e48/ethUsd = 1e56/p` (p = the real Chainlink ETH/USD, 8-dec — the same
///   anchor AUX pins for WETH, so the short's Morpho health and the manager's sizing move together).
///   Fork-proven in test/LevYbReal.t.sol (testReal_Bidirectional_ShortClose).
contract InverseRateMorphoOracle {
    IChainlinkFeed public immutable ETH_USD;
    constructor(address ethUsd) { ETH_USD = IChainlinkFeed(ethUsd); }
    function price() external view returns (uint256) {
        (, int256 p,,,) = ETH_USD.latestRoundData();
        return 1e56 / uint256(p);
    }
}
