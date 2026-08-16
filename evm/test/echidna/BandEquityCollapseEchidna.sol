// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @title Echidna harness — collapsing the `dust6` term out of `Core._bandEquityUsd18`.
///
/// @notice **WHY THIS EXISTS.** `_bandEquityUsd18` folds three inputs into one band's equity:
///
/// ```
///   pooled18 = (base6 > dust6 ? base6 - dust6 : 0) * 1e12    // base6 = basketUsdEth/Btc
///   equity   = pooled18 > debt18 ? pooled18 - debt18 : 0
/// ```
///
/// `dust6 = _dustOf(address(_mockUsd(isBTC)))` exists for ONE reason (§E60): the v4 protocol fee
/// can move mockUSD to a recipient outside `{poolManager, Core}`, so `basketUsd*` keeps claiming
/// dollars that have left. **Remove v4 and there is no mockUSD, no protocol fee and no dust — the
/// term collapses to zero and `_dustOf`/`_mockUsd` delete with it.**
///
/// `basketUsd*` is what survives, and it is the right thing to survive: §#12 defines it as what the
/// BASKET contributed, moving ONLY on `addLiq`/burn and never on a swap, which is why
/// `committedUsd18` is derived from it rather than from the curve inventory.
///
/// **WHAT MUST BE TRUE FOR THE COLLAPSE TO BE SAFE**, and it is a property over ALL inputs rather
/// than a fork case — which is what a fuzzer should own:
///
///   1. **The collapse can never LOOSEN the backing gate.** `Core` enforces
///      `require(committedUsd18() <= haircutTvl, "backing")`. `committed` is on the LEFT, so a
///      LARGER committed makes the gate STRICTER. Dropping a subtraction can only raise `pooled18`,
///      so the collapsed form must be `>=` the general form — never below it. **A collapse that
///      could lower committed would silently widen the gate, which is the one outcome that turns a
///      refactor into a solvency bug.**
///   2. Both floors stay saturating: no underflow, and zero rather than a wrapped value.
///   3. Equity is monotonic in `base6` — more basket contribution never yields less equity.
///
/// ASSERTION MODE (`--test-mode assertion`): Echidna fuzzes these arguments directly. Deliberately
/// self-contained pure math — no PoolManager, no venues, no fork — per the §C#20 note, matching
/// `SwapLibClampEchidna`. Inputs are bounded only where `* 1e12` would overflow arithmetically;
/// that bound is stated, not silent, because a bound chosen to make a fuzzer quiet is the tell that
/// the property is wrong.
/// ⚠️ **RUN IT ON THE FILE, NOT ON `.` — the config's documented invocation FAILS for this harness.**
///
///     cd evm && echidna test/echidna/BandEquityCollapseEchidna.sol \
///       --contract BandEquityCollapseEchidna --test-mode assertion --test-limit 50000
///
/// `echidna . --config echidna.yaml` compiles the WHOLE project and dies with
/// *"Error: Unlinked libraries detected in bytecode"* — the delegatecalled libraries (`SwapLib`,
/// `Aux`, …) need linking, and Echidna refuses before reaching any harness. This one imports
/// NOTHING, so pointing at the file sidesteps the project graph entirely. That self-containment
/// is not stylistic: it is what makes the harness runnable at all.
///
/// **RESULT (2026-08-16, 50,000 tests): all three properties `passing`.** Read the body, never the
/// exit code — `echidna .` above exited 0 while failing to compile, exactly as `echidna.yaml` warns.
contract BandEquityCollapseEchidna {
    /// Largest `base6` whose 18-dec lift cannot overflow. 6-dec USD, so this is ~1.15e65 dollars —
    /// astronomically above any real basket, and it exists so the fuzzer explores the real domain
    /// instead of failing on unreachable arithmetic.
    uint private constant MAX_6DEC = type(uint256).max / 1e12;

    /// TODAY's form, with the dust subtraction.
    function _equityWithDust(uint base6, uint dust6, uint debt18) internal pure returns (uint) {
        uint pooled18 = (base6 > dust6 ? base6 - dust6 : 0) * 1e12;
        return pooled18 > debt18 ? pooled18 - debt18 : 0;
    }

    /// The COLLAPSED form, after v4 removal takes `dust6` with it.
    function _equityCollapsed(uint base6, uint debt18) internal pure returns (uint) {
        uint pooled18 = base6 * 1e12;
        return pooled18 > debt18 ? pooled18 - debt18 : 0;
    }

    /// @notice **THE COLLAPSE PROPERTY.** Removing the dust term must never lower a band's equity,
    ///         because `committedUsd18` gates as `committed <= haircutTvl` and a LOWER committed
    ///         would let more through. Equality is expected wherever dust is genuinely zero, which
    ///         is every state after v4 is gone; the inequality is what must hold in between.
    function echidna_collapse_never_loosens_the_backing_gate() public pure returns (bool) {
        return true; // properties are asserted in the fuzzed entrypoints below
    }

    function checkCollapse(uint base6, uint dust6, uint debt18) external pure {
        base6 = base6 % (MAX_6DEC + 1);
        dust6 = dust6 % (MAX_6DEC + 1);

        uint withDust = _equityWithDust(base6, dust6, debt18);
        uint collapsed = _equityCollapsed(base6, debt18);

        // 1. THE SAFETY DIRECTION: collapsing can only ever RAISE committed, never lower it.
        assert(collapsed >= withDust);

        // 2. And where dust is zero — every post-v4 state — the two forms are IDENTICAL, so the
        //    collapse is not merely safe but behaviour-preserving.
        if (dust6 == 0) assert(collapsed == withDust);
    }

    /// @notice Both floors saturate rather than wrap, on either form.
    function checkFloorsSaturate(uint base6, uint dust6, uint debt18) external pure {
        base6 = base6 % (MAX_6DEC + 1);
        dust6 = dust6 % (MAX_6DEC + 1);

        // Dust at or above the base zeroes the pooled term, so equity is zero — never a wrap.
        if (dust6 >= base6) assert(_equityWithDust(base6, dust6, debt18) == 0);

        // Debt at or above the lifted base zeroes equity on the collapsed form.
        if (debt18 >= base6 * 1e12) assert(_equityCollapsed(base6, debt18) == 0);
    }

    /// @notice Monotonic in the basket's own contribution: more `base6` never yields less equity.
    ///         This is what makes `committedUsd18` usable as a gate at all — a non-monotonic
    ///         committed could be gamed by adding depth to LOWER the measured commitment.
    function checkMonotoneInBase(uint a6, uint b6, uint debt18) external pure {
        a6 = a6 % (MAX_6DEC + 1);
        b6 = b6 % (MAX_6DEC + 1);
        if (a6 > b6) (a6, b6) = (b6, a6);
        assert(_equityCollapsed(b6, debt18) >= _equityCollapsed(a6, debt18));
    }
}
