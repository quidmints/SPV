// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV3Router, V3_SWAP_ROUTER} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";

/// @notice A swap path is a chain of V4 hops sharing an entry stable +
///         4626 source vault. The token sequence has length N+1; the
///         The terminal token is always
///         native ETH (Aux wraps to WETH inside unlockCallback).
struct SorPath {
    address sourceAsset;
    address sourceVault;          // 4626 vault for the source stable
    address[] tokens;             // length N+1; tokens[0] = source, tokens[N] = address(0) (ETH)
    // §V4-ZERO — `PoolKey[] keys` DELETED, and it was the LAST v4 symbol in src/. It encoded the
    // Uniswap-v4 hop chain that `unlockBody` walked; with routing on `_v3Route` (which discovers its
    // own path at call time) nothing read it, and its only remaining use was being REVERSED in
    // `_reversePath` to fill itself. A field whose sole consumer is its own mirror image.
    address output;               // always address(WETH); Aux wraps the ETH terminal
}

// §V4-ZERO — `UnlockData` DELETED with `unlockBody`: it was the ABI of a callback payload for a
// callback that no longer exists.

/// @notice Subset of Aux's public surface the SOR-routing bodies call back into
///         via DELEGATECALL -> external self-CALL (address(this)==Aux). Mirrors the
///         identically-named entries on SwapLib's IAux; only the methods the
///         moved SOR router cluster needs. Named imports everywhere ⇒ no clash with
///         SwapLib's own file-scope IAux.

