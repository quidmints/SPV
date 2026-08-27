// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LevKeeperTarget — a real on-chain target for the quid-bridge lev-keeper anvil e2e.
/// @notice NOT a protocol stub — it's the deploy target that lets the keeper's LIVE round-trip be proven end
///         to end against a real node: it exposes the EXACT read surface the keeper eth_calls (so the decode
///         path is exercised on real return data) returning a position that is URGENTLY near liquidation, and
///         records the writes the keeper sends (so the encode/sign/send path is exercised). The protocol logic
///         itself is fork-proven separately (LevManager/Quid); this isolates the keeper's RPC plumbing.
contract LevKeeperTarget {
    address public constant LP = address(0xBEEF);
    bool public cascaded;   // set when the keeper sends cascadeDelever (the urgent path)
    bool public synced;     // set when the keeper sends syncLev after the move
    address public lastCascadeLp;
    address public lastSyncLp;

    // ── read surface (lev_manager) ──
    function openLevCount() external pure returns (uint256) { return 1; }
    function openLpAt(uint256) external pure returns (address) { return LP; }
    // §POOL-VENUE — **THIS LP IS HEALTHY AND THE BOOK IS NOT, WHICH IS THE POINT.** It returned 9000
    // (urgent on the per-LP gate). The venue holds ONE pooled Morpho position, so Morpho liquidates on
    // the AGGREGATE — the case that actually threatens every LP is a comfortable LP inside a stressed
    // pool, and the old keeper held straight through it. Splitting the two numbers here makes the e2e
    // prove the SYSTEMIC trigger over real RPC, not just the per-LP one it already covered.
    function getCurrentLtvBps(address) external pure returns (uint256) { return 3000; } // comfortable
    function poolLtvBps() external pure returns (uint256) { return 9000; }              // book near the 8600 liq → urgent
    function ilLtvBps(address) external pure returns (uint256) { return 9000; } // debt/E0 IL-track LTV — keeper reads it in position_view (net-equity/YB rewrite); the urgent path ignores it, but a missing selector reverts the whole read
    function ilTargetLtvBps(address) external pure returns (uint256) { return 2000; }
    function netEquityUsd(address) external pure returns (uint256) { return 100_000e18; }
    // pos(lp) → the keeper reads word[0] as the venue; point it at self so liqThresholdBps() resolves here.
    function pos(address) external view returns (address, uint64, uint128, bool) { return (address(this), 0, 0, true); }
    function liqThresholdBps() external pure returns (uint256) { return 8600; }

    // ── write surface (recorded) ──
    // §E357 — the selector the keeper sends now carries the routes array; a harness on the old
    // arity would silently never be hit, which is the failure this target exists to catch.
    function cascadeDelever(address[] calldata lps, uint256[] calldata, uint256[] calldata) external {
        cascaded = true;
        if (lps.length > 0) lastCascadeLp = lps[0];
    }
    function rebalance(address, uint256, uint256) external {}
    function syncLev(address lp) external { synced = true; lastSyncLp = lp; }
}
