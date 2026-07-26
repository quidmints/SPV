// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {SwapLib} from "./SwapLib.sol";

// ── Minimal external surfaces the ETH-venue ladder touches (the library can't
//    read Vault's immutables, so every handle is passed in via EthCfg). Mirror
//    the interfaces Vault declares; same signatures. ──────────────────────────
interface IAaveV4Spoke_V {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256, uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
}
interface IWeETH_V { function getEETHByWeETH(uint _weETHAmount) external view returns (uint); }
interface IRover_V { function take(uint amount) external returns (uint wethAmount); function valueWeth() external view returns (uint); }
interface IRoverDep_V { function deposit(uint amount) external payable; }                       // supply-leg: fund the Rover
interface IDepositAdapter_V { function depositWETHForWeETH(uint _amount, address _referral) external; } // ether.fi stake
interface IAuxView_V { function vaultBlocked(address vault) external view returns (bool); }
/// Morpho-V2 vault surface (NOT MetaMorpho v1.1, which has a withdrawQueue instead). A V2 vault keeps
/// its assets in ADAPTERS and auto-allocates on deposit, so `maxWithdraw` tracks IDLE rather than what
/// the holder owns; these three reads are the published hatch for pulling allocated liquidity back.
interface IMorphoV2_V {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function forceDeallocate(address adapter, bytes memory data, uint assets, address onBehalf)
        external returns (uint penaltyAssets);
}
interface ILevEquity_V { function totalNetEquityEth() external view returns (uint256); }

