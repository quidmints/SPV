//! §FACILITY-SIM REPORT — the sign map, and the hunt for negative cells.

use crate::facility_sim::*;

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
    let thin = Cfg { ratio_bps: 2_500, attrition_bps: 2_000, hedgeable_bps: 750, ..Cfg::default() };
    let full = Cfg { hedgeable_bps: 10_000, ..thin };
    assert!(wrun2(Arm::PersistenceGated, thin).0 <= wrun2(Arm::PersistenceGated, full).0,
        "a hedge that can only reach part of the book cannot beat one that reaches all of it");
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
