// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}     from "v4-core/src/types/PoolKey.sol";
import {Currency}    from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC4626}    from "forge-std/interfaces/IERC4626.sol";
import {IERC20}      from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}   from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FeeLib}      from "./FeeLib.sol";
import {IV3SwapRouter} from "./v3/IV3SwapRouter.sol";
import {IAux} from "./Interfaces.sol";

/// @notice A swap path is a chain of V4 hops sharing an entry stable +
///         4626 source vault. The token sequence has length N+1; the
///         V4 PoolKey chain has length N. The terminal token is always
///         native ETH (Aux wraps to WETH inside unlockCallback).
struct SorPath {
    address sourceAsset;
    address sourceVault;          // 4626 vault for the source stable
    address[] tokens;             // length N+1; tokens[0] = source, tokens[N] = address(0) (ETH)
    PoolKey[] keys;               // length N — V4 swap chain
    address output;               // always address(WETH); Aux wraps the ETH terminal
}

/// @notice Unlock-callback payload. Aux's `unlockCallback` decodes
///         this and walks the V4 hop chain. Blacklist-safety invariants
///         are enforced there: source vault redeems direct to
///         PoolManager (skipping Aux), and the terminal is native ETH.
struct UnlockData {
    address sourceAsset;
    address sourceVault;
    uint256 amountIn;
    address output;
    address recipient;
    address[] tokens;
    PoolKey[] keys;
}

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
/// FALLBACK order: at runtime SwapLib._pickBestPath selects the source with
/// the highest live basket concentration fee (FeeLib.calcFeeL1) FIRST, and the
/// deploy order is iterated only if that pick fails. If a path reverts
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
    function unlockBody(bytes memory data, address weth, address wbtc, IPoolManager pm)
        external returns (bytes memory)
    {
        UnlockData memory u = abi.decode(data, (UnlockData));
        if (u.sourceVault == address(0)) revert BadV4SourceVault();
        bool isEthTerm  = (u.output == weth);
        bool isWbtcTerm = (u.output == wbtc);
        bool isStableTerm = !isEthTerm && !isWbtcTerm;
        if (!(isEthTerm || isWbtcTerm || isStableTerm)) revert BadV4Terminal();
        address last = u.tokens[u.tokens.length - 1];
        if (isEthTerm)       { if (last != address(0)) revert BadV4Last(); }
        else if (isWbtcTerm) { if (last != wbtc)       revert BadV4Last(); }

        bool ethSource = (u.sourceAsset == weth &&
                          Currency.unwrap(u.keys[0].currency0) == address(0));
        // `flowing` MUST be the amount actually settled into the
        // PoolManager, not the requested amountIn: an ERC4626 redeem of
        // convertToShares(amountIn) rounds DOWN, so the vault delivers
        // <= amountIn. Using amountIn as the first-hop exact input then
        // leaves a 1-wei (rounding) source-currency deficit and the
        // unlock fails CurrencyNotSettled. `settle()` returns the true
        // paid amount.
        uint256 flowing;
        if (ethSource) {
            // ETH-source = the redemption ETH-fallback (ethToStableFallback). The
            // caller (Aux) has ALREADY pulled `amountIn` WETH to itself from the
            // ETH venue (withdrawSelf → EthVenue.withdrawForAux) before this
            // unlock, since the Galaxy shares are custodied on EthVenue now and
            // are not Aux's to redeem here. So just unwrap the WETH already held
            // and settle the native ETH. (sourceVault retained in UnlockData for
            // shape/back-compat; no longer redeemed from in this branch.)
            WETH9(payable(weth)).withdraw(u.amountIn);
            pm.sync(Currency.wrap(address(0)));
            (bool ok,) = address(pm).call{value: u.amountIn}("");
            if (!ok) revert BadV4SourceVault();
            flowing = pm.settle();
        } else if (u.sourceVault == SELF_FUNDED) {
            // CALLER-FUNDED (see SELF_FUNDED): Aux already holds `amountIn` of the source stable — settle it
            // straight into the PoolManager, no 4626 redeem. `settle()` returns the true paid amount.
            pm.sync(Currency.wrap(u.sourceAsset));
            IERC20(u.sourceAsset).transfer(address(pm), u.amountIn);
            flowing = pm.settle();
        } else {
            pm.sync(Currency.wrap(u.sourceAsset));
            uint256 shares = IERC4626(u.sourceVault).convertToShares(u.amountIn);
            IERC4626(u.sourceVault).redeem(shares, address(pm), address(this));
            flowing = pm.settle();
        }
        for (uint256 i; i < u.keys.length; i++) {
            PoolKey memory key = u.keys[i];
            bool zeroForOne = Currency.unwrap(key.currency0) == u.tokens[i];
            BalanceDelta delta = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(flowing),
                    sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                }),
                ""
            );
            flowing = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
        }
        if (isEthTerm) {
            pm.take(Currency.wrap(address(0)), address(this), flowing);
            WETH9(payable(weth)).deposit{value: flowing}();
            if (u.recipient != address(this))
                IERC20(weth).transfer(u.recipient, flowing);
        } else if (isWbtcTerm) {
            pm.take(Currency.wrap(wbtc), address(this), flowing);
            if (u.recipient != address(this))
                IERC20OZ(wbtc).safeTransfer(u.recipient, flowing);
        } else {
            pm.take(Currency.wrap(u.output), address(this), flowing);
            if (u.recipient != address(this))
                IERC20OZ(u.output).safeTransfer(u.recipient, flowing);
        }
        return abi.encode(flowing);
    }

    /// @notice Execute a path via V4 unlock. Returns amountOut.
    function executePath(
        bytes calldata encodedPath,
        uint amountIn, address recipient, uint minOut,
        IPoolManager poolManager
    ) external returns (uint amountOut) {
        SorPath memory p = abi.decode(encodedPath, (SorPath));
        if (p.tokens.length != p.keys.length + 1) revert PathShape();

        UnlockData memory u = UnlockData({
            sourceAsset: p.sourceAsset,
            sourceVault: p.sourceVault,
            amountIn:    amountIn,
            output:      p.output,
            recipient:   recipient,
            tokens:      p.tokens,
            keys:        p.keys
        });
        bytes memory ret = poolManager.unlock(abi.encode(u));
        amountOut = abi.decode(ret, (uint));
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

    address private constant V3_ROUTER_SF = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // Uniswap V3 SwapRouter02
    address private constant USDC_HUB      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // multi-hop intermediary
    /// @dev Uniswap V3 as a FIRST-CLASS SOR route (used by BOTH self-funded directions): try the direct
    ///      `tokenIn`/`tokenOut` pool (0.05% then 0.30% tiers), then a 2-hop via the deep USDC hub
    ///      (`tokenIn`/USDC 0.05% -> USDC/`tokenOut` 0.05% then 0.30%) for a stable with no deep direct WETH pool.
    ///      Multi-hop, `minOut`-floored (anti-MEV); returns 0 (=> caller reverts) iff no tier/route fills. External
    ///      real markets only — never the reserve. Reuses the offramp's IV3SwapRouter leg; no new dependency.
    function _v3Route(address tokenIn, address tokenOut, uint amountIn, address recipient, uint minOut)
        private returns (uint) {
        IERC20OZ(tokenIn).forceApprove(V3_ROUTER_SF, amountIn);
        bytes[4] memory paths;
        uint n;
        paths[n++] = abi.encodePacked(tokenIn, uint24(500), tokenOut);
        paths[n++] = abi.encodePacked(tokenIn, uint24(3000), tokenOut);
        if (tokenIn != USDC_HUB && tokenOut != USDC_HUB) {
            paths[n++] = abi.encodePacked(tokenIn, uint24(500), USDC_HUB, uint24(500), tokenOut);
            paths[n++] = abi.encodePacked(tokenIn, uint24(500), USDC_HUB, uint24(3000), tokenOut);
        }
        for (uint i; i < n; i++) {
            try IV3SwapRouter(V3_ROUTER_SF).exactInput(IV3SwapRouter.ExactInputParams({
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
        uint nK = p.keys.length;
        address[] memory toks = new address[](nT);
        PoolKey[] memory ks = new PoolKey[](nK);
        for (uint i; i < nT; i++) toks[i] = p.tokens[nT - 1 - i];   // [stable,..,ETH] -> [ETH,..,stable]
        for (uint i; i < nK; i++) ks[i] = p.keys[nK - 1 - i];       // key chain reversed
        return abi.encode(SorPath({
            sourceAsset: weth, sourceVault: SELF_FUNDED, tokens: toks, keys: ks, output: targetStable }));
    }

    /// @dev Fee-rank pre-pass in its own frame (deps/depsY arrays + the loop would
    ///      overflow sorAuxSwapBody's legacy stack). Returns the chosen path index
    ///      (type(uint).max if none match `output`).
    /// @dev CONTEXT-SWITCHED objective: the calcFeeL1 ranking is the COMPOSITION/drainage objective
    ///      (shed the stable whose draw most degrades the basket). That is only worth paying a possibly
    ///      worse route for when the basket is ACTUALLY over-concentrated (bestFee meaningfully above the
    ///      BASE floor). When flat (no rebalance/drainage benefit), chasing it can route the protocol's
    ///      own swap through avoidable slippage for nothing — so fall back to the FIRST eligible path
    ///      (the canonical/best-execution route). Cuts the sourcing-slippage leak. `CONC_GATE_BPS`
    ///      above BASE is the "actually over-concentrated" threshold.
    uint private constant CONC_GATE_BPS = 2; // shed-objective engages only when calcFeeL1 > BASE+2bps
    function _pickBestPath(IAux aux, address output, bytes[] memory pathEncodings)
        private returns (uint bestIdx) {
        bestIdx = type(uint).max;
        // Best-execution proxy = FEWEST hops (SorPath.keys.length): each extra V4 hop adds slippage,
        // so when there is no rebalance benefit the least-hops eligible path is the cheapest fill.
        uint leastHopsIdx = type(uint).max; uint leastHops = type(uint).max;
        uint nPaths = pathEncodings.length;
        (uint[15] memory deps, uint[15] memory depsY,,) = aux.get_deposits();
        uint bestFee;
        for (uint i; i < nPaths; i++) {
            SorPath memory p = abi.decode(pathEncodings[i], (SorPath));
            if (p.output != output) continue;
            uint srcIdx = aux.toIndex(p.sourceAsset); // 1-based; 0 ⇒ not a basket stable
            if (srcIdx == 0) continue;
            uint hops = p.keys.length;
            if (hops < leastHops) { leastHops = hops; leastHopsIdx = i; }
            // calcFeeL1(srcIdx-1) == calcFeeL1WithLookup(sourceAsset) but without the
            // per-path O(stables) linear rescan — toIndex already resolved the slot.
            uint fee = FeeLib.calcFeeL1(srcIdx - 1, deps, depsY);
            if (bestIdx == type(uint).max || fee > bestFee) {
                bestFee = fee;
                bestIdx = i;
            }
        }
        // ⚠️ PARTIAL — see docs/actionable/SOR-SIGNIFICANCE-DESIGN.md. This binary gate (shed when
        //    over-concentrated, else least-hops) is ONE corner of the intended objective: a per-reweigh
        //    SIGNIFICANCE comparison of {yield-preservation, concentration-reduction, execution}, where
        //    the most-significant goal sets the policy for THAT reweigh — NOT an either/or, NOT a single
        //    hardcoded priority. This is a down-payment on that design, not the design itself.
        // CONTEXT-SWITCH: basket flat (no shed/drainage benefit) ⇒ optimize EXECUTION = fewest-hops
        // path (don't pay extra slippage for an unneeded rebalance). Over-concentrated ⇒ the
        // highest-calcFeeL1 shed stands. (Truer least-slippage = an off-chain quote + minOut; this
        // hop-count proxy is the on-chain refinement over "first eligible".)
        if (bestIdx != type(uint).max && bestFee <= FeeLib.BASE + CONC_GATE_BPS) bestIdx = leastHopsIdx;
    }
}
