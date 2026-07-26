// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevVenueBase, ILevERC20} from "./imports/LevVenueBase.sol";

/// ── Liquity V2 (BOLD) surface this adapter needs. Declared here (no Liquity dep in-repo). The branch's
///    AddressesRegistry is NOT a reachable public getter on the live components, so the deployer pins the
///    (borrowerOps, troveManager, bold, coll) tuple explicitly — verified on mainnet: WETH branch has
///    BO=0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65, TM=0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A,
///    BOLD=0x6440f144b7e50D6a8439336510312d2F54beB01D, coll=WETH, MCR=1.1e18, MIN_DEBT=2000e18.
interface ILiquityBorrowerOps {
    /// V2 open: owner=this adapter, a per-LP ownerIndex → deterministic troveId. Draws `_boldAmount` (≥ min
    /// debt) to `_receiver`. `_annualInterestRate` sets the trove's rate; hints are the sorted-list neighbours
    /// (0/0 = unhinted, the protocol walks the list — costlier but correct). `_maxUpfrontFee` bounds the
    /// one-time premium. add/removeManager left as this adapter (sole authority over the LP's trove).
    function openTrove(
        address _owner, uint256 _ownerIndex, uint256 _collAmount, uint256 _boldAmount,
        uint256 _upperHint, uint256 _lowerHint, uint256 _annualInterestRate,
        uint256 _maxUpfrontFee, address _addManager, address _removeManager, address _receiver
    ) external returns (uint256 troveId);
    function addColl(uint256 _troveId, uint256 _collAmount) external;
    function withdrawColl(uint256 _troveId, uint256 _collAmount) external;
    function withdrawBold(uint256 _troveId, uint256 _boldAmount, uint256 _maxUpfrontFee) external;
    function repayBold(uint256 _troveId, uint256 _boldAmount) external;
    function closeTrove(uint256 _troveId) external;
    /// Re-price an OPEN trove's interest rate (owner-only; the adapter is owner). Hints are the sorted-list
    /// neighbours (0/0 = unhinted). A too-soon change charges a premature-adjustment upfront fee (bounded).
    function adjustTroveInterestRate(uint256 _troveId, uint256 _newAnnualInterestRate,
        uint256 _upperHint, uint256 _lowerHint, uint256 _maxUpfrontFee) external;
    function MCR() external view returns (uint256); // 1e18 min collateral ratio (e.g. 1.1e18) — lives on BorrowerOps
}

interface ILiquityTroveManager {
    /// V2 exposes the entire (interest-accrued, redistribution-inclusive) trove figures ONLY via this struct —
    /// there is no `getTroveEntireDebt/Coll` getter on the live contract. Field 0 = entireDebt, field 1 =
    /// entireColl (the rest — redistribution gains, accrued interest, recorded debt, rate, fees — unused here).
    struct LatestTroveData {
        uint256 entireDebt;
        uint256 entireColl;
        uint256 redistBoldDebtGain;
        uint256 redistCollGain;
        uint256 accruedInterest;
        uint256 recordedDebt;
        uint256 annualInterestRate;
        uint256 weightedRecordedDebt;
        uint256 accruedBatchManagementFee;
        uint256 lastInterestRateAdjTime;
    }
    function getLatestTroveData(uint256 _troveId) external view returns (LatestTroveData memory);
    function getTroveStatus(uint256 _troveId) external view returns (uint8); // 0 nonExistent,1 active,2 closedByOwner,3 closedByLiq,4 closedByRedemption,...
}

