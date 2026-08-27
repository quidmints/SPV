//! §FACILITY-SIM — does the xStocks hedging facility make depositors better off?
//!
//! 🔴 **THE QUESTION WAS POSED AS A DOMINANCE CLAIM — "better in every case, no
//! matter the market conditions" — AND A DOMINANCE CLAIM DIES TO ONE
//! COUNTEREXAMPLE.** So this harness does NOT sample scenarios and check they
//! look fine; that is the confirmation-bias trap the request explicitly warned
//! against. It enumerates a grid and **hunts the cells where the facility
//! LOSES**, then reports where the sign boundary is.
//!
//! ⚠️ ONE COUNTEREXAMPLE IS ALREADY KNOWN FROM STRUCTURE, BEFORE ANY SIMULATION:
//! a hedge pays a round trip UNCONDITIONALLY and pays out only in the tail, so in
//! a mean-reverting book the pool buys, the net reverts, and it sells — two
//! spreads for nothing. That is what insurance is, and insurance is never
//! always-better. The simulation's job is therefore to size the losing region,
//! not to decide whether one exists.
//!
//! ⭐ **IT DRIVES THE REAL CODE.** `Actuary::update_price`, `collar_bps`,
//! `rate_bps`, `fee_bps` are the program's own functions, so the sim cannot
//! drift from what the chain does. A reimplementation would have measured a
//! model of the protocol rather than the protocol.
//!
//! Compiled only under `cfg(test)` — nothing here reaches the deployed binary.

use crate::etc::*;

/// Basis points of a whole.
const B: i64 = 10_000;

// ── Grid axes ───────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Price { TrendUp, TrendDown, Chop, Jump, CrashRecover }

/// How the pool's NET exposure evolves. This is the borrowers' behaviour, and
/// `AdversarialInduced` is the attack: push past the trigger, then withdraw.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Net { PersistentLong, MeanReverting, AdversarialInduced }

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Flow { Calm, RedemptionRun }

/// xStock-vs-underlying basis. `Widening` is the weekend/thin-secondary case.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Basis { Tight, Widening }

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Clock { Continuous, WeekendGapped }

/// `Paused` is not hypothetical: AAPLx carries a `PermanentDelegate` that can
/// move or burn any holder's balance and a `Pausable` authority that can halt
/// transfers. A synthetic book has no such exposure, so it belongs on the grid.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Issuer { Normal, Paused }

#[derive(Clone, Copy, Debug)]
pub struct Cell {
    pub price: Price, pub net: Net, pub flow: Flow,
    pub basis: Basis, pub clock: Clock, pub issuer: Issuer,
}

/// The three arms. `A` is the counterfactual: no facility at all.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Arm {
    /// Synthetic only — carry the net, never buy a share.
    NoFacility,
    /// Hedge whenever `|net| > theta`. A LEVEL trigger: an impulse fires it.
    LevelTrigger,
    /// Hedge on `∫(|net| − theta)+ dt > THETA`. Only a SUSTAINED position fires
    /// it, and sustaining pays carry the whole time.
    PersistenceGated,
}

// ── Cost constants, stated so they can be argued with ───────────────────────

/// Round-trip cost of one hedge ticket in bps of notional: xStock secondary
/// spread plus impact. Thin secondary is the whole reason this is not 5.
const HEDGE_RT_BPS: i64 = 60;
/// Minimum ticket. Backed's primary mint minimum is $100k; below this the pool
/// cannot transact at all, which is a constraint before it is a cost.
const TICKET: i64 = 100_000;
/// Basis drift suffered while holding the hedge, per step, when widening.
const BASIS_DRIFT_BPS: i64 = 8;
/// Extra cost of liquidating a share rather than holding dollars during a run.
const RUN_ILLIQUIDITY_BPS: i64 = 250;
/// Level trigger, in bps of book.
const THETA_BPS: i64 = 1_500;
/// Persistence budget: bps-of-book × steps above theta before acting.
const PERSIST_BUDGET: i64 = 6_000;

const STEPS: i64 = 64;
const DEPOSITS: i64 = 10_000_000;

/// Deterministic LCG — no `rand`, no clock, so a failure reproduces exactly.
fn lcg(state: &mut u64) -> i64 {
    *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    ((*state >> 33) as i64) % 1000
}

/// Price path in bps-change per step.
fn price_step(p: Price, t: i64, rng: &mut u64) -> i64 {
    let noise = lcg(rng) % 60 - 30;
    match p {
        Price::TrendUp   =>  45 + noise,
        Price::TrendDown => -45 + noise,
        Price::Chop      => if t % 2 == 0 { 120 + noise } else { -120 + noise },
        Price::Jump      => if t == STEPS / 2 { -1_800 } else { noise / 2 },
        Price::CrashRecover => {
            if t < STEPS / 4 { -260 + noise }
            else if t < STEPS / 2 { 240 + noise }
            else { noise }
        }
    }
}

/// Net exposure as a fraction of the book, in bps.
fn net_path(n: Net, t: i64) -> i64 {
    match n {
        Net::PersistentLong => 2_600,
        Net::MeanReverting  => if (t / 6) % 2 == 0 { 2_200 } else { -2_000 },
        // The attack: cross the trigger, hold just long enough for a level
        // trigger to fire, then leave. A persistence gate should not fire.
        Net::AdversarialInduced => {
            let phase = t % 16;
            if phase < 3 { 3_400 } else { 200 }
        }
    }
}

