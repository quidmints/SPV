//! §FACILITY-SIM REPORT — the sign map, and the hunt for negative cells.

use crate::facility_sim::*;
use crate::etc::{Actuary, COLLAR_BREACH_BPS, collar_bps, lgd_bps, MAX_TRANCHE_BPS};

fn delta(cell: Cell, arm: Arm) -> i64 {
    run(cell, arm).depositor_bps - run(cell, Arm::NoFacility).depositor_bps
}

fn sweep(arm: Arm) -> (usize, usize, i64, i64, Vec<(Cell, i64)>) {
    let mut worst = i64::MAX; let mut best = i64::MIN;
    let mut neg = 0usize; let mut losers = Vec::new();
    let cells = grid();
    for c in &cells {
        let d = delta(*c, arm);
        if d < worst { worst = d; }
        if d > best { best = d; }
        if d < 0 { neg += 1; losers.push((*c, d)); }
    }
    losers.sort_by_key(|(_, d)| *d);
    (cells.len(), neg, worst, best, losers)
}

/// 🔴 THE DOMINANCE CLAIM IS FALSE, AND THIS IS THE COUNTEREXAMPLE SET.
/// The test does not assert the facility is good. It asserts that a losing
/// region EXISTS — because if this ever passes with zero negative cells, the
/// harness has stopped modelling the cost of a hedge and is lying.
#[test]
fn facility_is_not_dominant_and_the_losing_region_is_reported() {
    for arm in [Arm::LevelTrigger, Arm::PersistenceGated] {
        let (n, neg, worst, best, losers) = sweep(arm);
        println!("\n=== {:?} vs NoFacility — {} cells ===", arm, n);
        println!("    negative: {}/{} ({}%)   worst {} bps   best {} bps",
                 neg, n, neg * 100 / n, worst, best);
        for (c, d) in losers.iter().take(6) {
            println!("      {:>5} bps  {:?}/{:?}/{:?}/{:?}/{:?}/{:?}",
                     d, c.price, c.net, c.flow, c.basis, c.clock, c.issuer);
        }
        assert!(neg > 0,
            "{:?}: a hedge pays a round trip unconditionally and pays out only in \
             the tail, so SOME cell must lose. Zero negatives means the harness \
             stopped charging for the hedge.", arm);
    }
}

/// The attack the persistence gate exists for: an induced position that crosses
/// the level trigger and then withdraws. The gate must not be fooled by it.
#[test]
fn persistence_gate_resists_the_induced_position_that_fools_a_level_trigger() {
    let c = Cell { price: Price::Chop, net: Net::AdversarialInduced, flow: Flow::Calm,
                   basis: Basis::Tight, clock: Clock::Continuous, issuer: Issuer::Normal };
    let lvl = run(c, Arm::LevelTrigger);
    let per = run(c, Arm::PersistenceGated);
    println!("induced: level fired {}x on {} notional; gated fired {}x on {}",
             lvl.hedges, lvl.hedged_notional, per.hedges, per.hedged_notional);
    assert!(per.hedges < lvl.hedges,
        "the gate must fire less often than a level trigger on an INDUCED path: {} vs {}",
        per.hedges, lvl.hedges);
    assert!(per.depositor_bps >= lvl.depositor_bps,
        "and firing less must leave depositors no worse: gated {} vs level {}",
        per.depositor_bps, lvl.depositor_bps);
}

/// Where the facility EARNS its cost — and this test's FIRST version had the
/// direction backwards, which is worth keeping as the record.
///
/// 🔴 I asserted `Jump` (a −18% move) was "the case a hedge is FOR" and measured
/// **−230 bps**. The premise was wrong, not the model: **the pool is SHORT what
/// borrowers are long, so a crash is when the pool WINS**, and hedging there
/// deletes a gain. The tail that hurts a net-short pool is a market going UP.
///
/// ⭐ WHICH IS THE REAL ARGUMENT FOR THE FACILITY, AND IT IS NOT A TAIL ARGUMENT
/// AT ALL: a retail book is persistently LONG, so the pool is persistently SHORT
/// an asset class that drifts upward. That is a structural, everyday exposure —
/// far stronger grounds than "protection against a jump", which points the other
/// way.
#[test]
fn facility_pays_where_it_should_short_book_into_a_rising_market() {
    let c = Cell { price: Price::TrendUp, net: Net::PersistentLong, flow: Flow::Calm,
                   basis: Basis::Tight, clock: Clock::Continuous, issuer: Issuer::Normal };
    let d = delta(c, Arm::PersistenceGated);
    println!("short book into a rising market: {} bps", d);
    assert!(d > 0, "a net-short pool in a rally is the case a hedge is FOR: {} bps", d);

    // And the mirror, asserted so the asymmetry is on the record rather than
    // discovered again later: in a CRASH the same hedge destroys value.
    let down = Cell { price: Price::TrendDown, ..c };
    let dd = delta(down, Arm::PersistenceGated);
    println!("short book into a falling market: {} bps", dd);
    assert!(dd < 0, "hedging a short book into a crash must give up the gain: {} bps", dd);
}

/// ⚠️ AND THE CASE THAT SHOULD DECIDE THE PRODUCT: the issuer can seize.
#[test]
fn issuer_pause_is_a_loss_the_synthetic_book_cannot_have() {
    let normal = Cell { price: Price::TrendDown, net: Net::PersistentLong, flow: Flow::Calm,
                        basis: Basis::Tight, clock: Clock::Continuous, issuer: Issuer::Normal };
    let paused = Cell { issuer: Issuer::Paused, ..normal };
    let dn = delta(normal, Arm::PersistenceGated);
    let dp = delta(paused, Arm::PersistenceGated);
    println!("issuer normal {} bps -> paused {} bps", dn, dp);
    assert!(dp < dn, "a pausable/seizable hedge must show up as a loss: {} vs {}", dp, dn);
}

// ═══════════════════════════════════════════════════════════════════════════
// §WIDER — the first sweep answered a narrower question than it appeared to.
// ═══════════════════════════════════════════════════════════════════════════

fn stats(arm: Arm, cfg: Cfg) -> (i64, i64, i64, i64) {
    let cells = grid();
    let mut v: Vec<i64> = cells.iter()
        .map(|c| run_cfg(*c, arm, cfg).depositor_bps).collect();
    v.sort();
    let n = v.len() as i64;
    let mean = v.iter().sum::<i64>() / n;
    let mad = v.iter().map(|x| (x - mean).abs()).sum::<i64>() / n;   // dispersion
    (mean, mad, v[0], v[(n - 1) as usize])
}

/// ⭐ THE MEASUREMENT THE FIRST SWEEP NEVER TOOK, AND IT IS THE POINT OF A HEDGE.
/// Mean P&L was reported and dispersion was not — so a facility that trades a
/// little mean for a lot of variance scored as a pure loss. A depositor buys
/// exactly that trade.
#[test]
fn hedging_is_a_variance_trade_and_the_ratio_sweep_shows_the_knee() {
    println!("\n=== hedge ratio sweep (PersistenceGated) ===");
    println!("  ratio   mean   dispersion    worst     best");
    for r in [0, 2_500, 5_000, 7_500, 10_000] {
        let cfg = Cfg { ratio_bps: r, ..Cfg::default() };
        let (mean, mad, lo, hi) = stats(Arm::PersistenceGated, cfg);
        println!("  {:>5}  {:>5}   {:>9}   {:>6}   {:>6}", r, mean, mad, lo, hi);
    }
    let (_, mad0, _, _) = stats(Arm::PersistenceGated, Cfg { ratio_bps: 0, ..Cfg::default() });
    assert!(mad0 > 0, "the unhedged book must have dispersion to reduce");
}

/// 🔴 THE LARGEST OMITTED TERM. Without a hedge the pool cannot carry the net for
/// free — it widens collars, caps tickers, or refuses flow. Scoring that at zero
/// assumed the facility's only effect is cost, which is what produced "79% lose".
#[test]
fn forgone_revenue_moves_the_sign_map_and_the_first_sweep_scored_it_at_zero() {
    println!("\n=== sensitivity to revenue forgone without a hedge ===");
    println!("  forgone   negative / 240");
    for f in [0, 50, 150, 300, 600] {
        let cfg = Cfg { forgone_rev_bps: f, ..Cfg::default() };
        let neg = grid().iter().filter(|c|
            run_cfg(**c, Arm::PersistenceGated, cfg).depositor_bps
          < run_cfg(**c, Arm::NoFacility, cfg).depositor_bps).count();
        println!("  {:>7}   {:>3}/240", f, neg);
    }
    let cnt = |f| grid().iter().filter(|c| {
        let cfg = Cfg { forgone_rev_bps: f, ..Cfg::default() };
        run_cfg(**c, Arm::PersistenceGated, cfg).depositor_bps
      < run_cfg(**c, Arm::NoFacility, cfg).depositor_bps }).count();
    assert!(cnt(600) < cnt(0),
        "if not having a hedge costs revenue, the facility must look better: {} vs {}",
        cnt(600), cnt(0));
}