/// @title  LiquityTroveVenue — per-LP isolated Liquity-V2 Trove as an `ILevVenue` (collateral WETH, debt BOLD)
/// @notice The LONG borrow venue for the leverage overlay backed by a Liquity V2 branch: each LP gets its
///         OWN Trove (owner = this adapter, a per-LP ownerIndex → deterministic troveId), so one LP's
///         liquidation/redemption can never touch another's — exactly the EulerEscrowVenue sub-account model,
///         but with a Trove. Draws BOLD, which LevManager IMMEDIATELY swaps to WETH collateral via the external
///         SOR to build the levered LONG — no idle BOLD is ever held, so there is nothing to park in a Stability
///         Pool. (UP-SIDE-ONLY: the below-entry short hedge was removed 2026-07-24 as an LVR leak; a long LP holds
///         through the dip and de-levers to 1× only to avoid liquidation. See docs §J.4.) (`SorExchange` is a
///         SEPARATE optional adapter — it makes QU!D's SOR a swap venue for Liquity's OWN LeverageWETHZapper;
///         unrelated to this venue.)
///
///         MIN-DEBT FLOOR (the one real Liquity impedance): V2 `openTrove` requires an initial BOLD draw ≥
///         `MIN_DEBT` and forbids `repayBold` below it (only `closeTrove` clears it). So the FIRST `supply`
///         opens the trove with `MIN_DEBT` BOLD which the adapter HOLDS (`pendingBold[lp]`); `borrow` delivers
///         that held BOLD first (then `withdrawBold` for more), and `debtOf` nets it out so LevManager only
///         ever sees the debt actually delivered. `repay` clamps at the floor; a repay that would clear the
///         trove `closeTrove`s it (repaying the floor from the held/supplied BOLD) and returns the collateral.
///
///         Custody (per ILevVenue): MANAGER transfers WETH/BOLD IN before supply/repay; the adapter sends
///         withdrawn WETH / borrowed BOLD back to MANAGER. No LP cap (uint256 ownerIndex space).
contract LiquityTroveVenue is LevVenueBase {
    ILiquityBorrowerOps public immutable BORROWER_OPS;
    ILiquityTroveManager public immutable TROVE_MANAGER;
    address public immutable COLLATERAL;        // branch collateral (WETH)

    // DEFAULT per-trove interest rate + fee bounds. Chosen conservative (generous fee cap) so opens/adjusts never
    // revert on the upfront-fee bound. This is the FALLBACK rate; each borrower may set their OWN via
    // `setInterestRate` (the rate they pay IS the borrower's choice in Liquity V2 — it sets redemption priority).
    uint256 public immutable ANNUAL_RATE;       // 1e18-scaled default (e.g. 0.05e18 = 5%)
    uint256 public immutable MIN_DEBT;          // branch min net debt (BOLD, 1e18)
    // Liquity V2 branch interest-rate bounds (MIN_ANNUAL_INTEREST_RATE = 0.5%, MAX = 250%). Borrower rates clamp
    // here so a bad input never reverts the whole open.
    uint256 internal constant MIN_RATE = 5e15;     // 0.5%
    uint256 internal constant MAX_RATE = 250e16;   // 250%

    mapping(address => uint256) public troveIdOf;   // lp → troveId (0 = no trove)
    mapping(address => uint256) public pendingBold;  // lp → BOLD drawn at open, not yet delivered to MANAGER
    mapping(address => uint256) public rateOf;       // lp → chosen annual rate (0 = use ANNUAL_RATE default)
    uint256 public nextIndex = 1;                    // per-LP ownerIndex (0 reserved)

    /// @param borrowerOps  Liquity V2 branch BorrowerOperations.
    /// @param troveManager Liquity V2 branch TroveManager.
    /// @param bold         the branch BOLD token (== stable()).
    /// @param coll         the branch collateral (WETH).
    /// @param manager      LevManager (the sole caller).
    /// @param annualRate   per-trove interest rate (1e18); minDebt the branch min net debt (BOLD, 1e18 = 2000e18).
    constructor(address borrowerOps, address troveManager, address bold, address coll,
                address manager, uint256 annualRate, uint256 minDebt)
        LevVenueBase(manager, bold)
    {
        BORROWER_OPS = ILiquityBorrowerOps(borrowerOps);
        TROVE_MANAGER = ILiquityTroveManager(troveManager);
        COLLATERAL = coll;
        ANNUAL_RATE = annualRate;
        MIN_DEBT = minDebt;
        // One-time max approvals to the trusted BorrowerOperations: collateral (coll + any WETH gas-comp on
        // open) and BOLD (repay/close). Avoids per-call approves and covers Liquity's separate gas-comp pull.
        ILevERC20(coll).approve(borrowerOps, type(uint256).max);
        ILevERC20(bold).approve(borrowerOps, type(uint256).max);
    }

    /// @notice The BORROWER sets the annual interest rate they pay (Liquity V2 makes this the trove owner's
    ///         choice — a lower rate is redeemed first, a higher rate pays more but is safer from redemption).
    ///         msg.sender IS the LP, keyed to their own position: sets the rate used when their trove OPENS, and
    ///         if the trove already exists, re-prices it live via Liquity's owner-only adjust (bounded upfront
    ///         fee). Clamped to the branch's [MIN_RATE, MAX_RATE] so a bad input can never revert the open.
    function setInterestRate(uint256 annualRate) external nonReentrant {
        uint256 r = annualRate < MIN_RATE ? MIN_RATE : (annualRate > MAX_RATE ? MAX_RATE : annualRate);
        rateOf[msg.sender] = r;
        uint256 id = troveIdOf[msg.sender];
        if (id != 0) BORROWER_OPS.adjustTroveInterestRate(id, r, 0, 0, type(uint256).max);
    }

    /// The rate for `lp`'s trove: their chosen `rateOf`, or the venue default when unset.
    function _rate(address lp) internal view returns (uint256) {
        uint256 r = rateOf[lp];
        return r == 0 ? ANNUAL_RATE : r;
    }

    // ── ILevVenue ────────────────────────────────────────────────────────────────
    function supply(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        uint256 id = troveIdOf[lp];
        if (id == 0) {
            // Open the LP's trove: coll + the MIN_DEBT floor draw (held here, delivered on the first borrow).
            uint256 before = ILevERC20(STABLE).balanceOf(address(this));
            id = BORROWER_OPS.openTrove(
                address(this), nextIndex, collAmount, MIN_DEBT,
                0, 0, _rate(lp), type(uint256).max, address(this), address(this), address(this));
            unchecked { nextIndex++; }
            troveIdOf[lp] = id;
            pendingBold[lp] = ILevERC20(STABLE).balanceOf(address(this)) - before;  // actual drawn (net upfront fee)
        } else {
            BORROWER_OPS.addColl(id, collAmount);
        }
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        uint256 id = troveIdOf[lp];
        if (id == 0 || stableAmount == 0) return 0;
        uint256 sent;
        // 1) Deliver the floor BOLD held from open, first.
        uint256 pend = pendingBold[lp];
        if (pend > 0) {
            sent = stableAmount < pend ? stableAmount : pend;
            pendingBold[lp] = pend - sent;
        }
        // 2) Draw the remainder from the trove.
        uint256 more = stableAmount - sent;
        if (more > 0) {
            uint256 before = ILevERC20(STABLE).balanceOf(address(this));
            BORROWER_OPS.withdrawBold(id, more, type(uint256).max);
            sent += ILevERC20(STABLE).balanceOf(address(this)) - before;             // actual (net upfront fee)
        }
        if (sent > 0) ILevERC20(STABLE).transfer(MANAGER, sent);
        return sent;
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        uint256 id = troveIdOf[lp];
        if (id == 0 || stableAmount == 0) return 0;
        ILiquityTroveManager.LatestTroveData memory d = TROVE_MANAGER.getLatestTroveData(id); // one read: debt + coll
        uint256 entire = d.entireDebt;
        uint256 pend = pendingBold[lp];
        // The floor (MIN_DEBT) can't be repaid below without closing. Repayable-in-place = debt above floor.
        uint256 repayable = entire > MIN_DEBT ? entire - MIN_DEBT : 0;
        uint256 r = stableAmount > repayable ? repayable : stableAmount;
        if (r > 0) {
            BORROWER_OPS.repayBold(id, r);   // BOLD pushed in by MANAGER; BorrowerOps holds a constructor max-approve
        }
        // A full de-lever (caller sent enough to cover the whole net-delivered debt) CLOSES the trove: the
        // net-delivered debt is `entire - pend` (pend is BOLD the LP never received). Close when the caller's
        // stable covers that and the position is being fully unwound (repayable exhausted, coll then withdrawn).
        uint256 leftIn = ILevERC20(STABLE).balanceOf(address(this));   // already includes the still-held `pend`
        uint256 netDebt = entire > pend ? entire - pend : 0;
        if (r == repayable && leftIn + r >= netDebt && netDebt > 0 && d.entireColl > 0) {
            // Enough on hand to clear the floor too → close, returning collateral to MANAGER.
            uint256 needFloor = TROVE_MANAGER.getLatestTroveData(id).entireDebt; // == MIN_DEBT + interest, post-repay
            if (leftIn >= needFloor) {                              // `pend` is part of `leftIn` — do NOT re-add it
                uint256 cBefore = ILevERC20(COLLATERAL).balanceOf(address(this)); // BOLD max-approved in ctor
                BORROWER_OPS.closeTrove(id);
                troveIdOf[lp] = 0; pendingBold[lp] = 0;
                uint256 coll = ILevERC20(COLLATERAL).balanceOf(address(this)) - cBefore;
                if (coll > 0) ILevERC20(COLLATERAL).transfer(MANAGER, coll);
                r += needFloor;   // report the floor repayment too
            }
        }
        return r;
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        uint256 id = troveIdOf[lp];
        if (id == 0 || collAmount == 0) return 0;
        uint256 bal = TROVE_MANAGER.getLatestTroveData(id).entireColl;
        uint256 w = collAmount > bal ? bal : collAmount;
        if (w == 0) return 0;
        uint256 before = ILevERC20(COLLATERAL).balanceOf(address(this));
        BORROWER_OPS.withdrawColl(id, w);
        uint256 got = ILevERC20(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) ILevERC20(COLLATERAL).transfer(MANAGER, got);
        return got;
    }

    // ── PROTOCOL TROVE — the depth-INDEPENDENT BOLD source for closing a levered LP ────────────────────────
    // A single venue-OWNED trove (never an LP's), from which the MANAGER draws BOLD to repay a closing LP's own
    // trove — instead of flashing thin BOLD (Morpho holds ~1052) or selling WETH→BOLD on a shallow DEX. It mints
    // at FACE VALUE (Liquity), so the close is depth-independent at any size. The trove PERSISTS holding
    // {WETH, BOLD debt} as the protocol's aggregate leverage COUNTERPARTY (the accepted trader-vs-LP model). The
    // WETH locked BEYOND the BOLD's face value (Liquity over-collateralization) is funded by the MANAGER from
    // protocol capital — never an LP — so the closing LP always receives full FAIR equity.
    uint256 public protocolTroveId;
    uint256 public protocolPending;   // MIN_DEBT floor BOLD drawn at protocol-trove open, not yet delivered

    /// Marker: lets LevManager detect that this venue mints its OWN debt for closing (flash WETH → mint, not
    /// flash-the-thin-stable → sell). Only this adapter returns true; the try/catch on others yields false.
    function usesMintClose() external pure returns (bool) { return true; }

    /// @notice Draw `boldWanted` BOLD from the protocol trove against manager-pushed `wethIn` WETH (already
    ///         transferred in), and send it to the MANAGER. Opens the protocol trove on first use (coll = wethIn
    ///         + the forced MIN_DEBT floor draw, held here and delivered first), else `addColl`s. `wethIn` is
    ///         sized by the manager to keep the protocol trove safely over-collateralized; the excess WETH stays
    ///         locked here as the trove's own equity (funded by the manager, not the LP). Mirrors supply+borrow.
    function mintForClose(uint256 wethIn, uint256 boldWanted)
        external onlyManager nonReentrant returns (uint256 boldOut)
    {
        if (boldWanted == 0) return 0;
        uint256 id = protocolTroveId;
        if (id == 0) {
            uint256 before = ILevERC20(STABLE).balanceOf(address(this));
            id = BORROWER_OPS.openTrove(
                address(this), nextIndex, wethIn, MIN_DEBT,
                0, 0, ANNUAL_RATE, type(uint256).max, address(this), address(this), address(this));
            unchecked { nextIndex++; }
            protocolTroveId = id;
            protocolPending = ILevERC20(STABLE).balanceOf(address(this)) - before;  // actual drawn (net upfront fee)
        } else {
            BORROWER_OPS.addColl(id, wethIn);
        }
        // Deliver the held floor BOLD first, then draw the remainder from the trove (mirrors `borrow`).
        uint256 pend = protocolPending;
        if (pend > 0) {
            boldOut = boldWanted < pend ? boldWanted : pend;
            protocolPending = pend - boldOut;
        }
        uint256 more = boldWanted - boldOut;
        if (more > 0) {
            uint256 b = ILevERC20(STABLE).balanceOf(address(this));
            BORROWER_OPS.withdrawBold(id, more, type(uint256).max);
            boldOut += ILevERC20(STABLE).balanceOf(address(this)) - b;               // actual (net upfront fee)
        }
        if (boldOut > 0) ILevERC20(STABLE).transfer(MANAGER, boldOut);
    }

    function debtOf(address lp) external view returns (uint256) {
        uint256 id = troveIdOf[lp];
        if (id == 0) return 0;
        if (TROVE_MANAGER.getTroveStatus(id) != 1) return 0;    // closed by owner/liq/redemption → no live debt
        uint256 entire = TROVE_MANAGER.getLatestTroveData(id).entireDebt;
        uint256 pend = pendingBold[lp];
        return entire > pend ? entire - pend : 0;               // net of the still-held floor draw
    }

    function collateralOf(address lp) external view returns (uint256) {
        uint256 id = troveIdOf[lp];
        if (id == 0 || TROVE_MANAGER.getTroveStatus(id) != 1) return 0;
        return TROVE_MANAGER.getLatestTroveData(id).entireColl;
    }

    /// Liquity MCR is a 1e18 minimum COLLATERAL ratio (e.g. 1.1e18 = 110%). The ILevVenue LLTV is the inverse
    /// max loan-to-value in bps: 10000·1e18 / MCR (110% MCR → ~9090 bps).
    function liqThresholdBps() external view returns (uint256) {
        uint256 mcr = BORROWER_OPS.MCR();   // MCR getter is on BorrowerOperations, not TroveManager
        return mcr == 0 ? 0 : (10000 * 1e18) / mcr;
    }
}
