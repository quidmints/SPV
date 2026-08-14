// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapLib} from "./SwapLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
// §E57: ether.fi's native-ETH sentinel, moved here with the offramp body that is its only user.
import {IEtherFiLiquidityPool} from "./Interfaces.sol";   // §E57: the shared OfframpCfg shape (declared there;  still uses it)
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {SwapLib} from "./SwapLib.sol";
import {IAaveV4Spoke} from "./Interfaces.sol";
import {IWeETH} from "./Interfaces.sol";
import {ICurvePool} from "./Interfaces.sol";
import {IDepositAdapter} from "./Interfaces.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";

// The ETH-venue ladder's external surface is the canonical `IAux` in Interfaces.sol (`vaultBlocked`
// — vault-health state stays Aux-owned).
//
/// @title  VaultLib — the ETH yield-venue custody ladder extracted from Vault
///         to free bytecode under the EIP-170 limit. DELEGATECALL'd by Vault:
///         inside each public function `address(this)` resolves to the Vault,
///         so all token custody, balances, and the AAVE/weETH positions
///         are the Vault's. The library holds NO storage; every immutable Vault
///         reads (WETH/AUX/GALAXY/EULER/AAVE spoke+reserveId/WEETH/EETH/
///         LEV_MANAGER) is passed in via `EthCfg`. Semantics are byte-for-byte
///         with the former in-Vault bodies — only the home moved.
/// Morpho-V2 MARKER (NOT MetaMorpho v1.1, which has a withdrawQueue instead). A V2 vault keeps its
/// assets in ADAPTERS and auto-allocates on deposit, so its ERC-4626 max-views track IDLE rather than
/// what the holder owns. `liquidityAdapter()` is the cheapest published read that only a V2 exposes, so
/// we use it purely to IDENTIFY the impl — see `_withdrawableOf`.
///
/// We do NOT call `forceDeallocate`/`liquidityData`: probed live, the call SUCCEEDS and returns
/// `penaltyAssets: 0` while leaving `maxWithdraw` at 0, because `liquidityData()` names ONE market
/// and the vault's assets sit in others. ~113k gas per pull, freeing nothing.
/// It is also unnecessary — `withdraw()` self-deallocates (see `_withdrawableOf`).
interface IMorphoV2 {
    function liquidityAdapter() external view returns (address);
}