/// ⚠️ MY COST ESTIMATE WAS DOING REAL WORK. `HEDGE_RT_BPS = 60` was a guess about
/// xStock secondary depth, not a measurement.
#[test]
fn the_conclusion_is_sensitive_to_a_cost_i_estimated_rather_than_measured() {
    println!("\n=== sensitivity to round-trip hedge cost ===");
    println!("   rt_bps   negative / 240   mean");
    for rt in [15, 30, 60, 120, 240] {
        let cfg = Cfg { rt_bps: rt, ..Cfg::default() };
        let neg = grid().iter().filter(|c|
            run_cfg(**c, Arm::PersistenceGated, cfg).depositor_bps
          < run_cfg(**c, Arm::NoFacility, cfg).depositor_bps).count();
        let (mean, _, _, _) = stats(Arm::PersistenceGated, cfg);
        println!("   {:>6}   {:>3}/240          {:>5}", rt, neg, mean);
    }
}

/// ⚠️ CELL COUNTS ARE NOT PROBABILITIES. A binary `Issuer` axis puts seizure in
/// HALF the grid; that measure is a property of how I built it, not of the world.
#[test]
fn equal_weighting_overstates_rare_catastrophes() {
    let w = |c: &Cell| -> i64 {
        let mut p: i64 = 10_000;
        if c.issuer == Issuer::Paused    { p = p * 2 / 100; }
        if c.flow == Flow::RedemptionRun { p = p * 15 / 100; }
        if c.basis == Basis::Widening    { p = p * 30 / 100; }
        p.max(1)
    };
    let cells = grid();
    let (mut num, mut den, mut neg_w) = (0i64, 0i64, 0i64);
    for c in &cells {
        let d = run(*c, Arm::PersistenceGated).depositor_bps
              - run(*c, Arm::NoFacility).depositor_bps;
        let wt = w(c);
        num += d * wt; den += wt;
        if d < 0 { neg_w += wt; }
    }
    let uniform_neg = cells.iter().filter(|c|
        run(**c, Arm::PersistenceGated).depositor_bps
      < run(**c, Arm::NoFacility).depositor_bps).count();
    println!("\n=== uniform vs plausibility-weighted ===");
    println!("  uniform:  {}/240 negative ({}%)", uniform_neg, uniform_neg * 100 / 240);
    println!("  weighted: {}% of probability mass negative, mean delta {} bps",
             neg_w * 100 / den, num / den);
    assert!(den > 0);
}

// ═══════════════════════════════════════════════════════════════════════════
// §REGRET — "is our rule optimal?" cannot be answered by comparing it to
// another rule I also invented. It needs a benchmark and a derived arm.
// ═══════════════════════════════════════════════════════════════════════════

fn mean_of(arm: Arm, cfg: Cfg) -> i64 {
    let cells = grid();
    cells.iter().map(|c| run_cfg(*c, arm, cfg).depositor_bps).sum::<i64>() / cells.len() as i64
}

/// 🔴 THE QUESTION I HAD NOT ASKED. `PersistenceGated` beating `LevelTrigger`
/// says nothing about either being good — both were invented for this harness.
/// Regret against a perfect-foresight benchmark is what says whether a rule is
/// close to the best achievable, and it decomposes the gap into the part caused
/// by the POLICY FORM and the part that is irreducible ignorance of the future.
#[test]
fn regret_against_perfect_foresight_is_the_only_optimality_evidence_here() {
    let cfg = Cfg::default();
    let oracle = mean_of(Arm::Clairvoyant, cfg);
    println!("\n=== regret vs perfect foresight (mean bps over 240 cells) ===");
    println!("  Clairvoyant (bound)   {:>6}", oracle);
    for arm in [Arm::NoFacility, Arm::LevelTrigger, Arm::PersistenceGated, Arm::DerivedBand] {
        let m = mean_of(arm, cfg);
        println!("  {:<20?} {:>6}    regret {:>6}", arm, m, oracle - m);
    }
    assert!(mean_of(Arm::Clairvoyant, cfg) >= mean_of(Arm::LevelTrigger, cfg),
        "a foresight benchmark that loses to a blind rule is not a benchmark");
}

/// ⭐ THE DERIVED ARM EXISTS BECAUSE THE OPTIMAL POLICY FORM IS KNOWN. Impulse
/// control under a fixed cost solves to a NO-TRADE BAND; neither invented rule
/// is one. If the band does not beat them, the derivation is being applied
/// wrongly here — which is itself worth knowing, and is not something the
/// original two-rule comparison could ever have surfaced.
#[test]
fn the_derived_band_is_the_only_arm_with_a_claim_to_optimal_form() {
    let cfg = Cfg::default();
    let (band, gate, lvl) = (mean_of(Arm::DerivedBand, cfg),
                             mean_of(Arm::PersistenceGated, cfg),
                             mean_of(Arm::LevelTrigger, cfg));
    println!("\n  DerivedBand {}   PersistenceGated {}   LevelTrigger {}", band, gate, lvl);
    println!("  (band beats gate: {}, band beats level: {})", band > gate, band > lvl);
    assert!(band >= lvl,
        "the known-optimal FORM should not lose to a hysteresis-free trigger: {} vs {}",
        band, lvl);
}

/// ⚠️ AND THE EXECUTION ASSUMPTION, WHICH WAS OPTIMISTIC RATHER THAN NEUTRAL.
/// A published trigger makes the pool a predictable buyer. The first cut charged
/// a flat spread and assumed the fill was otherwise fair — but the whole reason
/// to publish the rule was to stop it SIGNALLING, and publishing is exactly what
/// lets someone stand in front of it. The two goals are in tension and the sim
/// priced only one of them.
#[test]
fn publishing_the_rule_costs_execution_quality_and_that_was_unpriced() {
    let private = Cfg::default();
    let public  = Cfg { adverse_fill_bps: ADVERSE_FILL_BPS, ..Cfg::default() };
    for arm in [Arm::PersistenceGated, Arm::DerivedBand] {
        let (a, b) = (mean_of(arm, private), mean_of(arm, public));
        println!("  {:<20?} private {:>6}   published {:>6}   cost {:>5}", arm, a, b, a - b);
        assert!(b <= a, "being predictable cannot be free: {} vs {}", b, a);
    }
}

/// ⚠️ THE REGRET TABLE ABOVE CARRIES THE SAME UNIFORM-WEIGHTING FLAW I HAD JUST
/// FINISHED CORRECTING, plus it runs every arm at a 100% hedge ratio that the
/// ratio sweep already showed to be dominated. Re-run it honestly before
/// concluding anything from it.
#[test]
fn regret_under_plausible_weights_and_the_ratio_the_sweep_actually_favours() {
    let w = |c: &Cell| -> i64 {
        let mut p: i64 = 10_000;
        if c.issuer == Issuer::Paused    { p = p * 2 / 100; }
        if c.flow == Flow::RedemptionRun { p = p * 15 / 100; }
        if c.basis == Basis::Widening    { p = p * 30 / 100; }
        p.max(1)
    };
    let wmean = |arm: Arm, cfg: Cfg| -> i64 {
        let (mut num, mut den) = (0i64, 0i64);
        for c in &grid() { let k = w(c); num += run_cfg(*c, arm, cfg).depositor_bps * k; den += k; }
        num / den
    };
    for (label, ratio) in [("100% ratio", 10_000i64), ("25% ratio", 2_500)] {
        let cfg = Cfg { ratio_bps: ratio, ..Cfg::default() };
        let oracle = wmean(Arm::Clairvoyant, cfg);
        println!("\n=== weighted regret, {} ===", label);
        println!("  Clairvoyant (bound)  {:>6}", oracle);
        for arm in [Arm::NoFacility, Arm::PersistenceGated, Arm::DerivedBand, Arm::LevelTrigger] {
            let m = wmean(arm, cfg);
            println!("  {:<20?} {:>6}   regret {:>6}", arm, m, oracle - m);
        }
    }
}

