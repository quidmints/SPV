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
    /// ⭐ THE ONLY ARM DERIVED FROM AN OPTIMALITY CONDITION RATHER THAN INVENTED.
    /// Impulse control under a fixed transaction cost has a known solution — a
    /// NO-TRADE BAND of width `h = ∛(g/(C·K))` (Constantinides; Janeček–Shreve),
    /// which is the same result already implemented on the EVM side as
    /// `noTradeBandBps`. `LevelTrigger` and `PersistenceGated` are not of this
    /// form at all: one has no hysteresis and re-fires on every crossing, the
    /// other is a time integral. Both are therefore suboptimal BY CONSTRUCTION,
    /// and comparing them to each other could never have revealed that.
    DerivedBand,
    /// 🔴 THE COMPARISON THAT WAS MISSING ENTIRELY: the facility had only ever
    /// been measured against NOTHING. These two are what a pool without a hedge
    /// actually does, and both are FREE of the round trip, the basis, the
    /// weekend, and the issuer — the four costs that dominate the hedging arms.
    ///
    /// Charge more as the book crowds, so the imbalance shrinks endogenously.
    /// `crowding_bps` and `info_mult` already exist; this is turning them up.
    PriceTheImbalance,
    /// Refuse the marginal one-sided trade past a hard per-ticker cap. Costs the
    /// revenue on flow not written, and nothing else.
    PerTickerCap,
    /// 🔴 NOT A POLICY — A BENCHMARK. Knows the next `LOOKAHEAD` steps of the
    /// price path and hedges only when that move will actually pay for the round
    /// trip. Unimplementable, and that is the point: the gap between a rule and
    /// this is REGRET, which is the only way to say whether a rule is good
    /// rather than merely better than another rule I also made up.
    Clairvoyant,
}

/// Perfect-foresight window for the benchmark arm.
pub const LOOKAHEAD: i64 = 6;

