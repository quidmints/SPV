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