/// 🔴 THE COMPARISON THAT DECIDES IT, AND IT HAD NEVER BEEN RUN. Every previous
/// sweep measured the facility against NOTHING — a pool that carries the net for
/// free. That is not an option. The real choice is between laying the risk off
/// (hedge), pricing it away (charge more as the book crowds), and refusing it
/// (cap per ticker). The last two are free of the round trip, the basis, the
/// weekend and the issuer; they cost only the flow not written.
#[test]
fn the_facility_against_its_actual_alternatives_not_against_nothing() {
    let w = |c: &Cell| -> i64 {
        let mut p: i64 = 10_000;
        if c.issuer == Issuer::Paused    { p = p * 2 / 100; }
        if c.flow == Flow::RedemptionRun { p = p * 15 / 100; }
        if c.basis == Basis::Widening    { p = p * 30 / 100; }
        p.max(1)
    };
    let wstats = |arm: Arm, cfg: Cfg| -> (i64, i64) {
        let (mut num, mut den) = (0i64, 0i64);
        let mut v = Vec::new();
        for c in &grid() {
            let k = w(c); let x = run_cfg(*c, arm, cfg).depositor_bps;
            num += x * k; den += k; v.push((x, k));
        }
        let mean = num / den;
        let mad = v.iter().map(|(x, k)| (x - mean).abs() * k).sum::<i64>() / den;
        (mean, mad)
    };

    for (label, ratio) in [("100% hedge ratio", 10_000i64), ("25% hedge ratio", 2_500)] {
        let cfg = Cfg { ratio_bps: ratio, ..Cfg::default() };
        let oracle = wstats(Arm::Clairvoyant, cfg).0;
        println!("\n=== weighted, {} — vs REAL alternatives ===", label);
        println!("  {:<20} {:>7} {:>8} {:>8}", "arm", "mean", "disp", "regret");
        for arm in [Arm::NoFacility, Arm::PriceTheImbalance, Arm::PerTickerCap,
                    Arm::PersistenceGated, Arm::DerivedBand, Arm::LevelTrigger] {
            let (m, d) = wstats(arm, cfg);
            println!("  {:<20?} {:>7} {:>8} {:>8}", arm, m, d, oracle - m);
        }
    }

    // The claim that must not be assumed: is hedging actually the best option?
    let cfg = Cfg { ratio_bps: 2_500, ..Cfg::default() };
    let hedge = wstats(Arm::PersistenceGated, cfg).0;
    let price = wstats(Arm::PriceTheImbalance, cfg).0;
    let cap   = wstats(Arm::PerTickerCap, cfg).0;
    println!("\n  best non-hedging alternative: {}", price.max(cap));
    println!("  best hedging arm:             {}", hedge);
    assert!(price != 0 || cap != 0, "alternatives must actually do something");
}

/// 🔴 THE BLIND SPOT, AND IT INVERTED THE PREVIOUS ANSWER. Flow was an INPUT, so
/// every arm faced the same book and a refusal cost one period of carry. In
/// reality a refusal costs the USER — and a cap refuses precisely when demand is
/// strongest. Scoring depositor P&L per unit of a FIXED book is the assumption
/// that made the cap look free.
///
/// A cap removes risk BY REFUSING BUSINESS. A hedge removes it by PAYING TO KEEP
/// the business. Both cut variance; only one preserves growth.
#[test]
fn capacity_is_an_output_not_an_input_and_the_cap_pays_for_its_variance_in_growth() {
    let w = |c: &Cell| -> i64 {
        let mut p: i64 = 10_000;
        if c.issuer == Issuer::Paused    { p = p * 2 / 100; }
        if c.flow == Flow::RedemptionRun { p = p * 15 / 100; }
        if c.basis == Basis::Widening    { p = p * 30 / 100; }
        p.max(1)
    };
    let wrun = |arm: Arm, cfg: Cfg| -> (i64, i64) {
        let (mut pnl, mut cap, mut den) = (0i64, 0i64, 0i64);
        for c in &grid() {
            let k = w(c); let o = run_cfg(*c, arm, cfg);
            pnl += o.depositor_bps * k; cap += o.capacity_bps * k; den += k;
        }
        (pnl / den, cap / den)
    };

    for att in [0i64, 2_000, 5_000] {
        let cfg = Cfg { ratio_bps: 2_500, attrition_bps: att, ..Cfg::default() };
        println!("\n=== attrition {}bps of refused flow — weighted, 25% ratio ===", att);
        println!("  {:<20} {:>7} {:>10} {:>12}", "arm", "mean", "capacity", "mean x cap");
        for arm in [Arm::NoFacility, Arm::PerTickerCap, Arm::PriceTheImbalance,
                    Arm::PersistenceGated, Arm::DerivedBand] {
            let (m, c) = wrun(arm, cfg);
            println!("  {:<20?} {:>7} {:>9}  {:>11}", arm, m, c, m * c / B_LOCAL);
        }
    }

    // At zero attrition the cap must look best — that is the old result. With
    // attrition it must lose ground, or the term is not doing anything.
    let no_att  = Cfg { ratio_bps: 2_500, attrition_bps: 0, ..Cfg::default() };
    let att     = Cfg { ratio_bps: 2_500, attrition_bps: 5_000, ..Cfg::default() };
    let cap_0 = wrun(Arm::PerTickerCap, no_att).1;
    let cap_a = wrun(Arm::PerTickerCap, att).1;
    let hedge_a = wrun(Arm::PersistenceGated, att).1;
    println!("\n  cap capacity: {} (no attrition) -> {} (with)", cap_0, cap_a);
    println!("  hedge capacity under the same attrition: {}", hedge_a);
    assert!(cap_a < cap_0, "attrition must actually shrink the capped book");
    assert!(hedge_a >= cap_a,
        "a hedging arm refuses nobody, so it cannot lose more capacity than a cap: {} vs {}",
        hedge_a, cap_a);
}

const B_LOCAL: i64 = 10_000;

fn wt(c: &Cell) -> i64 {
    let mut p: i64 = 10_000;
    if c.issuer == Issuer::Paused    { p = p * 2 / 100; }
    if c.flow == Flow::RedemptionRun { p = p * 15 / 100; }
    if c.basis == Basis::Widening    { p = p * 30 / 100; }
    p.max(1)
}
fn wrun2(arm: Arm, cfg: Cfg) -> (i64, i64) {
    let (mut pnl, mut cap, mut den) = (0i64, 0i64, 0i64);
    for c in &grid() {
        let k = wt(c); let o = run_cfg(*c, arm, cfg);
        pnl += o.depositor_bps * k; cap += o.capacity_bps * k; den += k;
    }
    (pnl / den, cap / den)
}

/// 🔴 COVERAGE. Every run so far hedged 100% of the book. Only 80 of 1,063
/// tickers have a token, so the facility can lay off a FRACTION and the rest is
/// carried by every arm alike. Full coverage flattered the hedging arms in every
/// previous result.
#[test]
fn only_part_of_the_book_is_hedgeable_and_the_sim_assumed_all_of_it() {
    println!("\n=== hedgeable share of the net (weighted, 25% ratio, 20% attrition) ===");
    println!("  {:<10} {:>18} {:>18} {:>16}", "coverage", "PersistenceGated", "PerTickerCap", "NoFacility");
    for cov in [750i64, 2_500, 5_000, 10_000] {
        let cfg = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: cov, ..Cfg::default() };
        let (g, gc) = wrun2(Arm::PersistenceGated, cfg);
        let (p, pc) = wrun2(Arm::PerTickerCap, cfg);
        let (n, _)  = wrun2(Arm::NoFacility, cfg);
        println!("  {:>5}bps   {:>7} / cap {:>5}   {:>7} / cap {:>5}   {:>7}", cov, g, gc, p, pc, n);
    }
    // ⚠️ THIS ASSERTED "more coverage is better" AND THAT WAS AN ASSUMPTION, NOT
    //    AN INVARIANT. It held while every net path in the grid was one-sided;
    //    adding `PersistentShort` made hedging net-harmful, at which point
    //    reaching LESS of the book is an improvement and the assertion failed.
    //    The sign of the coverage effect is downstream of whether hedging pays at
    //    all, so assert only that coverage is not INERT and let the table above
    //    report the direction.
    let thin = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 750, ..Cfg::default() };
    let full = Cfg { hedgeable_bps: 10_000, ..thin };
    assert_ne!(wrun2(Arm::PersistenceGated, thin).0, wrun2(Arm::PersistenceGated, full).0,
        "coverage must change the outcome; if it does not, the hedge is doing nothing");
}