/// @title  VaultLib — the ETH yield-venue custody ladder extracted from Vault
///         to free bytecode under the EIP-170 limit. DELEGATECALL'd by Vault:
///         inside each public function `address(this)` resolves to the Vault,
///         so all token custody, balances, and the AAVE/4626/Rover positions
///         are the Vault's. The library holds NO storage; every immutable Vault
///         reads (WETH/AUX/GALAXY/EULER/AAVE spoke+reserveId/ROVER/WEETH/EETH/
///         LEV_MANAGER) is passed in via `EthCfg`. Semantics are byte-for-byte
///         with the former in-Vault bodies — only the home moved.
library VaultLib {

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
        address rover;
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
            if (IAuxView_V(aux).vaultBlocked(vault)) {
                try IERC4626(vault).maxWithdraw(address(this)) returns (uint m) { return m; }
                catch { return 0; }   // throwing venue ⇒ value at 0 (see note above)
            }
            try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; } catch { return 0; }
        } catch { return 0; }
    }

    /// @dev WETH currently supplied to AAVE-v4 (yield-accrued). 0 if unwired.
    ///      Gate on `aaveSpoke`, NOT on `wethReserveId`: reserve 0 is a legitimate reserve
    ///      (mainnet WETH == asset 0 == reserve 0), so a zero-id check disables a live venue.
    function _aaveBal(EthCfg memory c) internal view returns (uint) {
        if (c.aaveSpoke == address(0)) return 0;
        return IAaveV4Spoke_V(c.aaveSpoke).getUserSuppliedAssets(c.wethReserveId, address(this));
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
            if (w > 0) total += IWeETH_V(c.weeth).getEETHByWeETH(w);
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
        // Rover (protocol-owned weETH/WETH LP) — WETH-equiv value; try/catch so a
        // broken Rover defers to 0 (conservative).
        if (c.rover != address(0)) {
            try IRover_V(c.rover).valueWeth() returns (uint rv) { total += rv; } catch {}
        }
        // IL-protect: count the leveraged book's net-equity (gross collateral - debt), not gross. The buffer
        // half is debt-funded (offset by the LP's borrow), so counting gross would overstate solvency by the debt
        // -- the same error the fold fixed for `committed`. Net-equity is the LP's real deliverable claim (what
        // `closeLev` returns after auto-repaying the debt). The 2x band depth is untouched -- it lives in
        // `levPooled = gross`, not here. try/catch degrades to "no lev credit". Unified with the BTC model.
        if (c.levManager != address(0)) {
            try ILevEquity_V(c.levManager).totalNetEquityEth() returns (uint n) { total += n; } catch {}
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
        if (shares == 0 || IAuxView_V(aux).vaultBlocked(vault)) return total;
        uint solvent = IERC4626(vault).convertToAssets(shares);
        // GUARDED — restored 2026-07-26 after removing it broke the suite. Euler's real EVault
        // REVERTS in `maxWithdraw` (it calls `EVC.getControllers(account)` internally; fork-traced),
        // so an unguarded read here bricks `deliverableETH` and with it EVERY ETH LP withdraw. A
        // reverting view is treated as 0 withdrawable = the CONSERVATIVE side (understates what is
        // deliverable, so it can only defer, never over-promise). Same rule as `_venue4626Value`.
        uint withdrawable;
        try IERC4626(vault).maxWithdraw(address(this)) returns (uint m) { withdrawable = m; } catch {}
        if (solvent > withdrawable) {
            uint undeliverable = solvent - withdrawable;
            return total > undeliverable ? total - undeliverable : 0;
        }
        return total;
    }

    /// @notice Body of Vault.deliverableETH — DELIVERABLE ETH backing.
    function deliverableETH(EthCfg memory c) public view returns (uint total) {
        total = _vogueETH(c);
        address[3] memory venues = _venues(c);
        for (uint i; i < 3; ++i) total = _deliverableCap(venues[i], c.aux, total);
        // The leverage net-equity is solvency backing (now counted in vogueETH as net) but NOT deliverable
        // from this Vault (unwind-only via closeLev -- the LP gets it back by repaying debt + withdrawing coll,
        // not from redemption). Exclude the same net-equity term vogueETH added, so deliverableETH == base
        // (non-levered venue ETH), byte-identical to the prior gross-in/gross-out result. Redemptions never draw it.
        if (c.levManager != address(0)) {
            try ILevEquity_V(c.levManager).totalNetEquityEth() returns (uint n) {
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
        if (vault != address(0) && !IAuxView_V(c.aux).vaultBlocked(vault)) {
            try IERC4626(vault).deposit(amount, address(this)) returns (uint sh) {
                require(sh > 0, "v4626:0");
                return amount;
            } catch {}
        }
        if (c.aaveSpoke != address(0))   // reserve 0 is valid — spoke is the wiring flag
            IAaveV4Spoke_V(c.aaveSpoke).supply(c.wethReserveId, amount, address(this));
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
    ///         Vault). `kind`: 0=Rover, 1=ether.fi adapter stake, 2=AAVE-v4, 3=Euler 4626, 4=Galaxy default
    ///         (`supplyFromAux`), 5=Gauntlet 4626. `from` = the approver the WETH is pulled from (V4 for the venue wrappers, AUX for
    ///         `supplyFromAux`). Each branch is byte-identical to the former in-Vault body (guard → pull → supply).
    function supplyVenueBody(EthCfg memory c, uint8 kind, uint amount, address from) public returns (uint) {
        if (amount == 0) return 0;
        if (kind == 0) {
            if (c.rover == address(0)) return 0;
            IERC20(c.weth).transferFrom(from, address(this), amount);
            IRoverDep_V(c.rover).deposit(amount);
            return amount;
        }
        if (kind == 1) {
            if (ETHERFI_ADAPTER_VL == address(0)) return 0;
            IERC20(c.weth).transferFrom(from, address(this), amount);
            IDepositAdapter_V(ETHERFI_ADAPTER_VL).depositWETHForWeETH(amount, address(this));
            return amount;
        }
        if (kind == 2) {
            if (c.aaveSpoke == address(0)) return 0;   // reserve 0 is valid — see _aaveBal
            IERC20(c.weth).transferFrom(from, address(this), amount);
            IAaveV4Spoke_V(c.aaveSpoke).supply(c.wethReserveId, amount, address(this));
            return amount;
        }
        if (kind == 3) {
            if (c.euler == address(0)) return 0;
            IERC20(c.weth).transferFrom(from, address(this), amount);
            return supplyEuler(c, amount);
        }
        if (kind == 5) {
            if (c.gauntlet == address(0)) return 0;
            IERC20(c.weth).transferFrom(from, address(this), amount);
            return supplyGauntlet(c, amount);
        }
        // kind == 4: Galaxy default (supplyFromAux) — pull from Aux, then the WETH 4626 default supply.
        IERC20(c.weth).transferFrom(from, address(this), amount);
        return supplyETH(c, c.weth, amount);
    }

    // ── Withdraw ladder ─────────────────────────────────────────────────────

    /// @dev Pull up to the shortfall from a WETH 4626 venue's withdrawable amount
    ///      (maxWithdraw). Best-effort, try/catch'd.
    function _pull4626(EthCfg memory c, address vault, uint amount) internal {
        if (vault == address(0)) return;
        uint bal = IERC20(c.weth).balanceOf(address(this));
        if (bal >= amount) return;
        uint need = amount - bal;
        // GUARDED (see _deliverableCap): a venue whose view reverts contributes 0 to this rung and
        // the ladder moves on to the next source, rather than failing the LP's entire withdraw.
        uint maxOut;
        try IERC4626(vault).maxWithdraw(address(this)) returns (uint m) { maxOut = m; } catch {}
        // MORPHO-V2 DEALLOCATE (2026-07-26). A Morpho-V2 vault parks its assets in ADAPTERS and
        // AUTO-ALLOCATES on deposit, so `maxWithdraw` is bounded by IDLE, not by what we own.
        // MEASURED on mainnet: Galaxy holds 8971 WETH with **0 idle** and Gauntlet 4720 with ~0 —
        // that is their steady-state POLICY, so our own fresh deposit raised `totalAssets` but stayed
        // un-withdrawable and this pull silently returned nothing. Left unfixed, LP exits can NEVER
        // source from those venues even though `vogueETH` counts them as backing (the ~20% exit
        // shortfall class). Morpho-V2 publishes `liquidityAdapter()`/`liquidityData()` precisely so an
        // integrator can pull allocated liquidity back to idle on demand; the penalty is currently 0,
        // so this is value-neutral. try/catch because a v1.1 MetaMorpho has no such surface (it keeps
        // a withdrawQueue instead) and must fall through unchanged.
        if (maxOut < need) {
            try IMorphoV2_V(vault).liquidityAdapter() returns (address adapter) {
                if (adapter != address(0)) {
                    try IMorphoV2_V(vault).forceDeallocate(
                        adapter, IMorphoV2_V(vault).liquidityData(), need - maxOut, address(this)
                    ) { maxOut = IERC4626(vault).maxWithdraw(address(this)); } catch {}
                }
            } catch {}
        }
        uint pull = need > maxOut ? maxOut : need;
        if (pull > 0) {
            // NOT swallowed: a venue that reports `pull` withdrawable and then fails to deliver it is
            // a venue fault, and letting it degrade into a short `sent` turns it into SILENT LP value
            // loss (see withdrawETH's `sent = wethBal >= amount ? amount : wethBal`). The ladder's
            // liveness is preserved by the maxWithdraw clamp above — we only ask for what the venue
            // itself says it can pay — so a revert here is a real fault worth surfacing, not routine.
            IERC4626(vault).withdraw(pull, address(this), address(this));
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
                uint aaveBalance = IAaveV4Spoke_V(c.aaveSpoke)
                    .getUserSuppliedAssets(c.wethReserveId, address(this));
                uint apull = need > aaveBalance ? aaveBalance : need;
                if (apull > 0) {
                    try IAaveV4Spoke_V(c.aaveSpoke).withdraw(
                        c.wethReserveId, apull, address(this)) {} catch {}
                }
                wethBal = IERC20(c.weth).balanceOf(address(this));
            }
            // Last source → unwind the protocol-owned Rover. Non-blocking.
            if (wethBal < amount && c.rover != address(0)) {
                try IRover_V(c.rover).take(amount - wethBal) {} catch {}
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
        // GUARDED: evacuate exists to RESCUE a failing venue, so the failing venue's own reverting
        // view must not be what prevents the rescue.
        uint maxW;
        try IERC4626(vault).maxWithdraw(address(this)) returns (uint m) { maxW = m; } catch {}
        if (maxW == 0) return; // frozen → blocked; vogueETH writes it down
        try IERC4626(vault).withdraw(maxW, address(this), address(this))
            returns (uint got) {
            if (got > 0 && c.aaveSpoke != address(0))   // reserve 0 is valid — see _aaveBal
                IAaveV4Spoke_V(c.aaveSpoke).supply(c.wethReserveId, got, address(this));
        } catch { /* froze mid-pull: blocked + written down */ }
    }

}
