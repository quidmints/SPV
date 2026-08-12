// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./Types.sol";
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
    /// Max-leverage LTV ceiling an LP may set for itself: 7500 bps ≈ 4×.
    uint256 public constant TARGET_LTV_CAP_BPS = 7500;

    /// Oracle (`getTWAPforAsset`) + the caller-funded paths both managers reach through.
    IAux public immutable AUX;

    /// Per-LP, one isolated position. PUBLIC ⇒ ABI-visible 6-tuple getter (see note above).
    mapping(address => Types.Pos) public pos;

    /// @dev Enumerable set of LPs with an open position, so the whole book's live net equity can be
    ///      summed on-chain. `_lpIdx` is 1-based (0 = absent); removal is swap-and-pop.
    address[] internal _openLps;
    mapping(address => uint256) internal _lpIdx;

    event TargetSet(address indexed lp, uint256 targetLtvBps);

    error NotOpen();
    error BadTarget();

    constructor(address aux) { AUX = IAux(aux); }

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
}