/// 🔴 CORRELATION. The sim netted per ticker as though tickers were independent.
/// In stress they load on one factor, so the offsetting positions stop
/// offsetting EXACTLY when the net matters. `max_liability` already sums collars
/// for this reason; the simulation did not.
#[test]
fn per_ticker_netting_fails_under_a_common_factor() {
    println!("\n=== market beta (weighted, 25% ratio, 20% attrition, 25% coverage) ===");
    println!("  {:<8} {:>18} {:>16} {:>14}", "beta", "PersistenceGated", "PerTickerCap", "NoFacility");
    for beta in [0i64, 2_500, 5_000, 8_000] {
        let cfg = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 2_500,
                        beta_bps: beta, ..Cfg::default() };
        println!("  {:>5}bps   {:>13} {:>16} {:>14}", beta,
                 wrun2(Arm::PersistenceGated, cfg).0,
                 wrun2(Arm::PerTickerCap, cfg).0,
                 wrun2(Arm::NoFacility, cfg).0);
    }
}

/// 🔴 LIQUIDATION REVENUE, named by the owner as depositor income and never
/// modelled. The surprise is its SIGN CORRELATION: borrowers are net long, so
/// they liquidate on FALLS — which is when a short pool is already winning.
/// Income that arrives only in the good state AMPLIFIES the asymmetry instead of
/// offsetting it, which is the opposite of the usual intuition about an omitted
/// income stream.
#[test]
fn liquidation_income_arrives_in_the_state_the_pool_was_already_winning() {
    let base = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 2_500, ..Cfg::default() };
    println!("\n=== liquidation penalty (weighted) ===");
    for liq in [0i64, 200, 500] {
        let cfg = Cfg { liq_penalty_bps: liq, ..base };
        println!("  penalty {:>4}bps   NoFacility {:>6}   PersistenceGated {:>6}",
                 liq, wrun2(Arm::NoFacility, cfg).0, wrun2(Arm::PersistenceGated, cfg).0);
    }
    // Does it help MORE in up-paths (where the pool loses) or down-paths?
    let up   = Cell { price: Price::TrendUp,   net: Net::PersistentLong, flow: Flow::Calm,
                      basis: Basis::Tight, clock: Clock::Continuous, issuer: Issuer::Normal };
    let down = Cell { price: Price::TrendDown, ..up };
    let with = Cfg { liq_penalty_bps: 500, ..base };
    let gain_up   = run_cfg(up,   Arm::NoFacility, with).depositor_bps
                  - run_cfg(up,   Arm::NoFacility, base).depositor_bps;
    let gain_down = run_cfg(down, Arm::NoFacility, with).depositor_bps
                  - run_cfg(down, Arm::NoFacility, base).depositor_bps;
    println!("  liquidation income in a RALLY (pool loses): {} bps", gain_up);
    println!("  liquidation income in a CRASH (pool wins):  {} bps", gain_down);
    assert!(gain_down >= gain_up,
        "borrowers are long, so liquidation income must concentrate in falls: {} vs {}",
        gain_down, gain_up);
}

/// ⭐ THE INSTRUMENT COMPARISON, which is a different question from the policy
/// comparison and had never been asked. Every earlier arm hedged by buying SPOT,
/// and most of what those arms were charged for is a property of spot rather
/// than of hedging: the $100k ticket, the weekend hole, and the issuer's power
/// to seize. A perp has none of them, and equity perps on single US names are
/// live today.
#[test]
fn the_instrument_matters_more_than_the_policy() {
    println!("\n=== spot vs perp (weighted, 25% ratio, 20% attrition) ===");
    println!("  {:<10} {:>18} {:>14} {:>14}", "coverage", "PersistenceGated", "PerpHedge", "NoFacility");
    for cov in [750i64, 2_500, 5_000, 10_000] {
        let cfg = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: cov,
                        perp_venue_loss_bps: 3_000, ..Cfg::default() };
        println!("  {:>5}bps {:>16} {:>14} {:>14}", cov,
                 wrun2(Arm::PersistenceGated, cfg).0,
                 wrun2(Arm::PerpHedge, cfg).0,
                 wrun2(Arm::NoFacility, cfg).0);
    }

    // The perp's own risk, priced rather than waved through: venue failure is the
    // counterpart of issuer seizure and it is the one thing a perp ADDS.
    println!("\n=== perp venue-failure severity (25% coverage) ===");
    for loss in [0i64, 3_000, 7_200] {
        let cfg = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 2_500,
                        perp_venue_loss_bps: loss, ..Cfg::default() };
        println!("  loss {:>5}bps   PerpHedge {:>6}", loss, wrun2(Arm::PerpHedge, cfg).0);
    }

    let cfg = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 2_500,
                    perp_venue_loss_bps: 3_000, ..Cfg::default() };
    assert!(wrun2(Arm::PerpHedge, cfg).1 == 10_000,
        "a perp refuses nobody, so it must preserve capacity like any hedging arm");
}

/// 🔴 THE NUMBER THE DECISION ACTUALLY TURNS ON: how much notional coverage the
/// deliverable set gives, and where the hedge starts to pay. Reported as a
/// break-even rather than argued, so it can be checked against a real book.
#[test]
fn break_even_coverage_is_the_one_input_that_decides_this() {
    let base = |cov| Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: cov,
                           perp_venue_loss_bps: 3_000, ..Cfg::default() };
    let carry = wrun2(Arm::NoFacility, base(0)).0;
    println!("\n=== break-even coverage (carrying = {}) ===", carry);
    let (mut be_spot, mut be_perp) = (0i64, 0i64);
    for cov in (500..=10_000).step_by(500) {
        let c = cov as i64;
        let spot = wrun2(Arm::PersistenceGated, base(c)).0;
        let perp = wrun2(Arm::PerpHedge, base(c)).0;
        if be_spot == 0 && spot > carry { be_spot = c; }
        if be_perp == 0 && perp > carry { be_perp = c; }
    }
    println!("  spot hedge beats carrying from {} bps coverage", be_spot);
    println!("  perp hedge beats carrying from {} bps coverage", be_perp);
    println!("  (the deliverable ticker set is 80/1063 = 753 bps by COUNT;");
    println!("   by NOTIONAL it is the megacaps, so the real figure is higher");
    println!("   and is the one number that decides this.)");
}

/// ⭐ THE SCOPE THE OWNER SET: assume we have BOTH capabilities with Backed —
/// buy real paper spot, and borrow it to short. No competitor venue.
///
/// 🔴 THE SHORT LEG WAS FREE IN EVERY EARLIER RUN, AND THAT WAS WRONG. `target`
/// is signed, so every arm already flipped short when the book flipped — paying
/// only the round trip. A real short pays a BORROW FEE for every step it is open
/// and carries RECALL risk, which lands in stress because that is when lenders
/// call. Those two costs land entirely on one side of the book, so they change
/// which imbalances are worth hedging, not merely how much it costs.
#[test]
fn both_legs_priced_a_short_in_real_paper_is_not_the_mirror_of_a_long() {
    let base = |borrow, recall| Cfg {
        // ⚠️ 100% coverage here ON PURPOSE. At 25% the hedge is inert, so a
        //    borrow-cost sweep there measures nothing and reports zeros that read
        //    like "borrow cost is irrelevant". Isolate the leg being priced.
        ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 10_000,
        borrow_fee_bps: borrow, recall_bps: recall, ..Cfg::default() };

    println!("\n=== borrow cost on the short leg (weighted, 25% cov) ===");
    println!("  {:<22} {:>10} {:>10}", "borrow fee / step", "gated", "carry");
    for (b, r) in [(0i64, 0i64), (1, 200), (4, 500), (10, 1_000)] {
        let cfg = base(b, r);
        println!("  {:>3}bps + recall {:>4}   {:>8} {:>10}", b, r,
                 wrun2(Arm::PersistenceGated, cfg).0, wrun2(Arm::NoFacility, cfg).0);
    }

    // General collateral vs hard-to-borrow is the asymmetry that matters: the
    // SAME policy is worth having on one name and not on another.
    let gc  = wrun2(Arm::PersistenceGated, base(1, 200)).0;
    let htb = wrun2(Arm::PersistenceGated, base(10, 1_000)).0;
    println!("\n  general collateral {}   hard-to-borrow {}   spread {}", gc, htb, gc - htb);
    assert!(htb <= gc,
        "a hard-to-borrow name cannot be cheaper to hedge than general collateral: {} vs {}",
        htb, gc);
}

