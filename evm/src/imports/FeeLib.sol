
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {WAD} from "./Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IAggregatorV3, IAux} from "./Interfaces.sol";

// ⛔ AN ORPHANED `@notice` STOOD HERE — *"Aux surface the multi-venue withdraw cluster (relocated
//    from BasketLib) calls back into via DELEGATECALL self-call (address(this)==Aux)"* — describing
//    an `interface` declaration that has since moved to `Interfaces.sol` (rule 2). A natspec block
//    with no subject does not merely go unread: the next declaration below it is `library FeeLib`,
//    so tooling attaches an Aux-callback description to the fee library itself. Demoted to a plain
//    comment recording where the surface went.


/// @title  FeeLib — protocol fee model + depeg-aware haircut helpers
/// @notice Stripped of LMSR / prediction-market machinery (was several
///         hundred LOC of exp/log internals, market price/cost, weight
///         and payout calculations for the now-removed depeg market).
///         The remaining surface is the fee/haircut math Aux uses on
///         deposits and pro-rata withdrawals, plus the risk-discount
///         factor consumed in Aux pricing paths.
library FeeLib {

    /// @dev x^n by binary exponentiation in 1e18 fixed point (Liquity _decPow).
    ///      Extracted from Aux (baseRate decay) to free Aux bytecode -- that is why it lives here,
    ///      and it OUTLIVED the thing it was extracted for. `cap` is the decay-exponent ceiling.
    ///      §SCRUB: this said "Aux passes BR_MAX_MIN". Neither half is true any more: `BR_MAX_MIN`
    ///      exists only inside removal records, and the ONLY caller is `Core` (`:247`) passing
    ///      `FLOW_MAX_MIN` for the 48h flow-EWMA decay. A doc naming a deleted constant and a caller
    ///      that no longer calls is worse than none -- it sends a reader to Aux for a live use.
    function decPow(uint base, 
        uint mins, uint cap) public 
        pure returns (uint) {
        if (mins > cap) mins = cap;
        if (mins == 0) return 1e18;
        uint y = 1e18; 
        uint x = base; 
        uint n = mins;
        while (n > 1) {
            if (n % 2 == 0) { 
                x = SoladyMath.fullMulDiv(
                         x, x, 1e18); 
                              n /= 2;
            } else { 
                y = SoladyMath.fullMulDiv(
                         x, y, 1e18); 
                x = SoladyMath.fullMulDiv(
                         x, x, 1e18); 
                n = (n - 1) / 2; 
            }
        } return SoladyMath.fullMulDiv(
                      x, y, 1e18);
    }

    // baseRate (Liquity-style directional redemption velocity toll) + BR_DECAY/BR_MAX_MIN + touchBaseRate

    uint public constant DEPEG_DEADZONE_BPS = 50; // live-feed peg tolerance (bps);
                                            // below this a stable is "healthy" (absorbs
                                            // Chainlink's deviation range + heartbeat noise)
    uint public constant BASE = 3;          // 0.03% baseline outflow fee (bps)
    uint public constant MAX_FEE = 30;      // 0.3% cap on the composite outflow fee
                                            // (the ether.fi-redeem-equivalent ceiling;
                                            // the depeg HAIRCUT via calcRisk is separate
                                            // and uncapped — fee ≠ pass-through loss)

    /// @notice Per-stable risk score in bps, sourced from the simplified
    ///         Link oracle. 0 if not depegged; otherwise the severity bps
    ///         (capped at 10000). No prior, no Bayesian blend — Link is
    ///         the authoritative signal.
    function calcRisk(address token, address range)
        internal view returns (uint)
    {
        if (range == address(0) || token == address(0)) return 0;
        try IAux(range).getDepegSeverityBps(token) returns (uint s) {
            if (s == 0) return 0;
            return s > 10000 ? 10000 : s;   // Recognize FULL severity (was capped at 3500/65c)
        } catch {
            return 0;
        }
    }

    /// ⛔ THE DOCBLOCK THAT STOOD HERE WAS THE OBITUARY OF THE FUNCTION THIS ONE REPLACED, AND IT SAT
    ///    DIRECTLY ABOVE ITS REPLACEMENT. It read *"Composite fee on a specific stable, factoring in
    ///    basket-wide exposure (Σ share_i × risk_i). When no stable is depegged, totalExposure = 0 →
    ///    BASE fee."* The body computes no exposure sum and holds no such variable: **`totalExposure`
    ///    has exactly ONE occurrence in all of `evm/src`, and it was that comment.** The very next
    ///    line says so outright — *"this REPLACES the old risk-weighted concentration term"* — so the
    ///    file described the old design and the new one in consecutive sentences, with the dead one
    ///    first. A reader taking the FIRST notice tag as authoritative gets the retired fee model.
    /// ⚠️ AND NEVER WRITE AN AT-PREFIXED TAG NAME INSIDE THE PROSE OF A DOCBLOCK — IT IS HOW THIS
    ///    BLOCK BROKE THE BUILD TWICE, THE SECOND TIME IN THE SENTENCE WARNING ABOUT THE FIRST.
    ///    solc parses an at-word as a natspec TAG wherever it appears, not only at the start of a
    ///    line, and backticks do not escape it: the tag name simply absorbed the closing backtick.
    ///    The failure reads `Documentation tag ... not valid for functions` and points at the FIRST
    ///    line of the docblock, tens of lines above the offending word, so it names neither the
    ///    word nor the line. Spell such tags out in words, as "the first notice tag" above.
    /// @notice Composite L1 fee on draining `idx`-th stable, driven by the
    ///         YIELD-vs-weighted-average BASELINE (this REPLACES the old
    ///         risk-weighted concentration term).
    ///
    ///   baseline = basket weighted-average yield factor  = Σyieldᵢ / Σdepᵢ
    ///   mine     = this stable's yield factor            = yieldᵢ / depᵢ
    ///
    ///         Draining a stable whose factor is ABOVE the basket average
    ///         lowers that average, so it's taxed in proportion to the
    ///         excess (the "reduces the weighted-average yield" measure).
    ///         At/below average → BASE (cheap: draining it heals or is
    ///         neutral to basket yield). A depegged stable's `yield` is
    ///         already discounted upstream in get_deposits, which drags
    ///         `mine` down to/under baseline → it lands at BASE here too,
    ///         so "cheap to drain the bad collateral" is preserved with no
    ///         separate risk term. All inputs are in memory (no vault re-
    ///         read): `yields` is the per-stable yield-weighted array that
    ///         get_deposits already computed.
    function calcFeeL1(uint idx, uint[15] memory deps, uint[15] memory yields)
        public pure returns (uint)
    {
        uint total = deps[14];
        if (total == 0) return BASE;
        uint myDep = deps[idx + 1];
        if (myDep == 0) return BASE;
        uint baseline = SoladyMath.fullMulDiv(deps[0], WAD, total);
        uint mine     = SoladyMath.fullMulDiv(yields[idx + 1], WAD, myDep);
        if (mine <= baseline) return BASE;
        uint feeBps = SoladyMath.fullMulDiv(mine - baseline, 10000, WAD);
        if (feeBps < BASE) return BASE;
        return feeBps > MAX_FEE ? MAX_FEE : feeBps;
    }


    /// @notice Gross-up the amount a depositor must send to net the
    ///         requested amount after fee + depeg haircut. Aux uses this
    ///         to compute the deposit size needed to honour a mint at
    ///         book value when the target stable is currently discounted.
    /// @notice Immutable fee-context bundle threaded through calcNeeded/allocate.
    ///         Bundling these TWO (vs passing them individually) keeps the
    ///         redemption path (BasketLib.takeBody) within the legacy stack — no
    ///         via_ir crutch. The MUTATED deps/yields arrays stay SEPARATE
    ///         by-reference args (a fixed-array member would be COPIED into the
    ///         struct, silently breaking the loop's in-place mutation semantics).
    struct FeeCtx {
        address[] stables;
        address range;
    }

    /// @notice Gross up `amount` for a depegged leg — deliver more units of the cheap collateral for the same
    ///         USD value. `sev` = depeg severity bps (0 or ≥10000 ⇒ no-op). ONE definition shared by calcNeeded
    ///         / applyFeeAndHaircut / allocate.
    function grossUpForDepeg(uint amount, uint sev) internal pure returns (uint) {
        return (sev > 0 && sev < 10000) ? SoladyMath.fullMulDiv(amount, 10000, 10000 - sev) : amount;
    }

    function calcNeeded(address token, uint amount,
        uint[15] memory deps, uint[15] memory yields, FeeCtx memory c)
        external view returns (uint needed)
    {
        // Concentration/cherry-pick fee is NO LONGER CHARGED to the user (baseRate already removed). The
        // concentration `calcFeeL1` signal (yield-vs-baseline) survives ONLY as a ROUTING input.
        // The sole outflow COST is the depeg haircut, and only during an actual depeg. deps/yields/c.stables
        // are retained in the signature for the lens seam (unused here).
        // 🔴 THE JUSTIFICATION FOR RETAINING THEM NAMED A COMPONENT THAT IS DELETED. It read *"SOR
        // (`_pickBestPath`) still ranks paths by concentration + hop-count"*. `Aux.sol:819` is headed
        // **"§E233-sor — THE SOR IS DELETED: PLUMBING FOR A CAPABILITY THAT WAS ALREADY GONE"**, and
        // `_pickBestPath` has ZERO references anywhere in `evm/src`. ⇒ The "SOR seam" these unused
        // parameters are held open for does not exist, so what is left is the lens seam alone.
        // ⚠️ THAT MAKES THE RETENTION A LIVE QUESTION RATHER THAN A SETTLED ONE — booked, not fixed
        // here: changing this signature is a cross-file edit (`BasketLib` calls it) and this lane
        // cannot compile. See the report accompanying this commit for `calcFeeL1` itself, whose only
        // remaining consumers are tests.
        deps; yields;
        needed = grossUpForDepeg(amount, calcRisk(token, c.range));
    }

    /// @notice Apply fee + depeg haircut to a paid-out amount in one call.
    function applyFeeAndHaircut(address token, uint idx,
        uint amount, uint[15] memory deps, uint[15] memory yields,
        address range) external view returns (uint)
    {
        // Concentration/cherry-pick fee no longer charged (only the depeg haircut is). idx/deps/yields kept in
        // the signature for callers; concentration survives as a SOR routing signal only.
        idx; deps; yields;
        return grossUpForDepeg(amount, calcRisk(token, range));
    }

    /// @notice Pro-rata allocation + fee + haircut in one call. Computes
    ///         each slot's share of `totalAmount` proportional to
    ///         slotDep/totalDep, then applies fee and haircut.
    function allocate(address token, uint totalAmount, uint slotDep,
        uint totalDep, FeeCtx memory c) external view returns (uint amount)
    {
        if (totalDep == 0 || slotDep == 0) return 0;
        amount = SoladyMath.fullMulDiv(totalAmount,
            SoladyMath.fullMulDiv(WAD, slotDep, totalDep), WAD);
        if (amount == 0) return 0;
        // Pro-rata draws the SAME fraction of every stable → the basket mix (and its weighted-avg yield) is
        // unchanged → ZERO cherry-pick externality, so NO fee here (the concentration/cherry-pick fee is priced
        amount = grossUpForDepeg(amount, calcRisk(token, c.range));
    }

    /// @notice Risk-weighted discount factor for a stablecoin's basket
    ///         valuation. Returns bps in [0, 10000]: 10000 = no discount, lower =
    ///         larger discount, 0 = worthless (recognizes the FULL live severity;
    ///         the old 6500/65c floor understated severe depegs). When NORMAL, Link
    ///         returns severity 0 → 10000 (no-op).
    function riskFactor(
        address token,
        address range
    ) external view returns (uint factorBps) {
        if (token == address(0)) return 10000;
        // `range` is Aux itself (getDepegSeverityBps reads the per-stable Chainlink
        // feed via liveDepegBps). The CRE that once answered this was removed; the
        // on-chain feed IS the depeg signal now. A revert is treated as healthy.
        uint sev;
        try IAux(range).getDepegSeverityBps(token) returns (uint s) {
            sev = s;
        } catch {
            return 10000;
        }
        if (sev == 0) return 10000;
        factorBps = sev >= 10000 ? 0 : 10000 - sev;   // full severity, clamped to [0, 10000]
    }

    /// @notice Downside deviation (bps) of a stable's USD feed below $1 — the depeg
    ///         severity, sourced directly from the pinned Chainlink feed (this is what
    ///         Aux.getDepegSeverityBps returns). A feed that is stale / reverting /
    ///         zero / at-or-above peg returns 0 (healthy). A deadzone absorbs benign
    ///         sub-peg noise (Chainlink's deviation range + heartbeat lag). Deliberately
    ///         NOT treating a stale feed as max-severity: a benign heartbeat lapse must
    ///         not inflict a redemption haircut on an otherwise-healthy stable.
    function liveDepegBps(address feed, uint maxAge)
        public view returns (uint)
    {
        try IAggregatorV3(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return 0;
            if (maxAge != 0 && block.timestamp > updatedAt
                && block.timestamp - updatedAt > maxAge) return 0; // stale → defer to CRE
            uint8 dec;
            try IAggregatorV3(feed).decimals() returns (uint8 d) { dec = d; }
            catch { return 0; }
            uint peg = 10 ** dec;
            uint price = uint(answer);
            if (price >= peg) return 0;             // at/above peg → no risk
            uint down = ((peg - price) * 10000) / peg;   // downside bps
            // Deadzone: Chainlink stable feeds carry a deviation range (~0.25–0.5%)
            // and update on deviation OR a ~24h heartbeat, so a perfectly healthy
            // stable routinely sits a few–tens of bps below $1 between updates.
            // Without a deadzone the live leg would haircut EVERY deposit/redeem on
            // that benign noise (and diverge from the CRE, which medians+quantizes
            // to ≈0 in steady state). Treat anything within DEADZONE of peg as
            // healthy; a real depeg (hundreds–thousands of bps) clears it easily.
            return down <= DEPEG_DEADZONE_BPS ? 0 : down;
        } catch {
            return 0;
        }
    }

    /// @dev Multi-venue 4626 withdraw (the INNER pro-rata dimension), relocated
    ///      from BasketLib to even out the EIP-170 budget. Single-vault collapses
    ///      to the legacy single redeem; multi draws each vault in proportion to its
    ///      balance (pass 1, floored) then sweeps the remainder (pass 2). Runs in
    ///      Aux's context (delegatecall → address(this)==Aux holds the shares).
    /// @param aaveSpoke  the AAVE-v4 spoke sentinel; a `vs[j] == aaveSpoke`
    ///                   entry is the dual-venue (USDC/USDT) Aave leg — its
    ///                   balance is read via aaveBalance(stable) and it is
    ///                   withdrawn via withdrawAaveLeg(stable,…) instead of an
    ///                   ERC4626 redeem. For 4626-only stables (aaveSpoke not
    ///                   present in vs) behavior is IDENTICAL to before.
    /// @param stable     the underlying stable (only needed for the Aave leg's
    ///                   reserve-id resolution + delivery token).
    function multiVaultWithdrawBody(address[] memory vs, uint amount, address to,
        address aaveSpoke, address stable)
        external returns (uint sent) {
        if (vs.length == 1) {
            if (vs[0] == aaveSpoke) {
                uint cap = IAux(address(this)).aaveBalance(stable);
                if (cap == 0) return 0;
                uint want = Math.min(amount, cap);
                return IAux(address(this)).withdrawAaveLeg(stable, want, to);
            }
            uint shares = _shareCap(vs[0], amount);
            if (shares == 0) return 0;
            return IERC4626(vs[0]).redeem(shares, to, address(this));
        }
        uint n = vs.length;
        uint total;
        uint[] memory bals = new uint[](n);
        for (uint j; j < n; j++) {
            if (vs[j] == aaveSpoke) {
                // Aave leg balance = our reserve-supplied (asset-denominated),
                // the same read get_deposits/_valueStable uses.
                bals[j] = IAux(address(this)).aaveBalance(stable);
            } else {
                // Reverting vault → bals[j]=0 → skipped in both passes below.
                try IERC4626(vs[j]).balanceOf(address(this)) returns (uint sh) {
                    try IERC4626(vs[j]).convertToAssets(sh) returns (uint a) { bals[j] = a; } catch {}
                } catch {}
            }
            total += bals[j];
        }
        if (total == 0) return 0;
        uint remaining = amount;
        for (uint j; j < n && remaining > 0; j++) {
            if (bals[j] == 0) continue;
            uint want = SoladyMath.fullMulDiv(
                        amount, bals[j], total);
            if (want > remaining) want = remaining;
            if (want == 0) continue;
            uint got = _withdrawLeg(vs[j],
             aaveSpoke, stable, want, to);
            sent += got;
            remaining = got >= remaining ? 
                           0 : remaining - got;
        }
        for (uint j; j < n && remaining > 0; j++) {
            if (bals[j] == 0) continue; // Skip empty / reverting-read vaults
            uint got = _withdrawLeg(vs[j], aaveSpoke, stable, remaining, to);
            sent += got;
            remaining = got >= remaining 
                         ? 0 : remaining - got;
        } return sent;
    }

    /// @dev Withdraw `want` (asset-denominated) from one venue leg of a stable.
    ///      The Aave spoke leg goes through withdrawAaveLeg (capped at our
    ///      supplied balance); every other leg is a 4626 redeem of the
    ///      share-capped amount. Returns assets actually delivered to `to`.
    function _withdrawLeg(address v, address aaveSpoke, address stable,
        uint want, address to) private returns (uint) {
        if (v == aaveSpoke) {
            uint cap = IAux(address(this)).aaveBalance(stable);
            if (cap == 0) return 0;
            uint w = Math.min(want, cap);
            if (w == 0) return 0;
            return IAux(address(this)).withdrawAaveLeg(stable, w, to);
        }
        uint shares = _shareCap(v, want);
        if (shares == 0) return 0;
        return IERC4626(v).redeem(shares, to, address(this));
    }

    /// @dev convertToShares(amount) capped at the holder's balance — the share
    ///      side of a 4626 withdrawal, used by multiVaultWithdrawBody above.
    function _shareCap(address vault, uint amount) private view returns (uint) {
        uint bal = IERC4626(vault).balanceOf(address(this));
        uint sh = IERC4626(vault).convertToShares(amount);
        return Math.min(bal, sh);
    }
}
