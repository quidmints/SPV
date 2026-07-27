// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVogueShares {
    function lpShares() external view returns (uint);
    function balanceOf(address user) external view returns (uint);
    function convertToShares(uint assets) external view returns (uint);
    function convertToAssets(uint shares) external view returns (uint);
}

interface IAuxBacking { function vogueETH() external view returns (uint); }

/// @title  VEth — the ERC-4626 identity of the vETH LP position, segregated out of `Vogue` (§J.2b).
///
/// @notice WHY THIS EXISTS. `Vogue` is the BAND MANAGER for BOTH asset classes: its math is parameterised
///         by `isBTC` throughout (`kLvrWad(bool)`, `derivedThetaWad(bool)`, `realizedVarianceWad(bool)`,
///         `bandSqrtP(bool)`, `vogueOp(bool, ...)`). A contract that manages two asset classes CANNOT
///         honestly implement ERC-4626, which is defined around ONE `asset()`. Vogue nevertheless used to
///         declare `asset() => WETH`, `name = "QU!D Vogue ETH LP"` and the full `max*`/`preview*` surface,
///         so any 4626-aware integrator (aggregator, router, pricing venue) would read the ETH identity
///         and silently mis-account the BTC side. That claim now lives HERE, where it is true.
///
///         WHY THIS IS A PROJECTION AND NOT A VAULT — the asymmetry with `VBtc.sol`. `VBtc` OWNS its
///         balances and supply, because the vBTC token face had merely been FUSED onto `Vault` and
///         nothing else read it. vETH is the opposite: its "balances" ARE `Vogue.autoManaged[].pooled`
///         and its "supply" IS `Vogue.lpShares` — LOAD-BEARING BAND STATE read by `exposeToLev`, the
///         withdraw ladder, `ethfiBacked`, and the `_pricingBacking` numerator. Relocating that storage
///         would not be a face-split; it would move the accounting core across a call boundary and put
///         an external call inside the same-clock invariant repaired in §A.16b. So this contract holds
///         NO state: every balance, supply and conversion is READ THROUGH Vogue, which remains the
///         single source of truth and the transfer authority.
///
///         SCOPE — VIEWS ONLY, DELIBERATELY. The 4626 IDENTITY and the read surface live here; the
///         ENTRYPOINTS (`deposit`/`mint`/`withdraw`/`redeem`) deliberately stay on `Vogue`, because they
///         are the protocol's native LP API: they carry the per-deposit `venue` selector, the payable
///         ETH path, and route through `_depositImpl`/`_withdraw` (checkBacking, _rebalance, addLiq,
///         JIT-defense, AUX.take). Forwarding them through here would add a WETH pull-and-re-approve hop
///         and change the allowance flow users already have — a separate decision, not a free side
///         effect of splitting the identity. Integrators price against this contract and transact
///         against Vogue; `VOGUE` below is the public pointer that makes that unambiguous.
contract VEth {
    string public constant name     = "QU!D Vogue ETH LP";
    string public constant symbol   = "vETH";
    /// vETH shares are ETH-denominated, matching WETH.
    uint8  public constant decimals = 18;

    /// The band manager that owns the actual share state. Also the address to TRANSACT against.
    IVogueShares public immutable VOGUE;
    /// The single asset this identity is defined over — the whole point of the split.
    address      public immutable WETH;
    /// Backing oracle: `vogueETH()` is Vogue's live venue-side ETH balance.
    IAuxBacking  public immutable AUX;

    constructor(address vogue, address weth, address aux) {
        VOGUE = IVogueShares(vogue); WETH = weth; AUX = IAuxBacking(aux);
    }

    function asset() external view returns (address) { return WETH; }

    /// @notice Total ETH-equivalent backing all LP positions: principal + ALL accrued V4/Morpho fees,
    ///         claimed or not. Note this is `vogueETH()` RAW — the same value Vogue reported before the
    ///         split. It is deliberately NOT `_pricingBacking()`, which restates the levered book onto
    ///         the denominator's clock for SHARE PRICING (§A.16b); conversions below inherit that
    ///         restatement by delegating to Vogue rather than recomputing it here.
    function totalAssets() external view returns (uint) { return AUX.vogueETH(); }

    function totalSupply() external view returns (uint) { return VOGUE.lpShares(); }
    function balanceOf(address user) external view returns (uint) { return VOGUE.balanceOf(user); }

    /// Conversions delegate so the §A.16b same-clock pricing has exactly ONE implementation.
    function convertToShares(uint assets) public view returns (uint) { return VOGUE.convertToShares(assets); }
    function convertToAssets(uint shares) public view returns (uint) { return VOGUE.convertToAssets(shares); }

    function maxDeposit(address) external pure returns (uint) { return type(uint).max; }
    function maxMint(address) external pure returns (uint) { return type(uint).max; }
    function previewDeposit(uint assets) external view returns (uint) { return convertToShares(assets); }
    function previewMint(uint shares) external view returns (uint) { return convertToAssets(shares); }
    function maxWithdraw(address owner) external view returns (uint) { return convertToAssets(VOGUE.balanceOf(owner)); }
    function previewWithdraw(uint assets) external view returns (uint) { return convertToShares(assets); }
    function maxRedeem(address owner) external view returns (uint) { return VOGUE.balanceOf(owner); }
    function previewRedeem(uint shares) external view returns (uint) { return convertToAssets(shares); }
}