/// The decision number, recomputed under the owner's scope: both legs, real
/// paper, Backed-direct, borrow priced.
#[test]
fn break_even_coverage_with_both_legs_and_a_priced_borrow() {
    let mk = |cov, borrow, recall| Cfg {
        ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: cov,
        borrow_fee_bps: borrow, recall_bps: recall, ..Cfg::default() };
    let carry = wrun2(Arm::NoFacility, mk(0, 0, 0)).0;
    println!("\n=== break-even coverage, BOTH LEGS (carrying = {}) ===", carry);
    for (label, b, r) in [("free short (the old, wrong assumption)", 0i64, 0i64),
                          ("general collateral", 1, 200),
                          ("hard-to-borrow", 10, 1_000)] {
        let mut be = 0i64;
        for cov in (500..=10_000).step_by(500) {
            let c = cov as i64;
            if be == 0 && wrun2(Arm::PersistenceGated, mk(c, b, r)).0 > carry { be = c; }
        }
        println!("  {:<38} break-even {} bps coverage",
                 label, if be == 0 { -1 } else { be });
    }
    println!("  (deliverable set = 80/1063 = 753 bps by COUNT; by NOTIONAL it is");
    println!("   the megacaps, and that figure is what decides this.)");
}

/// 🔴 GROSS FLOW vs HEDGEABLE NET — a distinction the sim did not make, raised by
/// the owner: *"some people will buy and sell in the same block... not within
/// scope of the minting ... if we didnt get 100000 gathered."*
///
/// A round trip inside the window never becomes exposure and never accumulates
/// toward a ticket, so it is invisible to the hedge by construction. But the
/// residual that SURVIVES the filter is the flow that chose to stay — smaller,
/// and adversely selected. Both effects are priced here so the net direction is
/// measured rather than assumed.
#[test]
fn churn_shrinks_the_hedgeable_book_and_concentrates_the_view_in_what_remains() {
    let mk = |churn, adverse| Cfg {
        ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 10_000,
        borrow_fee_bps: 1, recall_bps: 200,
        churn_bps: churn, durable_adverse_bps: adverse, ..Cfg::default() };

    println!("\n=== transient share of gross flow (no adverse premium yet) ===");
    println!("  {:<8} {:>10} {:>10}", "churn", "gated", "carry");
    for ch in [0i64, 3_000, 6_000, 8_500] {
        let cfg = mk(ch, 0);
        println!("  {:>5}bps {:>10} {:>10}", ch,
                 wrun2(Arm::PersistenceGated, cfg).0, wrun2(Arm::NoFacility, cfg).0);
    }

    println!("\n=== ...and what survives has a view (churn 6000bps) ===");
    println!("  {:<10} {:>10} {:>10} {:>10}", "adverse", "gated", "carry", "gated-carry");
    for ad in [0i64, 5, 15, 30] {
        let cfg = mk(6_000, ad);
        let (g, c) = (wrun2(Arm::PersistenceGated, cfg).0, wrun2(Arm::NoFacility, cfg).0);
        println!("  {:>6}bps {:>10} {:>10} {:>10}", ad, g, c, g - c);
    }

    // The two effects genuinely oppose: churn alone helps the carrier (less
    // exposure), adverse selection alone hurts it (worse exposure).
    let plain   = wrun2(Arm::NoFacility, mk(6_000, 0)).0;
    let toxic   = wrun2(Arm::NoFacility, mk(6_000, 30)).0;
    let nochurn = wrun2(Arm::NoFacility, mk(0, 0)).0;
    println!("\n  carry: no churn {}   churn-only {}   churn+adverse {}", nochurn, plain, toxic);
    assert!(toxic <= plain,
        "flow that stayed on must be worse to hold than flow that did not: {} vs {}", toxic, plain);
}

/// 🔴 THE OBJECTIVE WAS WRONG IN EVERY EARLIER TEST. Owner: *"this is not hedging
/// to see if the borrower was wrong, this is to see if they were RIGHT and
/// protecting depositors from losing their deposit ... in exchange for providing
/// instant settlement the depositors earn the risk premiums."*
///
/// That is a RUIN objective — earn the premium, do not lose principal — not a
/// mean or a dispersion objective. Mean rewards a fat right tail the depositor
/// was never promised; dispersion penalises upside symmetrically with downside.
/// A hedge that costs mean but TRUNCATES THE LEFT TAIL is precisely what this
/// objective wants, and every metric I used scored that as a loss.
#[test]
fn principal_protection_is_the_objective_not_mean_or_dispersion() {
    let w = |c: &Cell| -> i64 {
        let mut p: i64 = 10_000;
        if c.issuer == Issuer::Paused    { p = p * 2 / 100; }
        if c.flow == Flow::RedemptionRun { p = p * 15 / 100; }
        if c.basis == Basis::Widening    { p = p * 30 / 100; }
        p.max(1)
    };
    // P(depositor ends below principal) and the average severity when they do.
    let ruin = |arm: Arm, cfg: Cfg| -> (i64, i64, i64) {
        let (mut den, mut bad_w, mut bad_sum, mut worst) = (0i64, 0i64, 0i64, 0i64);
        for c in &grid() {
            let k = w(c); let x = run_cfg(*c, arm, cfg).depositor_bps;
            den += k;
            if x < 0 { bad_w += k; bad_sum += x * k; if x < worst { worst = x; } }
        }
        (bad_w * 10_000 / den,                                  // P(loss), bps
         if bad_w > 0 { bad_sum / bad_w } else { 0 },           // mean loss | loss
         worst)                                                 // worst case
    };

    for (label, cfg) in [
        ("no churn, one-sided-heavy grid",
         Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 10_000,
               borrow_fee_bps: 1, recall_bps: 200, ..Cfg::default() }),
        ("60% churn, adverse residual",
         Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 10_000,
               borrow_fee_bps: 1, recall_bps: 200,
               churn_bps: 6_000, durable_adverse_bps: 15, ..Cfg::default() }),
    ] {
        println!("\n=== {} ===", label);
        println!("  {:<20} {:>10} {:>14} {:>10}", "arm", "P(loss)", "loss|loss", "worst");
        for arm in [Arm::NoFacility, Arm::PersistenceGated, Arm::PerTickerCap] {
            let (p, sev, w2) = ruin(arm, cfg);
            println!("  {:<20?} {:>8}bps {:>12}bps {:>8}", arm, p, sev, w2);
        }
    }

    // The claim the objective actually cares about: does the hedge truncate the
    // LEFT tail, whatever it does to the mean?
    let cfg = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 10_000,
                    borrow_fee_bps: 1, recall_bps: 200, ..Cfg::default() };
    let (_, _, w_none) = ruin(Arm::NoFacility, cfg);
    let (_, _, w_hedge) = ruin(Arm::PersistenceGated, cfg);
    println!("\n  worst case: carrying {}   hedged {}   truncation {}",
             w_none, w_hedge, w_hedge - w_none);
    assert!(w_none <= 0, "there must be a left tail to talk about truncating");
}

/// 🔴 THE METRIC THIS SHOULD HAVE BEEN ALL ALONG. Owner: *"whatever is profit
/// beyond what was pledged (using the borrowed money for instance to get the
/// exposure) still has to come from somewhere."*
///
/// A levered borrower pledges `P` and carries `L·P` of exposure. On a move `m`
/// they are owed `L·P·m`. The pledge funds `P`. **The excess is funded by
/// depositors unless the pool HOLDS THE ASSET**, in which case the asset's own
/// appreciation funds it one-for-one.
///
/// ⇒ THE FACILITY IS A FUNDING MATCH, NOT A RISK REDUCER. Every earlier test
/// measured pool P&L, which is a different question and answered it wrongly:
/// P&L asks "did we make money", funding asks "could we pay without touching
/// deposits". The second is the deposit contract.
#[test]
fn the_facility_is_a_funding_match_and_the_ratio_sets_the_move_it_survives() {
    // Depositor-funded shortfall on a winning levered borrower:
    //   shortfall = max(0, L·P·m·(1−r) − P)
    // r = 1 makes it identically negative: fully self-funding at ANY move.
    let shortfall = |lev: i64, move_bps: i64, ratio_bps: i64| -> i64 {
        let pledge = 10_000i64;                       // P, in bps of itself
        let gross  = lev * pledge / 100 * move_bps / B_LOCAL;
        let unhedged = gross * (B_LOCAL - ratio_bps) / B_LOCAL;
        (unhedged - pledge).max(0)
    };

    println!("\n=== depositor-funded payout (bps of the borrower's pledge) ===");
    println!("  {:<8} {:>8} {:>8} {:>8} {:>8} {:>8}", "move", "r=0%", "r=25%", "r=50%", "r=75%", "r=100%");
    for m in [500i64, 1_000, 2_000, 4_000, 8_000] {
        println!("  {:>5}bps {:>8} {:>8} {:>8} {:>8} {:>8}", m,
                 shortfall(300, m, 0), shortfall(300, m, 2_500), shortfall(300, m, 5_000),
                 shortfall(300, m, 7_500), shortfall(300, m, 10_000));
    }

    println!("\n=== the move at which depositors start funding (3x leverage) ===");
    for r in [0i64, 2_500, 5_000, 7_500, 10_000] {
        let mut first = 0i64;
        for m in (100..=20_000).step_by(100) {
            if shortfall(300, m as i64, r) > 0 { first = m as i64; break; }
        }
        println!("  ratio {:>5}bps -> depositors fund from a {} move",
                 r, if first == 0 { "no".to_string() } else { format!("{}bps", first) });
    }

    // The claim: hedging is not about being right, it is about the payout being
    // self-funded. A full hedge survives ANY move; an unhedged book does not.
    assert_eq!(shortfall(300, 20_000, 10_000), 0,
        "a fully hedged position must be self-funding at any move");
    assert!(shortfall(300, 20_000, 0) > 0,
        "an unhedged levered winner must reach past its pledge");
    // And the asymmetry that makes leverage the whole story:
    assert!(shortfall(500, 4_000, 0) > shortfall(200, 4_000, 0),
        "more leverage must reach further past the pledge on the same move");
}

