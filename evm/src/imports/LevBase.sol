// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
import {ILevVenue} from "./ILevVenue.sol";
import {IAux} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";

/// @title  LevBase — the per-LP position registry both lev managers duplicated
///
/// @notice §A.71 STEP 3. `LevManager` and `BtcLevManager` each carried their own copy of this
///         registry: the same `pos` mapping, the same open-LP enumeration, the same target-LTV cap
///         and the same four functions. 15 of 33 bodies scored as near-duplicates, and these four
///         differed ONLY cosmetically — `uint256` vs `uint`, a parameter named `capBps` vs `cap`,
///         and one `address(AUX)` cast. One implementation now, two instances.
///
///         TWO RESIDUALS WERE SETTLED BY MEASUREMENT, NOT TASTE, BECAUSE BOTH ANSWERS COST SOMETHING:
///         • `AUX` was `IAux` in one manager and `address` in the other — which is exactly why
///           `swapOutDeleverAmt` read `_fromUsd(address(AUX), …)` on one side and `_fromUsd(AUX, …)`
///           on the other. Unified on `IAux`: ABI-SAFE, since both forms generate an
///           address-returning getter.
///         • `TARGET_LTV_CAP_BPS` was `internal` in one and `public` in the other. `internal` would
///           have DELETED BtcLevManager's existing public getter — an ABI break. `public` only adds a
///           getter to LevManager, and measurement says it can afford one: 24,352 bytes with 224 to
///           spare (CLAUDE.md's "70 bytes" line is stale). So `public` is both the compatible answer
///           and the affordable one. ⚠️ Re-run tools/check-contract-sizes.py after any addition here:
///           224 bytes is headroom, not licence, and `forge test` does NOT enforce EIP-170.
///
///         ⚠️ `_openLps` / `_lpIdx` are `internal`, not `private`, ONLY because a derived contract
///         cannot see a `private` member. No ABI consequence — neither visibility emits a getter.
///         ⚠️ `pos` is PUBLIC, so its generated getter is an ABI-visible 6-tuple. Do not reorder
///         `Types.Pos`'s fields for tidiness; clients decode by position.
abstract contract LevBase {
    /// TWAP window both sides price against. Identical (1800) in each manager; PUBLIC here because
    /// BtcLevManager already exposed a getter and removing it would be an ABI break, while adding one
    /// to LevManager is affordable (317 bytes of margin, measured).
    uint32 public constant TWAP_WINDOW = 1800;

    /// Max-leverage LTV ceiling an LP may set for itself: 7500 bps ≈ 4×.
    uint256 public constant TARGET_LTV_CAP_BPS = 7500;

    /// Oracle (`getTWAPforAsset`) + the caller-funded paths both managers reach through.
    IAux public immutable AUX;

    /// @notice The asset this instance prices against — WETH on the ETH side, WBTC on the BTC side.
    ///         THE ONLY per-asset input to the shared valuation bodies. Before this existed, every
    ///         shared function differed solely by naming `WETH` or `WBTC` in its TWAP call, which is
    ///         what kept ~20 otherwise-identical lines from being one implementation.
    address public immutable ORACLE_KEY;

    /// Per-LP, one isolated position. PUBLIC ⇒ ABI-visible 6-tuple getter (see note above).
    mapping(address => Types.Pos) public pos;

    /// @dev Enumerable set of LPs with an open position, so the whole book's live net equity can be
    ///      summed on-chain. `_lpIdx` is 1-based (0 = absent); removal is swap-and-pop.
    address[] internal _openLps;
    mapping(address => uint256) internal _lpIdx;

    /// The band's sync hook (Vogue's `syncLev` / Vault's `syncLevBTC`). GOV pin-once, then frozen —
    ///  the SETTER stays per-manager (BtcLevManager fuses it into `init` alongside `venuesFrozen`).
    address public vogueSyncHook;

    event TargetSet(address indexed lp, uint256 targetLtvBps);
    event ReanchoredToBand(address indexed lp, uint160 entrySqrtP, uint256 e0);

    error NotOpen();
    error BadTarget();

    constructor(address aux, address oracleKey) { AUX = IAux(aux); ORACLE_KEY = oracleKey; }

    function _trackOpen(address lp) internal {
        if (_lpIdx[lp] == 0) { _openLps.push(lp); _lpIdx[lp] = _openLps.length; }
    }

    function _untrackOpen(address lp) internal {
        uint256 idx = _lpIdx[lp];
        if (idx == 0) return;
        uint256 last = _openLps.length;
        if (idx != last) { address moved = _openLps[last - 1]; _openLps[idx - 1] = moved; _lpIdx[moved] = idx; }
        _openLps.pop();
        _lpIdx[lp] = 0;
    }

    /// @notice Adjust the caller's max-leverage CAP (bps LTV, ≤ TARGET_LTV_CAP_BPS).
    function setTargetLtv(uint64 capBps) external {
        if (!pos[msg.sender].open) revert NotOpen();
        if (capBps == 0 || capBps > TARGET_LTV_CAP_BPS) revert BadTarget();
        pos[msg.sender].targetLtvCapBps = capBps;
        emit TargetSet(msg.sender, capBps);
    }

    /// @notice Venue + stable + native amount for a swap-out-driven delever of `lp`.
    function swapOutDeleverAmt(address lp, uint256 maxUsd18)
        external view returns (address venue, address stable, uint256 amtNative) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (address(0), address(0), 0);
        venue = address(p.venue);
        stable = p.venue.stable();
        amtNative = LevMath._fromUsd(address(AUX), stable, maxUsd18);
    }

    /// @notice Book-level deliverable dollars across every open LP.
    ///         LIFTED from both managers — after ORACLE_KEY the two copies were BYTE-IDENTICAL.
    ///         Safe over `_openLps` because _untrackOpen is called UNCONDITIONALLY on close
    ///         (LevManager:659, BtcLevManager:529), including the ETH keepState branch that
    ///         retains the Pos with open=false. So this never iterates a closed position.
    function totalDeliverableDollars() external view returns (uint total) {
        uint n = _openLps.length;
        if (n == 0) return 0;
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        for (uint i; i < n; i++) total += _deliverableDollarsAt(_openLps[i], px);
    }

    /// @dev The ONLY per-asset step in the two valuation bodies below: native collateral units for
    ///      `lp` at `v`. Everything else — the debt read, the net-equity floor, the LTV and the
    ///      deliverable formula — was IDENTICAL in both managers and now exists once.
    ///      ⚠️ It is a hook rather than a shared helper because `_collToEth` CANNOT serve BTC: it
    ///      tests `COLLATERAL() == WETH`, which is false for a vBTC venue, so sats would be routed
    ///      through `getEETHByWeETH` and silently mis-converted.
    ///      ⚠️ When these move to a delegatecall library, the CALLER computes this and passes it as a
    ///      VALUE — a library cannot call a virtual on its caller.
    function _collNative(ILevVenue v, address lp) internal view virtual returns (uint);

    /// @notice Per-LP deliverable dollars at price `px`. LIFTED from both managers 2026-08-13 —
    ///         identical once `_collNative` absorbed the collateral conversion.
    function _deliverableDollarsAt(address lp, uint px) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        uint collUsd = (_collNative(p.venue, lp) * px) / 1e18;          // C (USD 1e18)
        uint d = debtUsd(lp);                                           // D (USD 1e18)
        uint netEq = collUsd > d ? collUsd - d : 0;
        return LevMath.deliverableDollars(netEq, collUsd, LevMath.ltvBps(d, collUsd), p.venue.liqThresholdBps());
    }

    /// @notice Per-LP net equity in NATIVE units at price `px`. Same lift, same reason.
    function _netEquityAt(address lp, uint px) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        return LevMath.netEquityBase(_collNative(p.venue, lp), debtUsd(lp), px);
    }

    /// @dev Debt in USD 1e18 for `lp` — per-asset only in which stable the venue names.
    function debtUsd(address lp) public view virtual returns (uint);

    /// @notice Per-LP net-of-debt equity in the instance's OWN native unit — 1e18 ETH on the ETH side,
    ///         8-dec sats on the BTC side. The unit differs; the MEANING does not, which is why one
    ///         name serves both. (Was `netEquityEth`/`netEquityBtc`; those two names were the last
    ///         per-asset difference in `_reanchorIfReseated`.)
    function netEquity(address lp) public view virtual returns (uint256);

    /// @notice A band reseat REALIZES accrued IL, so re-anchor `E0` to the position's CURRENT
    ///         net-equity — the new fixed base — NOT the band position (which is 0 in the (A) model,
    ///         the deposit having no separate unlevered band slice). Net-equity IS the delta-1 slice
    ///         now sitting in the recentered band; the next hedge cycle sizes from it at zero IL.
    /// @dev    The over-hedge fix still holds: `E0` tracks NET-EQUITY, never the growing collateral.
    ///         IDENTICAL on both sides once `netEquity` replaced the two per-asset accessors — the
    ///         bodies differed only in `uint` vs `uint256` spelling and comment framing.
    function _reanchorIfReseated(address lp) internal {
        Types.Pos storage p = pos[lp];
        if (!p.open) return;
        (bool go, uint160 s) = LevMath.reanchorCompute(vogueSyncHook, p.entrySqrtP);
        if (!go) return;
        uint256 px   = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        uint256 base = netEquity(lp);
        p.entrySqrtP    = s;
        p.entryPriceWad = uint128(px);
        p.e0            = uint128(base);
        emit ReanchoredToBand(lp, s, base);
    }
}