library VaultLib {
    /// §E57: moved with the offramp body — its only emitter.


    // Mirror Vault's custom errors so reverts from delegatecalled bodies carry
    // the SAME 4-byte selector (selector = keccak(name+args), name-derived).

    /// @dev Vault's ETH-venue immutables, gathered so the delegatecalled library
    ///      can operate on them (it can't read Vault's immutable slots).
    struct EthCfg {
        address weth;
        address aux;
        address curvePool;   // bounds what weETH is DELIVERABLE — see deliverableETH
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

    /// @dev Body of Vault.vogueETH — AGGREGATE ETH-equivalent backing across the
    ///      depositor-chosen venues.
    function _vogueETH(EthCfg memory c) internal view returns (uint total) {
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


    /// @notice Body of Vault.deliverableETH — SOLVENCY-side ETH backing with PARTIAL liquidity haircuts.
    ///
    /// @dev    READ THE NAME NARROWLY (§A.5c, re-derived 2026-07-27). This is NOT a promptness
    ///         guarantee and NOT a view-twin of the withdraw ladder. It caps the three WETH-4626
    ///         venues via `_deliverableCap` and subtracts the levered net equity, but it counts the
    ///         AAVE-v4 leg, weETH at the Vault, and raw eETH at FULL FACE — none of which is
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
    /// @notice The ONE `withdrawable` definition for a WETH 4626 venue — what it can actually pay us.
    ///
    ///         MORPHO-V2 (probed live). A V2 vault parks its assets
    ///         in ADAPTERS and auto-allocates on deposit, so BOTH its max-views are idle-only: with our
    ///         own 20 ETH position it reported `maxWithdraw == 0` AND `maxRedeem == 0`. That is NOT
    ///         illiquidity — `withdraw(1 ether)` SUCCEEDED (burned 0.9939 shares) and `redeem` returned
    ///         1.875 ETH, because `withdraw()` self-deallocates from the adapters. Clamping a pull by
    ///         `maxWithdraw` therefore means we NEVER TRY: measured, that zeroed `deliverableETH` with
    ///         16 ETH sitting solvent in the vault and made EVERY ETH LP exit return 0 while the LP kept a
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

    /// @dev BOUNDED BY WHAT CURVE CAN PAY, and this is NOT a clamp -- it is what the word DELIVERABLE
    ///      means here. `deliverableETH` is INSTANT deliverability, and weETH's instant deliverability
    ///      genuinely is bounded by the pool: the wait-NFT makes it EVENTUALLY deliverable at fair value,
    ///      which is a different quantity. Conflating the two is what made an earlier attempt argue this
    ///      bound away as unnecessary.
    ///      ⚠️ MEASURED BOTH WAYS. Removing it does not merely under-report: the `amount > 0` fallback in
    ///      `Vogue`'s exit then OVER-delivers against backing the offramp cannot source, so nothing
    ///      defers and both test_RunSim_B_LiquidityRace_* fail "deferral recovers: 0 <= 0" -- there is
    ///      no deferral left to recover. It replaces the three per-venue `_deliverableCap` bounds that
    ///      went with the ETH venues, and serves the same purpose: virtual burn == real delivery.
    ///      (Superseded framing, 2026-08-13.) The three `_deliverableCap` venue bounds
    ///      removed with the ETH venues existed because a 4626 curator could hold value that was
    ///      genuinely UNREACHABLE — `maxWithdraw` short of the position with no other exit. weETH has no
    ///      such state: if Curve cannot absorb it the wait-NFT redeems it at fair value from ether.fi, so
    ///      the value is SLOWER, never stuck. A cap here would model an unreachable state that cannot
    ///      occur, and would understate backing on every read.
    function deliverableETH(EthCfg memory c) public view returns (uint total) {
        total = _vogueETH(c);
        // WEETH IS ONLY DELIVERABLE TO THE EXTENT CURVE CAN PAY FOR IT.
        // RE-DERIVED 2026-08-13, replacing the three `_deliverableCap` venue caps removed with the ETH
        // venues. Those caps were what made an undeliverable slice DEFER; deleting them without a
        // replacement left `_vogueETH` counting weETH at full oracle value while the exit can realise at
        // most the pool's WETH, so delivery was overstated and the deferral machinery never engaged.
        // (Measured: that regression broke test_SETTLE_LvrResidualIsDeferralNotLeak,
        // test_RunSim_B_LiquidityRace_* and testRT_DeliveredPlusRetainedEqualsPrincipal, all of which
        // pass on stock main — a control run, not an inference.)
        // Bound only the weETH-sourced portion: idle WETH, AAVE and eETH are already deliverable as-is.
        if (c.curvePool != address(0) && c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) {
                uint weethEth = IWeETH(c.weeth).getEETHByWeETH(w);
                uint payable_ = (ICurvePool(c.curvePool).balances(0) * 9) / 10;   // same headroom as offrampBody
                if (weethEth > payable_) total -= (weethEth - payable_);          // the surplus DEFERS
            }
        }
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


    /// @notice WETH supply — into weETH. Only WETH is accepted.
    /// @dev  REPOINTED FROM GALAXY 2026-08-13. This is the destination for WETH swept by SwapLib
    ///       (`:179`, `:190`, `:234` via `Aux.supplySelf`), which is a LIVE path — it is NOT part of the
    ///       depositor-venue surface that was deleted, and must not be removed with it. With the
    ///       WETH-4626 curators gone it had no destination left, so it routes where every other ETH
    ///       supply now routes: the ether.fi adapter.
    function supplyETH(EthCfg memory c, address token, uint amount) public returns (uint) {
        require(token == c.weth, "ethv:notWeth");
        // HOLD IT AS WETH. This is the sink for WETH swept by SwapLib (`:179`, `:190`, `:234` via
        // `Aux.supplySelf`) -- transient balances on swap/sweep paths, NOT depositor capital.
        // Do NOT eagerly convert it to weETH: measured, that starves every path that sweeps WETH and then spends it
        // (`testReal_Liquity_*` revert "transfer amount exceeds balance"), and makes a deferred exit
        // unrecoverable because the retry has no WETH to deliver.
        // Idle WETH is already counted as backing by `_vogueETH` and is DIRECTLY deliverable -- no
        // conversion, no spread, no pool capacity. Buying the ratchet on a transient balance costs two
        // spreads to earn a few hours of yield. So: no destination at all.
        return amount;
    }



    /// @notice Consolidated venue-supply body — the `transferFrom` + venue call for every ETH supply wrapper, so the
    ///         Vault forwarders keep ONLY their `NotVogueCore`/`NotAux` gate (bytecode OUTSIDE the EIP-170-critical
    ///         Vault). `from` = the approver the WETH is pulled from (V4 for the venue wrappers, AUX for
    ///         `supplyFromAux`).
    /// @dev THE `kind` SELECTOR IS GONE (2026-08-13). It was already ignored — every value routed to the
    ///      ether.fi adapter — and its own docblock said to remove it once the routing decision was
    ///      final. It is: there are no WETH-holding venues left to select, so the parameter had
    ///      nothing left to choose between.
    function supplyVenueBody(EthCfg memory c, uint amount, address from) public returns (uint) {
        if (amount == 0) return 0;
        // ALL ETH SUPPLY IS weETH: it earns the ether.fi ratchet, measured at +0.674 bps/day =
        // 2.46%/yr. That is the hurdle any WETH-holding venue must clear just
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



    /// @notice Body of Vault._withdrawETH — idle-then-ether.fi(opportunistic)-then
    ///         -then-AAVE ladder. Only WETH is served.
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
            // OPPORTUNISTIC, NON-BLOCKING: before AAVE, sell idle ether.fi
            // weETH → WETH on the deep pool. Any failure swallowed (returns 0).
            if (SwapLib.sourceWethBody(amount - wethBal, off) > 0)
                wethBal = IERC20(c.weth).balanceOf(address(this));
        }
        if (wethBal < amount) {
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



    // ── ether.fi OFFRAMP (moved from SwapLib, §E57) ──────────────────────────────────────────
    //  Its ONE caller is `Vault.offrampEtherFi` (`Vault.sol:444`), so it was always a VAULT
    //  concern living in a SWAP library. Moving it is not just tidiness: SwapLib was the binding
    //  EIP-170 contract at +14 bytes while VaultLib had 15,040 spare, and E55/E53 need room in
    //  SwapLib specifically. Put the code where the room is — the same trade as E32.
    /// @notice Body of Aux.offrampEtherFi — the exit ladder. Rung 1 = Curve pool sale; rung 2 = wait NFT.
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
        // CAPACITY — shrink to what the pool can actually pay. This MUST happen before `covered` is
        // derived: `covered` is returned as the amount SERVED, and `Vogue` burns it and decrements
        // `LP.pooled` by it. Shrinking inside `curveSellWeeth` instead would leave `covered` reflecting
        // the pre-shrink size, so the offramp would report serving more than it sold — a silent
        // over-credit on the exit path. Same arithmetic, wrong place, money-path defect.
        // MEASURED 2026-08-09: fills track ~1.4 + 55·(dx/D)² bps up to ~1,000 weETH (−1.39 at 1, −1.51 at
        // 100, −3.47 at 1,000) and then break by 70× — −722.80 at 2,000. That cliff is NOT slippage but
        // EXHAUSTION: 2,000 weETH asks ~2,202 WETH out of a pool holding 2,047. No floor value survives
        // it, because the pool cannot pay; only sizing does.
        // NEVER GATE — shrink. The unserved remainder falls to the wait-NFT rung on its own, so a partial
        // fill still serves most of a large exit instead of deferring all of it for ~7 days.
        if (c.curvePool != address(0) && weethIn > 0) {
            uint wantOut = (weethFull == 0 || weethIn == weethFull)
                ? amount : FullMath.mulDiv(amount, weethIn, weethFull);
            // 90% of the pool's WETH: slippage steepens toward the edge, so leave headroom rather than
            // sizing to the exact boundary the quadratic stops describing.
            uint cap = (ICurvePool(c.curvePool).balances(0) * 9) / 10;
            if (wantOut > cap) weethIn = FullMath.mulDiv(weethIn, cap, wantOut);
        }
        uint covered = (weethFull == 0 || weethIn == weethFull)
            ? amount : FullMath.mulDiv(amount, weethIn, weethFull);
        // RUNG 1 — CURVE `weETH/WETH-ng` (only if this contract holds weETH). Replaced a two-tier
        // Uniswap v3 loop 2026-08-09. Measured live against the weETH/WETH oracle, Curve vs the 0.01%
        // v3 tier: −1.39 vs −17.55 bps @1, −1.51 vs −18.79 @100, −3.47 vs −28.16 @1000. ~17–25 bps
        // better at every realistic size, so there is no tier to choose between and no ordering to get
        // wrong. Both venues cliff near 2,000 weETH, where Curve's 2,047 WETH runs out — and THAT is the
        // only case rung 2 now exists for.
        // THE FLOOR GUARDS **MEV**, NOT CAPACITY — those were one number until 2026-08-09 and are now two.
        // 50 bps had to straddle "normal" and "drained" because a single constant did both jobs; with the
        // shrink above handling capacity, the floor only has to sit above HONEST execution.
        // 25 bps = worst measured slippage (3.5 bps) + room for the pool-vs-ether.fi-rate offset, which
        // widens at up to 0.674 bps/day (the ratchet) when the pool is unarbed — roughly a month's drift.
        // ⚠️ THAT SECOND TERM IS WHY IT IS NOT 15: sizing against slippage alone ignores a divergence that
        // grows with TIME rather than trade size, and a false reject costs the LP a ~7-day wait-NFT.
        // Anchored to `covered`, i.e. the ether.fi rate — NOT to any pool-derived quote, which a
        // front-runner moves along with the fill it is supposed to police.
        if (weethIn > 0) {
            uint got = SwapLib.curveSellWeeth(c, weethIn, (covered * 9975) / 10_000);
            if (got > 0) {
                IERC20(c.weth).transfer(recipient, got);   // Curve pays msg.sender; deliver onward
                return covered;
            }
        }
        // There is deliberately NO ether.fi instant-redeem rung: `totalRedeemableAmount` measures ZERO
        // at every sampled block, because the pool absorbs the flow first.
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