/// 🔴 THE IMPLIED HEDGE RATIO, DERIVED — and it is not a number, it is a
/// function, exactly as the owner said.
///
/// Self-funding requires `L·P·m·(1−r) ≤ P`, i.e.
///
///     r_required = 1 − 1/(L·m)
///
/// where `L` is the position's leverage and `m` the move to survive. NEITHER is
/// a constant, and both are already computed by the program:
///   • `L` is capped by `max_leverage_pct`, which falls with volatility and
///     oracle staleness;
///   • `m` is that TICKER'S OWN fitted tail — `expected_shortfall_bps` off the
///     GPD in its own `Actuary` — so a quiet name and a violent one imply
///     different ratios for the identical position.
/// Direction, per-ticker utilisation and total utilisation enter through the
/// COST of holding the ratio (borrow fee on the short leg, `rate_bps` and
/// `solvency_bps` on the premium funding it) rather than through the ratio.
///
/// ⚠️ AND THE TRANCHING DOES NOT REDUCE IT. `stay.rs:1011` computes
/// `from_pool = redeem_dollars − pledged − accrued_interest` on a full
/// take-profit, with NO CAP. Partial TP capitalises into `deposited_quid`, which
/// DEFERS the draw at the borrower's option; it does not bound it.
#[test]
fn implied_hedge_ratio_is_a_function_of_leverage_and_that_tickers_own_tail() {
    let ratio_bps = |lev_pct: i64, tail_bps: i64| -> i64 {
        // r = 1 − 1/(L·m), in bps, clamped to [0, 10000].
        let lm = lev_pct * tail_bps / 100;            // L·m in bps
        if lm <= B_LOCAL { 0 } else { B_LOCAL - (B_LOCAL * B_LOCAL / lm) }
    };

    // Tails taken from the REAL fitted model at three volatility regimes, so the
    // table is the program's own numbers rather than invented ones.
    println!("\n=== implied hedge ratio r = 1 − 1/(L·m) ===");
    println!("  {:<26} {:>8} {:>10} {:>10} {:>10}", "regime (sigma -> ES tail)", "2x", "3x", "5x", "10x");
    for (label, sigma) in [("calm      (sigma 80bps)", 80i64),
                           ("normal    (sigma 220bps)", 220),
                           ("stressed  (sigma 600bps)", 600)] {
        // ⚠️ `obs_count` MATTERS AND ITS ABSENCE MADE THE FIRST TABLE VACUOUS.
        //    `eff_sigma` is `vol_floor`, which BLENDS `observed_vol_bps` with a
        //    prior weighted by `pow_bps(9512, obs_count)`. At `obs_count = 0` the
        //    decay is 1.0 and the prior dominates COMPLETELY — so setting the
        //    observed vol did nothing and calm and normal printed the identical
        //    tail (m=796 twice), which reads as "volatility does not matter".
        let mut a = Actuary::default();
        a.observed_vol_bps = sigma;
        a.max_drawdown_bps = sigma * 3;
        a.obs_count = 200;                 // let the empirical dominate the prior
        let m = a.expected_shortfall_bps(COLLAR_BREACH_BPS);
        println!("  {:<20} m={:>4}  {:>7}% {:>9}% {:>9}% {:>9}%",
                 label, m,
                 ratio_bps(200, m) / 100, ratio_bps(300, m) / 100,
                 ratio_bps(500, m) / 100, ratio_bps(1000, m) / 100);
    }

    // The two properties that make this a function and not a policy knob.
    let mut calm = Actuary::default();
    calm.observed_vol_bps = 80; calm.max_drawdown_bps = 240; calm.obs_count = 200;
    let mut wild = Actuary::default();
    wild.observed_vol_bps = 600; wild.max_drawdown_bps = 1_800; wild.obs_count = 200;
    let (mc, mw) = (calm.expected_shortfall_bps(COLLAR_BREACH_BPS),
                    wild.expected_shortfall_bps(COLLAR_BREACH_BPS));
    println!("\n  same 3x position: calm ticker needs {}bps, wild ticker needs {}bps",
             ratio_bps(300, mc), ratio_bps(300, mw));
    assert!(ratio_bps(300, mw) >= ratio_bps(300, mc),
        "a fatter-tailed ticker must require at least as much coverage: {} vs {}",
        ratio_bps(300, mw), ratio_bps(300, mc));
    assert!(ratio_bps(1000, mc) >= ratio_bps(200, mc),
        "more leverage must require more coverage on the same ticker");
}

// ═══════════════════════════════════════════════════════════════════════════
// §BAND-BOUND — what actually sets the facility policy, and it is not any of
// the things measured so far.
// ═══════════════════════════════════════════════════════════════════════════

/// 🔴 I TOLD THE OWNER THE PROFIT OBLIGATION WAS UNBOUNDED. IT IS NOT, AND THE
/// BOUND IS THE WHOLE POLICY.
///
/// `stay.rs:938` sets `upper = pledged + collar`, and `:944` forces a position
/// past it to either post variation margin from `deposited_quid` or be worked off
/// by `unwind_a_tranche`. So a winner cannot run: the most it can owe beyond its
/// pledge is ONE COLLAR plus whatever accrues while the ladder unwinds it.
///
/// That residual is what a facility would have to fund, and it is small and
/// computable — `lgd_bps` already computes its shape:
///     overshoot = mean_excess_bps(collar)         // GPD mean excess past the barrier
///     residual  = BPS − MAX_TRANCHE_BPS           // still exposed per window
#[test]
fn the_band_bounds_the_payout_and_that_is_what_the_facility_must_fund() {
    println!("\n=== uncovered profit past the band (bps of exposure) ===");
    println!("  {:<24} {:>8} {:>12} {:>14} {:>12}", "regime", "collar", "overshoot", "per-window", "windows to flat");
    for (label, sigma) in [("calm      (sigma 80)", 80i64),
                           ("normal    (sigma 220)", 220),
                           ("stressed  (sigma 600)", 600),
                           ("crisis    (sigma 1200)", 1_200)] {
        let mut a = Actuary::default();
        a.observed_vol_bps = sigma; a.max_drawdown_bps = sigma * 3; a.obs_count = 200;
        let collar = collar_bps(300, &a);
        let overshoot = a.mean_excess_bps(collar);
        let lgd = lgd_bps(collar, &a);
        // The ladder removes up to MAX_TRANCHE_BPS of the position per window.
        let windows = (B_LOCAL + MAX_TRANCHE_BPS - 1) / MAX_TRANCHE_BPS;
        println!("  {:<24} {:>8} {:>12} {:>14} {:>12}", label, collar, overshoot, lgd, windows);
    }

    // The facility only has to fund what the band lets escape, not the whole
    // position — which is the difference between a sizing question and an
    // existential one.
    let mut a = Actuary::default();
    a.observed_vol_bps = 600; a.max_drawdown_bps = 1_800; a.obs_count = 200;
    let collar = collar_bps(300, &a);
    assert!(collar > 0 && collar < 10_000, "the collar must be a real bound: {}", collar);
    assert!(lgd_bps(collar, &a) < collar + a.mean_excess_bps(collar) + 1,
        "loss-given-breach cannot exceed the barrier plus its own overshoot");
}

