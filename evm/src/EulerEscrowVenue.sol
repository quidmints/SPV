// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevVenueBase, ILevERC20} from "./imports/LevVenueBase.sol";

/// Minimal Euler EVK vault surface (subset of ybamm's IEVault) used by the IL-protect.
interface IEVault {
    function asset() external view returns (address);
    function EVC() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function LTVBorrow(address collateral) external view returns (uint16);
    function LTVLiquidation(address collateral) external view returns (uint16);
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256);
    function borrow(uint256 amount, address receiver) external returns (uint256);
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// Minimal Euler Vault Connector surface. `batch` sets the on-behalf-of context to
/// `onBehalfOfAccount` for each item — the only way to borrow/withdraw FROM a sub-account.
interface IEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }
    function batch(BatchItem[] calldata items) external payable;
    function enableCollateral(address account, address vault) external payable;
    function enableController(address account, address vault) external payable;
    function isCollateralEnabled(address account, address vault) external view returns (bool);
    function isControllerEnabled(address account, address vault) external view returns (bool);
}

/// @title  EulerEscrowVenue — generic ESCROW-collateral / stable-debt `ILevVenue` for the IL-protect (collateral is the vault asset: weETH on ETH, vBTC on BTC)
/// @notice Per-LP ISOLATED leverage on a real Euler EVK market: each LP gets its OWN EVC **sub-account**
///         (`address(this) ^ subId`), so one LP's liquidation can never cascade into another's — and it
///         hits that LP's external account, never the QU!D basket. This is the on-chain arm of the
///         keeper-managed `L=1/α` IL-protect (see docs/actionable/LEVERAGE-ENGINE-SPEC.md).
///
///         INVARIANT #1 (rehypothecation): `collVault` MUST be an **escrow** EVK vault — it holds the
///         weETH and never re-lends it (weETH still earns ether.fi staking *intrinsically*, since the
///         token appreciates, but the underlying ETH is never lent to a borrower). The constructor cannot
///         prove escrow-ness on-chain (it's a vault-config property), so it is the DEPLOYER's
///         responsibility; passing a borrowable collateral vault re-introduces the double-lend the whole
///         weETH design exists to avoid. We DO assert the market is configured (`LTVBorrow != 0`) and the
///         vault assets match.
///
///         Custody (per ILevVenue): `LevManager` transfers weETH/stable IN before `supply`/`repay`; the
///         adapter sends withdrawn weETH / borrowed stable back to `LevManager`. v1 caps at 255 LPs (the
///         EVC sub-account space of one owner address); beyond that, deploy another adapter instance.
contract EulerEscrowVenue is LevVenueBase {
    IEVault public immutable COLL_VAULT;   // weETH ESCROW collateral vault
    IEVault public immutable DEBT_VAULT;   // stable debt/controller vault
    IEVC    public immutable EVC;
    address public immutable COLLATERAL;        // collateral token (== COLL_VAULT.asset())

    mapping(address => uint8) public subIdOf;  // lp → sub-account id (0 = unallocated)
    uint8 public nextSub = 1;                   // 0 reserved for the adapter's own account

    error MarketUnconfigured();
    error SubAccountsExhausted();
    error SharedEvc();

    constructor(address collVault, address debtVault, address manager)
        LevVenueBase(manager, IEVault(debtVault).asset())
    {
        IEVault cv = IEVault(collVault);
        IEVault dv = IEVault(debtVault);
        if (dv.LTVBorrow(collVault) == 0) revert MarketUnconfigured();   // market configured
        if (cv.EVC() != dv.EVC()) revert SharedEvc();                    // shared EVC
        COLL_VAULT = cv;
        DEBT_VAULT = dv;
        EVC = IEVC(cv.EVC());
        COLLATERAL = cv.asset();
    }

    // ── sub-account isolation ────────────────────────────────────────────────────
    /// Allocate (first time) + return `lp`'s isolated EVC sub-account, enabling its
    /// collateral + controller on first use.
    function _sub(address lp) internal returns (address sub) {
        uint8 id = subIdOf[lp];
        if (id == 0) {
            id = nextSub;
            if (id == 0) revert SubAccountsExhausted(); // wrapped past 255
            subIdOf[lp] = id;
            unchecked { nextSub = id + 1; }             // wraps to 0 after 255 → next alloc reverts
            sub = _subAddr(id);
            EVC.enableCollateral(sub, address(COLL_VAULT));
            EVC.enableController(sub, address(DEBT_VAULT));
        } else {
            sub = _subAddr(id);
        }
    }
    function _subAddr(uint8 id) internal view returns (address) {
        return address(uint160(address(this)) ^ uint160(uint256(id)));
    }
    /// View-only sub-account (0 if `lp` never supplied).
    function _subView(address lp) internal view returns (address) {
        uint8 id = subIdOf[lp];
        return id == 0 ? address(0) : _subAddr(id);
    }

    // ── ILevVenue ────────────────────────────────────────────────────────────────
    function supply(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        address sub = _sub(lp);
        ILevERC20(COLLATERAL).approve(address(COLL_VAULT), collAmount); // weETH already transferred in by MANAGER
        COLL_VAULT.deposit(collAmount, sub);                       // shares minted to the LP's sub-account
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;
        address sub = _sub(lp);
        uint256 before = ILevERC20(STABLE).balanceOf(address(this));
        // Borrow ON BEHALF OF the LP's sub-account (so the debt + the health check are the LP's),
        // delivering the stable to this adapter; the minimal EVC.batch returns nothing, so measure
        // the actual stable received by balance delta.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(DEBT_VAULT),
            onBehalfOfAccount: sub,
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, stableAmount, address(this))
        });
        EVC.batch(items);
        uint256 got = ILevERC20(STABLE).balanceOf(address(this)) - before;
        if (got > 0) ILevERC20(STABLE).transfer(MANAGER, got);
        return got;
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        address sub = _subView(lp);
        if (sub == address(0) || stableAmount == 0) return 0;
        uint256 d = DEBT_VAULT.debtOf(sub);
        uint256 r = stableAmount > d ? d : stableAmount; // never over-repay
        if (r == 0) return 0;
        ILevERC20(STABLE).approve(address(DEBT_VAULT), r); // stable already transferred in by MANAGER
        DEBT_VAULT.repay(r, sub);                          // reduces the sub-account's debt
        return r;
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        address sub = _subView(lp);
        if (sub == address(0) || collAmount == 0) return 0;
        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount;   // capped at the position
        if (w == 0) return 0;
        uint256 before = ILevERC20(COLLATERAL).balanceOf(address(this));
        // Withdraw ON BEHALF OF the sub-account (the post-withdraw health check is the LP's),
        // delivering weETH to this adapter; measure by balance delta.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(COLL_VAULT),
            onBehalfOfAccount: sub,
            value: 0,
            data: abi.encodeWithSelector(IEVault.withdraw.selector, w, address(this), sub)
        });
        EVC.batch(items);
        uint256 got = ILevERC20(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) ILevERC20(COLLATERAL).transfer(MANAGER, got);
        return got;
    }

    function debtOf(address lp) external view returns (uint256) {
        address sub = _subView(lp);
        return sub == address(0) ? 0 : DEBT_VAULT.debtOf(sub);
    }

    function collateralOf(address lp) public view returns (uint256) {
        address sub = _subView(lp);
        if (sub == address(0)) return 0;
        return COLL_VAULT.convertToAssets(COLL_VAULT.balanceOf(sub)); // weETH assets (1e18)
    }


    /// Euler EVK LTVs are uint16 on a 1e4 scale (10000 = 100%), i.e. already bps.
    function liqThresholdBps() external view returns (uint256) {
        return uint256(DEBT_VAULT.LTVLiquidation(address(COLL_VAULT)));
    }
}