/// @title SOR — Smart Order Router (V4 only, stable → ETH)
///
/// Each path is a chain of V4 swap hops sharing an entry stable + 4626
/// source vault. Routes through PoolManager.unlock; Aux's
/// `unlockCallback` walks the chain. The deploy array order is
/// most-blacklistable-source-first by convention — but that is only the
/// FALLBACK order: at runtime `_pickBestPath` selects the FEWEST-HOPS eligible
/// path (best execution), and the deploy order is iterated only if that pick
/// fails. §E228 removed the `calcFeeL1` shed-rank that used to lead here — it
/// was inverted, saturating, and until §E155 it sorted by token decimals; see
/// the note on `_pickBestPath`. If a path reverts
/// (slippage / pool issue / vault paused), Aux's auxSwap try/catch advances to
/// the next path.
library SOR {
    using SafeERC20 for IERC20OZ;
    error Slippage();
    error PathShape();
    error BadV4SourceVault();
    error BadV4Terminal();
    error BadV4Last();

    /// @notice Sentinel `sourceVault` marking a CALLER-FUNDED path: the caller (LevManager via Aux) has
    ///         ALREADY transferred `amountIn` of the source stable to Aux, so `unlockBody` settles it directly
    ///         and SKIPS the 4626 redeem — letting an external caller route its OWN funds through the same
    ///         real-Uniswap-V4 hops WITHOUT touching basket backing (non-toxic; the leverage's borrowed
    ///         dollars, never the reserve). `address(1)` is a precompile, never a real 4626 vault; existing
    ///         basket paths (real `sourceVault`) hit the redeem branch unchanged.
    address internal constant SELF_FUNDED = address(1);

    /// @notice Body of Aux._unlockCallback, extracted to keep Aux under
    /// the EIP-170 limit. Delegatecall'd from Aux's _unlockCallback, so
    /// address(this) == Aux and the PoolManager settle/take/swap are
    /// attributed to Aux (the unlock initiator). Touches no Aux storage —
    /// only the decoded payload + the three passed addresses.
    // §V4-ZERO — `unlockBody` DELETED. It was the v4 unlock callback's body: settle/take/swap
    // against a PoolManager, walking `SorPath.keys`. Nothing unlocks a PoolManager in this tree, so
    // its only caller (`Aux._unlockCallback`) went with the `SafeCallback` base and this became
    // unreachable. Routing moved to `_v3Route` in `executePath`.

    /// @notice Execute a path via V4 unlock. Returns amountOut.
    /// @notice Execute one encoded path. §V4-ZERO — NO POOL MANAGER, NO UNLOCK.
    /// @dev    This used to build an `UnlockData` and call `poolManager.unlock(...)`, with the
    ///         callback landing on `Aux.unlockCallback` to walk a v4 hop chain. That callback is
    ///         gone with the `SafeCallback` base, so the unlock could not complete -- it surfaced as
    ///         `NoSorPath()` 164 times, because `sorAuxSwapBody` had no fallback while
    ///         `sorSelfFundedBody` did.
    ///
    ///         THE REPLACEMENT WAS ALREADY IN THIS FILE. `_v3Route` is a complete stable<->volatile
    ///         router -- four Uniswap V3 fee-tier paths including a two-hop through the USDC hub --
    ///         and `sorSelfFundedBody` already called it, with a comment calling it "a FIRST-CLASS
    ///         PEER ROUTE ... not a hardcoded caller bypass". Routing HERE means both bodies get it,
    ///         so the v4 hops are not replaced by a fallback but by the peer that outlived them.
    ///
    ///         ⚠️ `p.keys` (the `PoolKey[]` hop chain) is now UNREAD. V3 discovers its own route at
    ///         call time, which is why the deploy-time path encoding can follow: `_buildSORPaths`,
    ///         `_pk` and the `_hop*` builders in DeployLib exist only to fill that field. Left in
    ///         place here so this change is one thing; the struct and the builders go together.
    function executePath(
        bytes calldata encodedPath,
        uint amountIn, address recipient, uint minOut
    ) external returns (uint amountOut) {
        SorPath memory p = abi.decode(encodedPath, (SorPath));
        // §V4-ZERO — the `tokens == keys + 1` shape check went with `keys`. V3 routes from the
        // endpoints, so a hop-count invariant has nothing left to constrain.
        amountOut = _v3Route(p.sourceAsset, p.output, amountIn, recipient, minOut);
        if (amountOut < minOut) revert Slippage();
    }

    error NoSorPath();

    /// @notice Body of Aux.auxSwap (the SOR / volatile-output overload).
    ///         Wrapper pre-passes `_pathEncodings` (memory copy of state
    ///         array), `stables`, `LINK` and DELEGATECALL's here. Library
    ///         iterates highest-fee-first, calls back via `_tryPath`
    ///         (already self-gated on Aux). State reads via IAux.
    ///
    ///         WRAPPER (Aux.auxSwap) holds the `nonReentrant` lock for
    ///         the entire chain. This function MUST NOT carry its own.
    function sorAuxSwapBody(
        uint amountIn,
        address output,
        address recipient,
        uint    minOut,
        bytes[] memory pathEncodings
    ) external returns (uint outAmount) {
        IAux aux = IAux(address(this));
        // Fee-rank pre-pass (own frame — legacy stack) — pick the path whose source
        // stable the protocol most wants to shed (same signal `take` uses). It also
        // returns `matchMask` (bit i set iff path i's `output` matches) so the
        // fallback loop below skips non-matching paths WITHOUT re-decoding each one —
        // the rank pass already decoded every path to read `output`. (nPaths is
        // deploy-fixed and small; the mask comfortably fits a uint256.)
        uint bestIdx = _pickBestPath(aux, output, pathEncodings);

        // Try fee-best first.
        if (bestIdx != type(uint).max) {
            try aux._tryPath(
                pathEncodings[bestIdx], amountIn, output, recipient, minOut
            ) returns (uint got) {
                if (got >= minOut && got > 0) return got;
            } catch { /* fall through */ }
        }

        // Fallback iteration via the SHARED path-try helper (skip the already-tried bestIdx; no source filter,
        // not self-funded). This is the SAME loop `sorSelfFundedBody` uses — one implementation, no duplication.
        outAmount = _tryPathsMatching(aux, pathEncodings, output, address(0), false, amountIn, recipient, minOut, bestIdx);
        if (outAmount == 0 || outAmount < minOut) revert NoSorPath();
    }

    /// @dev SHARED path-iteration primitive (dedup of the two SOR loops): try each `enc[i]` whose `output`
    ///      matches — and, if `srcFilter != 0`, whose `sourceAsset` matches — via `aux._tryPath`, returning the
    ///      first success (got ≥ minOut). `selfFunded` sets `sourceVault = SELF_FUNDED` (skip the 4626 redeem —
    ///      the caller brought the funds). `skipIdx` skips an already-tried index (`type(uint).max` = skip none).
    ///      `internal` ⇒ inlined into SwapLib's own bytecode, never Aux's.
    function _tryPathsMatching(
        IAux aux, bytes[] memory enc, address output, address srcFilter, bool selfFunded,
        uint amountIn, address recipient, uint minOut, uint skipIdx
    ) internal returns (uint) {
        for (uint i; i < enc.length; i++) {
            if (i == skipIdx) continue;
            SorPath memory p = abi.decode(enc[i], (SorPath));
            if (p.output != output) continue;
            if (srcFilter != address(0) && p.sourceAsset != srcFilter) continue;
            bytes memory pe = enc[i];
            if (selfFunded) { p.sourceVault = SELF_FUNDED; pe = abi.encode(p); }
            try aux._tryPath(pe, amountIn, output, recipient, minOut) returns (uint got) {
                if (got >= minOut && got > 0) return got;
            } catch { /* try next */ }
        }
        return 0;
    }

    /// @notice SELF-FUNDED SOR body (extracted from Aux for EIP-170 relief). Routes the CALLER's own `amountIn`
    ///         of `sourceAsset` (already pulled into Aux by the thin wrapper) through a `sourceAsset`-matching
    ///         path with the 4626 redeem skipped (`SELF_FUNDED`). REUSES `_tryPathsMatching` (no duplicate loop).
    ///         Returns 0 if no path matched — the Aux wrapper reverts `NoSelfFundedPath` (its selector preserved).
    function sorSelfFundedBody(
        address sourceAsset, uint amountIn, address output, address recipient, uint minOut,
        bytes[] memory pathEncodings
    ) external returns (uint got) {
        // Route the caller's own funds `sourceAsset`->`output` through the basket's real-V4 hops (best-path first,
        // then the rest via the shared loop) — the toxicity boundary: never the reserve. Uniswap V3 is a FIRST-CLASS
        // PEER ROUTE (`_v3Route`, both directions, multi-hop), tried when the V4 hops can't fill — not a hardcoded
        // caller bypass. Returns 0 => the Aux wrapper reverts NoSelfFundedPath.
        got = _tryPathsMatching(IAux(address(this)), pathEncodings, output, sourceAsset, true,
                                amountIn, recipient, minOut, type(uint).max);
        if (got == 0) got = _v3Route(sourceAsset, output, amountIn, recipient, minOut);
    }

    /// @notice SELF-FUNDED **REVERSE** SOR body — routes the caller's own `amountIn` of WETH to `targetStable` by
    ///         running that stable's registered forward (stable->WETH) path BACKWARDS through the SAME real-V4 hops.
    ///         `unlockBody` already handles this shape end-to-end: the reversed path's source is native ETH (its
    ///         first key's currency0 == address(0)) so the `ethSource` branch unwraps the caller-held WETH and
    ///         settles ETH; the terminal is the stable so the `isStableTerm` branch takes it out. So we only flip
    ///         the token+key arrays and swap source/output — no unlockBody change, no UniV3, still never the reserve.
    ///         The multi-hop reverse (WETH->USDC->stable) is exactly the forward (stable->USDC->WETH) mirrored.
    ///         Returns 0 if no `targetStable`-sourced path exists — the Aux wrapper reverts (selector preserved).
    function sorSelfFundedReverseBody(
        address weth, address targetStable, uint amountIn, address recipient, uint minOut,
        bytes[] memory pathEncodings
    ) external returns (uint got) {
        IAux aux = IAux(address(this));
        for (uint i; i < pathEncodings.length; i++) {
            SorPath memory p = abi.decode(pathEncodings[i], (SorPath));
            if (p.sourceAsset != targetStable || p.output != weth) continue;  // the forward path to reverse
            try aux._tryPath(_reversePath(p, weth, targetStable), amountIn, targetStable, recipient, minOut)
                returns (uint g) { if (g >= minOut && g > 0) return g; } catch { /* try next matching path */ }
        }
        // Uniswap V3 peer route (same one the forward leg uses), reversed: WETH -> targetStable, multi-hop via USDC.
        return _v3Route(weth, targetStable, amountIn, recipient, minOut);
    }

    address private constant USDC_HUB      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // multi-hop intermediary
    /// @dev Uniswap V3 as a FIRST-CLASS SOR route (used by BOTH self-funded directions): try the direct
    ///      `tokenIn`/`tokenOut` pool (0.05% then 0.30% tiers), then a 2-hop via the deep USDC hub
    ///      (`tokenIn`/USDC 0.05% -> USDC/`tokenOut` 0.05% then 0.30%) for a stable with no deep direct WETH pool.
    ///      Multi-hop, `minOut`-floored (anti-MEV); returns 0 (=> caller reverts) iff no tier/route fills. External
    ///      real markets only — never the reserve. Reuses the offramp's IV3Router leg; no new dependency.
    function _v3Route(address tokenIn, address tokenOut, uint amountIn, address recipient, uint minOut)
        private returns (uint) {
        IERC20OZ(tokenIn).forceApprove(V3_SWAP_ROUTER, amountIn);
        bytes[4] memory paths;
        uint n;
        paths[n++] = abi.encodePacked(tokenIn, uint24(500), tokenOut);
        paths[n++] = abi.encodePacked(tokenIn, uint24(3000), tokenOut);
        if (tokenIn != USDC_HUB && tokenOut != USDC_HUB) {
            paths[n++] = abi.encodePacked(tokenIn, uint24(500), USDC_HUB, uint24(500), tokenOut);
            paths[n++] = abi.encodePacked(tokenIn, uint24(500), USDC_HUB, uint24(3000), tokenOut);
        }
        for (uint i; i < n; i++) {
            try IV3Router(V3_SWAP_ROUTER).exactInput(IV3Router.ExactInputParams({
                path: paths[i], recipient: recipient, amountIn: amountIn, amountOutMinimum: minOut
            })) returns (uint out) { if (out > 0) return out; } catch { /* try next route */ }
        }
        return 0;
    }

    /// @dev Reverse a forward `stable->...->WETH` SorPath into `WETH->...->stable`: flip the token sequence and the
    ///      V4 key chain, set the source to WETH (so unlockBody's ethSource entry fires) and the output to the
    ///      stable (isStableTerm), and mark SELF_FUNDED (the caller brought the WETH; skip the 4626 redeem).
    function _reversePath(SorPath memory p, address weth, address targetStable) internal pure returns (bytes memory) {
        uint nT = p.tokens.length;
        address[] memory toks = new address[](nT);
        for (uint i; i < nT; i++) toks[i] = p.tokens[nT - 1 - i];   // [stable,..,ETH] -> [ETH,..,stable]
        return abi.encode(SorPath({
            sourceAsset: weth, sourceVault: SELF_FUNDED, tokens: toks, output: targetStable }));
    }

    /// @dev Path pick in its own frame (the loop would overflow sorAuxSwapBody's legacy stack).
    ///      Returns the chosen path index (`type(uint).max` if none match `output`).
    ///
    /// §E228 — THE `calcFeeL1` SHED-RANK IS GONE, AND IT WAS WRONG IN SIX WAYS, NOT ONE.
    /// It used to pick the source whose yield most EXCEEDED the basket average. Removed because:
    ///   1. **Direction inverted.** `SOR-SIGNIFICANCE-DESIGN.md:14-16` wants the opposite — *"keep the
    ///      good-yield stables and shed low-yield ones (protects `avgYield`)"*. Maximising drained the
    ///      BEST earner first, ratcheting `avgYield` down over time.
    ///   2. **The comparator was never flipped.** Maximising is correct for a FEE the redeemer pays
    ///      (cherry-pick pricing). `FeeLib.applyFeeAndHaircut` stopped charging it and the value
    ///      "survives as a SOR routing signal only" — repurposed from fee to routing, sign intact.
    ///   3. **Wrong quantity.** The gate says "concentration"; the formula is yield-vs-average. The
    ///      design doc says so outright: *"the two are conflated."*
    ///   4. **No referent.** `CONC_GATE_BPS` tested "over-concentrated", but the basket has NO TARGET
    ///      RATIO (§E218), so there was nothing for concentration to be measured against.
    ///   5. **Saturating.** Capped at `MAX_FEE`, reached at a 0.30pp spread, so most real inputs TIED
    ///      at the cap and fell through to least-hops anyway (§E227).
    ///   6. **It sorted by TOKEN DECIMALS.** Pre-§E155 the 6-dec legs computed a 1e-12 yield factor
    ///      and returned `BASE` unconditionally, so maximising ALWAYS picked an 18-dec stable —
    ///      9 of 14 eligible, 5 (USDC, USDT, PYUSD, USDG, AUSD) structurally excluded, USDC included
    ///      despite being `stables[0]` and the swap-source by convention.
    ///
    /// ⇒ **NEUTRALISED RATHER THAN INVERTED (owner, 2026-08-16).** Inverting a saturating,
    ///   weight-blind comparator on yield history that only became trustworthy today (§E155/§E190)
    ///   would be guessing in the other direction. There is now ONE objective — EXECUTION — and the
    ///   three-axis significance design is built when real weight-vs-target and yield-history inputs
    ///   exist. Standing rule 3/17: remove the bad state, do not stack a second heuristic over it.
    ///
    /// ⚠️ `aux` is still taken: `toIndex` is what proves a path's source IS a basket stable. Dropping
    ///    that check would let a non-basket source route, which is a different guard entirely.
    function _pickBestPath(IAux aux, address output, bytes[] memory pathEncodings)
        private returns (uint bestIdx) {
        bestIdx = type(uint).max;
        // Best-execution proxy = FEWEST hops (`SorPath.keys.length`): each extra hop adds slippage, so
        // the least-hops eligible path is the cheapest fill. (Truer least-slippage = an off-chain
        // quote + minOut; this hop count is the on-chain refinement over "first eligible".)
        uint leastHops = type(uint).max;
        uint nPaths = pathEncodings.length;
        for (uint i; i < nPaths; i++) {
            SorPath memory p = abi.decode(pathEncodings[i], (SorPath));
            if (p.output != output) continue;
            if (aux.toIndex(p.sourceAsset) == 0) continue;   // 0 ⇒ not a basket stable
            uint hops = p.keys.length;
            if (hops < leastHops) { leastHops = hops; bestIdx = i; }
        }
    }
}