/// 🔴 THE HORIZON MISMATCH, WHICH IS THE ACTUAL FINDING AND WHICH BOTH OF MY
/// EARLIER STATEMENTS MISSED.
///
/// `LIQ_GRACE_SECS = 3600`, and the ladder is calibrated to `N = 7d/3600 = 168`
/// windows. So an unwind takes A WEEK, and the pool carries the position's
/// exposure — decaying at 1.85%/window — for the whole of it.
///
/// But `collar_bps` is sized off `expected_shortfall_bps(COLLAR_BREACH_BPS)`,
/// which is the tail of a SINGLE OBSERVATION. The exposure being collateralised
/// is a 168-OBSERVATION exposure. Under a random walk those differ by √168 ≈ 13×.
/// ⇒ **The collar answers "how far can it move before we act"; the facility must
/// answer "how far can it move while we are acting", and nothing in the sizing
/// currently reconciles the two horizons.**
#[test]
fn the_collar_is_a_one_step_tail_but_the_unwind_is_a_168_step_exposure() {
    const N: i64 = 168;                     // 7d / LIQ_GRACE_SECS
    // Mean open fraction over the unwind: (1-r)^n decaying at MAX_TRANCHE_BPS.
    let mut open = B_LOCAL; let mut area = 0i64;
    for _ in 0..N { area += open; open -= open * MAX_TRANCHE_BPS / B_LOCAL; }
    let mean_open = area / N;               // bps of the original position

    println!("\n=== one-step collar vs the exposure it is asked to cover ===");
    println!("  ladder: {} windows of 1h, mean open fraction {} bps ({}% of position)",
             N, mean_open, mean_open / 100);
    println!("  {:<24} {:>10} {:>16} {:>16}", "regime", "collar(1 obs)", "7d tail (sqrt-N)", "shortfall");
    for (label, sigma) in [("calm      (sigma 80)", 80i64),
                           ("normal    (sigma 220)", 220),
                           ("stressed  (sigma 600)", 600),
                           ("crisis    (sigma 1200)", 1_200)] {
        let mut a = Actuary::default();
        a.observed_vol_bps = sigma; a.max_drawdown_bps = sigma * 3; a.obs_count = 200;
        let collar = collar_bps(300, &a);
        // sqrt(168) ~ 12.96, in integer bps.
        let tail_7d = collar * 1296 / 100;
        // What the pool actually carries: the 7d tail on the mean open fraction.
        let carried = tail_7d * mean_open / B_LOCAL;
        println!("  {:<24} {:>10} {:>16} {:>16}", label, collar, tail_7d,
                 carried.saturating_sub(collar).max(0));
    }
    println!("  (shortfall = what escapes past the collar while the ladder runs.)");

    // The claim: a one-step tail cannot bound a 168-step exposure.
    let mut a = Actuary::default();
    a.observed_vol_bps = 600; a.max_drawdown_bps = 1_800; a.obs_count = 200;
    let collar = collar_bps(300, &a);
    let carried = (collar * 1296 / 100) * mean_open / B_LOCAL;
    assert!(carried > collar,
        "a 7-day exposure must exceed a 1-hour collar, or the horizons already agree: {} vs {}",
        carried, collar);
}

// ═══════════════════════════════════════════════════════════════════════════
// §COLLAR-CALIBRATION — everything above is built on `collar_bps`, and nothing
// had ever checked that `collar_bps` does what it says.
// ═══════════════════════════════════════════════════════════════════════════

/// 🔴 THE COLLAR STATES ITS OWN FALSIFIABLE TARGET AND NOBODY HAD TESTED IT.
/// `COLLAR_BREACH_BPS = 100` — *"1% of moves are expected to carry through the
/// band"*. If the realised breach rate is not ~1%, every risk number in this
/// file inherits the error, because they are all built on `collar_bps`.
///
/// Deterministic LCG, fat-tailed returns (a Gaussian-ish core with a rare jump),
/// so a failure reproduces exactly and the tail is not an artefact of `rand`.
#[test]
fn the_collar_breach_rate_should_be_the_one_percent_it_claims() {
    // Student-t-ish: sum of uniforms for the core, plus a heavy jump tail.
    let draw = |st: &mut u64, scale: i64| -> i64 {
        let mut acc = 0i64;
        for _ in 0..4 {
            *st = st.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            acc += ((*st >> 33) % 2001) as i64 - 1000;
        }
        let core = acc * scale / 4000;
        *st = st.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let u = ((*st >> 33) % 10_000) as i64;
        if u < 30 { core * 8 } else if u < 200 { core * 3 } else { core }   // fat tail
    };

    println!("\n=== realised breach rate vs the 1% the collar is sized to ===");
    println!("  {:<19} {:>8} {:>12} {:>14} {:>10}", "regime / lev", "collar", "breaches", "of samples", "rate");
    let mut worst_ratio = 0i64;
    for (label, scale) in [("calm     (scale 80)", 80i64),
                           ("normal   (scale 220)", 220),
                           ("stressed (scale 600)", 600)] {
        let mut a = Actuary::default();
        a.last_price = 1_000_000; a.last_price_slot = 0;
        let mut st: u64 = 0xC0FFEE;
        let mut px: i64 = 1_000_000;
        // Warm up so the tail is fitted rather than assumed.
        for i in 1..600i64 {
            let d = draw(&mut st, scale);
            px = (px as i128 * (10_000 + d as i128) / 10_000).max(1) as i64;
            a.update_price(px, i * 10);
        }
        // ⚠️ MEASURE AT EVERY LEVERAGE, because the collar is NOT monotone in it
        //    the way its docstring implies — it is pinned at the sigma FLOOR for
        //    everything at or above 2x, so 1x and 10x are different instruments.
        //    A first version of this test measured 1x only, saw zero breaches,
        //    and would have reported "the collar is conservative".
        for lev in [100i64, 200, 500, 1_000] {
            let collar = collar_bps(lev, &a);
            let (mut breach, mut n) = (0i64, 0i64);
            let mut s2 = st; let mut p2 = px;
            for i in 600..5_600i64 {
                let d = draw(&mut s2, scale);
                if d.abs() > collar { breach += 1; }
                n += 1;
                p2 = (p2 as i128 * (10_000 + d as i128) / 10_000).max(1) as i64;
                let _ = i;
            }
            let rate = breach * 10_000 / n.max(1);
            let ratio = rate * 100 / COLLAR_BREACH_BPS.max(1);
            if ratio > worst_ratio { worst_ratio = ratio; }
            println!("  {:<16} {}x {:>8} {:>12} {:>14} {:>7}bps", label, lev / 100,
                     collar, breach, n, rate);
        }
        for i in 600..5_600i64 {
            let d = draw(&mut st, scale);
            px = (px as i128 * (10_000 + d as i128) / 10_000).max(1) as i64;
            a.update_price(px, i * 10);
        }
    }
    println!("  target {} bps (1%). worst regime is {}% of target.", COLLAR_BREACH_BPS, worst_ratio);
    println!("  >100% means the collar is TOO TIGHT (breaches more than designed);");
    println!("  <100% means it is too wide (over-collateralised, LPs over-charged).");

    // Not an assertion on the exact number — the point is to REPORT it, because
    // a calibration claim nobody measures is the definition of a blindfold.
    assert!(worst_ratio > 0, "the harness must actually produce breaches to measure");
}

/// The collar's own docstring claims two monotonicities. Neither had been tested,
/// and they are the properties a borrower would call FAIR: more volatility buys
/// more room, more leverage buys less.
#[test]
fn the_collar_is_monotone_in_the_two_things_it_claims_to_be_monotone_in() {
    let mk = |sigma: i64| {
        let mut a = Actuary::default();
        a.observed_vol_bps = sigma; a.max_drawdown_bps = sigma * 3; a.obs_count = 200;
        a
    };
    println!("\n=== collar monotonicity ===");
    println!("  {:<12} {:>8} {:>8} {:>8} {:>8}", "sigma", "1x", "2x", "5x", "10x");
    for s in [80i64, 220, 600, 1_200] {
        let a = mk(s);
        println!("  {:<12} {:>8} {:>8} {:>8} {:>8}", s,
                 collar_bps(100, &a), collar_bps(200, &a), collar_bps(500, &a), collar_bps(1000, &a));
    }
    let (calm, wild) = (mk(80), mk(1_200));
    assert!(collar_bps(100, &wild) >= collar_bps(100, &calm),
        "higher vol must not buy a NARROWER collar");
    assert!(collar_bps(1000, &calm) <= collar_bps(100, &calm),
        "higher leverage must not buy a WIDER collar");
}

