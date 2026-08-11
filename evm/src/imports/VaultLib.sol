// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapLib} from "./SwapLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
// §E57: ether.fi's native-ETH sentinel, moved here with the offramp body that is its only user.
import {IV3SwapRouter} from "./v3/IV3SwapRouter.sol";
import {IEtherFiLiquidityPool} from "./Interfaces.sol";   // §E57: the shared OfframpCfg shape (declared there;  still uses it)
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {SwapLib} from "./SwapLib.sol";
import {IAaveV4Spoke} from "./Interfaces.sol";
import {IWeETH} from "./Interfaces.sol";
import {IDepositAdapter} from "./Interfaces.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";

// The ETH-venue ladder's external surface is the canonical `IAux` in Interfaces.sol (`vaultBlocked`
// — vault-health state stays Aux-owned). The Rover supply-leg surface went with Rover (2026-08-05).
//
/// Morpho-V2 MARKER (NOT MetaMorpho v1.1, which has a withdrawQueue instead). A V2 vault keeps its
/// assets in ADAPTERS and auto-allocates on deposit, so its ERC-4626 max-views track IDLE rather than
/// what the holder owns. `liquidityAdapter()` is the cheapest published read that only a V2 exposes, so
/// we use it purely to IDENTIFY the impl — see `_withdrawableOf`.
///
/// `forceDeallocate`/`liquidityData` were removed 2026-07-26: PROBED against real Galaxy, the call
/// SUCCEEDS and returns `penaltyAssets: 0` while leaving `maxWithdraw` at 0, because `liquidityData()`
/// names ONE market and the vault's assets sit in others. It cost ~113k gas per pull and freed nothing.
/// It is also unnecessary — `withdraw()` self-deallocates (see `_withdrawableOf`).
interface IMorphoV2 {
    function liquidityAdapter() external view returns (address);
}

