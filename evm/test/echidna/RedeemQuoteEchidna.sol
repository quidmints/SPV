// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BasketLib} from "../../src/imports/BasketLib.sol";

/// @title Redeem-quote invariants — VALUATION and LIQUIDITY are two different bounds.
///
/// WHY THIS EXISTS, and it is a measured reason rather than a tidy one. `BasketLib._redeemQuote`
/// applies exactly two haircuts and one liquidity bound:
///
///     solvent  = solvent > depegLoss ? solvent - depegLoss : 0          // (1) depeg severity
///     perShare = BasketLib.qdShareValue(WAD, solvent, mature)           // (2) solvency, ≡ min(par, pro-rata)
///     freeUsd  = solvent > locked ? solvent - locked : 0                // (3) NOT a haircut
///                where locked = max(illiquidLoss, committedUsd18)
///
/// MEASURED 2026-08-16 in `LeveragePnLProbe`: `matureSupply == 0`, so `qdShareValue` takes its
/// `supplyPreBurn == 0` branch and returns PAR — **no valuation haircut runs at all** — while
/// `committedUsd18` was ~$251k and bounded the payout. Three documents nevertheless described the
/// shortfall as a "7.90% haircut" / "92.1 cents on the dollar". The arithmetic was never marking
/// anything down; the USD was committed and therefore not free to pay.
///
/// ⇒ THE STARTING CONDITIONS ARE THE WHOLE PROBLEM. The Foundry fixture reaches ONE regime
/// (`mature == 0`), so every branch behind `mature > 0` is untested there and a reader infers the
/// mechanism from a case that never executes. This harness takes the starting conditions as FUZZED
/// ARGUMENTS instead of inheriting them from a fixture, so Echidna accumulates the edge cases the
/// fixture cannot construct — and nothing here assumes a regime.
///
/// ASSERTION MODE — Echidna fuzzes the arguments directly:
///   echidna evm/test/echidna/RedeemQuoteEchidna.sol \
///     --contract RedeemQuoteEchidna --test-mode assertion --test-limit 50000
contract RedeemQuoteEchidna {
    uint private constant WAD = 1e18;

    /// Domain bound, applied ONCE at each entrypoint and never inside the mirrors.
    ///
    /// `qdShareValue` does `mulDiv(total, WAD, supplyPreBurn)`, which REVERTS once the 512-bit
    /// intermediate exceeds uint256 — and in assertion mode a revert is not a finding, it is
    /// SILENCE. Unbounded fuzzing would spend its budget reverting and report "all passing" while
    /// exercising almost nothing. 1e30 is ~1e12 dollars in WAD, far above any reachable basket, and
    /// keeps `total·WAD` at 1e48 against a 1.16e77 ceiling.
    ///
    /// ⚠️ BOUNDING INSIDE THE MIRRORS WAS TRIED AND IS WRONG — it makes the harness report FALSE
    /// POSITIVES. `check_depeg_only_reduces` derives `after_ <= solvent` in raw arithmetic; if the
    /// mirror then re-bounds, `_b(after_)` can exceed `_b(solvent)` by wrapping and the monotonicity
    /// assertion fails on an input that is fine. A harness that cries wolf is worse than none, so
    /// the bound is applied to the ARGUMENTS and every derived value stays in the same domain.
    uint private constant MAX = 1e30;
    function _b(uint x) private pure returns (uint) { return x % (MAX + 1); }

    // Mirrors of the live expressions, kept thin so the property is about the ARITHMETIC and not
    // about a copy of it drifting. These take ALREADY-BOUNDED inputs.
    function _perShare(uint solvent, uint mature) private pure returns (uint) {
        return BasketLib.qdShareValue(WAD, solvent, mature);
    }

    function _freeUsd(uint solvent, uint il, uint committed) private pure returns (uint) {
        uint locked = il > committed ? il : committed;
        return solvent > locked ? solvent - locked : 0;
    }

    // ── (2) VALUATION ────────────────────────────────────────────────────────────────────────

    /// @notice A share may NEVER pay above par. This is the solvency guard's entire job, and it must
    ///         hold for every (solvent, mature) — including the mature==0 branch the fixture pins.
    function check_never_pays_above_par(uint solvent, uint mature) public pure {
        assert(_perShare(_b(solvent), _b(mature)) <= WAD);
    }

    /// @notice THE BRANCH THE FIXTURE LIVES IN, ASSERTED RATHER THAN ASSUMED. With no mature supply
    ///         the guard returns PAR, so NO valuation haircut runs. Anything attributing a shortfall
    ///         to a haircut in this regime is mis-attributing it.
    function check_zero_mature_is_par_exactly(uint solvent) public pure {
        assert(_perShare(_b(solvent), 0) == WAD);
    }

    /// @notice MORE BACKING NEVER PAYS LESS. Monotone in `solvent` at fixed maturity — otherwise a
    ///         redeemer could be better off with a WEAKER basket, which is the shape of an exploit.
    function check_monotone_in_solvency(uint a, uint b, uint mature) public pure {
        (a, b, mature) = (_b(a), _b(b), _b(mature));
        if (a > b) (a, b) = (b, a);                    // a <= b
        assert(_perShare(a, mature) <= _perShare(b, mature));
    }

    /// @notice A HAIRCUT REQUIRES AN ACTUAL SHORTFALL. If backing covers the mature supply, par is
    ///         paid; only a genuine shortfall may mark a share down.
    function check_haircut_implies_shortfall(uint solvent, uint mature) public pure {
        (solvent, mature) = (_b(solvent), _b(mature));
        if (_perShare(solvent, mature) < WAD) assert(mature > 0 && solvent < mature);
    }

    // ── (1) DEPEG SEVERITY, composed with (2) ────────────────────────────────────────────────

    /// @notice DEPEG LOSS CAN ONLY REDUCE. Subtracting severity before the ratio must never raise
    ///         the per-share value, and must not underflow into a wrap.
    function check_depeg_only_reduces(uint solvent, uint depegLoss, uint mature) public pure {
        (solvent, depegLoss, mature) = (_b(solvent), _b(depegLoss), _b(mature));
        uint after_ = solvent > depegLoss ? solvent - depegLoss : 0;   // stays inside the domain
        assert(after_ <= solvent);
        assert(_perShare(after_, mature) <= _perShare(solvent, mature));
    }

    // ── (3) LIQUIDITY — the bound that is NOT a haircut ──────────────────────────────────────

    /// @notice A LIQUIDITY BOUND CANNOT MANUFACTURE VALUE. `freeUsd` may never exceed `solvent`.
    function check_free_never_exceeds_solvent(uint solvent, uint il, uint committed) public pure {
        (solvent, il, committed) = (_b(solvent), _b(il), _b(committed));
        assert(_freeUsd(solvent, il, committed) <= solvent);
    }

    /// @notice COMMITTED CAPITAL IS NEVER FREE. Whatever is committed (or illiquid, whichever binds)
    ///         is withheld — this is the term that actually bounded the measured redeem.
    function check_committed_is_withheld(uint solvent, uint il, uint committed) public pure {
        (solvent, il, committed) = (_b(solvent), _b(il), _b(committed));
        uint locked = il > committed ? il : committed;
        if (solvent > locked) assert(_freeUsd(solvent, il, committed) == solvent - locked);
        else                  assert(_freeUsd(solvent, il, committed) == 0);
    }

    /// @notice MORE COMMITMENT NEVER FREES MORE. Monotone DOWNWARD in `committed`.
    function check_more_commitment_frees_less(uint solvent, uint il, uint a, uint b) public pure {
        (solvent, il, a, b) = (_b(solvent), _b(il), _b(a), _b(b));
        if (a > b) (a, b) = (b, a);                    // a <= b
        assert(_freeUsd(solvent, il, b) <= _freeUsd(solvent, il, a));
    }

    // ── THE ONE THAT ENCODES TODAY'S ACTUAL CONFUSION ────────────────────────────────────────

    /// @notice 🔴 PAR AND LIQUIDITY ARE INDEPENDENT — A FULL-PAR SHARE CAN STILL BE PAYOUT-BOUNDED.
    ///         This is the property whose absence cost three documents a wrong mechanism: the redeem
    ///         paid short while `perShare` was exactly par, and the shortfall was read as a haircut.
    ///         Here it is as an executable statement — valuation UNIMPAIRED while the payout is
    ///         nevertheless bounded, so the two can never be conflated again.
    function check_par_does_not_imply_unbounded_payout(uint solvent, uint il, uint committed)
        public pure
    {
        (solvent, il, committed) = (_b(solvent), _b(il), _b(committed));
        assert(_perShare(solvent, 0) == WAD);          // valuation: exactly par, no haircut
        uint locked = il > committed ? il : committed;
        if (locked > 0 && solvent > locked) {
            assert(_freeUsd(solvent, il, committed) < solvent);   // ...payout still bounded
        }
    }
}
