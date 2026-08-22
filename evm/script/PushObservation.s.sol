// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {OracleLib} from "../src/imports/OracleLib.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title  §E294 — **THE MISSING CALLER.** Read 1inch off-chain, push it on-chain.
///
/// @notice `Core.pushObservation` is permissionless, anchor-bounded, and had **ZERO callers**, which
///         is the entire reason σ² ≡ 0: the ring has two writers and neither runs (§E308). The pull
///         path (`_observeIfSourced`) has no source by owner decision; this is the push path's caller.
///
///         ⭐ **WHY A SCRIPT IS THE RIGHT SHAPE, AND NOT A WORKAROUND.** 1inch's `getRate` costs
///         **33.6M gas against a 30M block** (§E232, `OneInchGasProbe`) — unaffordable ON-CHAIN, which
///         is what killed it as an observation SOURCE. But that is the cost of a *transaction*: read
///         as an `eth_call` it runs under an effectively unbounded allowance and costs nothing, which
///         is exactly why §E257 records that it *"looked perfectly healthy from a console."*
///         ⇒ **This script does the read in SIMULATION and broadcasts only the `pushObservation`
///         write.** The expensive half never becomes a transaction. That is the owner's framing —
///         *cache `getRate` and submit it as an update* — with no 712 needed, because the 50 bps
///         Chainlink guard does the work a signature would have (§E294).
///
///         **MEASURED PREMISES, so this is not hopeful:** the 1inch↔Chainlink basis is **23 bps**
///         against the 50 bps guard (`PushSourceIsAdmissible.t.sol`), so a push IS admitted; and nine
///         in-range pushes move σ² from 0 to **7.7e17** (`PushObservationFillsTheRing.t.sol`), so the
///         estimator works.
///
///         ⚠️ **CADENCE IS THE PART THIS FILE DOES NOT DECIDE.** A caller that chooses WHEN to push
///         chooses which prices the ring sees, and selective sampling is the one manipulation the
///         50 bps range does not bound (§E294). **Drive it from range state — a repack, a swap, a
///         delever — not from a discretionary loop.** Running it on a bare timer is the sampling
///         vector, not a schedule.
///
/// Usage:  CORE=0x… AUX=0x… forge script script/PushObservation.s.sol --rpc-url $ETH_RPC_URL --broadcast
///         Dry run (no `--broadcast`) prints the basis and whether the push would be ADMITTED.
contract PushObservationScript is Script {
    address constant ONE_INCH_ORACLE = 0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8;
    address constant WETH            = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC            = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// Mirrors `Core.OBS_PUSH_MAX_BPS` (internal). Used only to REPORT admissibility — the contract
    /// enforces its own copy, so a drift here misreports but cannot admit anything Core would refuse.
    uint256 constant OBS_PUSH_MAX_BPS = 50;

    function run() external {
        Core core = Core(payable(vm.envAddress("CORE")));

        // ── READ (simulation only — this is the 33.6M-gas call that must never be broadcast) ──
        uint256 px = OracleLib.oneInchRateWad(ONE_INCH_ORACLE, WETH, USDC, 18, 6);
        require(px != 0, "1inch returned 0 - refusing to push a zero");

        // ── PREVIEW the guard, so a refused push is visible instead of a silent no-op ──
        // `pushObservation` swallows an out-of-range price by design (that silence is what makes it
        // safe to attach to a carrier), so without this the operator cannot tell success from nothing.
        (uint256 anchor,) = SwapLib.twapResolve(
            _feed(core), 0, false, OBS_PUSH_MAX_BPS, 1 days);
        require(anchor != 0, "no Chainlink anchor - every push would be refused");
        (uint256 lo, uint256 hi) = px < anchor ? (px, anchor) : (anchor, px);
        uint256 bps = (hi - lo) * 10_000 / lo;

        console2.log("1inch     (wad):", px);
        console2.log("anchor    (wad):", anchor);
        console2.log("basis     (bps):", bps);
        console2.log("admitted       :", bps < OBS_PUSH_MAX_BPS ? 1 : 0);
        require(bps < OBS_PUSH_MAX_BPS,
            "basis outside the push range - the write would be silently refused, so it is not sent");

        // ── WRITE (the only broadcast leg: one SSTORE, permissionless, no auth needed) ──
        vm.startBroadcast();
        core.pushObservation(px);
        vm.stopBroadcast();

        console2.log("sigma^2 after (wad):", core.realizedVarianceWad());
    }

    /// The feed `pushObservation` itself will use.
    /// ⚠️ **`AUX` MUST BE SUPPLIED SEPARATELY — `Core` declares `Aux AUX;` with NO visibility
    /// specifier (`Core.sol:519`), so it defaults to `internal` and cannot be read from outside.**
    /// The asset comes from `Core.ASSET()` (public), so only the Aux address is external input, and a
    /// wrong one fails loudly on the `anchor != 0` require rather than pushing against a stale feed.
    function _feed(Core core) internal view returns (address) {
        return IAuxFeed(vm.envAddress("AUX")).assetPriceFeed(core.ASSET());
    }
}

interface IAuxFeed { function assetPriceFeed(address) external view returns (address); }