/// Integer cube root, for the derived band.
fn icbrt(x: i64) -> i64 {
    if x <= 0 { return 0; }
    let mut r = 1i64;
    while (r + 1).saturating_mul(r + 1).saturating_mul(r + 1) <= x { r += 1; }
    r
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

/// Execution quality. A PUBLISHED trigger makes the pool a predictable buyer,
/// and a predictable buyer does not transact at the mark — it transacts against
/// whoever read the rule. The first cut charged a flat spread and assumed the
/// fill was otherwise fair, which is the optimistic case, not the neutral one.
pub const ADVERSE_FILL_BPS: i64 = 25;

/// Knobs that were constants in the first cut. Each was an assumption doing
/// real work in the answer, so each is now something you can sweep instead of
/// something I asserted.
#[derive(Clone, Copy, Debug)]
pub struct Cfg {
    /// Fraction of the net actually hedged, in bps. 10_000 = full. The first
    /// version only ever tested 0 or 10_000, which skipped the entire middle
    /// where most of the variance reduction is bought at half the cost.
    pub ratio_bps: i64,
    /// Round-trip hedge cost. My estimate, not a measurement — sweep it.
    pub rt_bps: i64,
    /// 🔴 THE TERM THE FIRST CUT SCORED AT ZERO, AND IT IS THE LARGEST ONE
    /// OMITTED. Without a hedge the pool cannot simply carry the net for free:
    /// it must widen collars, cap per-ticker exposure, or refuse flow. That is
    /// REVENUE FORGONE, and scoring it at zero silently assumed the facility's
    /// only effect is cost. Expressed as bps of the net that the pool cannot
    /// write when it has no way to lay the risk off.
    pub forgone_rev_bps: i64,
    /// Extra cost per hedge when the trigger is publicly computable, i.e. when
    /// someone can stand in front of it. Zero models a private (and therefore
    /// signalling) rule; `ADVERSE_FILL_BPS` models a published one.
    pub adverse_fill_bps: i64,
    /// 🔴 THE DIMENSION THE WHOLE SIM WAS BLIND TO. Flow was an INPUT: every arm
    /// faced the identical net path, which silently assumed that refusing a user
    /// costs one period of carry and nothing else. It costs the user.
    ///
    /// A cap removes risk BY REFUSING BUSINESS; a hedge removes it by paying to
    /// KEEP the business. Both cut variance, only one preserves growth — so
    /// measuring depositor P&L per unit of a FIXED book is precisely the
    /// assumption that makes a cap look free. `attrition_bps` is the fraction of
    /// refused flow that does not come back, per refusal.
    pub attrition_bps: i64,

    /// 🔴 THE SIM HEDGED 100% OF THE BOOK. Only **80 of 1,063 tickers** have a
    /// token on Solana, so the facility can cover a FRACTION of the net and the
    /// rest is carried no matter which arm is chosen. Assuming full coverage
    /// flattered every hedging arm in every run so far. (By notional the
    /// deliverable set is richer than 7.5% — it is the megacaps — so this is a
    /// knob, not a constant.)
    pub hedgeable_bps: i64,

    /// 🔴 AND IT NETTED PER TICKER AS IF TICKERS WERE INDEPENDENT. They are not:
    /// in stress everything loads on one market factor, so the offsetting
    /// positions that make the net small stop offsetting EXACTLY when the net
    /// matters. `max_liability` already sums collars for this reason; the sim did
    /// not. Beta is the share of exposure that is common rather than
    /// idiosyncratic.
    pub beta_bps: i64,

    /// 🔴 LIQUIDATION REVENUE WAS NEVER MODELLED AT ALL, and the owner named it
    /// as a depositor income stream. It is not a hedge: borrowers are net LONG,
    /// so they liquidate on FALLS — which is when the short pool is ALREADY
    /// winning. Income that arrives only in the good state amplifies the
    /// asymmetry rather than offsetting it, which is the opposite of what an
    /// unmodelled income stream is usually assumed to do.
    pub liq_penalty_bps: i64,
    /// Swap fees earned on turnover, per step, in bps of the book.
    pub swap_fee_bps: i64,
}

impl Default for Cfg {
    fn default() -> Self { Cfg { ratio_bps: 10_000, rt_bps: HEDGE_RT_BPS, forgone_rev_bps: 0, adverse_fill_bps: 0, attrition_bps: 0,
            hedgeable_bps: 10_000, beta_bps: 0, liq_penalty_bps: 0, swap_fee_bps: 0 } }
}

pub struct Outcome {
    pub depositor_bps: i64, pub hedges: i64, pub hedged_notional: i64,
    /// Business the pool still supports at the end, in bps of its starting book.
    /// The output that distinguishes "removed the risk" from "removed the
    /// customer", and the reason a cap cannot be scored on P&L alone.
    pub capacity_bps: i64,
}

/// One (cell, arm) run. Returns depositor P&L in bps of deposits.
pub fn run(cell: Cell, arm: Arm) -> Outcome { run_cfg(cell, arm, Cfg::default()) }

pub fn run_cfg(cell: Cell, arm: Arm, cfg: Cfg) -> Outcome {
    let mut a = Actuary::default();
    a.observed_vol_bps = 220;
    a.max_drawdown_bps = 700;
    a.last_price = 1_000_000;
    a.last_price_slot = 0;
    a.total_exposure = DEPOSITS / 2;

    // The path is generated up front so the benchmark arm can look forward. The
    // POLICY arms never read past `t`; only `Clairvoyant` does, which is exactly
    // what makes it a bound rather than a strategy.
    let mut rng: u64 = 0x5EED;
    let path: Vec<i64> = (0..STEPS).map(|t| price_step(cell.price, t, &mut rng)).collect();
    let mut px: i64 = 1_000_000;
    let mut pnl: i64 = 0;              // depositor P&L, absolute
    let mut hedge_notional: i64 = 0;   // signed, in dollars
    let mut persist_acc: i64 = 0;
    let mut hedges: i64 = 0;
    let mut hedged_total: i64 = 0;
    // Starts whole; every refusal permanently removes a slice.
    let mut capacity: i64 = B;

    for t in 0..STEPS {
        // ── price ──────────────────────────────────────────────────────────
        let mut d = path[t as usize];
        // A closed primary market does not stop the price; it stops the HEDGE.
        // The move still lands, it just lands all at once on reopening.
        let tradable = !(cell.clock == Clock::WeekendGapped && t % 7 >= 5);
        if cell.clock == Clock::WeekendGapped && t % 7 == 0 { d += 400; }
        let new_px = (px as i128 * (B as i128 + d as i128) / B as i128) as i64;
        a.update_price(new_px, t * 3_000);
        px = new_px;

        // ── the pool's own book ────────────────────────────────────────────
        let raw_bps = net_path(cell.net, t);
        // The two no-hedge alternatives act on the NET ITSELF rather than
        // laying it off — which is why they cost revenue instead of spread.
        let (net_bps, refused_bps) = match arm {
            // A convex premium damps the crowded side. Modelled as the net that
            // survives a charge rising with imbalance: the marginal borrower on
            // the crowded side stops showing up.
            Arm::PriceTheImbalance => {
                let damp = (raw_bps.abs() * raw_bps.abs() / (B * 2)).min(6_000);
                let kept = raw_bps * (B - damp) / B;
                (kept, raw_bps.abs() - kept.abs())
            }
            Arm::PerTickerCap => {
                let cap = 1_800;
                (raw_bps.clamp(-cap, cap), (raw_bps.abs() - cap).max(0))
            }
            _ => (raw_bps, 0),
        };
        // ⚠️ CORRELATION: a share `beta` of every ticker's exposure is COMMON, so
        //    it does not net away against another ticker. The book's effective
        //    net is therefore larger than the per-ticker net suggests, and the
        //    gap widens precisely in the regimes that produce large moves.
        let common = net_bps.abs() * cfg.beta_bps / B;
        let net_bps = net_bps + if net_bps >= 0 { common } else { -common };
        let net_dollars = DEPOSITS / 2 * net_bps / B;
        a.net_exposure = net_dollars;

        // Swap fees: earned on turnover regardless of arm, so they lift every
        // arm equally and cannot change an ORDERING — recorded for realism, not
        // as a differentiator.
        if cfg.swap_fee_bps > 0 { pnl += DEPOSITS * cfg.swap_fee_bps / B / STEPS; }

        // Liquidations. Borrowers are net long, so a fall past the collar
        // liquidates them — and a fall is when a short pool already profits.
        if cfg.liq_penalty_bps > 0 && net_dollars > 0 {
            // ⚠️ THE THRESHOLD WAS `collar/4` AND NEVER FIRED — the collar runs to
            //    hundreds of bps while a step move is tens, so the branch was
            //    dead and its test passed as `0 >= 0`. A vacuous bound is worse
            //    than none: it reads as evidence. Liquidations trigger on the
            //    CUMULATIVE drawdown against the borrower, which is what a collar
            //    is measured against in the first place.
            let collar = collar_bps(150, &a);
            if a.max_drawdown_bps > collar / 2 && d < 0 {
                pnl += net_dollars * cfg.liq_penalty_bps / B / 10;
            }
        }

        // Flow not written earns nothing. This is the ENTIRE cost of both
        // alternatives, and it is why they are not free lunches.
        if refused_bps > 0 {
            let refused = DEPOSITS / 2 * refused_bps / B;
            let carry_now = rate_bps((a.total_exposure * B / DEPOSITS).clamp(0, B), 150, &a);
            pnl -= refused * carry_now / B / 100;
            // ⚠️ AND THE USER DOES NOT COME BACK. This is the term that was
            // missing: a refusal is not a deferred trade, it is a lost account,
            // and it shrinks every future period's revenue too.
            if cfg.attrition_bps > 0 {
                let lost = refused_bps * cfg.attrition_bps / B;
                capacity = (capacity - lost).max(0);
                a.total_exposure = a.total_exposure * (B - lost).max(0) / B;
            }
        }

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

        // Only the deliverable slice can ever be hedged; the rest is carried by
        // every arm alike.
        let hedgeable = net_dollars * cfg.hedgeable_bps / B;
        let target = hedgeable * cfg.ratio_bps / B;
        let want = match arm {
            Arm::NoFacility => 0,
            Arm::LevelTrigger => if net_bps.abs() > THETA_BPS { target } else { 0 },
            Arm::PersistenceGated =>
                if persist_acc > PERSIST_BUDGET { target } else { hedge_notional },

            // h = ∛(g / (C·K)). `g` is the ticket's own cost in dollars, `C` the
            // net notional, `K` the risk coefficient — and K is NOT invented
            // here: it is the fitted tail the program already computes.
            Arm::DerivedBand => {
                let k = a.expected_shortfall_bps(COLLAR_BREACH_BPS).max(1);
                let g = TICKET * cfg.rt_bps / B;
                let c = net_dollars.abs().max(1);
                // h in bps: ∛(g·B³ / (C·K)) with the scaling carried inside.
                let inner = (g as i128 * (B as i128).pow(3)) / (c as i128 * k as i128 / B as i128).max(1);
                let h = icbrt(inner.min(i64::MAX as i128) as i64).clamp(1, B);
                let drift = (target - hedge_notional).abs();
                // Hysteresis: act only outside the band, and then go to target.
                if c > 0 && drift * B / c > h { target } else { hedge_notional }
            }

            // Perfect foresight over LOOKAHEAD steps: hedge only if the move
            // ahead pays for the round trip on this notional.
            Arm::PriceTheImbalance | Arm::PerTickerCap => 0,   // never buys a share
            Arm::Clairvoyant => {
                let mut fwd = 0i64;
                for k in 0..LOOKAHEAD {
                    let i = t + k;
                    if i < STEPS { fwd += path[i as usize]; }
                }
                // Pool is short the net, so it loses when `fwd` is positive.
                let gain = net_dollars * fwd / B;
                if gain > (target - hedge_notional).abs() * cfg.rt_bps / B { target }
                else { 0 }
            }
        };

        // Revenue the pool CANNOT earn because it has no way to lay this off.
        // Charged against the unhedged remainder, so a full hedge pays none of it
        // and the no-facility arm pays all of it.
        if cfg.forgone_rev_bps > 0 {
            let unlaid = (net_dollars - hedge_notional).abs();
            pnl -= unlaid * cfg.forgone_rev_bps / B / STEPS;
        }

        // ⚠️ A PAUSE DOES NOT STOP US BUYING — it strands what we already hold.
        //    Gating the TRADE on `Issuer::Normal` silently turned every paused
        //    cell into the no-facility arm, so the pause column measured nothing.
        let delta = want - hedge_notional;
        if tradable && delta.abs() >= TICKET {
            // Spread + impact, plus the cost of being a PREDICTABLE buyer.
            pnl -= delta.abs() * (cfg.rt_bps + cfg.adverse_fill_bps) / B;
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
    Outcome { depositor_bps: pnl * B / DEPOSITS, hedges,
              hedged_notional: hedged_total, capacity_bps: capacity }
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