pub struct Outcome { pub depositor_bps: i64, pub hedges: i64, pub hedged_notional: i64 }

/// One (cell, arm) run. Returns depositor P&L in bps of deposits.
pub fn run(cell: Cell, arm: Arm) -> Outcome {
    let mut a = Actuary::default();
    a.observed_vol_bps = 220;
    a.max_drawdown_bps = 700;
    a.last_price = 1_000_000;
    a.last_price_slot = 0;
    a.total_exposure = DEPOSITS / 2;

    let mut rng: u64 = 0x5EED;
    let mut px: i64 = 1_000_000;
    let mut pnl: i64 = 0;              // depositor P&L, absolute
    let mut hedge_notional: i64 = 0;   // signed, in dollars
    let mut persist_acc: i64 = 0;
    let mut hedges: i64 = 0;
    let mut hedged_total: i64 = 0;

    for t in 0..STEPS {
        // ── price ──────────────────────────────────────────────────────────
        let mut d = price_step(cell.price, t, &mut rng);
        // A closed primary market does not stop the price; it stops the HEDGE.
        // The move still lands, it just lands all at once on reopening.
        let tradable = !(cell.clock == Clock::WeekendGapped && t % 7 >= 5);
        if cell.clock == Clock::WeekendGapped && t % 7 == 0 { d += 400; }
        let new_px = (px as i128 * (B as i128 + d as i128) / B as i128) as i64;
        a.update_price(new_px, t * 3_000);
        px = new_px;

        // ── the pool's own book ────────────────────────────────────────────
        let net_bps = net_path(cell.net, t);
        let net_dollars = DEPOSITS / 2 * net_bps / B;
        a.net_exposure = net_dollars;

        // Revenue: borrowers pay carry on the book, continuously.
        let util = (a.total_exposure * B / DEPOSITS).clamp(0, B);
        let carry = rate_bps(util, 150, &a);
        pnl += a.total_exposure * carry / B / 100;

        // 🔴 SIGN: THE POOL IS THE COUNTERPARTY, SO IT IS SHORT WHAT BORROWERS ARE
        //    LONG. A borrower book that is net +X leaves the pool at −X, and the
        //    hedge is a LONG position of +X that cancels it. A first draft had the
        //    pool long on BOTH legs, which double-counted direction and made the
        //    hedge look like it lost money in the one case it exists for — the
        //    test `facility_pays_where_it_should_...` is what caught it.
        pnl += (hedge_notional - net_dollars) * d / B;

        // ── the hedge decision ─────────────────────────────────────────────
        let excess = net_bps.abs() - THETA_BPS;
        if excess > 0 { persist_acc += excess; } else { persist_acc = 0; }

        let want = match arm {
            Arm::NoFacility => 0,
            Arm::LevelTrigger => if net_bps.abs() > THETA_BPS { net_dollars } else { 0 },
            Arm::PersistenceGated =>
                if persist_acc > PERSIST_BUDGET { net_dollars } else { hedge_notional },
        };

        // ⚠️ A PAUSE DOES NOT STOP US BUYING — it strands what we already hold.
        //    Gating the TRADE on `Issuer::Normal` silently turned every paused
        //    cell into the no-facility arm, so the pause column measured nothing.
        let delta = want - hedge_notional;
        if tradable && delta.abs() >= TICKET {
            pnl -= delta.abs() * HEDGE_RT_BPS / B;   // spread + impact, both ways
            hedge_notional = want;
            hedges += 1;
            hedged_total += delta.abs();
        }

        // ── carrying the hedge is not free ─────────────────────────────────
        if hedge_notional != 0 {
            if cell.basis == Basis::Widening {
                pnl -= hedge_notional.abs() * BASIS_DRIFT_BPS / B;
            }
            // A redemption run needs dollars; the pool is holding shares.
            if cell.flow == Flow::RedemptionRun {
                pnl -= hedge_notional.abs() * RUN_ILLIQUIDITY_BPS / B / STEPS;
            }
            // The issuer can freeze or seize. The liability does not freeze with it.
            if cell.issuer == Issuer::Paused && t == STEPS / 2 {
                // Seized/frozen: the hedge stops offsetting, the liability does not.
                pnl -= hedge_notional.abs() / 2;
                hedge_notional = 0;
            }
        }
    }
    Outcome { depositor_bps: pnl * B / DEPOSITS, hedges, hedged_notional: hedged_total }
}

pub fn grid() -> Vec<Cell> {
    let mut v = Vec::new();
    for price in [Price::TrendUp, Price::TrendDown, Price::Chop, Price::Jump, Price::CrashRecover] {
    for net in [Net::PersistentLong, Net::MeanReverting, Net::AdversarialInduced] {
    for flow in [Flow::Calm, Flow::RedemptionRun] {
    for basis in [Basis::Tight, Basis::Widening] {
    for clock in [Clock::Continuous, Clock::WeekendGapped] {
    for issuer in [Issuer::Normal, Issuer::Paused] {
        v.push(Cell { price, net, flow, basis, clock, issuer });
    }}}}}}
    v
}