/// @title  VaultLib — the ETH yield-venue custody ladder extracted from Vault
///         to free bytecode under the EIP-170 limit. DELEGATECALL'd by Vault:
///         inside each public function `address(this)` resolves to the Vault,
///         so all token custody, balances, and the AAVE/4626/Rover positions
///         are the Vault's. The library holds NO storage; every immutable Vault
///         reads (WETH/AUX/GALAXY/EULER/AAVE spoke+reserveId/WEETH/EETH/
///         LEV_MANAGER) is passed in via `EthCfg`. Semantics are byte-for-byte
///         with the former in-Vault bodies — only the home moved.
library VaultLib {
    /// §E57: moved with the offramp body — its only emitter.


    // Mirror Vault's custom errors so reverts from delegatecalled bodies carry
    // the SAME 4-byte selector (selector = keccak(name+args), name-derived).

    /// @dev Vault's ETH-venue immutables, gathered so the delegatecalled library
    ///      can operate on them (it can't read Vault's immutable slots).
    struct EthCfg {
        address weth;
        address aux;
        address galaxy;
        address euler;
        address gauntlet;
        address aaveSpoke;
        uint256 wethReserveId;
        address weeth;
        address eeth;        // ETHERFI_EETH (raw eETH transiently held mid wait-NFT)
        address levManager;
    }

    /// ether.fi deposit adapter — the SAME compile-time constant Vault pins (ETHERFI_ADAPTER); kept here so
    /// supplyVenueBody (kind 1) needs no extra EthCfg field across its 12 build sites.
    address internal constant ETHERFI_ADAPTER_VL = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;

    // ── Venue valuation ───────────────────────────────────────────────────

    /// @dev ETH-equivalent value of our position in a WETH 4626 venue (Galaxy or
    ///      Euler). A BLOCKED (incident) venue is valued at its WITHDRAWABLE
    ///      amount (maxWithdraw); else the optimistic convertToAssets.
    function _venue4626Value(address vault, address aux) internal view returns (uint) {
        if (vault == address(0)) return 0;
        // A venue whose 4626 VIEW functions REVERT (self-destructed / paused-that-reverts /
        // malicious) must value at 0 — never brick EVERY ETH LP's withdraw + the backing read.
        // This helper feeds _syncYield / vogueETH / get_deposits (and AUX.tryCheckBacking on the
        // withdraw path), all of which run bare today; full utilization already returns 0 from a
        // LIVE venue, but a throwing view would revert the whole call. Valuing a throwing venue at
        // 0 is the conservative side (understates backing ⇒ cannot over-mint), and the LP's
        // undelivered slice stays a recoverable deferral (re-withdrawn once the venue is fixed).
        try IERC20(vault).balanceOf(address(this)) returns (uint shares) {
            if (shares == 0) return 0;
            if (IAux(aux).vaultBlocked(vault)) {
                // ONE definition (2026-07-26). This was the LAST raw `maxWithdraw` reader and the most
                // dangerous one left: it is the SOLVENCY read (feeds vogueETH / get_deposits /
                // tryCheckBacking), so on a Morpho-V2 venue — whose max-view reports 0 against a fully
                // recoverable position — blocking Galaxy or Gauntlet would have written their ENTIRE
                // backing to zero in one call and broken `D >= S + L` on a healthy protocol. Since the
                // poke that sets `blocked` now uses this same definition, a V2 venue can no longer be
                // blocked off that false signal either; the two fixes have to agree or the write-down
                // contradicts the trigger.
                return _withdrawableOf(vault, address(this));
            }
            try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; } catch { return 0; }
        } catch { return 0; }
    }

    /// @dev WETH currently supplied to AAVE-v4 (yield-accrued). 0 if unwired.
    ///      Gate on `aaveSpoke`, NOT on `wethReserveId`: reserve 0 is a legitimate reserve
    ///      (mainnet WETH == asset 0 == reserve 0), so a zero-id check disables a live venue.
    function _aaveBal(EthCfg memory c) internal view returns (uint) {
        if (c.aaveSpoke == address(0)) return 0;
        return IAaveV4Spoke(c.aaveSpoke).getUserSuppliedAssets(c.wethReserveId, address(this));
    }

    /// @notice Public AAVE-WETH balance read (Vault.aaveEthBalance forwards here).
    function aaveBal(EthCfg memory c) public view returns (uint) {
        return _aaveBal(c);
    }

    /// @dev The WETH-4626 curator set, in ONE place. Every consumer (`_vogueETH` value sum,
    ///      `deliverableETH` caps, the `withdrawETH` pull ladder, the `evacuate` membership check)
    ///      used to enumerate `c.galaxy`/`c.euler`/`c.gauntlet` by hand — 9 sites over 3 addresses,
    ///      so a 4th curator meant editing every one and an omission was silent. Now they loop.
    ///      NOTE the slots MUST stay pairwise distinct: these are SUMMED into backing, so aliasing
    ///      two of them double-counts (measured: vogueETH 14 for a 10 ETH deposit when gauntlet
    ///      aliased euler). `Vault`'s ctor enforces distinctness ("vault:dupVenue").
    function _venues(EthCfg memory c) internal pure returns (address[3] memory) {
        return [c.galaxy, c.euler, c.gauntlet];
    }

    /// @dev Body of Vault.vogueETH — AGGREGATE ETH-equivalent backing across the
    ///      depositor-chosen venues.
    function _vogueETH(EthCfg memory c) internal view returns (uint total) {
        address[3] memory venues = _venues(c);
        for (uint i; i < 3; ++i) total += _venue4626Value(venues[i], c.aux);
        if (c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) total += IWeETH(c.weeth).getEETHByWeETH(w);
        }
        total += _aaveBal(c);
        // Idle WETH is still ETH backing — count it at BOTH the Vault (venue
        // custody, evacuated remainders) AND Aux (transient swap/deposit legs).
        total += IERC20(c.weth).balanceOf(address(this));
        total += IERC20(c.weth).balanceOf(c.aux);
        // Raw eETH transiently sits here mid wait-NFT withdrawal — real backing,
        // counted at BOTH Vault and Aux so a partial failure never strands it.
        if (c.eeth != address(0)) {
            total += IERC20(c.eeth).balanceOf(address(this));
            total += IERC20(c.eeth).balanceOf(c.aux);
        }
        // IL-protect: count the leveraged book's net-equity (gross collateral - debt), not gross. The buffer
        // half is debt-funded (offset by the LP's borrow), so counting gross would overstate solvency by the debt
        // -- the same error the fold fixed for `committed`. Net-equity is the LP's real deliverable claim (what
        // `closeLev` returns after auto-repaying the debt). The 2x band depth is untouched -- it lives in
        // `levPooled = gross`, not here. try/catch degrades to "no lev credit". Unified with the BTC model.
        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquityEth() returns (uint n) { total += n; } catch {}
        }
    }

    /// @notice Body of Vault.vogueETH.
    function vogueETH(EthCfg memory c) public view returns (uint) {
        return _vogueETH(c);
    }

    /// @dev Deliverable cap for one UNBLOCKED 4626 venue: subtract the
    ///      undeliverable slice (convertToAssets − maxWithdraw) so the redemption
    ///      ETH leg defers it rather than over-burning.
    function _deliverableCap(address vault, address aux, uint total) internal view returns (uint) {
        if (vault == address(0)) return total;
        uint shares = IERC20(vault).balanceOf(address(this));
        if (shares == 0 || IAux(aux).vaultBlocked(vault)) return total;
        uint solvent = IERC4626(vault).convertToAssets(shares);
        // ONE definition, shared with `_pull4626` and `evacuate` (see `_withdrawableOf`). For a
        // Morpho-V2 venue this equals `solvent`, so the haircut below is correctly ZERO — the old raw
        // `maxWithdraw` read it as 0 withdrawable and haircut the ENTIRE position, which is what made
        // `deliverableETH` return 0 against 16 solvent ETH in Galaxy. Still fully guarded: a venue whose
        // view reverts is treated as 0 withdrawable = the CONSERVATIVE side (defers, never over-promises).
        uint withdrawable = _withdrawableOf(vault, address(this));
        if (solvent > withdrawable) {
            uint undeliverable = solvent - withdrawable;
            return total > undeliverable ? total - undeliverable : 0;
        }
        return total;
    }

    /// @notice Body of Vault.deliverableETH — SOLVENCY-side ETH backing with PARTIAL liquidity haircuts.
    ///
    /// @dev    READ THE NAME NARROWLY (§A.5c, re-derived 2026-07-27). This is NOT a promptness
    ///         guarantee and NOT a view-twin of the withdraw ladder. It caps the three WETH-4626
    ///         venues via `_deliverableCap` and subtracts the levered net equity, but it counts the
    ///         AAVE-v4 leg, weETH at the Vault, raw eETH, and Rover at FULL FACE — none of which is
    ///         instantly convertible (the ether.fi legs need the offramp ladder, whose rung 1 is a v3 pool
    ///         sale at up to the 0.5% slippage cap and whose rung 2 is a multi-day wait NFT — there is NO
    ///         deterministic-cost tier between them since the instant-redeem was removed 2026-08-06).
    ///
    ///         WHY THAT IS SAFE RATHER THAN A BUG — it is not load-bearing for delivery. Its two
    ///         consumers both tolerate over-statement:
    ///           • `Vogue` uses it ONLY to cap `firstBurn`, i.e. how much of a withdrawal is sourced
    ///             from the in-range band burn before the venue ladder takes the remainder. The
    ///             shortfall is then derived from the ACTUAL `sent`, never from this number, so an
    ///             over-statement shifts the sourcing ORDER and self-corrects.
    ///           • `SwapLib.deleverEthOnDelivery` gates the swap-out de-lever; under-triggering there
    ///             is caught downstream by `minOut` + deferral (§A.29).
    ///         Measured: exit fairness holds to 1%, and a full exit strands < 1 gwei
    ///         (`test_RunSim_AllExit_Normal`). Do NOT "fix" this by rebuilding it as a ladder twin
    ///         without first re-establishing a harm — the previous attempt to do so rested on a
    ///         19.4%-short figure that measurement showed to be stale (~3%, and DEFERRED not lost).
    function deliverableETH(EthCfg memory c) public view returns (uint total) {
        total = _vogueETH(c);
        address[3] memory venues = _venues(c);
        for (uint i; i < 3; ++i) total = _deliverableCap(venues[i], c.aux, total);
        // The leverage net-equity is solvency backing (now counted in vogueETH as net) but NOT deliverable
        // from this Vault (unwind-only via closeLev -- the LP gets it back by repaying debt + withdrawing coll,
        // not from redemption). Exclude the same net-equity term vogueETH added, so deliverableETH == base
        // (non-levered venue ETH), byte-identical to the prior gross-in/gross-out result. Redemptions never draw it.
        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquityEth() returns (uint n) {
                total = total > n ? total - n : 0;
            } catch {}
        }
    }

    // ── Supply ────────────────────────────────────────────────────────────

    /// @dev Deposit `amount` WETH to a WETH 4626 venue (Galaxy or Euler). INCIDENT:
    ///      blocked/reverting venue → AAVE haven if wired, else hold at the Vault.
    ///      A SUCCESS that mints 0 shares reverts (never credit unbacked WETH).
    function _supply4626(EthCfg memory c, address vault, uint amount) internal returns (uint) {
        if (amount == 0) return 0;
        if (vault != address(0) && !IAux(c.aux).vaultBlocked(vault)) {
            try IERC4626(vault).deposit(amount, address(this)) returns (uint sh) {
                require(sh > 0, "v4626:0");
                return amount;
            } catch {}
        }
        if (c.aaveSpoke != address(0))   // reserve 0 is valid — spoke is the wiring flag
            IAaveV4Spoke(c.aaveSpoke).supply(c.wethReserveId, amount, address(this));
        return amount;
    }

    /// @notice WETH supply — default Galaxy (Morpho 4626). Only WETH is accepted.
    function supplyETH(EthCfg memory c, address token, uint amount) public returns (uint) {
        require(token == c.weth, "ethv:notWeth");
        return _supply4626(c, c.galaxy, amount);
    }

    /// @notice ETH-venue = Euler (second WETH 4626 curator).
    function supplyEuler(EthCfg memory c, uint amount) public returns (uint) {
        return _supply4626(c, c.euler, amount);
    }

    /// @notice ETH-venue = Gauntlet (third WETH 4626 curator).
    function supplyGauntlet(EthCfg memory c, uint amount) public returns (uint) {
        return _supply4626(c, c.gauntlet, amount);
    }

    /// @notice Consolidated venue-supply body — the `transferFrom` + venue call for every ETH supply wrapper, so the
    ///         Vault forwarders keep ONLY their `NotVogueCore`/`NotAux` gate (bytecode OUTSIDE the EIP-170-critical
    ///         Vault). `kind`: 0=(removed, was Rover), 1=ether.fi adapter stake, 2=AAVE-v4, 3=Euler 4626, 4=Galaxy default
    ///         (`supplyFromAux`), 5=Gauntlet 4626. `from` = the approver the WETH is pulled from (V4 for the venue wrappers, AUX for
    ///         `supplyFromAux`). Each branch is byte-identical to the former in-Vault body (guard → pull → supply).
    /// @dev `kind` IS NOW IGNORED — every venue routes to weETH (see below). Kept so the Vogue/Vault
    ///      call sites and the venue-selection surface need not change in the same commit as the
    ///      routing decision; remove it once the WETH venues are fully drained.
    function supplyVenueBody(EthCfg memory c, uint8 kind, uint amount, address from) public returns (uint) {
        kind;   // retained-but-ignored, see docblock
        if (amount == 0) return 0;
        // ALL ETH SUPPLY IS NOW weETH (owner decision 2026-08-06). Every `kind` routes to the
        // ether.fi adapter; the WETH-holding venues (2 AAVE-v4, 3 Euler, 4 Galaxy, 5 Gauntlet) are no
        // longer supplied to.
        //
        // WHY: holding weETH earns the ether.fi ratchet, MEASURED at +0.674 bps/day = 2.46%/yr
        // (`analysis/rover/decompose.py`). That is the hurdle any WETH-holding venue must clear just
        // to break even, before conversion friction each way. AAVE v4 measured 2026-08-06 on live
        // mainnet: WETH 21,103 supplied / 400 borrowed = 1.90% utilisation ⇒ supply APY in SINGLE
        // BASIS POINTS; weETH 714 supplied / ZERO borrowed = 0.00% ⇒ exactly zero yield whatever the
        // rate curve says. Supplying WETH there is a strict loss of ~2.46 points, and the only thing
        // it buys is borrow capacity against the collateral — which is encumbrance (the offramp
        // design), not yield.
        //
        // ⚠️ SUPPLY ONLY. The withdraw ladder below is DELIBERATELY UNTOUCHED so existing positions in
        // those venues stay pullable. Do not remove the withdraw rungs until the balances are drained.
        if (ETHERFI_ADAPTER_VL == address(0)) return 0;
        IERC20(c.weth).transferFrom(from, address(this), amount);
        IDepositAdapter(ETHERFI_ADAPTER_VL).depositWETHForWeETH(amount, address(this));
        return amount;
    }

    // ── Withdraw ladder ─────────────────────────────────────────────────────

    /// @notice The ONE `withdrawable` definition for a WETH 4626 venue — what it can actually pay us.
    ///
    ///         MORPHO-V2 (2026-07-26, PROBED against the real Galaxy vault). A V2 vault parks its assets
    ///         in ADAPTERS and auto-allocates on deposit, so BOTH its max-views are idle-only: with our
    ///         own 20 ETH position it reported `maxWithdraw == 0` AND `maxRedeem == 0`. That is NOT
    ///         illiquidity — `withdraw(1 ether)` SUCCEEDED (burned 0.9939 shares) and `redeem` returned
    ///         1.875 ETH, because `withdraw()` self-deallocates from the adapters. Clamping a pull by
    ///         `maxWithdraw` therefore means we NEVER TRY: measured, that zeroed `deliverableETH` with
    ///         16 ETH sitting solvent in Galaxy and made EVERY ETH LP exit return 0 while the LP kept a
    ///         full pooled balance. So for a V2 vault the REPORTED position is the deliverable amount.
    ///
    ///         Everything else (Euler, AAVE, MetaMorpho v1.1) has honest max-views — real Euler reports
    ///         `maxWithdraw` equal to the full position — and keeps the conservative read. Both branches
    ///         are try/catch'd: a venue whose view REVERTS (Euler's EVault calls `EVC.getControllers`
    ///         inside `maxWithdraw`; fork-traced) must value at 0 rather than brick every ETH withdraw.
    ///         `holder` is parameterised so the STABLE side (`BasketLib`, whose holder is `Aux`) shares
    ///         this ONE definition rather than keeping a second copy. 6 of our 8 registered stable
    ///         vaults are Morpho-V2 — measured, holding ~124M of ~126M total stable TVL — so the stable
    ///         side had the same understatement, and there it feeds the REDEMPTION haircut.
    function _withdrawableOf(address vault, address holder) internal view returns (uint) {
        try IMorphoV2(vault).liquidityAdapter() returns (address adapter) {
            if (adapter != address(0)) {
                try IERC20(vault).balanceOf(holder) returns (uint shares) {
                    if (shares == 0) return 0;
                    try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; }
                    catch { return 0; }
                } catch { return 0; }
            }
        } catch {}
        try IERC4626(vault).maxWithdraw(holder) returns (uint m) { return m; }
        catch {
            // `maxWithdraw` REVERTED. Euler's EVault does this whenever the holder has no
            // controller enabled on the EVC (fork-traced: `liquidityAdapter()` is also absent on
            // the current implementation, so BOTH probes above miss and we land here). Returning 0
            // valued a real, fully-liquid position at NOTHING — which understated backing and made
            // the venue unwithdrawable, so an LP whose ETH sat in Euler could redeem and receive 0.
            //
            // Fall back to the share value, which is exactly what the `liquidityAdapter` branch
            // above uses for Morpho-V2. It is an UPPER bound on what the venue can pay if the vault
            // is illiquid — but `_pull4626` already clamps the pull to `min(need, maxOut)` and the
            // withdraw itself reverts on real illiquidity, so an over-estimate degrades to a failed
            // pull, whereas 0 silently strands the position. Prefer the recoverable failure.
            try IERC20(vault).balanceOf(holder) returns (uint shares) {
                if (shares == 0) return 0;
                try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; }
                catch { return 0; }
            } catch { return 0; }
        }
    }

    function _pull4626(EthCfg memory c, address vault, uint amount) internal {
        if (vault == address(0)) return;
        uint bal = IERC20(c.weth).balanceOf(address(this));
        if (bal >= amount) return;
        uint need = amount - bal;
        uint maxOut = _withdrawableOf(vault, address(this));
        uint pull = need > maxOut ? maxOut : need;
        if (pull > 0) {
            // OPTIMISTIC-THEN-FALL-BACK. For a Morpho-V2 venue `pull` is the REPORTED position, which
            // the vault satisfies by self-deallocating — but unlike the old `maxWithdraw` clamp it is
            // no longer a figure the venue has itself promised, so a stressed V2 market can legitimately
            // fail to fill it. Retry at the venue's own conservative number instead of reverting the
            // LP's entire withdraw; the unfilled remainder stays a recoverable deferral and the ladder
            // moves to the next source. A venue that fails BOTH is genuinely broken, and that revert is
            // a real fault worth surfacing (a silent short `sent` would be SILENT LP value loss — see
            // withdrawETH's `sent = wethBal >= amount ? amount : wethBal`).
            try IERC4626(vault).withdraw(pull, address(this), address(this)) {}
            catch {
                uint conservative;
                try IERC4626(vault).maxWithdraw(address(this)) returns (uint m) { conservative = m; } catch {}
                if (conservative > need) conservative = need;
                // MUST NOT swallow a zero fallback. On a Morpho-V2 venue `maxWithdraw` is ALWAYS 0, so
                // `conservative == 0` is the GUARANTEED case there, not an edge one — and simply
                // skipping would hand the LP a short delivery reported as success (`withdrawETH`'s
                // `sent = wethBal >= amount ? amount : wethBal`). That is precisely the SILENT LP VALUE
                // LOSS this function's own comment forbids, on 2 of our 3 ETH venues. If the venue
                // cannot fill the optimistic amount AND admits no smaller number, it is genuinely
                // faulted: surface it rather than paying the LP short and calling it done.
                require(conservative > 0, "ethv:venuePullFailed");
                IERC4626(vault).withdraw(conservative, address(this), address(this));
            }
        }
    }

    /// @notice Body of Vault._withdrawETH — idle-then-ether.fi(opportunistic)-then
    ///         -Galaxy/Euler-then-AAVE-then-Rover ladder. Only WETH is served.
    function withdrawETH(EthCfg memory c, SwapLib.OfframpCfg memory off,
        address token, uint amount, address to) public returns (uint sent) {
        if (amount == 0) return 0;
        require(token == c.weth, "ethv:notWeth");
        // Sweep any idle WETH from Aux into the Vault first (Aux approved the Vault),
        // preserving the idle-first ladder (vogueETH counts Aux idle as backing).
        uint auxIdle = IERC20(c.weth).balanceOf(c.aux);
        if (auxIdle > 0) {
            try IERC20(c.weth).transferFrom(c.aux, address(this), auxIdle) {} catch {}
        }
        uint wethBal = IERC20(c.weth).balanceOf(address(this));
        if (wethBal < amount) {
            // OPPORTUNISTIC, NON-BLOCKING: before Galaxy/AAVE, sell idle ether.fi
            // weETH → WETH on the deep pool. Any failure swallowed (returns 0).
            if (SwapLib.sourceWethBody(amount - wethBal, off) > 0)
                wethBal = IERC20(c.weth).balanceOf(address(this));
        }
        if (wethBal < amount) {
            // Galaxy + Euler are fungible; pull from each at its maxWithdraw.
            address[3] memory venues = _venues(c);
            for (uint i; i < 3; ++i) _pull4626(c, venues[i], amount);
            wethBal = IERC20(c.weth).balanceOf(address(this));
            // Still short → pull from the AAVE-v4 WETH venue (ETH venue 2).
            if (wethBal < amount && c.aaveSpoke != address(0)) {   // reserve 0 is valid
                uint need = amount - wethBal;
                uint aaveBalance = IAaveV4Spoke(c.aaveSpoke)
                    .getUserSuppliedAssets(c.wethReserveId, address(this));
                uint apull = need > aaveBalance ? aaveBalance : need;
                if (apull > 0) {
                    try IAaveV4Spoke(c.aaveSpoke).withdraw(
                        c.wethReserveId, apull, address(this)) {} catch {}
                }
                wethBal = IERC20(c.weth).balanceOf(address(this));
            }
        }
        sent = wethBal >= amount ? amount : wethBal;
        if (sent > 0 && to != address(this)) {
            IERC20(c.weth).transfer(to, sent);
        }
        return sent;
    }

    // ── Vault-health evacuate ────────────────────────────────────────────────

    /// @notice Body of Vault.evacuateVenue — ETH-VENUE incident drain for a WETH
    ///         4626 curator (Galaxy or Euler): pull the WITHDRAWABLE WETH to the
    ///         AAVE haven (or hold at the Vault if AAVE-WETH is unwired).
    function evacuate(EthCfg memory c, address vault) public {
        // Membership over the ONE curator set (see `_venues`). The old hand-rolled disjunction had to
        // special-case `vault != address(0)` per slot to stop an UNWIRED (zero) venue matching a zero
        // `vault` argument; hoisting that single check covers all slots at once.
        require(vault != address(0), "ethv:notVenue");
        address[3] memory venues = _venues(c);
        require(vault == venues[0] || vault == venues[1] || vault == venues[2], "ethv:notVenue");
        // Same ONE definition as the ladder (see `_withdrawableOf`), which for a Morpho-V2 venue is the
        // full reported position rather than its idle-only `maxWithdraw`. That matters most here:
        // Galaxy and Gauntlet both sit at 0 idle by policy, so the old bare `maxWithdraw` read returned
        // early and made this emergency rescue a NO-OP on 2 of our 3 ETH venues. Guarded, so a failing
        // venue's own reverting view is not what prevents its rescue.
        uint maxW = _withdrawableOf(vault, address(this));
        if (maxW == 0) return; // genuinely frozen → blocked; vogueETH writes it down
        try IERC4626(vault).withdraw(maxW, address(this), address(this))
            returns (uint got) {
            if (got > 0 && c.aaveSpoke != address(0))   // reserve 0 is valid — see _aaveBal
                IAaveV4Spoke(c.aaveSpoke).supply(c.wethReserveId, got, address(this));
        } catch { /* froze mid-pull: blocked + written down */ }
    }


    // ── ether.fi OFFRAMP (moved from SwapLib, §E57) ──────────────────────────────────────────
    //  Its ONE caller is `Vault.offrampEtherFi` (`Vault.sol:444`), so it was always a VAULT
    //  concern living in a SWAP library. Moving it is not just tidiness: SwapLib was the binding
    //  EIP-170 contract at +14 bytes while VaultLib had 15,040 spare, and E55/E53 need room in
    //  SwapLib specifically. Put the code where the room is — the same trade as E32.
    /// @notice Body of Aux.offrampEtherFi — the exit ladder. TWO rungs, not four: the Rover and
    ///         ether.fi-instant-redeem rungs were removed 2026-08-05/06 (see the block below) and the
    ///         numbering was never renumbered. Rung 1 = v3 pool sale; rung 2 = wait NFT.
    ///         HONEST SERVING: when the held weETH covers less than `amount`
    ///         (clamped balance), both rungs report the
    ///         pro-rata `covered` slice, never the full ask — so the caller's
    ///         position accounting only decrements what was actually served.
    function offrampBody(uint amount, address recipient, SwapLib.OfframpCfg memory c)
        external returns (uint) {
        if (amount == 0 || c.weeth == address(0)) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(amount);
        uint weethIn = weethFull;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        if (weethIn > bal) weethIn = bal;
        uint covered = (weethFull == 0 || weethIn == weethFull)
            ? amount : FullMath.mulDiv(amount, weethIn, weethFull);
        // RUNG 1 — CURVE `weETH/WETH-ng` (only if this contract holds weETH). Replaced a two-tier
        // Uniswap v3 loop 2026-08-09. Measured live against the weETH/WETH oracle, Curve vs the 0.01%
        // v3 tier: −1.39 vs −17.55 bps @1, −1.51 vs −18.79 @100, −3.47 vs −28.16 @1000. ~17–25 bps
        // better at every realistic size, so there is no tier to choose between and no ordering to get
        // wrong. Both venues cliff near 2,000 weETH, where Curve's 2,047 WETH runs out — and THAT is the
        // only case rung 2 now exists for.
        // The 0.5%-of-FAIR floor is retained deliberately: at −1.4 bps typical, a fill that misses it by
        // this margin means the pool has been drained, which is exactly the cliff.
        if (weethIn > 0) {
            uint got = SwapLib.curveSellWeeth(c, weethIn, (covered * 995) / 1000);
            if (got > 0) {
                IERC20(c.weth).transfer(recipient, got);   // Curve pays msg.sender; deliver onward
                return covered;
            }
        }
        // TWO RUNGS REMOVED 2026-08-05/06, both because they could never fill:
        //   * Rover unwind — `c.rover` is always address(0) once nothing funds Rover, so the branch
        //     was unreachable.
        //   * ether.fi 0.3% instant-redeem — `totalRedeemableAmount` measured ZERO at every sampled
        //     block across 90 days and still does, because the v3 pool absorbs the flow first. Its
        //     test only ever passed by MANUFACTURING capacity (vm.deal + a mocked withdrawal lock),
        //     so it guarded a path live state has never once permitted.
        // RUNG 2 (last) — no-fee withdrawal NFT, minted to the WITHDRAWER.
        //
        // ⚠️ THE LADDER IS TWO RUNGS, AND THE INTENDED FIRST RUNG IS MISSING. Today it sells weETH on v3
        // (rung 1) and falls back to a redemption claim (rung 2). The DESIGN is: BORROW WETH against the
        // weETH, deliver that, and repay from the redemption — with the v3 pool as the borrow's ONLY
        // alternative (owner, 2026-08-09). Under that design `waitNft` stops being a way to serve an LP
        // and becomes the REPAYMENT of the borrow.
        //
        // The ~25.6 bps sale is charged ONLY on the slice `weethIn` covers — i.e. the weETH this contract
        // holds FREE (`:452-457` clamps to `balanceOf(address(this))`). Levered collateral sits in per-LP
        // venue escrows and is untouchable here, so the sale is a bounded slice, NOT the whole withdrawal.
        // ⚠️ That makes it LARGEST IN BOOTSTRAP, when little is levered and most weETH is free.
        //
        // ▶️ Building it is NOT deploy config (an earlier note here said so, wrongly). Venue `borrow` is
        // `onlyManager`, so the entrypoint must live on `LevManager` — and with ~100 free bytes there it
        // needs the repo's forwarder shape: thin function in `LevManager`, body in `LevMath` (439 free).
        // The protocol's debt is then seeded into `LevManager.totalDebtUsd`, which already flows to
        // `Core._bandEquityUsd18` → `committedUsd18`; NO new accounting term (adding one double-subtracts).
        return waitNft(covered, recipient, c);
    }


    /// @notice Rung-2 (last) wait-NFT, standalone: unwrap up to `amount`-worth of the
    ///         held idle weETH → eETH → LiquidityPool withdraw-request NFT
    ///         minted to `recipient`. Returns the ETH-worth actually covered
    ///         (honest: a clamped weETH balance covers proportionally less).
    ///         Used by offrampBody — the LP-exit down-leg fallback when the v3
    ///         pool sale above it fails its 0.5% floor (the redemption-side
    ///         wrapper was removed: redemption is stables-only). ⚠️ It is the ONLY
    ///         thing under rung 1: there is no instant-redeem buffer to exhaust
    ///         first, so a pool that cannot fill puts the withdrawer straight
    ///         into a multi-day queue.
    function waitNft(uint amount, address recipient, SwapLib.OfframpCfg memory c)
        internal returns (uint) {
        if (amount == 0 || c.weeth == address(0) || c.lp == address(0)) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(amount);
        if (weethFull == 0) return 0;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        uint weethIn = weethFull > bal ? bal : weethFull;
        if (weethIn == 0) return 0;
        try IWeETH(c.weeth).unwrap(weethIn) returns (uint eeth) {
            if (eeth > 0) {
                // TO THE WITHDRAWER. This was briefly changed to `address(this)` on 2026-08-06 so the
                // NFT could serve as the repayment leg of a WETH borrow -- but that change was
                // COUPLED to a borrow leg that does not exist, and worse, cannot exist against this
                // venue: MorphoEscrowVenue.borrow(lp, stableAmount) lends STABLE, not WETH, so
                // "borrow WETH against weETH" has no market behind it. Borrowing would yield stable
                // needing a stable->WETH leg, i.e. the SOR double-charge the design exists to avoid.
                // While mis-set, ANY exit reaching this rung delivered the withdrawer NOTHING while
                // taking their weETH -- caught by three tests all reporting "delivered ETH: 0".
                // Do not repoint this again without a weETH-collateral / WETH-loan market AND the
                // claim-and-repay step landed together.
                try IEtherFiLiquidityPool(c.lp).requestWithdraw(recipient, eeth) returns (uint) {
                    return weethIn == weethFull
                        ? amount : FullMath.mulDiv(amount, weethIn, weethFull);
                } catch {}
            }
        } catch {}
        return 0;
    }

}