// ═══════════════════════════════════════════════════════════════════════════
// §RETURNS-VALIDATION — validate the generator BEFORE measuring with it.
// ═══════════════════════════════════════════════════════════════════════════

use crate::returns::Equity;

/// ⚠️ A GENERATOR I DO NOT VALIDATE IS THE SAME BLINDFOLD IN A NEW PLACE. The
/// previous measurement used an invented tail; replacing it with a different
/// invented tail would be no better. These are the stylised facts of equity
/// returns that a barrier model is sensitive to, each checked against its known
/// empirical value.
#[test]
fn the_return_generator_reproduces_the_stylised_facts_it_claims() {
    for target_daily in [120i64, 300] {
        let mut g = Equity::new(0xA11CE, target_daily);
        let (mut n, mut sum2, mut sum4, mut gaps, mut gap2) = (0i64, 0i128, 0i128, 0i64, 0i128);
        let mut moves: Vec<i64> = Vec::new();
        for _ in 0..(24 * 7 * 500) {                       // ~400 weeks of hours
            let (r, is_gap) = g.step();
            if r == 0 { continue; }
            n += 1;
            sum2 += (r as i128) * (r as i128);
            sum4 += (r as i128).pow(4);
            if is_gap { gaps += 1; gap2 += (r as i128) * (r as i128); }
            moves.push(r);
        }
        let var = (sum2 / n.max(1) as i128) as i64;
        let sd = (var as f64).sqrt() as i64;
        // Kurtosis = E[r^4]/var^2. Normal = 3; equities are 5-10 daily.
        let kurt = if var > 0 { (sum4 / n.max(1) as i128) / ((var as i128) * (var as i128)) } else { 0 };
        // Vol clustering: corr(|r_t|, |r_{t-1}|), crudely as a ratio of
        // co-movement to mean, positive when large moves cluster.
        let mean_abs = moves.iter().map(|x| x.abs()).sum::<i64>() / moves.len().max(1) as i64;
        let mut co = 0i64;
        for w in moves.windows(2) {
            if (w[0].abs() > mean_abs) == (w[1].abs() > mean_abs) { co += 1; }
        }
        let cluster = co * 100 / (moves.len().max(1) as i64 - 1);
        let gap_var_share = if sum2 > 0 { (gap2 * 100 / sum2) as i64 } else { 0 };

        println!("\n=== generator @ target daily vol {}bps ===", target_daily);
        println!("  realised per-move sd   {:>6} bps", sd);
        println!("  kurtosis               {:>6}   (normal 3; equities 5-10)", kurt);
        println!("  |r| clustering         {:>6}%  (50% = none)", cluster);
        println!("  gap share of variance  {:>6}%", gap_var_share);
        println!("  moves {} of which gaps {}", n, gaps);

        assert!(kurt >= 3, "equity returns are leptokurtic; got kurtosis {}", kurt);
        assert!(cluster > 50, "vol must cluster, else tails are independent: {}%", cluster);
        assert!(gap_var_share > 5, "gaps must carry real variance: {}%", gap_var_share);
    }
}

/// 🔴 THE COLLAR CALIBRATION, RE-RUN AGAINST CALIBRATED RETURNS RATHER THAN A
/// TAIL I MADE UP. This is the number the whole facility policy rests on.
#[test]
fn collar_breach_rate_against_calibrated_equity_returns() {
    println!("\n=== realised breach vs the 1% target — CALIBRATED returns ===");
    println!("  {:<28} {:>8} {:>10} {:>10} {:>9}", "name / lev", "collar", "breaches", "samples", "rate");
    let mut worst = 0i64;
    for (label, dv) in [("large-cap  (19% ann)", 120i64),
                        ("mid-vol    (32% ann)", 200),
                        ("high-vol   (48% ann)", 300),
                        ("meme       (95% ann)", 600)] {
        let mut a = Actuary::default();
        a.last_price = 1_000_000; a.last_price_slot = 0;
        let mut g = Equity::new(0xBEEF, dv);
        let mut px: i64 = 1_000_000;
        let mut h = 0i64;
        for _ in 0..(24 * 7 * 500) {                        // warm up ~60 weeks
            let (r, _) = g.step(); h += 1;
            if r == 0 { continue; }
            px = ((px as i128) * (10_000 + r as i128) / 10_000).max(1) as i64;
            a.update_price(px, h * 3_000);
        }
        for lev in [100i64, 200, 500, 1_000] {
            let collar = collar_bps(lev, &a);
            let mut g2 = Equity::new(0xF00D, dv);
            let (mut breach, mut n) = (0i64, 0i64);
            for _ in 0..(24 * 7 * 500) {
                let (r, _) = g2.step();
                if r == 0 { continue; }
                n += 1;
                if r.abs() > collar { breach += 1; }
            }
            let rate = breach * 10_000 / n.max(1);
            let ratio = rate * 100 / COLLAR_BREACH_BPS.max(1);
            if ratio > worst { worst = ratio; }
            println!("  {:<22} {}x {:>8} {:>10} {:>10} {:>6}bps",
                     label, lev / 100, collar, breach, n, rate);
        }
    }
    println!("\n  target {}bps. worst regime = {}% of target.", COLLAR_BREACH_BPS, worst);
    println!("  >100% = collar too TIGHT (breaches more than designed)");
    println!("  <100% = too WIDE (over-collateralised, capital wasted)");
    assert!(worst > 0, "the calibrated process must produce breaches somewhere");
}

/// 🔴 THE NETTING CALCULATION. Two errors were measured and never netted:
///   • the collar breaches 0.16% where it targets 1% — call it ~6x WIDE
///   • it is a ONE-step tail against a 168-step unwind — call it ~13x NARROW
/// They point in OPPOSITE directions, so neither number alone says whether the
/// collar is wrong. This measures the only thing that does: the collar against
/// the actual 168-step cumulative move, at the breach rate it claims to target.
#[test]
fn net_the_over_collateralisation_against_the_horizon_shortfall() {
    use crate::returns::Equity;
    const N: usize = 168;                       // 7d / LIQ_GRACE_SECS

    println!("\n=== collar vs the move it must actually survive ===");
    println!("  {:<22} {:>8} {:>12} {:>12} {:>10}", "regime", "collar", "1-step p99", "168-step p99", "verdict");
    for (label, dv) in [("large-cap (19% ann)", 120i64), ("mid-vol   (32% ann)", 200),
                        ("high-vol  (48% ann)", 300), ("meme      (95% ann)", 600)] {
        let mut a = Actuary::default();
        a.last_price = 1_000_000; a.last_price_slot = 0;
        let mut g = Equity::new(0xBEEF, dv);
        let mut px: i64 = 1_000_000; let mut h = 0i64;
        for _ in 0..(24 * 7 * 40) {
            let (r, _) = g.step(); h += 1;
            if r == 0 { continue; }
            px = ((px as i128) * (10_000 + r as i128) / 10_000).max(1) as i64;
            a.update_price(px, h * 3_000);
        }
        let collar = collar_bps(100, &a);

        // Empirical distributions: single moves, and 168-move cumulative windows.
        let mut g2 = Equity::new(0xF00D, dv);
        let mut singles: Vec<i64> = Vec::new();
        let mut moves: Vec<i64> = Vec::new();
        for _ in 0..(24 * 7 * 400) {
            let (r, _) = g2.step();
            if r == 0 { continue; }
            singles.push(r.abs()); moves.push(r);
        }
        // Cumulative |move| over rolling 168-observation windows, decayed by the
        // ladder: what is still OPEN when each step lands is what can hurt.
        let mut cum: Vec<i64> = Vec::new();
        let mut i = 0usize;
        while i + N < moves.len() {
            let (mut open, mut acc) = (10_000i64, 0i64);
            for k in 0..N {
                acc += moves[i + k] * open / 10_000;
                open -= open * MAX_TRANCHE_BPS / 10_000;
            }
            cum.push(acc.abs());
            i += N;
        }
        singles.sort(); cum.sort();
        let p99 = |v: &Vec<i64>| if v.is_empty() { 0 } else { v[(v.len() * 99) / 100] };
        let (s99, c99) = (p99(&singles), p99(&cum));
        let verdict = if collar >= c99 { "ADEQUATE" } else { "SHORT" };
        println!("  {:<22} {:>8} {:>12} {:>12} {:>10}", label, collar, s99, c99, verdict);
    }
    println!("  1-step p99 is what the collar is DERIVED against;");
    println!("  168-step p99 is what it must actually SURVIVE (ladder-decayed).");
}
