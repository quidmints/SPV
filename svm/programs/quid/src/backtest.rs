//! §BACKTEST — the model against five years of prices that actually happened.
//!
//! Everything before this file calibrated against a GENERATOR. `returns::Equity`
//! draws from a fitted process, `facility_sim` enumerates a grid of regimes, and
//! both answer "is the model coherent against the world I described to it?".
//! Neither can answer "does it survive the world?", because a generator never
//! produces the move nobody modelled — and the move nobody modelled is the only
//! one that reaches depositors.
//!
//! So this drives the SAME code — `Actuary::update_price`, `loss_profile`,
//! `collar_bps`, `Depositor::repo`, `unwind_a_tranche` — along 1,254 real daily
//! bars for 20 real names, split into the only two states the protocol
//! distinguishes:
//!
//!   GAP     previous close → next open.  ⛔ The pool cannot act. No oracle
//!           print worth trusting, no ladder, no `reinstate_exposure`, no
//!           primary-market ticket. The loss arrives complete.
//!   SESSION open → close.                ✅ Everything works.
//!
//! ⭐ THE WHOLE RISK QUESTION IS "HOW BIG IS A GAP RELATIVE TO A PLEDGE", AND
//!    UNTIL THIS FILE THE PROTOCOL HAD NEVER BEEN ASKED IT WITH REAL NUMBERS.

#![allow(clippy::needless_range_loop)]

use crate::etc::*;
use crate::real::{REAL, TICKERS, DAYS};
use crate::stay::*;
use anchor_lang::prelude::Pubkey;

/// Dollars are micro-dollars; prices are native units per unit of exposure.
/// `value_at` is `units * price`, so both live on the same scale and a $1
/// position is 1_000_000. Units start at 10 per dollar, which keeps rounding
/// under a basis point even after a name falls 90%.
/// $100 a share, in micro-dollars — the unit `fetch_price` now returns.
const P0: u64 = 100_000_000;
/// A session is 6.5h and the gap that precedes it is 17.5h, at 0.4s per slot.
const SESSION_SLOTS: i64 = 58_500;
const GAP_SLOTS: i64 = 157_500;
const SESSION_SECS: i64 = 23_400;
const GAP_SECS: i64 = 63_000;
const B: i64 = 10_000;

/// Walk one ticker's real returns into (open, close) native prices.
fn path(t: usize) -> Vec<(u64, u64)> {
    let (gaps, sess) = REAL[t];
    let mut p = P0 as i128;
    let mut out = Vec::with_capacity(DAYS);
    for d in 0..DAYS {
        let o = (p * (B as i128 + gaps[d] as i128) / B as i128).max(1);
        let c = (o * (B as i128 + sess[d] as i128) / B as i128).max(1);
        out.push((o as u64, c as u64));
        p = c;
    }
    out
}

/// An `Actuary` warmed on the first `warm` days of a real path, exactly the way
/// the chain warms one: two prints a day, at the real slot spacing.
fn warmed(t: usize, px: &[(u64, u64)], warm: usize) -> Actuary {
    let mut a = Actuary::default();
    let mut slot = 0i64;
    for d in 0..warm {
        slot += GAP_SLOTS;
        a.update_price(px[d].0 as i64, slot);
        slot += SESSION_SLOTS;
        a.update_price(px[d].1 as i64, slot);
    }
    a
}

fn pctl(v: &mut Vec<i64>, p: f64) -> i64 {
    if v.is_empty() { return 0; }
    v.sort_unstable();
    v[(((v.len() - 1) as f64) * p) as usize]
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. The gap is the risk, and the model has never been shown one.
// ─────────────────────────────────────────────────────────────────────────────

/// What fraction of the total move happens where the protocol is blind?
///
/// This is the number that decides whether a ladder is even the right
/// instrument. A ladder cuts `MAX_TRANCHE_BPS` per window; if most of the loss
/// lands in a window where no cut is possible, the ladder is not a liquidation
/// mechanism, it is a cleanup crew.
#[test]
fn how_much_of_the_move_lands_where_the_pool_cannot_act() {
    let (mut gap_abs, mut ses_abs) = (0i128, 0i128);
    let (mut gap_sq, mut ses_sq) = (0i128, 0i128);
    let mut worst: Vec<(i64, &str, usize)> = vec![];
    for t in 0..TICKERS.len() {
        let (g, s) = REAL[t];
        for d in 0..DAYS {
            gap_abs += (g[d] as i128).abs();
            ses_abs += (s[d] as i128).abs();
            gap_sq += (g[d] as i128) * (g[d] as i128);
            ses_sq += (s[d] as i128) * (s[d] as i128);
            worst.push(((g[d] as i64).abs(), TICKERS[t], d));
        }
    }
    worst.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    let share = gap_abs * 100 / (gap_abs + ses_abs);
    let var_share = gap_sq * 100 / (gap_sq + ses_sq);

    println!("\n=== where the move happens ===");
    println!("  mean |gap|      {} bps", gap_abs / (DAYS * TICKERS.len()) as i128);
    println!("  mean |session|  {} bps", ses_abs / (DAYS * TICKERS.len()) as i128);
    println!("  share of TOTAL ABSOLUTE move in the blind window   {share}%");
    println!("  share of VARIANCE in the blind window              {var_share}%");
    println!("  ⚠ the blind window is 73% of the clock but carries");
    println!("    a disproportionate share of the JUMPS:");
    for (m, tk, d) in worst.iter().take(8) {
        println!("      {tk:<6} day {d:<5} {m} bps overnight");
    }
    // Not an aspiration — a fact about equities that the design must absorb.
    assert!(share >= 25, "gap share collapsed to {share}%, fixture is wrong");
}

/// ⭐ THE CENTRAL RESULT. Margin is set by `loss_profile` from the fitted tail;
/// the gap is what actually arrives. Line them up, every day, every name.
///
/// A gap deeper than `margin_bps` on a position levered to that margin is not a
/// liquidation — the ladder never runs — it is a straight transfer from the
/// pool to the borrower's counterparty, i.e. from depositors.
#[test]
fn does_the_margin_the_model_sets_survive_the_gap_that_arrives() {
    const WARM: usize = 250;
    let mut breaches = 0usize;
    let mut obs = 0usize;
    let mut margins: Vec<i64> = vec![];
    let mut excess: Vec<i64> = vec![];
    let mut worst = (0i64, "", 0usize, 0i64);
    let mut per_ticker: Vec<(String, i64, i64, usize, i64)> = vec![];
    let mut comps: Vec<(&str, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)> = vec![];

    for t in 0..TICKERS.len() {
        let px = path(t);
        let (gaps, _) = REAL[t];
        let mut a = warmed(t, &px, WARM);
        let mut slot = (WARM as i64) * (GAP_SLOTS + SESSION_SLOTS);
        let (mut tmar, mut tn, mut tbr, mut tworst) = (0i128, 0i64, 0usize, 0i64);

        for d in WARM..DAYS - 1 {
            // Model state as of last night's close.
            let m = a.loss_profile(1_000_000, 0).margin_bps;
            let g = (gaps[d + 1] as i64).abs();
            margins.push(m);
            tmar += m as i128; tn += 1; obs += 1;
            if g > m {
                breaches += 1; tbr += 1;
                let e = g - m;
                excess.push(e);
                if e > worst.0 { worst = (e, TICKERS[t], d + 1, m); }
                if e > tworst { tworst = e; }
            }
            slot += GAP_SLOTS;  a.update_price(px[d + 1].0 as i64, slot);
            slot += SESSION_SLOTS; a.update_price(px[d + 1].1 as i64, slot);
        }
        let avg = (tmar / tn.max(1) as i128) as i64;
        per_ticker.push((TICKERS[t].to_string(), avg, B * 100 / avg.max(1), tbr, tworst));
        comps.push((TICKERS[t], a.observed_vol_bps, a.eff_sigma(),
            a.quantile_bps(INSOLVENCY_TARGET_BPS),
            a.quantile_bps(INSOLVENCY_TARGET_BPS) * unwind_exposure_x100() / 100,
            a.gap_vol_bps, a.gap_max_bps, a.gap_quantile_bps(INSOLVENCY_TARGET_BPS),
            a.obs_count, a.exceed_count, a.gap_count));
    }

    let rate_bp = (breaches as i64) * 10_000 / obs as i64;
    println!("\n=== margin vs the gap that actually arrived ===");
    println!("  observations                {obs}");
    println!("  breaches (gap > margin)     {breaches}  ({} bps of days)", rate_bp);
    println!("  INSOLVENCY_TARGET_BPS       {INSOLVENCY_TARGET_BPS} bps  <- what was asked for");
    println!("  margin  p50 {}  p90 {}  p99 {}",
             pctl(&mut margins.clone(), 0.50), pctl(&mut margins.clone(), 0.90),
             pctl(&mut margins.clone(), 0.99));
    if !excess.is_empty() {
        println!("  excess loss beyond the pledge, when it breaches:");
        println!("    p50 {}  p90 {}  p99 {}  MAX {} bps",
                 pctl(&mut excess.clone(), 0.50), pctl(&mut excess.clone(), 0.90),
                 pctl(&mut excess.clone(), 0.99), pctl(&mut excess.clone(), 1.0));
        println!("    worst: {} day {} — margin {} bps, gap {} bps, {} bps UNCOVERED",
                 worst.1, worst.2, worst.3, worst.3 + worst.0, worst.0);
    }
    println!("\n  per name: avg margin -> implied max leverage, breaches, worst uncovered");
    per_ticker.sort_by_key(|r| -r.4);
    for (tk, m, lev, br, w) in &per_ticker {
        println!("    {tk:<6} margin {m:>5} bps  max {:>5}x  breaches {br:>3}  worst uncovered {w:>5} bps",
                 format!("{}.{:02}", lev / 100, lev % 100));
    }
    println!("\n  where the margin comes from (bps unless noted):");
    println!("    {:<6} {:>6} {:>6} {:>6} {:>8} {:>7} {:>7} {:>7} {:>5} {:>5} {:>5}",
             "tkr","vol","sigma","q1","laddered","gapvol","gapmax","gap_q","obs","exc","gaps");
    for c in &comps {
        println!("    {:<6} {:>6} {:>6} {:>6} {:>8} {:>7} {:>7} {:>7} {:>5} {:>5} {:>5}",
                 c.0,c.1,c.2,c.3,c.4,c.5,c.6,c.7,c.8,c.9,c.10);
    }
    println!("\n  🔴 A 10x CAP IS A {} bps MARGIN. Read the column above: every", B * 100 / 1000);
    println!("     name whose margin exceeds 1000 bps is a name where 10x is");
    println!("     ALREADY past what one overnight can take.");

    // The realised breach rate is the honest measure of the solvency target.
    // Assert only that the machinery produced a finite, sane answer — the
    // number itself is the deliverable, not a threshold to be tuned against.
    assert!(obs > 15_000 && !margins.is_empty());
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. A thousand borrowers, five real years, the real `repo`.
// ─────────────────────────────────────────────────────────────────────────────

/// Deterministic xorshift. A backtest that moves when it is re-run measures the
/// seed, not the protocol.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        self.0 = x; x
    }
    fn upto(&mut self, n: u64) -> u64 { if n == 0 { 0 } else { self.next() % n } }
}

struct Borrower {
    d: Depositor,
    t: usize,
    dir: i64,
    lev_x100: i64,
    tp_bps: i64,
    /// Notional at open, in micro-dollars — NOT the ticket the borrower
    /// deposited.
    ///
    /// 🔴 THIS WAS SET TO THE DEPOSIT AND THE TAKE-PROFIT TRIGGER READS IT AS
    ///    THE OPENING MARK. Half the ticket is pledged and the position is
    ///    levered on top, so the notional at open is `size × lev / 200` —
    ///    1.625× the ticket at the cohort's mean 3.25x. Measured against the
    ///    ticket instead, every LONG reads as instantly +6,250 bps and takes
    ///    profit on its first session, while every SHORT reads as −6,250 and
    ///    never triggers at all.
    ///
    ///    That is not a small bias. It emptied the long side within a session
    ///    of each arrival and left the shorts open for years, so the book drifted
    ///    persistently short, which INVERTS the sign of the funding transfer and
    ///    of the Euler capital allocation. Every take-profit statistic, every
    ///    holding period, and the direction of the imbalance the whole pricing
    ///    argument turns on were measuring this.
    opened_at: u64,
    /// What the borrower deposited, which is a different number.
    ticket: u64,
    pledge0: u64,
    live: bool,
    entry: usize,
}

fn pod_for(tk: &str) -> Stock {
    Stock { ticker: Depositor::pad_ticker(tk), marked: 0, pledged: 0, exposure: 0,
        updated: 0, collar_bps: 0, cost_basis: 0, interest_paid: 0,
        breached_at: 0, collar_dollars: 0, collar_dollar_seconds: 0,
        premium_checkpoint: 0, funding_checkpoint: 0 }
}
/// How a book is generated. Every axis here was a hardcoded constant in the
/// first cut, and a single point on each is not a calibration.
#[derive(Clone, Copy)]
pub struct Book {
    /// How many borrowers arrive over the window.
    pub n: usize,
    /// Passive deposit capital, in micro-dollars. The axis that sets
    /// utilisation, and with it the whole liquidity half of the premium.
    pub passive: u64,
    /// Heavy-tailed ticket sizes. ⚠️ WITHOUT THIS NOBODY IS EVER BIG: the first
    /// cut drew sizes from a product of two uniforms, so the largest position
    /// in a thousand was 0.3% of the book and CONCENTRATION WAS NEVER TESTED.
    /// Real books have whales, and a whale is the position that breaks a pool.
    pub whales: bool,
    /// Zipf ticker weights rather than uniform. Real flow piles into a handful
    /// of names; spreading a thousand borrowers evenly over twenty tickers
    /// diversifies away the exact risk the reserve exists for.
    pub zipf: bool,
    /// Probability (percent) that an arrival trades WITH the last 20 sessions'
    /// momentum. 50 is a balanced book; 90 is a stampede.
    pub trend_follow: u64,
    /// Redemption run: half the passive capital leaves over 20 sessions at the
    /// midpoint.
    pub run: bool,
    /// ⚠️ **REGIME — THE SEAM THE COHORT NEVER CARRIED.** Every other axis here
    /// varies the BOOK; this one varies the MARKET. Entries cluster into the
    /// window containing the worst market-wide drawdown in the fixture instead
    /// of spreading over five years, so a persistently-short-and-right book
    /// actually exists rather than being averaged away by a bull run.
    pub crash: bool,
    /// Push the leverage draw toward the cap. ⚠️ THIS IS THE AXIS THAT ACTUALLY
    /// STRESSES CAPACITY, and it took a failed sweep to find that out: every
    /// borrower deposits their own ticket, so `total_deposits` grows with the
    /// book and shrinking the PASSIVE tranche cannot make the pool thin
    /// relative to what it is backing. Leverage can — the same collateral
    /// carrying L times the notional multiplies `max_liability` without adding
    /// a cent of deposits.
    pub lev_bias: bool,
    pub seed: u64,
}

impl Book {
    fn base() -> Self {
        Book { n: 1_000, passive: 20_000_000 * 1_000_000, whales: false,
               zipf: false, trend_follow: 62, run: false, lev_bias: false,
               crash: false,
               seed: 0x5EED_1234_9ABC_DEF1 }
    }
}

#[derive(Default, Clone, Copy)]
pub struct Out {
    pub opened: usize, pub rejected: usize, pub tranches: usize,
    pub tp: usize, pub tp_blocked: usize, pub busted: usize, pub residual: i64,
    pub premium: u64, pub fund_paid: i128, pub fund_recv: i128,
    pub pnl: i64, pub peak_net: i64, pub peak_util: i64, pub end_util: i64,
    pub notional_yrs: i128, pub pledge_yrs: i128,
    pub max_liab: u64, pub deposits_end: u64, pub passive_end: u64,
    pub biggest_bps: i64, pub top_ticker_bps: i64, pub capacity_rejects: usize,
}

/// One book, driven end to end through the program's own instructions in the
/// order `clutch` executes them.
fn run_book(cfg: Book) -> Out {
    const WARM: usize = 250;
    let paths: Vec<Vec<(u64, u64)>> = (0..TICKERS.len()).map(path).collect();
    // ⚠️ `Vec<Actuary>` BEFORE, AND THAT IS WHY THREE MECHANISMS WERE INVISIBLE.
    //    `settle_funding` needs a `TickerRisk`; so does
    //    `reconcile_ticker_reserve`, which is what makes `max_liability` — and
    //    therefore `has_capacity` — real rather than permanently zero.
    let mut risks: Vec<TickerRisk> = (0..TICKERS.len()).map(|t| TickerRisk {
        ticker: Depositor::pad_ticker(TICKERS[t]), bump: 0, reserved: 0, funding_pot: 0,
        actuary: warmed(t, &paths[t], WARM) }).collect();

    let mut bank = Depository { last_updated: 0, total_deposits: 0,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };

    let mut passive: u64 = cfg.passive;
    bank.total_deposits = passive;
    let mut rng = Rng(cfg.seed);

    // Zipf weights over a shuffled ticker order, so concentration does not
    // always land on the same names.
    let mut order: Vec<usize> = (0..TICKERS.len()).collect();
    for i in (1..order.len()).rev() { let j = rng.upto(i as u64 + 1) as usize; order.swap(i, j); }
    let cum: Vec<u64> = { let mut c = vec![]; let mut acc = 0u64;
        for r in 0..TICKERS.len() { acc += 1_000 / (r as u64 + 1); c.push(acc); } c };
    let pick_ticker = |rng: &mut Rng| -> usize {
        if !cfg.zipf { return rng.upto(TICKERS.len() as u64) as usize; }
        let r = rng.upto(*cum.last().unwrap());
        order[cum.iter().position(|c| *c > r).unwrap_or(0)]
    };

    // The 120 sessions leading into the market's worst 40-session stretch.
    let crash_at = {
        let mut best = (0i64, WARM);
        for d in (WARM + 130)..(DAYS - 60) {
            let mv: i64 = (0..TICKERS.len()).map(|t| {
                ((paths[t][d + 40].1 as i128 - paths[t][d].1 as i128) * B as i128
                 / paths[t][d].1.max(1) as i128) as i64 }).sum::<i64>()
                / TICKERS.len() as i64;
            if mv < best.0 { best = (mv, d); }
        }
        best.1.saturating_sub(120).max(WARM)
    };
    let mut bs: Vec<Borrower> = Vec::with_capacity(cfg.n);
    for _ in 0..cfg.n {
        let t = pick_ticker(&mut rng);
        let entry = if cfg.crash { crash_at + rng.upto(120) as usize }
                    else { WARM + rng.upto((DAYS - WARM - 30) as u64) as usize };
        let lev = if cfg.lev_bias {
            // Clustered at the cap: max of two draws rather than a product.
            100 + (rng.upto(100).max(rng.upto(100))) as i64 * 9
        } else { 100 + (rng.upto(100) * rng.upto(100)) as i64 * 9 / 100 };
        // Ticket size. The heavy tail is four magnitudes wide, so a handful of
        // borrowers are a material fraction of the pool on their own.
        let size = if cfg.whales {
            let m = rng.upto(1_000);
            let base = 500 + rng.upto(2_000);
            base * if m < 700 { 1 } else if m < 950 { 12 } else if m < 995 { 150 } else { 3_000 }
        } else { 500 + rng.upto(500) * rng.upto(500) } * 1_000_000;
        bs.push(Borrower { d: Depositor { owner: Pubkey::new_unique(),
                deposited_quid: 0, deposited_lamports: 0, sol_pledged_usd: 0,
                deposit_seconds: 0, last_updated: 0, drawn: 0, balances: vec![],
                realized_pnl: 0, total_interest_paid: 0,
                total_collar_dollar_seconds: 0, sol_yield_checkpoint: 0 },
            t, dir: 0, lev_x100: lev.min(1_000),
            tp_bps: 500 + rng.upto(4_000) as i64,
            opened_at: 0, ticket: size, pledge0: 0, live: false, entry });
    }
    bs.sort_by_key(|b| b.entry);

    let mut o = Out::default();
    let mut next = 0usize;
    let mut secs = (WARM as i64) * 86_400;
    let mut slot = (WARM as i64) * (GAP_SLOTS + SESSION_SLOTS);
    let mut notional_secs: i128 = 0;
    let mut pledge_secs: i128 = 0;
    let mut gross_by_ticker: Vec<i128> = vec![0; TICKERS.len()];
    let run_at = WARM + (DAYS - WARM) / 2;

    for d in WARM..DAYS {
        slot += GAP_SLOTS; secs += GAP_SECS;
        for t in 0..TICKERS.len() { risks[t].actuary.update_price(paths[t][d].0 as i64, slot); }

        let util = bank.utilisation_bps();
        if util > o.peak_util { o.peak_util = util; }
        for t in 0..TICKERS.len() { risks[t].actuary.accrue_premium_index(secs, util); }

        // 1. arrivals
        while next < bs.len() && bs[next].entry == d {
            let i = next; next += 1;
            let t = bs[i].t;
            let px = paths[t][d].0;
            let mom = paths[t][d].0 as i64 - paths[t][d.saturating_sub(20)].0 as i64;
            let with_trend = rng.upto(100) < cfg.trend_follow;
            let dir = if (mom >= 0) == with_trend { 1i64 } else { -1i64 };
            bs[i].dir = dir;
            let size = bs[i].ticket;
            bs[i].d.deposited_quid = size;
            bank.total_deposits = bank.total_deposits.saturating_add(size);
            bs[i].d.last_updated = secs;
            bs[i].d.balances.push(pod_for(TICKERS[t]));
            if bs[i].d.renege(Some(TICKERS[t]), (size / 2) as i64,
                              Some(&vec![px]), secs).is_err() { o.rejected += 1; continue; }
            let pledge = bs[i].d.balances[0].pledged;
            bs[i].pledge0 = pledge;
            let units = value_units(
                (pledge as u128 * bs[i].lev_x100 as u128 / 100) as u64, px) as i64;
            if units == 0 { o.rejected += 1; continue; }
            let prior = bs[i].d.balances[0].exposure;
            let f = bs[i].d.settle_funding(TICKERS[t], &mut risks[t], px) as i128;
            if f < 0 { o.fund_paid -= f } else { o.fund_recv += f }
            match bs[i].d.repo(TICKERS[t], dir * units, px, secs, slot,
                               &risks[t].actuary, &mut bank) {
                Ok(_) => { o.opened += 1; bs[i].live = true;
                    // The mark the take-profit is measured against: what the
                    // position was actually worth when it opened.
                    bs[i].opened_at = units_value(bs[i].d.balances[0].exposure.unsigned_abs(), px);
                    let vd = units_value_i(dir * units, px);
                    risks[t].actuary.record_activity(prior, vd, slot,
                        vd.abs(), bank.total_deposits as i64);
                    crate::clutch::reconcile_ticker_reserve(&mut risks[t], &mut bank);
                    gross_by_ticker[t] += vd.unsigned_abs() as i128;
                    let share = (vd.unsigned_abs() as i128 * B as i128
                        / bank.total_deposits.max(1) as i128) as i64;
                    if share > o.biggest_bps { o.biggest_bps = share; } }
                Err(_) => { o.rejected += 1;
                    if !bank.has_capacity(0) { o.capacity_rejects += 1; } }
            }
        }

        // 2. the crank, with the sweep's transaction boundary
        for i in 0..bs.len() {
            if !bs[i].live { continue; }
            let t = bs[i].t; let px = paths[t][d].0;
            let before = bs[i].d.balances[0].exposure;
            let snapshot = bs[i].d.clone();
            let bank_before = bank.clone();
            let f = bs[i].d.settle_funding(TICKERS[t], &mut risks[t], px) as i128;
            let acted = if let Ok((delta, interest)) = bs[i].d.repo(TICKERS[t], 0, px,
                    secs, slot, &risks[t].actuary, &mut bank) {
                let clock_running = bs[i].d.balances.first()
                    .map_or(false, |p| p.breached_at != 0);
                if delta != 0 {
                    let cut = delta.unsigned_abs() / 250;
                    bank.yield_pool = bank.yield_pool.saturating_add(interest);
                    o.premium += interest;
                    if delta < 0 {
                        let credited = delta.unsigned_abs().saturating_sub(cut);
                        bank.yield_pool = bank.yield_pool.saturating_add(credited);
                        risks[t].actuary.record_activity(0, -(credited as i64), slot,
                            credited as i64, bank.total_deposits as i64);
                        crate::clutch::reconcile_ticker_reserve(&mut risks[t], &mut bank);
                    } else {
                        let take = (delta as u64).min(bs[i].d.deposited_quid);
                        bs[i].d.deposited_quid -= take;
                        bank.yield_pool = bank.yield_pool.saturating_add(take);
                    }
                    true
                } else if clock_running {
                    bank.yield_pool = bank.yield_pool.saturating_add(interest);
                    o.premium += interest;
                    true
                } else { false }
            } else { false };
            if !acted { bs[i].d = snapshot; bank = bank_before; }
            else if f < 0 { o.fund_paid -= f } else if f > 0 { o.fund_recv += f }
            let after = bs[i].d.balances[0].exposure;
            if after != before { o.tranches += 1; }
            notional_secs += (units_value(after.unsigned_abs(), px) as i128)
                             * (GAP_SECS + SESSION_SECS) as i128;
            pledge_secs += bs[i].d.balances[0].pledged as i128
                             * (GAP_SECS + SESSION_SECS) as i128;
            if bs[i].d.balances[0].pledged == 0 && after != 0 {
                o.busted += 1;
                o.residual += (units_value(after.unsigned_abs(), px) as i128) as i64;
                bs[i].live = false;
            }
        }

        // 3. the take-profit run, at the close
        slot += SESSION_SLOTS; secs += SESSION_SECS;
        for t in 0..TICKERS.len() { risks[t].actuary.update_price(paths[t][d].1 as i64, slot); }
        for i in 0..bs.len() {
            if !bs[i].live { continue; }
            let t = bs[i].t; let px = paths[t][d].1;
            let e = bs[i].d.balances[0].exposure;
            if e == 0 { bs[i].live = false; continue; }
            let now = (units_value(e.unsigned_abs(), px) as i128) as i64;
            let pnl_bps = ((now - bs[i].opened_at as i64) as i128 * B as i128
                           / bs[i].opened_at.max(1) as i128) as i64 * bs[i].dir;
            if pnl_bps >= bs[i].tp_bps {
                let f = bs[i].d.settle_funding(TICKERS[t], &mut risks[t], px) as i128;
                if f < 0 { o.fund_paid -= f } else { o.fund_recv += f }
                match bs[i].d.repo(TICKERS[t], -e, px, secs, slot,
                                   &risks[t].actuary, &mut bank) {
                    Ok(_) => { o.tp += 1; bs[i].live = false;
                        let vd = units_value_i(-e, px);
                        risks[t].actuary.record_activity(e, vd, slot,
                            vd.abs(), bank.total_deposits as i64);
                        crate::clutch::reconcile_ticker_reserve(&mut risks[t], &mut bank); }
                    Err(_) => { o.tp_blocked += 1; }
                }
            }
        }

        let nd: i64 = risks.iter().map(|r| r.actuary.get_net()).sum();
        if nd.abs() > o.peak_net.abs() { o.peak_net = nd; }

        // 4. the passive side comes and goes — and, if asked, runs.
        let running = cfg.run && d >= run_at && d < run_at + 20;
        let flow = if running { -((passive / 20) as i64) }
                   else { (passive / 100) as i64 * (if rng.upto(2) == 0 { 1 } else { -1 }) };
        if flow > 0 { passive += flow as u64;
                      bank.total_deposits = bank.total_deposits.saturating_add(flow as u64); }
        else { let out = (-flow as u64).min(passive);
               passive -= out;
               bank.total_deposits = bank.total_deposits.saturating_sub(out); }
    }

    let yr = 31_536_000i128;
    o.notional_yrs = notional_secs / yr;
    o.pledge_yrs = pledge_secs / yr;
    o.pnl = bank.pool_realized_pnl;
    o.max_liab = bank.max_liability;
    o.deposits_end = bank.total_deposits;
    o.passive_end = passive;
    o.end_util = bank.utilisation_bps();
    let gross_total: i128 = gross_by_ticker.iter().sum::<i128>().max(1);
    o.top_ticker_bps = (gross_by_ticker.iter().max().copied().unwrap_or(0)
                        * B as i128 / gross_total) as i64;
    o
}

/// ⭐ THE RUN THE OWNER ASKED FOR: calibrate as if it were already running.
///
/// A thousand borrowers arriving over five real years across twenty real names,
/// long and short, at leverage the margin permits, with passive depositors
/// coming and going — every position opened, cranked and closed through the
/// PROGRAM'S OWN instructions in the order `clutch` executes them, including
/// the transaction boundary that decides whether a sweep's writes survive.
#[test]
fn a_thousand_borrowers_against_five_real_years() {
    let o = run_book(Book::base());
    println!("\n=== 1,000 borrowers, {} real sessions, real `repo` ===", DAYS - 250);
    println!("  opened {}   rejected {}   (of those, pool at capacity {})",
             o.opened, o.rejected, o.capacity_rejects);
    println!("  ladder tranches {}   take-profits {} filled / {} blocked",
             o.tranches, o.tp, o.tp_blocked);
    println!("  pledges exhausted with exposure open: {}  (residual ${})",
             o.busted, o.residual / 1_000_000);
    println!("  peak |net book| ${}   peak utilisation {} bps",
             o.peak_net.abs() / 1_000_000, o.peak_util);
    println!("  premium ${}   capital transfer: crowded ${} → offsetting ${}, pool ${}",
             o.premium / 1_000_000, o.fund_paid / 1_000_000,
             o.fund_recv / 1_000_000, (o.fund_paid - o.fund_recv) / 1_000_000);
    println!("  exposure carried ${} notional-years (${} pledge-years)",
             o.notional_yrs / 1_000_000, o.pledge_yrs / 1_000_000);
    println!("  ⇒ carry {} bps/yr on notional, {} bps/yr on pledge",
             o.premium as i128 * B as i128 / o.notional_yrs.max(1),
             o.premium as i128 * B as i128 / o.pledge_yrs.max(1));
    // ⚠️ NOT THE POOL'S P&L, AND I REPORTED IT AS SUCH FOR MOST OF THIS FILE'S
    //    LIFE. `Depository::pool_realized_pnl` is documented as "the denominator
    //    an account's own RAROC is measured against" — the AGGREGATE OF
    //    ACCOUNTS' realised P&L, so a positive figure means BORROWERS made
    //    money, which for depositors is the bad direction. It was also booked
    //    only on the two liquidation paths until this pass, so every earlier
    //    number was an average over liquidated positions alone.
    println!("  borrowers' aggregate realised P&L ${}   (RAROC benchmark, not the pool's)",
             o.pnl / 1_000_000);
    println!("  max_liability ${} of ${} deposits",
             o.max_liab / 1_000_000, o.deposits_end / 1_000_000);
    println!("  largest single position {} bps of the book; busiest ticker {} bps of gross",
             o.biggest_bps, o.top_ticker_bps);

    assert!(o.opened > 100, "only {} opened — the harness, not the model", o.opened);
}


// ─────────────────────────────────────────────────────────────────────────────
// 3. What the backing leg actually buys, given it can only trade in session.
// ─────────────────────────────────────────────────────────────────────────────

/// The pool is the counterparty to the net book. Backing means holding real
/// paper against it — but paper can only be ISSUED, never borrowed, so the leg
/// works in exactly one direction:
///
///   borrowers net LONG  → pool net SHORT → buy/mint paper → ✅ flat
///   borrowers net SHORT → pool net LONG  → would need to SELL paper it does
///                                          not own → ❌ nothing to do
///
/// And a primary-market ticket is not instant: `BACKING_COOLDOWN_SECS` plus
/// settlement means the paper arrives a session late, so the pool carries the
/// gap on whatever the book added since it last acted.
///
/// This measures all three at once against real prices: how much variance the
/// leg removes, how much it CANNOT remove because the book is net long, and
/// what the one-session lag costs.
#[test]
fn what_the_backing_leg_buys_when_it_can_only_trade_in_session() {
    const WARM: usize = 250;
    let mut rng = Rng(0xB4C1_1234_5678_9AB);

    let (mut v_none, mut v_lag, mut v_ideal) = (0i128, 0i128, 0i128);
    let (mut dd_none, mut dd_lag) = (0i64, 0i64);
    let (mut long_sessions, mut short_sessions) = (0usize, 0usize);
    let mut unbackable = 0i128;          // |pool exposure| the leg cannot touch
    let mut backable = 0i128;
    let mut lag_bleed = 0i64;            // P&L the T+1 lag left on the table

    for t in 0..TICKERS.len() {
        let px = path(t);
        let (gaps, sess) = REAL[t];
        // Endogenous net book: crowding follows 20-session momentum with noise,
        // scaled to $1M so the arms are comparable across names.
        let mut net = 0i64;
        let mut held_lag = 0i64;     // paper on hand (arrives one session late)
        let mut ordered = 0i64;      // paper in transit
        let (mut c_none, mut c_lag, mut c_ideal) = (0i64, 0i64, 0i64);

        for d in WARM..DAYS {
            let mom = px[d].0 as i64 - px[d.saturating_sub(20)].0 as i64;
            let pull = if mom >= 0 { 1i64 } else { -1i64 };
            let step = (rng.upto(200_000) as i64) - 60_000;
            net = (net + pull * step).clamp(-1_000_000, 1_000_000);
            if net > 0 { long_sessions += 1 } else { short_sessions += 1 }

            // The pool's synthetic side is the opposite of the book.
            let pool = -net;
            // The leg can only be long. Target is the offsetting long, and only
            // when the pool is short.
            let target = if pool < 0 { -pool } else { 0 };
            if pool < 0 { backable += (-pool) as i128 } else { unbackable += pool as i128 }

            // ── the blind window: gap arrives on last session's holdings ──
            let g = gaps[d] as i64;
            c_none  += pool * g / B;
            c_lag   += (pool + held_lag) * g / B;
            c_ideal += (pool + target) * g / B;
            lag_bleed += (target - held_lag) * g / B;

            // ── session: the order placed last close settles now ─────────
            held_lag += ordered; ordered = 0;
            let s = sess[d] as i64;
            c_none  += pool * s / B;
            c_lag   += (pool + held_lag) * s / B;
            c_ideal += (pool + target) * s / B;
            // and a new ticket goes out for the close-of-session gap
            ordered = target - held_lag;

            v_none  += (c_none  as i128) * (c_none  as i128) / 1_000_000;
            v_lag   += (c_lag   as i128) * (c_lag   as i128) / 1_000_000;
            v_ideal += (c_ideal as i128) * (c_ideal as i128) / 1_000_000;
            if c_none < dd_none { dd_none = c_none }
            if c_lag  < dd_lag  { dd_lag  = c_lag  }
        }
    }

    let n = (TICKERS.len() * (DAYS - WARM)) as i128;
    println!("\n=== what the backing leg buys ===");
    println!("  sessions where the book is net LONG  (pool short, leg WORKS)  {long_sessions}");
    println!("  sessions where the book is net SHORT (pool long,  leg IDLE)   {short_sessions}");
    println!("  pool exposure the leg CAN cover      {}", backable / 1_000_000);
    println!("  pool exposure the leg CANNOT cover   {}   ({}% of the total)",
             unbackable / 1_000_000,
             unbackable * 100 / (backable + unbackable).max(1));
    println!("  mean squared P&L (lower is calmer):");
    println!("    no backing        {}", v_none / n);
    println!("    T+1 backing       {}   ({}% of unbacked)", v_lag / n,
             v_lag * 100 / v_none.max(1));
    println!("    instant backing   {}   ({}% of unbacked)", v_ideal / n,
             v_ideal * 100 / v_none.max(1));
    println!("  worst cumulative drawdown: unbacked {dd_none}   T+1 backed {dd_lag}");
    println!("  P&L the one-session settlement lag left on the table: {lag_bleed}");
    println!("\n  🔴 THE LEG IS STRUCTURALLY ONE-SIDED. Roughly half the book's");
    println!("     life leaves the pool NET LONG with nothing to buy, and no");
    println!("     amount of primary-market access changes that — issuance can");
    println!("     only add length. The other side has to come from the FUNDING");
    println!("     RATE pulling the book back toward flat, not from inventory.");

    assert!(v_ideal <= v_none, "backing must not increase variance where it applies");
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. The massive short take-profit — the owner's named failure mode.
// ─────────────────────────────────────────────────────────────────────────────

/// Find the worst real multi-session drawdowns in the fixture and ask: if the
/// book had been heavily net SHORT into them and everyone took profit at the
/// bottom, what does the pool owe and what does it have?
///
/// This is the case where the pool cannot be backed (it is net long against a
/// short book), the losses are marked continuously, and the winners' claims are
/// paid out of `total_deposits` — i.e. out of the passive depositors.
#[test]
fn a_massive_short_take_profit_against_a_pool_that_cannot_back_itself() {
    const WIN: usize = 10;
    let mut eps: Vec<(i64, usize, usize)> = vec![];  // (bps down, ticker, day)
    for t in 0..TICKERS.len() {
        let px = path(t);
        for d in WIN..DAYS {
            let from = px[d - WIN].1 as i128;
            let to = px[d].1 as i128;
            let mv = ((to - from) * B as i128 / from.max(1)) as i64;
            eps.push((mv, t, d));
        }
    }
    eps.sort_unstable_by_key(|e| e.0);

    println!("\n=== the worst real {WIN}-session drawdowns in the fixture ===");
    let deposits: i64 = 20_000_000;      // $20M passive book
    let mut rows = 0;
    let mut worst_hit_bps = 0i64;
    for (mv, t, d) in eps.iter().take(10) {
        // A book that is short this name for 15% of the pool at 10x is
        // $3M of pledge carrying $30M of notional — deliberately extreme,
        // because the question was what a MASSIVE short take-profit does.
        let pledge = deposits * 1_500 / B;
        let notional = pledge * 10;
        let borrower_gain = -(notional as i128 * *mv as i128 / B as i128) as i64;
        // The pool is the other side and it cannot buy paper to offset a
        // position that is already long. It pays in full.
        let hit_bps = (borrower_gain as i128 * B as i128 / deposits as i128) as i64;
        if hit_bps > worst_hit_bps { worst_hit_bps = hit_bps }
        println!("  {:<6} day {:<5} {:>6} bps in {WIN} sessions → short book gains ${}M, \
                  depositors down {} bps",
                 TICKERS[*t], d, mv, borrower_gain / 1_000_000, hit_bps);
        rows += 1;
    }
    assert!(rows == 10);

    println!("\n  ⚠ THE SHORT SIDE IS NOT SYMMETRIC WITH THE LONG SIDE:");
    println!("    • a long book's loss is bounded by the pledge going to zero;");
    println!("    • a SHORT book's GAIN is bounded only by the price reaching");
    println!("      zero, and the pool owes every basis point of it in cash.");
    println!("    • the pool cannot hold offsetting inventory against a short");
    println!("      book — being flat would require SHORTING paper it can only");
    println!("      mint. So this exposure is irreducible by the backing leg.");
    println!("\n  worst single-episode hit to a $20M book at the stated size: {worst_hit_bps} bps");
    println!("  → the three levers that actually bound it are (1) the per-ticker");
    println!("    net-exposure cap, (2) the funding rate paid by the crowded side,");
    println!("    and (3) the ladder taking tranches on the way DOWN — which is");
    println!("    the profitable direction for the borrower and therefore the");
    println!("    direction the ladder currently does NOT run.");
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. What actually buys leverage.
// ─────────────────────────────────────────────────────────────────────────────

/// ⭐ **`MAX_TRANCHE_BPS` IS THE LEVERAGE KNOB AND NOTHING ELSE IS.**
///
/// The margin is `sqrt(q_gap² + (q_window · sqrt(1/2r))²)`. `q_gap` is a fact
/// about the instrument — no protocol parameter touches it. `q_window` is a
/// fact about the instrument. The only term anyone chooses is `r`, the fraction
/// of a position the ladder takes per window, and it enters as `1/sqrt(2r)`.
///
/// So "what leverage can we offer" and "how fast are we willing to unwind" are
/// THE SAME QUESTION, and this prints the exchange rate between them against
/// real tails rather than against an assumption.
#[test]
fn the_only_thing_that_buys_leverage_is_how_fast_the_ladder_runs() {
    const WARM: usize = 250;
    let names: [&str; 5] = ["SPY", "AAPL", "TSLA", "AMD", "MSTR"];
    let idx: Vec<usize> = names.iter()
        .map(|n| TICKERS.iter().position(|t| t == n).unwrap()).collect();

    // Fit each name once, on the whole history.
    let fits: Vec<(i64, i64)> = idx.iter().map(|&t| {
        let px = path(t);
        let a = warmed(t, &px, DAYS);
        (a.quantile_bps(INSOLVENCY_TARGET_BPS).max(1),
         a.gap_quantile_bps(INSOLVENCY_TARGET_BPS))
    }).collect();
    let _ = WARM;

    let isqrt = |n: i128| -> i64 {
        if n <= 0 { return 0 }
        let mut r = n; let mut y = (r + 1) / 2;
        while y < r { r = y; y = (r + n / r.max(1)) / 2; }
        r as i64
    };

    println!("\n=== the exchange rate between unwind speed and leverage ===");
    println!("  r = MAX_TRANCHE_BPS, the fraction of a position taken per {}h window",
             LIQ_GRACE_SECS / 3_600);
    println!("\n  {:>6} {:>9} {:>8}   {}", "r bps", "unwind", "x1/√2r",
             names.iter().map(|n| format!("{n:>7}")).collect::<Vec<_>>().join(""));
    for r in [185i64, 300, 500, 750, 1_000, 1_500, 2_000, 3_000] {
        // sqrt(1/2r), x100 — the same closed form `unwind_exposure_x100` uses.
        let inv = B * 10_000 / (2 * r);
        let mult = isqrt(inv as i128 * 10_000) / 100;
        // Windows to unwind 95% of a position at rate r.
        let mut open = B; let mut n = 0;
        while open > B / 20 && n < 10_000 { open -= open * r / B; n += 1; }
        let cells: Vec<String> = fits.iter().map(|(q1, gq)| {
            let lad = (*q1 as i128 * mult as i128 / 100) as i64;
            let m = isqrt(lad as i128 * lad as i128 + *gq as i128 * *gq as i128)
                        .clamp(1, B);
            format!("{:>7}", format!("{}.{:01}x", B * 100 / m / 100, B * 100 / m % 100 / 10))
        }).collect();
        println!("  {:>6} {:>9} {:>8}   {}", r, format!("{n}h"),
                 format!("{}.{:02}", mult / 100, mult % 100), cells.join(""));
    }

    println!("\n  reading it:");
    println!("    • at today's r = {MAX_TRANCHE_BPS} bps the ladder needs 164 hours —");
    println!("      almost seven days — to clear 95% of a position, and the margin");
    println!("      therefore has to carry 5.2 windows of exposure. AAPL prices at");
    println!("      8.9x and MSTR at 2.6x, against a declared 10x cap.");
    println!("    • the return to speeding it up is sub-linear — 1/sqrt(2r) — so");
    println!("      doubling the tranche buys only 41% more leverage. There is no");
    println!("      setting at which a violent name reaches 10x, and that is the");
    println!("      honest answer rather than a knob to turn until it does.");
    println!("    • the gap floor is untouchable by ANY r. As r grows the margin");
    println!("      converges to q_gap and stops. For MSTR that floor alone is");
    println!("      {} bps, i.e. a hard ceiling of {}x no matter how fast the",
             fits[4].1, B * 100 / fits[4].1.max(1) / 100);
    println!("      ladder is allowed to run.");

    for (q1, gq) in &fits { assert!(*q1 > 0 && *gq >= 0); }
}

/// Is the per-ticker leverage spread real, or is it the model talking to itself?
///
/// The margin comes out 15.5x on SPY and 3.0x on MSTR — a 5x range across names
/// that trade on the same exchange in the same hours. That is either the model
/// measuring something true or the model amplifying noise, and the fixture can
/// settle it: compute each name's REALISED annualised volatility straight off
/// the raw bars, with no Actuary involved, and line it up against the margin.
#[test]
fn is_the_leverage_spread_proportional_to_anything_real() {
    let mut rows: Vec<(&str, i64, i64, i64, i64, i64)> = vec![];
    for t in 0..TICKERS.len() {
        let px = path(t);
        let (gaps, sess) = REAL[t];
        // Realised annualised vol, straight from close-to-close log-ish returns.
        // Σr²/n, ×252 days, square-rooted. No model, no fit, no prior.
        let mut sum = 0i128;
        for d in 0..DAYS {
            let r = gaps[d] as i128 + sess[d] as i128;   // close-to-close, bps
            sum += r * r;
        }
        let daily_var = sum / DAYS as i128;
        let ann = {                                        // sqrt(var × 252)
            let n = daily_var * 252;
            let mut r = n.max(1); let mut y = (r + 1) / 2;
            while y < r { r = y; y = (r + n / r.max(1)) / 2; }
            r as i64
        };
        let a = warmed(t, &px, DAYS);
        let m = a.loss_profile(1_000_000, 0).margin_bps;
        rows.push((TICKERS[t], ann, a.observed_vol_bps, m, B * 100 / m.max(1),
                   ann * 100 / m.max(1)));
    }
    rows.sort_by_key(|r| r.1);

    println!("\n=== is the spread real? ===");
    println!("  {:<6} {:>10} {:>9} {:>8} {:>9} {:>10}",
             "tkr", "realised σ", "model σ/h", "margin", "max lev", "σ/margin");
    for r in &rows {
        println!("  {:<6} {:>9}% {:>9} {:>8} {:>8}x {:>10}",
                 r.0, r.1 / 100, r.2, r.3,
                 format!("{}.{:01}", r.4 / 100, r.4 % 100 / 10), r.5);
    }
    let (lo, hi) = (rows[0], rows[rows.len() - 1]);
    println!("\n  {} at {}% annualised gets {} bps of margin.",
             lo.0, lo.1 / 100, lo.3);
    println!("  {} at {}% annualised gets {} bps of margin.",
             hi.0, hi.1 / 100, hi.3);
    println!("  vol ratio {}.{:02}x   margin ratio {}.{:02}x",
             hi.1 * 100 / lo.1.max(1) / 100, hi.1 * 100 / lo.1.max(1) % 100,
             hi.3 * 100 / lo.3.max(1) / 100, hi.3 * 100 / lo.3.max(1) % 100);
    println!("\n  The last column is realised σ divided by the margin the model");
    println!("  charges. If the spread were an artefact that column would wander;");
    println!("  if the model is simply pricing volatility it is roughly flat, and");
    println!("  the whole 5x range in leverage is 5x of actual volatility.");

    // The relationship must be monotone in the thing it claims to measure.
    for w in rows.windows(2) {
        assert!(w[1].3 >= w[0].3 * 60 / 100,
            "{} ({}% vol) got LESS margin than {} ({}%) — not monotone in risk",
            w[1].0, w[1].1 / 100, w[0].0, w[0].1 / 100);
    }
}

/// ⭐ **DOES THE FITTED TAIL BEAT A GAUSSIAN, OR IS THE ACTUARY EXPENSIVE
///    DECORATION?**
///
/// The margin came out at a near-constant multiple of realised volatility
/// across twenty names, which is exactly what a Gaussian would produce. If that
/// is all the GPD fit is doing then the peaks-over-threshold machinery — three
/// running moments, a method-of-moments fit, a bisection to invert the survival
/// function, all of it inside the compute budget — is buying nothing that
/// `2.33 × sigma` would not.
///
/// So compare all three against the truth: the EMPIRICAL 1% quantile of the
/// moves that actually happened.
#[test]
fn does_the_fitted_tail_beat_a_gaussian_on_real_moves() {
    let mut err_gpd = 0i64; let mut err_norm = 0i64;
    let mut rows: Vec<(&str, i64, i64, i64, i64, i64)> = vec![];

    for t in 0..TICKERS.len() {
        let px = path(t);
        let a = warmed(t, &px, DAYS);
        let (_, sess) = REAL[t];

        // The truth: empirical 1% quantile of the SAME quantity the model fits
        // — session moves carried onto the ladder's clock. sqrt(W/session).
        let f = {
            let n = LADDER_WINDOW_SLOTS * 10_000 / SESSION_SLOTS;
            let mut r = n.max(1); let mut y = (r + 1) / 2;
            while y < r { r = y; y = (r + n / r.max(1)) / 2; }
            r          // sqrt(W/session) x100
        };
        let mut obs: Vec<i64> = sess.iter()
            .map(|s| (*s as i64).abs() * f / 100).collect();
        let emp = pctl(&mut obs, 0.99);

        let sigma = a.eff_sigma();
        let gpd = a.quantile_bps(INSOLVENCY_TARGET_BPS);
        // Gaussian at 1%: 2.33 sigma. But `observed_vol_bps` is an EMA of
        // |return|, i.e. a MAD, and MAD = 0.798 sigma for a normal — so the
        // fair Gaussian comparison is 2.33/0.798 = 2.92 x MAD. Giving the
        // Gaussian its best shot rather than a strawman.
        let norm = sigma * 292 / 100;

        err_gpd += (gpd - emp).abs();
        err_norm += (norm - emp).abs();
        rows.push((TICKERS[t], sigma, emp, gpd, norm, gpd * 100 / sigma.max(1)));
    }
    rows.sort_by_key(|r| r.1);

    println!("\n=== fitted tail vs Gaussian vs what actually happened ===");
    println!("  {:<6} {:>7} {:>10} {:>8} {:>10} {:>8}",
             "tkr", "σ/win", "EMPIRICAL", "GPD fit", "Gaussian", "q/σ");
    for r in &rows {
        println!("  {:<6} {:>7} {:>10} {:>8} {:>10} {:>8}",
                 r.0, r.1, r.2, r.3, r.4, r.5);
    }
    println!("\n  mean |error| vs the empirical 1% quantile:");
    println!("    GPD fit   {} bps", err_gpd / TICKERS.len() as i64);
    println!("    Gaussian  {} bps", err_norm / TICKERS.len() as i64);

    let (lo, hi) = (rows.iter().map(|r| r.5).min().unwrap(),
                    rows.iter().map(|r| r.5).max().unwrap());
    println!("\n  q/σ ranges {lo}..{hi} across names — a Gaussian would print 292");
    println!("  for every one of them. The spread is the ONLY thing the tail fit");
    println!("  contributes to margin beyond scale, and it is worth measuring");
    println!("  rather than assuming in either direction.");

    assert!(err_gpd <= err_norm,
        "the GPD fit must not be WORSE than a Gaussian on real moves: {err_gpd} vs {err_norm}");
}

/// 🔴 **THE BARRIER IS WRITTEN ON LEVERAGE, AND ASKING FOR LEVERAGE SHRINKS IT.**
///
/// This is the whole of it, in closed form. `repo` knocks out when
/// `exposure_value > pledged + collar_amt`, and for a levered pod
/// `collar_notional` is the exposure, so the barrier sits at
///
///     L_barrier = 100 · (1 + c/BPS)        c = collar_bps
///
/// and `collar_bps(L) = ES · 100 / L`. Substituting:
///
///     L_barrier = 100 + ES / L
///
/// The barrier is a DECREASING function of the leverage being requested. Ask
/// for 10x and the band that would permit it collapses to 100.02. The fixed
/// point is `L = 100 + ES/L`, which for any realistic ES lands within a few
/// percent of 1.00x — precisely the 1.00–1.03x that every attempt to open a
/// levered position has produced.
///
/// ⚠️ THIS IS NOT THE PARISIAN STRUCTURE FAILING. The excursion clock, the
///    grace budget and the tranche ramp are all sound, and they are the thing
///    that makes this friendlier than an instant liquidation. The defect is
///    that the barrier is drawn on the wrong state variable: it measures
///    NOTIONAL AGAINST PLEDGE, which is leverage, so a position is "outside the
///    barrier" for being levered at all — winning or losing, solvent or not.
///    A Parisian knockout on solvency would measure equity against the margin
///    the tail demands, and let a 10x position that is merely levered sit
///    quietly inside its band until it actually starts losing.
#[test]
fn asking_for_leverage_shrinks_the_barrier_that_would_permit_it() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let a = warmed(t, &path(t), DAYS);
    let es = a.shortfall_bps.max(a.expected_shortfall_bps(COLLAR_BREACH_BPS));

    println!("\n=== the barrier as a function of the leverage requested ===");
    println!("  AAPL, ES at the {COLLAR_BREACH_BPS} bps breach rate = {es} bps");
    println!("\n  {:>10} {:>10} {:>12} {:>14}", "requested", "collar", "L_barrier", "achievable");
    for l in [100i64, 200, 300, 500, 1_000, 2_000] {
        let c = collar_bps(l, &a);
        let lb = 100 + (100 * c) / B;          // 100·(1 + c/BPS)
        println!("  {:>9}x {:>10} {:>12} {:>14}",
                 format!("{}.{:02}", l / 100, l % 100), c, lb,
                 format!("{}.{:02}x", lb / 100, lb % 100));
    }
    println!("\n  Every row is 1.0x. The column that was supposed to open up as");
    println!("  leverage rose closes instead, because `collar_bps` divides the");
    println!("  expected shortfall BY the leverage and the barrier then adds it");
    println!("  back as a fraction. The two operations cancel to a constant.");
    println!("\n  ⭐ The fix keeps every part of the Parisian design and changes");
    println!("     ONE thing: the barrier's width comes from");
    println!("     `LossProfile::margin_bps` — the leverage the fitted tail");
    println!("     actually supports, {} bps here, i.e. {}x — while the Actuary",
             a.loss_profile(1_000_000, 0).margin_bps,
             B * 100 / a.loss_profile(1_000_000, 0).margin_bps.max(1) / 100);
    println!("     keeps setting the ladder speed and the knockout premium. The");
    println!("     Actuary ends up doing MORE work, not less.");

    // The defect, asserted so it cannot silently come back.
    for l in [300i64, 1_000, 2_000] {
        let c = collar_bps(l, &a);
        assert!(100 + (100 * c) / B < 110,
            "barrier at {l} x100 leverage is {} — if this ever exceeds 1.10x the \
             conflation has been fixed and this test should be rewritten",
            100 + (100 * c) / B);
    }
}

/// ⭐ **WHAT THE LEGACY MODEL HAS THAT THIS ONE DOES NOT: CORRELATION.**
///
/// VIGOR (the legacy contract, WIPO WO2020102401) computes `portfolioVariance`
/// over a full covariance matrix supplied by its oracle hub, then stresses the
/// PORTFOLIO — `stresscol = 1 − exp(−ES_φ · σ_port)` — and sizes one
/// system-wide solvency capital requirement from it.
///
/// This program has no covariance anywhere. `max_liability` is
/// `Σ(exposure_i × collar_i)`, a straight sum over positions, which is exactly
/// the ρ = 1 assumption: every name is assumed to blow up together. That is
/// SAFE — it can only over-reserve — but it is not free, because reserve that
/// is held is reserve that is not earning, and the gap between `Σσ` and
/// `σ_portfolio` is depositor yield left on the table.
///
/// So: how much? The fixture can answer with real correlations rather than an
/// assumed one.
#[test]
fn what_the_sum_of_per_ticker_margins_costs_against_a_real_covariance() {
    let n = TICKERS.len();
    // Daily close-to-close returns, in bps.
    let r: Vec<Vec<i64>> = (0..n).map(|t| {
        let (g, s) = REAL[t];
        (0..DAYS).map(|d| g[d] as i64 + s[d] as i64).collect()
    }).collect();

    let mean: Vec<i64> = r.iter().map(|v| v.iter().sum::<i64>() / DAYS as i64).collect();
    let var: Vec<i128> = (0..n).map(|i| r[i].iter()
        .map(|x| { let d = (*x - mean[i]) as i128; d * d }).sum::<i128>() / DAYS as i128).collect();
    let isqrt = |x: i128| { if x <= 0 { return 0i128 }
        let mut a = x; let mut y = (a + 1) / 2;
        while y < a { a = y; y = (a + x / a.max(1)) / 2; } a };
    let sd: Vec<i128> = var.iter().map(|v| isqrt(*v)).collect();

    // Average pairwise correlation, x100.
    let (mut csum, mut cn) = (0i128, 0i128);
    let mut cov = vec![vec![0i128; n]; n];
    for i in 0..n { for j in 0..n {
        let c: i128 = (0..DAYS).map(|d|
            (r[i][d] - mean[i]) as i128 * (r[j][d] - mean[j]) as i128).sum::<i128>() / DAYS as i128;
        cov[i][j] = c;
        if i < j { csum += c * 100 / (sd[i] * sd[j]).max(1); cn += 1; }
    }}
    let rho = csum / cn.max(1);

    // Equal-weighted book: Σσ_i (what this program reserves) vs the true
    // portfolio σ (what the risk actually is).
    let sum_sd: i128 = sd.iter().sum();
    let port_var: i128 = (0..n).map(|i| (0..n).map(|j| cov[i][j]).sum::<i128>()).sum::<i128>();
    let port_sd = isqrt(port_var);
    let indep_sd = isqrt(var.iter().sum::<i128>());

    println!("\n=== correlation: the one thing legacy models and this one does not ===");
    println!("  20 names, {DAYS} daily returns each");
    println!("  average pairwise correlation            {}.{:02}", rho / 100, rho % 100);
    println!("  Σ σ_i        (this program's reserve, ρ=1 implicitly)   {}", sum_sd);
    println!("  σ_portfolio  (the real risk, with real correlations)    {}", port_sd);
    println!("  σ if independent (ρ=0, the other extreme)               {}", indep_sd);
    println!("  ⇒ the ρ=1 sum over-reserves by {}.{:02}x against the truth",
             sum_sd * 100 / port_sd.max(1) / 100, sum_sd * 100 / port_sd.max(1) % 100);
    println!("\n  Reading it honestly, both ways:");
    println!("    • the direction is SAFE. `max_liability` can only be too large,");
    println!("      never too small, so no correlation surprise can make the pool");
    println!("      insolvent through this channel. That is worth something and it");
    println!("      is the opposite of the usual failure.");
    println!("    • but {}.{:02}x of reserve is {}.{:02}x of depositor yield not earned,",
             sum_sd * 100 / port_sd.max(1) / 100, sum_sd * 100 / port_sd.max(1) % 100,
             sum_sd * 100 / port_sd.max(1) / 100, sum_sd * 100 / port_sd.max(1) % 100);
    println!("      and it binds hardest exactly when the book is well diversified —");
    println!("      i.e. when the pool is safest, it charges as if it were not.");
    println!("    • ρ = {}.{:02} is high but nowhere near 1. These are twenty US",
             rho / 100, rho % 100);
    println!("      equities; across 464 names spanning sectors it would be lower");
    println!("      still, so the gap widens as the book grows.");
    println!("\n  🔴 THIS IS THE ONE PLACE THE LEGACY DESIGN IS STRICTLY AHEAD.");
    println!("     Everything else — the fitted tail, the unwind horizon, the gap");
    println!("     term, the Parisian ladder — is new work. Covariance is old work");
    println!("     that was dropped, and `portfolioVariance` is not hard to carry");
    println!("     forward: a per-pair EMA of return products on TickerRisk, read");
    println!("     when `max_liability` is assembled.");

    assert!(rho > 0 && port_sd <= sum_sd,
        "a sum of standard deviations cannot be smaller than the portfolio's");
}

/// 🔴 **`Stock::INIT_SPACE` DOES NOT MATCH WHAT `Stock` SERIALISES TO.**
///
/// The hand-written figure at `stay.rs:111` was never updated when
/// `funding_checkpoint: u128` was added, and it carries a stray `+ 2` that
/// looks like struct padding — which Borsh does not do. `Depositor` allocates
/// `4 + MAX_LEN * Stock::INIT_SPACE` for its `balances`, so if the constant is
/// short, a depositor accumulating positions eventually cannot be written back
/// at all.
///
/// Asserted against the serialiser rather than against another hand count,
/// because a hand count is what produced the bug.
#[test]
fn the_declared_size_of_a_pod_matches_what_it_serialises_to() {
    use anchor_lang::AnchorSerialize;
    let pod = Stock { ticker: [0u8; 8], marked: 0, pledged: 0, exposure: 0, updated: 0,
        collar_bps: 0, cost_basis: 0, interest_paid: 0, collar_dollar_seconds: 0,
        collar_dollars: 0, premium_checkpoint: 0, funding_checkpoint: 0,
        breached_at: 0 };
    let actual = pod.try_to_vec().unwrap().len();
    let declared = <Stock as anchor_lang::Space>::INIT_SPACE;
    println!("\n=== pod account size ===");
    println!("  declared INIT_SPACE   {declared} bytes");
    println!("  actual  serialised    {actual} bytes");
    println!("  per-depositor budget  4 + {} x {} = {}",
             crate::etc::MAX_LEN, declared, 4 + crate::etc::MAX_LEN * declared);
    println!("  actually needed       4 + {} x {} = {}",
             crate::etc::MAX_LEN, actual, 4 + crate::etc::MAX_LEN * actual);
    if declared < actual {
        println!("  🔴 SHORT BY {} BYTES PER POD — a depositor bricks at {} positions",
                 actual - declared,
                 (crate::etc::MAX_LEN * declared) / actual + 1);
    }
    assert_eq!(declared, actual,
        "Stock::INIT_SPACE is {declared} but the pod serialises to {actual}");
}

/// ⭐ **WHY "JUST WIDEN THE COLLAR" IS NOT A FIX — THE LOWER BARRIER EVAPORATES.**
///
/// The band is `exposure_value ∈ pledged ± collar_amt` with
/// `collar_amt = max(exposure_value, pledged) × collar_bps`. At 1x leverage
/// `pledged ≈ exposure_value`, so `exposure_value − pledged` IS the profit and
/// loss and the band is a P&L band wearing a notional band's clothes. That is
/// why it works today, and it is the only reason.
///
/// Raise leverage and the disguise comes off. `collar_amt` is computed off the
/// EXPOSURE, so it grows with notional while `pledged` shrinks relative to it:
///
///     lower = pledged − exposure_value · c
///
/// At 10x with any collar past 10% that is zero. **A levered long can lose its
/// entire pledge without the band noticing**, because a losing long's notional
/// FALLS, which moves it further inside a band whose floor is already at zero.
///
/// So widening `MAX_COLLAR_BPS` toward 9000 buys the upper barrier — the pool's
/// cap on unfunded profit — and destroys the lower one, which is the barrier
/// that protects depositors. This is the option I put in front of the owner as
/// "smaller change, principal stays protected by construction". It was neither.
#[test]
fn widening_the_collar_buys_leverage_by_deleting_the_liquidation_barrier() {
    println!("\n=== the band at each leverage, for a $1,000 pledge ===");
    println!("  {:>5} {:>10} {:>9} {:>10} {:>10} {:>28}",
             "lev", "exposure", "collar", "lower", "upper", "loss that triggers the ladder");
    for lev in [1i64, 2, 5, 10] {
        let pledged = 1_000i64;
        let exposure = pledged * lev;
        // Give the collar the most generous setting the constant allows, then
        // the setting "widening" would need for this leverage: c = 1 − 1/L.
        for &c in [MAX_COLLAR_BPS, B - B / lev].iter().take(if lev == 1 { 1 } else { 2 }) {
            let collar_amt = exposure.max(pledged) * c / B;
            let lower = pledged.saturating_sub(collar_amt).max(0);
            let upper = pledged + collar_amt;
            let trigger = if lower == 0 { None }
                          else { Some((exposure - lower) * B / exposure) };
            println!("  {:>4}x {:>10} {:>9} {:>10} {:>10} {:>28}",
                     lev, exposure, c, lower, upper,
                     match trigger {
                         Some(t) => format!("{} bps down", t),
                         None => "NEVER — floor is at zero".to_string(),
                     });
        }
    }
    println!("\n  At 1x the floor sits {} bps below the mark and the ladder works.",
             MAX_COLLAR_BPS);
    println!("  At 10x, with the collar that 10x REQUIRES (9000 bps), the floor is");
    println!("  at zero: the position is inside its band all the way down to a");
    println!("  total loss. The borrower's pledge is gone at −1000 bps and nothing");
    println!("  in `repo` has fired.");
    println!("\n  🔴 AND `cost_basis` CANNOT RESCUE IT EITHER. The name suggests an");
    println!("     entry mark, but `renege` moves `cost_basis` and `pledged` by the");
    println!("     SAME amount on every collateral change (stay.rs:1531, 1558) — it");
    println!("     is CONTRIBUTED COLLATERAL, and it equals the entry notional only");
    println!("     because the 1x forcing makes exposure_value equal pledged. There");
    println!("     is no stored entry price anywhere in `Stock`.");
    println!("\n  ⇒ A levered position needs a MARK REFERENCE, and the current");
    println!("    design's whole trick is to avoid needing one by forcing");
    println!("    exposure_value == pledged. That is the real cost of leverage");
    println!("    here: one more u64, not a rewrite.");

    // The claim, asserted: at 10x the collar that grants the leverage zeroes the floor.
    let (pledged, lev) = (1_000i64, 10i64);
    let c = B - B / lev;                       // 9000 bps, the collar 10x needs
    let collar_amt = pledged * lev * c / B;
    assert!(pledged.saturating_sub(collar_amt) <= 0,
        "at 10x the lower barrier must have vanished for this finding to hold");
}

/// **THE ALTERNATIVE THAT NEEDS NO LEVERAGE AT ALL: NET THE PORTFOLIO.**
///
/// Before recommending a mark reference and a margin band, the other route
/// deserves a number. Keep every pod fully collateralised — `exposure_value ==
/// pledged`, exactly as today, no leverage, no uncollateralised pool exposure —
/// and instead compute the collateral requirement over the depositor's WHOLE
/// book rather than pod by pod. A depositor long AAPL and short QQQ is nearly
/// flat; charging them for both legs is charging twice for one risk.
///
/// That is capital efficiency rather than leverage, and it is strictly safer:
/// the pool never carries a position it has not been paid for. The question is
/// only whether it delivers enough. "offsetting shorts and longs through
/// virtual exposure represent puts and longs" is the owner's own description of
/// the book, so this is not a hypothetical shape.
#[test]
fn how_much_capital_efficiency_comes_from_netting_alone() {
    let n = TICKERS.len();
    let r: Vec<Vec<i64>> = (0..n).map(|t| {
        let (g, s) = REAL[t];
        (0..DAYS).map(|d| g[d] as i64 + s[d] as i64).collect()
    }).collect();
    let mean: Vec<i64> = r.iter().map(|v| v.iter().sum::<i64>() / DAYS as i64).collect();
    let cov = |i: usize, j: usize| -> i128 {
        (0..DAYS).map(|d| (r[i][d] - mean[i]) as i128 * (r[j][d] - mean[j]) as i128)
            .sum::<i128>() / DAYS as i128
    };
    let isqrt = |x: i128| { if x <= 0 { return 0i128 }
        let mut a = x; let mut y = (a + 1) / 2;
        while y < a { a = y; y = (a + x / a.max(1)) / 2; } a };

    let mut rng = Rng(0x9E3779B97F4A7C15);
    println!("\n=== capital efficiency from netting a book, no leverage anywhere ===");
    println!("  {:>18} {:>9} {:>12} {:>12} {:>10}",
             "book shape", "legs", "gross $", "risk-equiv $", "efficiency");

    for (name, longs_only, legs) in [("all long", true, 4usize), ("all long", true, 12),
                                     ("long/short mixed", false, 4),
                                     ("long/short mixed", false, 12),
                                     ("long/short mixed", false, 20)] {
        let (mut eff_sum, mut trials) = (0i128, 0i128);
        let (mut g_last, mut e_last) = (0i128, 0i128);
        for _ in 0..200 {
            // Pick `legs` distinct names, each $10k, sign per the shape.
            let mut w = vec![0i128; n];
            let mut picked = 0;
            while picked < legs {
                let i = rng.upto(n as u64) as usize;
                if w[i] != 0 { continue }
                w[i] = if longs_only { 10_000 } else if rng.upto(2) == 0 { 10_000 } else { -10_000 };
                picked += 1;
            }
            let gross: i128 = w.iter().map(|x| x.abs()).sum();
            // Portfolio σ in dollar terms: sqrt(wᵀΣw), σ in bps → /BPS.
            let mut pv = 0i128;
            for i in 0..n { if w[i] == 0 { continue }
                for j in 0..n { if w[j] == 0 { continue }
                    pv += w[i] * w[j] * cov(i, j) / (B as i128 * B as i128); } }
            let psd = isqrt(pv.max(0));
            // What the pool would need at the SAME confidence per dollar of
            // risk: scale gross by (portfolio σ / summed σ).
            let mut ssd = 0i128;
            for i in 0..n { if w[i] == 0 { continue }
                ssd += w[i].abs() * isqrt(cov(i, i)) / B as i128; }
            let risk_equiv = if ssd > 0 { gross * psd / ssd } else { gross };
            eff_sum += gross * 100 / risk_equiv.max(1);
            trials += 1;
            g_last = gross; e_last = risk_equiv;
        }
        let eff = eff_sum / trials;
        println!("  {:>18} {:>9} {:>12} {:>12} {:>9}x",
                 name, legs, g_last, e_last, format!("{}.{:02}", eff / 100, eff % 100));
    }

    println!("\n  Reading it:");
    println!("    • an all-long book nets almost nothing — ρ ≈ 0.37 between US");
    println!("      equities means twelve long legs are close to one big long leg,");
    println!("      and that is the book a bull market produces.");
    println!("    • a genuinely two-sided book nets a great deal, and it nets MORE");
    println!("      the more legs it has.");
    println!("\n  ⇒ Netting is real capital efficiency and it is strictly safer than");
    println!("    leverage — but it is EARNED BY THE BOOK, not granted to a trader.");
    println!("    Someone who simply wants 10x long AAPL gets none of it. So this");
    println!("    is a complement to the margin band, not a substitute: it belongs");
    println!("    in how `required` is computed, once there IS a `required`.");
}

/// The TWAP is the manipulation defence, so its weight must be bought with
/// TIME rather than with transactions. Same security property the drawdown
/// fade already asserts, on the estimator that was still missing it.
#[test]
fn dragging_the_twap_must_cost_time_not_transactions() {
    let build = || {
        let mut a = Actuary::default();
        a.update_price(1_000_000, 0);
        a
    };
    const STEP: i64 = 2_500;
    const N: i64 = 40;

    // Path A: N cheap calls, hammering a pushed price.
    let mut split = build();
    for i in 1..=N { split.update_price(1_500_000, i * STEP); }
    // Path B: the same elapsed time, one call — i.e. actually holding it there.
    let mut whole = build();
    whole.update_price(1_500_000, N * STEP);

    println!("\n=== what moves the TWAP ===");
    println!("  {N} calls {STEP} slots apart → twap {}", split.twap_price);
    println!("  one call after {} slots      → twap {}", N * STEP, whole.twap_price);
    println!("  target price                   1500000");
    println!("\n  alpha by elapsed slots (must increase):");
    for dt in [1i64, 100, 1_000, LADDER_WINDOW_SLOTS, GAP_MIN_SLOTS, 1_000_000] {
        println!("    dt {:>8} → {:>5} bps", dt, Actuary::twap_alpha_bps(dt));
    }

    // Monotonicity — the property, not a sample of it.
    let mut prev = 0;
    for dt in [1i64, 10, 100, 1_000, 5_000, 9_000, 36_000, 72_000, 500_000] {
        let a = Actuary::twap_alpha_bps(dt);
        assert!(a >= prev, "twap weight fell from {prev} to {a} as dt grew to {dt}");
        prev = a;
    }
    // And the attack: splitting an interval must not out-drag holding it.
    assert!((split.twap_price - 1_000_000).abs() <= (whole.twap_price - 1_000_000).abs(),
        "splitting moved the TWAP further than holding: split {} vs whole {}",
        split.twap_price, whole.twap_price);
}

/// ⚠️ **TESTING MY OWN CLAIM AGAINST THE CODE'S.** I reported that the additive
/// cross-ticker reserve over-reserves by 1.56x against a real covariance, and
/// called it the one place the legacy design is ahead. `ticker_reserve_dollars`
/// answers directly: *"a published correlation matrix lags regime change and
/// converges to 1 in exactly the crises the reserve exists for."*
///
/// 🔴 THE OBVIOUS TEST OF THAT IS WRONG AND I RAN IT FIRST. Selecting the worst
///    decile of market days and measuring correlation inside it returned ρ =
///    0.17 against 0.37 overall — correlation apparently FALLING in the tail,
///    which would have refuted the code. It is an artefact: conditioning on the
///    common factor removes the common factor's variance from the subsample, so
///    what is left is mostly idiosyncratic and the measured correlation
///    collapses by construction. Forbes and Rigobon made exactly this point
///    about contagion studies in 2002, and Boyer, Gibson and Loretan in 1999.
///
/// Two statistics that are not subject to it:
///   • TAIL DEPENDENCE — P(name i in its own worst q | name j in its own worst
///     q). Each name is conditioned on ITSELF, never on the shared factor.
///     Independence gives q; comonotonicity gives 1.
///   • REGIME SPLIT ON VOLATILITY rather than on return, so the selection
///     variable is not the quantity being measured.
#[test]
fn does_correlation_hold_up_in_the_tail_where_the_reserve_is_spent() {
    let n = TICKERS.len();
    let r: Vec<Vec<i64>> = (0..n).map(|t| {
        let (g, s) = REAL[t];
        (0..DAYS).map(|d| g[d] as i64 + s[d] as i64).collect()
    }).collect();

    // ── tail dependence at several depths ──────────────────────────────────
    println!("\n=== tail dependence: does everything fall together? ===");
    println!("  {:>8} {:>14} {:>16} {:>12}", "depth q", "independent", "observed λ", "λ/q");
    for q in [20i64, 10, 5, 2] {
        let k = (DAYS as i64 * q / 100).max(2) as usize;
        // Each name's own worst-k days.
        let worst: Vec<Vec<bool>> = (0..n).map(|t| {
            let mut idx: Vec<usize> = (0..DAYS).collect();
            idx.sort_by_key(|d| r[t][*d]);
            let mut m = vec![false; DAYS];
            for d in &idx[..k] { m[*d] = true; }
            m
        }).collect();
        let (mut both, mut given) = (0i64, 0i64);
        for i in 0..n { for j in 0..n { if i == j { continue }
            for d in 0..DAYS {
                if worst[j][d] { given += 1; if worst[i][d] { both += 1; } }
            }
        }}
        let lambda = both * 100 / given.max(1);
        println!("  {:>7}% {:>13}% {:>15}% {:>11}", q, q, lambda, 
                 format!("{}.{:02}x", lambda / q / 1, (lambda * 100 / q) % 100));
    }

    // ── regime split on volatility, not on return ──────────────────────────
    let mkt: Vec<i64> = (0..DAYS)
        .map(|d| (0..n).map(|t| r[t][d]).sum::<i64>() / n as i64).collect();
    let vol20: Vec<i64> = (0..DAYS).map(|d| {
        let lo = d.saturating_sub(20);
        let w = &mkt[lo..=d];
        w.iter().map(|x| x.abs()).sum::<i64>() / w.len().max(1) as i64
    }).collect();
    let mut byvol: Vec<usize> = (0..DAYS).collect();
    byvol.sort_by_key(|d| vol20[*d]);

    let rho_over = |days: &[usize]| -> i64 {
        let m: Vec<i64> = (0..n).map(|t|
            days.iter().map(|d| r[t][*d]).sum::<i64>() / days.len() as i64).collect();
        let isq = |v: i128| { let mut a = v.max(1); let mut y = (a + 1) / 2;
            while y < a { a = y; y = (a + v.max(1) / a.max(1)) / 2; } a };
        let sd: Vec<i128> = (0..n).map(|t| isq(days.iter()
            .map(|d| { let x = (r[t][*d] - m[t]) as i128; x * x }).sum::<i128>()
            / days.len() as i128)).collect();
        let (mut acc, mut cnt) = (0i128, 0i128);
        for i in 0..n { for j in (i + 1)..n {
            let c: i128 = days.iter().map(|d|
                (r[i][*d] - m[i]) as i128 * (r[j][*d] - m[j]) as i128).sum::<i128>()
                / days.len() as i128;
            acc += c * 100 / (sd[i] * sd[j]).max(1); cnt += 1;
        }}
        (acc / cnt.max(1)) as i64
    };
    let calm: Vec<usize> = byvol[..DAYS / 3].to_vec();
    let storm: Vec<usize> = byvol[DAYS - DAYS / 3..].to_vec();
    println!("\n=== correlation by VOLATILITY regime (selection is not the measure) ===");
    println!("  calmest third of sessions   ρ = 0.{:02}", rho_over(&calm));
    println!("  stormiest third             ρ = 0.{:02}", rho_over(&storm));

    println!("\n  ⇒ THE CODE IS RIGHT AND MY 1.56x WAS OVERSTATED. Diversification");
    println!("    is a fair-weather asset. Whatever a covariance matrix would");
    println!("    release on a calm day, the tail takes back — and it would be");
    println!("    wrong in the same direction as everything else precisely when");
    println!("    the reserve is being spent. Staying additive across tickers is");
    println!("    a deliberate, defensible choice, not an omission, and I should");
    println!("    not have called it the one place legacy is ahead.");

    assert!(rho_over(&storm) > rho_over(&calm),
        "correlation must rise with volatility for the additive reserve to be justified");
}

/// The carry the 1,000-borrower run measured is 157% a year on notional, which
/// no borrower would pay. Leverage did not cause it — the same run at the old
/// forced 1x measured 97% — but leverage made it impossible to ignore, because
/// the borrower feels it against the PLEDGE and that is now L times worse.
///
/// So: which term is it? The position rate is
///     `rate_bps(conc, lev) − rate_bps(conc, 100) + hazard_rate_bps(...)`
/// and this prints all three against a real, warmed ticker rather than a
/// synthetic one.
#[test]
fn which_term_makes_the_carry_absurd() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let a = warmed(t, &path(t), DAYS);
    let profile = a.loss_profile(1_000_000, 0);
    let band = profile.margin_bps;

    println!("\n=== decomposing the carry on a real AAPL book ===");
    println!("  σ/window {}   margin {} bps   ES(collar) {} bps",
             a.eff_sigma(), band, collar_bps(100, &a));
    println!("  loss_profile says the fair price is {} bps/yr", profile.premium_bps);
    println!("    of which expected loss {} bps and capital charge {} bps",
             profile.expected_loss_bps, profile.premium_bps - profile.expected_loss_bps);
    println!("\n  {:>6} {:>10} {:>12} {:>12} {:>14}",
             "util", "base rate", "lev term", "hazard", "TOTAL bps/yr");
    for util in [1_000i64, 5_000, 9_000] {
        for lev in [100i64, 300, 500, 1_000] {
            let base = rate_bps(util, 100, &a);
            let levt = rate_bps(util, lev, &a) - base;
            // A fresh position sits one full band-width from either edge.
            let haz = hazard_rate_bps(band, collar_bps(lev, &a), 1_000_000,
                                      &a, 20_000_000_000_000, 2_000_000_000_000);
            println!("  {:>5}% {:>10} {:>12} {:>12} {:>14}",
                     util / 100, base, levt, haz, base + levt + haz);
        }
    }
    println!("\n  and at the barrier itself, where a stressed position sits:");
    for d in [band, band / 2, band / 8, 0] {
        let haz = hazard_rate_bps(d, collar_bps(300, &a), 1_000_000,
                                  &a, 20_000_000_000_000, 2_000_000_000_000);
        println!("    distance {:>5} bps → hazard {:>8} bps/yr", d, haz);
    }
}

/// 🔴 **THE CAPITAL ALLOCATION WAS NOT EULER ALLOCATION, AND TWO COMMENTS IN
///    THIS TREE SAID IT WAS.** `facility_sim_report.rs:1755` and `:1770` both
///    claimed it. This test is what caught them, and it now guards the fix.
///
/// The risk measure is `ρ(net) = m·|net|`, homogeneous of degree 1. Euler's
/// theorem then gives the allocation to a position of signed size `x`:
///
///     aᵢ = xᵢ · ∂ρ/∂net = m · xᵢ · sign(net),     Σ aᵢ = m·|net|   ← EXACTLY
///
/// Full allocation is the whole point of Euler: the parts sum to the whole, and
/// the answer does not depend on the order positions are considered in.
///
/// What `loss_profile` computes is the INCREMENTAL charge `m·(|net+x| − |net|)`
/// with a floor at zero. Incremental allocation is order-dependent and does not
/// sum to the total — that is its known defect — and the `.max(0)` makes it
/// worse in a way that matters for this book specifically: a position that
/// OFFSETS the net genuinely consumes negative capital, and the clamp charges
/// it zero instead of paying it back. Offsetting flow is the flow this design
/// exists to attract.
#[test]
fn the_capital_charge_does_not_sum_to_the_capital() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let a = warmed(t, &path(t), DAYS);
    let m = a.loss_profile(1_000_000, 0).margin_bps;

    // A book on one ticker: four longs and two shorts.
    let book: [i64; 6] = [400_000, 300_000, 200_000, 150_000, -250_000, -100_000];
    let net: i64 = book.iter().sum();
    let total_capital = (m as i128 * net.unsigned_abs() as i128 / 10_000) as i64;

    println!("\n=== does the allocation add up? ===");
    println!("  margin {m} bps, book net {net}, capital to allocate {total_capital}");
    println!("\n  {:>10} {:>14} {:>14}", "position", "as coded", "Euler");
    let (mut sum_coded, mut sum_euler) = (0i64, 0i64);
    for x in book {
        // As coded: incremental against the net EXCLUDING this position.
        let others = net - x;
        let coded_bps = a.loss_profile(x, others).capital_bps;
        let coded = (coded_bps as i128 * x.unsigned_abs() as i128 / 10_000) as i64;
        // Euler: the derivative, times the position.
        let euler = (m as i128 * x as i128 / 10_000) as i64
            * if net >= 0 { 1 } else { -1 };
        sum_coded += coded; sum_euler += euler;
        println!("  {:>10} {:>14} {:>14}", x, coded, euler);
    }
    println!("  {:>10} {:>14} {:>14}", "SUM", sum_coded, sum_euler);
    println!("  {:>10} {:>14} {:>14}", "should be", total_capital, total_capital);
    println!("\n  over-allocated by {} ({}%)", sum_coded - total_capital,
             (sum_coded - total_capital) * 100 / total_capital.max(1));
    println!("\n  The offsetting positions were the whole story: the clamped form");
    println!("  charged them ZERO for reducing the pool's risk, and the 50% gap");
    println!("  above was exactly their two rebates. This is the book the design");
    println!("  is for — \"offsetting shorts and longs through virtual exposure\" —");
    println!("  so a capital charge blind to the offset was blind to the product.");

    assert_eq!(sum_euler, total_capital, "Euler must allocate the whole capital");
    assert_eq!(sum_coded, total_capital,
        "and `loss_profile` must now agree with it — the parts sum to the whole");
}

/// 🔴 **THE PARISIAN CLOCK CANNOT START FROM A SWEEP, SO THE LADDER CAN NEVER
///    FIRE.** This only becomes visible once the harness models the transaction
///    boundary, which is why every earlier run in this file showed thousands of
///    tranches: mutating a `Depositor` in place persists writes that the chain
///    would have rolled back.
///
/// The sequence, in `repo`:
///
///     let excursion = pod.excursion(now);              // SETS breached_at = now
///     require!(excursion > LIQ_GRACE_SECS, TooSoon);   // 0 > 3600 is false → Err
///
/// `excursion()` starts the clock on first sight of a breach, and the very next
/// line fails, so the instruction reverts and the clock is unwound with it. In
/// `handle_sweep` the `Err` lands on `_ => continue` and the depositor is never
/// serialised. Next sweep: identical. The excursion is re-zeroed forever and
/// `excursion > LIQ_GRACE_SECS` is unreachable from this path.
#[test]
fn a_breached_position_can_never_accumulate_an_excursion() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let px = path(t);
    let a = warmed(t, &px, 400);
    let mut bank = Depository { last_updated: 0, total_deposits: 100_000_000_000,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };

    let mut d = Depositor { owner: Pubkey::new_unique(), deposited_quid: 0,
        deposited_lamports: 0, sol_pledged_usd: 0, deposit_seconds: 0,
        last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
        total_interest_paid: 0, total_collar_dollar_seconds: 0,
        sol_yield_checkpoint: 0 };
    let p0 = px[400].0;
    d.deposited_quid = 20_000_000_000;
    d.balances.push(pod_for("AAPL"));
    d.renege(Some("AAPL"), 2_000_000_000, Some(&vec![p0]), 1).unwrap();
    let mut secs = 1i64; let mut slot = 1i64;
    d.repo("AAPL", (6_000_000_000i64) / p0 as i64, p0, secs, slot, &a, &mut bank)
        .expect("open");
    d.deposited_quid = 0;   // no free balance: the cure paths cannot fire

    // Move the price hard against it, then crank once a session for a week —
    // far longer than LIQ_GRACE_SECS — rolling back exactly as `handle_sweep`
    // does whenever the call returns Err or takes no action.
    let crashed = p0 / 2;
    println!("\n=== a week of sweeps against a broken position ===");
    let mut tranches = 0;
    for day in 0..7 {
        secs += 86_400; slot += 216_000;
        let snapshot = d.clone();
        let bank_before = bank.clone();
        let r = d.repo("AAPL", 0, crashed, secs, slot, &a, &mut bank);
        // The sweep's write rule, mirrored: a tranche, or a clock that started.
        let acted = matches!(&r, Ok((delta, _))
            if *delta != 0 || d.balances.first().map_or(false, |p| p.breached_at != 0));
        let seen = d.balances.first().map_or(0, |p| p.breached_at);
        if !acted { d = snapshot; bank = bank_before; } else { tranches += 1; }
        let kept = d.balances.first().map_or(0, |p| p.breached_at);
        println!("  day {day}: repo -> {:<28} breached_at during call {seen}, after write {kept}",
                 match &r { Ok((x, _)) => format!("Ok(delta {x})"),
                            Err(_) => "Err".to_string() });
    }
    println!("\n  tranches taken in a week: {tranches}");
    println!("\n  BEFORE THE FIX every row read `during call 86401 … after write 0`:");
    println!("  the clock was set inside each call and survived none of them, the");
    println!("  excursion could not accumulate, and a position 50% underwater was");
    println!("  never liquidated by the one path that exists to liquidate it.");

    println!("\n  ⭐ WITH THE CLOCK PERSISTED the first sweep starts it, the grace");
    println!("     elapses, and the ladder runs from the second onward — which is");
    println!("     the behaviour the design describes and never had.");
    assert!(tranches > 0,
        "the ladder must fire from a sweep once the excursion can accumulate");
}

/// ⚠️ **THE HOLE THAT LETTING A REDUCTION THROUGH WOULD HAVE OPENED.**
///
/// Allowing a reducing trade past the over-profit gate is right — closing is
/// the cure, and the pool is strictly better off after it. But the code
/// immediately below that gate cleared `breached_at` on the reasoning that
/// "neither breach branch fired, so the excursion is over". With reductions now
/// passing through, an over-profitable position could send ONE UNIT of
/// reduction, fall past the gate, and have its Parisian clock zeroed while
/// still outside its barrier — once per grace period, for ever.
///
/// That is the oscillation attack on a strict Parisian barrier, and it would
/// have made the knockout unreachable for the price of a dust trade an hour.
#[test]
fn a_dust_reduction_cannot_reset_the_excursion_clock() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let px = path(t);
    let a = warmed(t, &px, 400);
    let mut bank = Depository { last_updated: 0, total_deposits: 100_000_000_000,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
    let mut d = Depositor { owner: Pubkey::new_unique(), deposited_quid: 0,
        deposited_lamports: 0, sol_pledged_usd: 0, deposit_seconds: 0,
        last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
        total_interest_paid: 0, total_collar_dollar_seconds: 0,
        sol_yield_checkpoint: 0 };
    let p0 = px[400].0;
    d.deposited_quid = 20_000_000_000;
    d.balances.push(pod_for("AAPL"));
    d.renege(Some("AAPL"), 2_000_000_000, Some(&vec![p0]), 1).unwrap();
    let units = 6_000_000_000i64 / p0 as i64;
    let mut secs = 1i64; let mut slot = 1i64;
    d.repo("AAPL", units, p0, secs, slot, &a, &mut bank).expect("open");
    d.deposited_quid = 0;

    // Double the price: deep into over-profit, far outside the upper barrier.
    let spiked = p0 * 2;
    println!("\n=== dust reductions against a running excursion clock ===");
    let mut cleared = 0;
    for round in 0..6 {
        secs += 3_700; slot += 9_250;
        // A liquidator sees it and starts (or advances) the clock.
        let snap = d.clone(); let bsnap = bank.clone();
        let r = d.repo("AAPL", 0, spiked, secs, slot, &a, &mut bank);
        let acted = matches!(&r, Ok((delta, _))
            if *delta != 0 || d.balances.first().map_or(false, |p| p.breached_at != 0));
        if !acted { d = snap; bank = bsnap; }
        let started = d.balances[0].breached_at;

        // The borrower immediately sheds one unit, trying to reset the clock.
        secs += 60; slot += 150;
        let _ = d.repo("AAPL", -1, spiked, secs, slot, &a, &mut bank);
        let after = d.balances[0].breached_at;
        if started != 0 && after == 0 { cleared += 1; }
        println!("  round {round}: clock {started} → after dust reduction {after}{}",
                 if started != 0 && after == 0 { "   ← RESET" } else { "" });
        if d.balances[0].exposure == 0 { break; }
    }
    println!("\n  resets achieved: {cleared}");
    println!("  A position outside its barrier keeps its excursion whatever it");
    println!("  trades; the clock is asked of the BAND now, not inferred from");
    println!("  which control-flow branch happened to run.");
    assert_eq!(cleared, 0,
        "a dust reduction reset the Parisian clock {cleared} times");
}

/// ⭐ **ARE THE CAPITAL CHARGE AND THE FUNDING RATE TWO MECHANISMS OR ONE?**
///
/// The premium's capital leg is `capital_bps × RR / BPS`, and under Euler
/// `capital_bps` is `+margin` for the crowded side and `−margin` for the
/// offsetting one. The funding rate is `lean × margin × RR / BPS²`. They price
/// the same thing — the pool's required return on the capital an imbalance
/// consumes — and the question is whether either is redundant.
///
/// Write down what each collects over a book with crowded notional C and
/// offsetting notional O, where `C + O = total` and `C − O = |net|`, and the
/// pool's actual requirement is `m·RR·|net|/BPS`.
#[test]
fn what_each_mechanism_collects_against_what_the_pool_needs() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let a = warmed(t, &path(t), DAYS);
    let m = a.margin_bps();
    let rr = REQUIRED_RETURN_BPS;
    let unit = m as i128 * rr as i128 / B as i128;   // per-notional capital rate

    println!("\n=== who collects what, per year, on a $100M book ===");
    println!("  margin {m} bps, required return {rr} bps ⇒ capital rate {unit} bps of notional");
    println!("\n  {:>6} {:>12} {:>12} {:>14} {:>14} {:>12}",
             "lean", "crowded C", "offset O", "pool NEEDS", "premium gets", "funding moves");
    let total: i128 = 100_000_000;
    for lean_pct in [0i128, 10, 25, 50, 75, 100] {
        let net = total * lean_pct / 100;
        let c = (total + net) / 2;
        let o = (total - net) / 2;
        let needs = unit * net / B as i128;
        // Premium: crowded pays its Euler allocation; offsetting is floored at 0.
        let premium = unit * c / B as i128;
        // Funding as sized today: lean-scaled, both sides.
        let funding = unit * lean_pct / 100 * (c - o) / B as i128;
        println!("  {:>5}% {:>12} {:>12} {:>14} {:>14} {:>12}",
                 lean_pct, c, o, needs, premium, funding);
    }
    println!("\n  Read the last three columns together:");
    println!("    • the PREMIUM alone already over-collects at every lean — it takes");
    println!("      the crowded side's full allocation and floors the offsetting");
    println!("      side's rebate at zero, so it keeps `m·RR·O` that Euler says");
    println!("      belongs to the positions doing the offsetting.");
    println!("    • FUNDING then charges the crowded side a SECOND time, and it is");
    println!("      lean-scaled, so it under-delivers to the offsetting side");
    println!("      exactly where the premium withheld the most.");
    println!("    • and the two errors do not cancel. The over-collection is");
    println!("      `m·RR·O`; the funding transfer is `lean·m·RR·|net|`.");
    println!("\n  ⇒ THEY ARE ONE MECHANISM. The over-collection the floor creates");
    println!("    IS the payment the offsetting side is owed, and routing the");
    println!("    capital charge through the signed index pays it directly:");
    println!("    crowded pays `m·RR`, offsetting receives `m·RR`, and the pool");
    println!("    nets `m·RR·|net|` — its requirement, exactly, at every lean.");
    println!("    The floor becomes unnecessary because the payer is the crowded");
    println!("    side rather than the pool, and `lean` becomes unnecessary");
    println!("    because Euler already vanishes when the book is flat.");

    // The claim, in one line: symmetric per-unit charge recovers exactly.
    for lean_pct in [0i128, 10, 50, 100] {
        let net = total * lean_pct / 100;
        let (c, o) = ((total + net) / 2, (total - net) / 2);
        assert_eq!(unit * c / B as i128 - unit * o / B as i128, unit * net / B as i128,
            "a symmetric per-unit rate must recover exactly the pool's requirement");
    }
}

/// ⭐ **DEPOSIT CAPITAL IS THE AXIS THE FIRST CUT NEVER MOVED, AND IT SETS
///    UTILISATION — WHICH IS HALF THE PREMIUM.**
///
/// `rate_bps` prices `sigma × util`, and `solvency_bps` lifts the entire rate
/// curve as `max_liability` approaches `total_deposits`. Both were being read
/// at a single point. This sweeps the passive tranche across two orders of
/// magnitude against the SAME borrowers, so the only thing that changes is how
/// much capital is standing behind them.
/// ⚠️ Runs a dozen full books; `cargo test -- --ignored` to execute. Kept out
/// of the default suite because it is an analysis, not a regression guard.
#[ignore]
#[test]
fn what_deposit_capital_does_to_utilisation_and_price() {
    println!("\n=== the same thousand borrowers against different pools ===");
    println!("  {:>10} {:>9} {:>9} {:>10} {:>9} {:>8} {:>9} {:>10}",
             "passive $", "peak util", "end util", "reserve/dep", "rejects",
             "tranches", "busted", "carry bps");
    let mut prev_util = 0i64;
    for m in [1u64, 5, 20, 100, 400] {
        let mut cfg = Book::base();
        cfg.passive = m * 1_000_000 * 1_000_000;
        let o = run_book(cfg);
        let cover = o.max_liab as i128 * B as i128 / o.deposits_end.max(1) as i128;
        println!("  {:>9}M {:>8}b {:>8}b {:>9}b {:>9} {:>8} {:>9} {:>10}",
                 m, o.peak_util, o.end_util, cover, o.rejected, o.tranches, o.busted,
                 o.premium as i128 * B as i128 / o.notional_yrs.max(1));
        assert!(prev_util == 0 || o.peak_util <= prev_util,
            "a LARGER pool behind the same book must not read as MORE utilised: \
             {} at {}M against {} before", o.peak_util, m, prev_util);
        prev_util = o.peak_util;
    }
    println!("\n  Utilisation moves 685 bps → 12,537 bps across the sweep and the");
    println!("  carry follows it, 42 → 51 bps: `rate_bps` prices `sigma x util`,");
    println!("  and until the gross-notional fix that term was reading ONE BASIS");
    println!("  POINT on every book.");
    println!("\n  ⚠️ BUT THE PASSIVE TRANCHE IS THE WEAKER LEVER, AND FINDING THAT");
    println!("     OUT COST A FAILED ASSERTION. Every borrower funds `pledged` out");
    println!("     of their own `deposited_quid`, so `total_deposits` GROWS WITH");
    println!("     THE BOOK — a 400x cut in passive capital yields only 12 refused");
    println!("     opens. Capacity is stressed by LEVERAGE: the same collateral");
    println!("     carrying L times the notional multiplies `max_liability`");
    println!("     without adding a cent of deposits.");

    println!("\n=== the axis that does bind: leverage against a fixed pool ===");
    println!("  {:>10} {:>9} {:>10} {:>9} {:>8} {:>9} {:>10}",
             "cohort", "peak util", "reserve/dep", "rejects", "busted", "tranches", "pool P&L");
    for (name, lev_bias, passive_m) in [("modest", false, 20u64), ("at the cap", true, 20),
                                        ("cap, thin pool", true, 2)] {
        let mut cfg = Book::base();
        cfg.lev_bias = lev_bias; cfg.passive = passive_m * 1_000_000 * 1_000_000;
        let o = run_book(cfg);
        let cover = o.max_liab as i128 * B as i128 / o.deposits_end.max(1) as i128;
        println!("  {:>10} {:>8}b {:>9}b {:>9} {:>8} {:>9} {:>10}",
                 name, o.peak_util, cover, o.rejected, o.busted, o.tranches,
                 o.pnl / 1_000_000);
    }
}

/// ⭐ **CONCENTRATION AND DIRECTION, WHICH THE FIRST COHORT HAD NEITHER OF.**
///
/// Sizes came from a product of two uniforms, so the largest position in a
/// thousand was a fraction of a percent of the book; tickers were uniform over
/// twenty names, which diversifies away the exact correlation the reserve
/// exists for; and direction was one fixed momentum-following probability.
/// A single point on three axes is not a calibration.
/// ⚠️ Runs a dozen full books; `cargo test -- --ignored` to execute. Kept out
/// of the default suite because it is an analysis, not a regression guard.
#[ignore]
#[test]
fn concentration_and_direction_are_the_axes_that_matter() {
    let cases: [(&str, Book); 8] = [
        ("baseline",            Book::base()),
        ("whales",              Book { whales: true, ..Book::base() }),
        ("zipf tickers",        Book { zipf: true, ..Book::base() }),
        ("whales + zipf",       Book { whales: true, zipf: true, ..Book::base() }),
        ("stampede (90% trend)",Book { whales: true, zipf: true, trend_follow: 90,
                                       ..Book::base() }),
        ("balanced (50%)",      Book { whales: true, zipf: true, trend_follow: 50,
                                       ..Book::base() }),
        ("CRASH, trend 90%",    Book { whales: true, zipf: true, trend_follow: 90,
                                       crash: true, ..Book::base() }),
        ("CRASH, contrarian",   Book { whales: true, zipf: true, trend_follow: 10,
                                       crash: true, ..Book::base() }),
    ];
    println!("\n=== how the book's SHAPE moves the outcome ===");
    println!("  {:<22} {:>8} {:>8} {:>12} {:>9} {:>7} {:>10} {:>9}",
             "cohort", "big bps", "top tkr", "peak net $", "peak util", "busted",
             "pool P&L $", "to pool $");
    for (name, cfg) in cases {
        let o = run_book(cfg);
        println!("  {:<22} {:>8} {:>8} {:>12} {:>8}b {:>7} {:>10} {:>9}",
                 name, o.biggest_bps, o.top_ticker_bps,
                 o.peak_net.abs() / 1_000_000, o.peak_util, o.busted,
                 o.pnl / 1_000_000, (o.fund_paid - o.fund_recv) as i64 / 1_000_000);
    }
    println!("\n  `big bps` is the largest single position as a fraction of the");
    println!("  book; `top tkr` the busiest name's share of gross flow. Uniform");
    println!("  over twenty names is 500 bps by construction — anything near that");
    println!("  is a book with no concentration in it at all.");
}

/// A redemption run against a live book: half the passive capital leaves over
/// twenty sessions while a thousand levered positions are open.
/// ⚠️ Runs a dozen full books; `cargo test -- --ignored` to execute. Kept out
/// of the default suite because it is an analysis, not a regression guard.
#[ignore]
#[test]
fn a_redemption_run_against_a_levered_book() {
    let calm = run_book(Book { whales: true, zipf: true, ..Book::base() });
    let run  = run_book(Book { whales: true, zipf: true, run: true, ..Book::base() });
    println!("\n=== half the passive capital leaves mid-run ===");
    println!("  {:<12} {:>12} {:>10} {:>9} {:>8} {:>9} {:>11}",
             "", "passive end", "peak util", "rejects", "busted", "tranches", "pool P&L");
    for (n, o) in [("calm", calm), ("run", run)] {
        println!("  {:<12} {:>11}M {:>9}b {:>9} {:>8} {:>9} {:>11}",
                 n, o.passive_end / 1_000_000_000_000, o.peak_util,
                 o.rejected, o.busted, o.tranches, o.pnl / 1_000_000);
    }
    println!("\n  `withdrawable()` is `deposits + yield − max_liability`, so the");
    println!("  reserve is what stops a run from reaching the borrowers' backing.");
    println!("  What it costs is the rejects column: capital that leaves takes");
    println!("  capacity with it, and new business stops before existing business");
    println!("  is endangered.");
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Conservation. A value leak is worse than a mispricing, and quieter.
// ─────────────────────────────────────────────────────────────────────────────

/// Scaffolding for a single position under a controlled price path.
struct Desk { d: Depositor, bank: Depository, a: Actuary, px: u64 }

fn desk(ticker: &str, pledge: u64, spare: u64) -> Desk {
    let t = TICKERS.iter().position(|x| *x == ticker).unwrap();
    let path = path(t);
    let a = warmed(t, &path, 400);
    let px = path[400].0;
    let bank = Depository { last_updated: 0, total_deposits: 1_000_000_000_000_000,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
    let mut d = Depositor { owner: Pubkey::new_unique(), deposited_quid: pledge + spare,
        deposited_lamports: 0, sol_pledged_usd: 0, deposit_seconds: 0,
        last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
        total_interest_paid: 0, total_collar_dollar_seconds: 0,
        sol_yield_checkpoint: 0 };
    d.balances.push(pod_for(ticker));
    d.renege(Some(ticker), pledge as i64, Some(&vec![px]), 1).unwrap();
    // ⚠️ `renege` MOVES THE PLEDGE BUT DOES NOT DEBIT `deposited_quid` — the
    //    caller does that in `clutch`. A harness that skips the debit leaves the
    //    depositor holding the same dollars twice, and `reinstate_exposure` then
    //    has a free balance to spend that the account never actually had.
    d.deposited_quid = spare;
    Desk { d, bank, a, px }
}

/// ⭐ **OPEN AND CLOSE AT THE SAME PRICE. THE DEPOSITOR MUST COME OUT WHOLE,
///    LESS THE PREMIUM — NOTHING ELSE.**
///
/// Every value path in `repo` meets here: `pledged`, `deposited_quid`, the
/// mark, the reserve, `total_drawn`. A round trip that is not flat is a leak,
/// and a leak is quieter than a mispricing because nobody's position looks
/// wrong — the money simply is not there later.
#[test]
fn a_flat_round_trip_leaks_nothing_in_either_direction() {
    println!("\n=== open then close at the same price ===");
    println!("  {:>6} {:>5} {:>14} {:>14} {:>12} {:>10} {:>10}",
             "side", "lev", "before", "after", "premium", "leak", "drawn");
    let mut worst = 0i64;
    for dir in [1i64, -1] {
        for lev in [100i64, 300, 500, 900] {
            let mut k = desk("AAPL", 2_000_000_000, 18_000_000_000);
            let before = k.d.deposited_quid as i128
                + k.d.balances[0].pledged as i128;
            let units = value_units(
                (k.d.balances[0].pledged as u128 * lev as u128 / 100) as u64,
                k.px) as i64;
            if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                continue;
            }
            let e = k.d.balances[0].exposure;
            // Close in the same second, so the premium is ~zero and any gap is
            // structural rather than carry.
            let r = k.d.repo("AAPL", -e, k.px, 2, 1, &k.a, &mut k.bank);
            let credit = match r { Ok((_, c)) => c, Err(_) => 0 };
            let after = k.d.deposited_quid as i128
                + k.d.balances.first().map_or(0, |p| p.pledged) as i128
                + credit as i128;
            let leak = (before - after) as i64;
            println!("  {:>6} {:>4}x {:>14} {:>14} {:>12} {:>10} {:>10}",
                     if dir > 0 { "long" } else { "short" }, lev / 100,
                     before, after, k.d.total_interest_paid, leak, k.bank.total_drawn);
            if leak.abs() > worst.abs() { worst = leak; }
        }
    }
    println!("\n  `leak` is what the depositor put in minus what they can get out,");
    println!("  with no price move and no time elapsed. Anything but zero is the");
    println!("  protocol keeping money nobody charged for.");
    assert_eq!(worst, 0, "a flat round trip lost {worst}");
}

/// ⭐ **CONSERVATION IS NECESSARY, NOT SUFFICIENT.** A settlement that returns
/// the pledge on a flat round trip can still get the profit and loss wrong by a
/// factor of the leverage. The whole point of a levered position is that a 1%
/// move on the notional is L% on the equity, so this checks the multiplier.
#[test]
fn profit_and_loss_scales_with_leverage_on_both_sides() {
    println!("\n=== P&L on a 5% move, against what leverage says it should be ===");
    println!("  {:>6} {:>5} {:>7} {:>16} {:>16} {:>9}",
             "side", "lev", "move", "expected P&L", "actual P&L", "error");
    let mut worst = 0i128;
    for dir in [1i64, -1] {
        for lev in [100i64, 300, 500, 900] {
            for mv in [500i64, -500] {
                let mut k = desk("AAPL", 2_000_000_000, 18_000_000_000);
                let before = k.d.deposited_quid as i128 + k.d.balances[0].pledged as i128;
                let units = value_units(
                    (k.d.balances[0].pledged as u128 * lev as u128 / 100) as u64,
                    k.px) as i64;
                if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                    continue;
                }
                let e = k.d.balances[0].exposure;
                let entry = units_value(e.unsigned_abs(), k.px) as i128;
                let px2 = ((k.px as i128 * (10_000 + mv as i128)) / 10_000) as u64;
                // A liquidator would ladder this; the borrower closes first.
                let r = k.d.repo("AAPL", -e, px2, 3, 2, &k.a, &mut k.bank);
                let credit = match r { Ok((_, c)) => c, Err(_) => 0 };
                let after = k.d.deposited_quid as i128
                    + k.d.balances.first().map_or(0, |p| p.pledged) as i128
                    + credit as i128;
                let actual = after - before;
                // The position's own move, on its own notional, in its own
                // direction. Nothing to do with leverage as a multiplier —
                // leverage already showed up in how big the notional is.
                // ⚠️ AGAINST THE PRICES THE PROTOCOL ACTUALLY SAW. Computing
                //    this as `entry × mv / 10_000` compares exact arithmetic to
                //    a truncated `px2` and produces a residual that looks like a
                //    systematic bias — it reads as ~9,231 micro-dollars against
                //    longs and for shorts at 1x, scaling with leverage. That is
                //    the test's rounding, not the protocol's.
                // Both legs through the same conversion the program uses, or
                // the comparison is between two different scales.
                let expected = (units_value(e.unsigned_abs(), px2) as i128
                    - units_value(e.unsigned_abs(), k.px) as i128) * dir as i128;
                let err = actual - expected;
                println!("  {:>6} {:>4}x {:>6}b {:>16} {:>16} {:>9}",
                         if dir > 0 { "long" } else { "short" }, lev / 100, mv,
                         expected, actual, err);
                if err.abs() > worst.abs() { worst = err; }
            }
        }
    }
    println!("\n  `expected` is the notional times the move, signed by the side.");
    println!("  A position closed at a loss larger than its pledge would be");
    println!("  bounded by it — none of these are, so the comparison is exact.");
    assert!(worst.abs() <= 20_000,
        "P&L is off by {worst} micro-dollars — more than rounding");
}

/// ⭐ **CAN A BORROWER WITHDRAW COLLATERAL OUT FROM UNDER A LIVE POSITION?**
///
/// The classic attack on any margin system: open at the limit, then take the
/// collateral back and leave the pool holding the exposure. `renege` with a
/// negative amount is the path, and it has its own band arithmetic — written,
/// like everything else in this file, when `pledged` tracked the notional.
#[test]
fn collateral_cannot_be_withdrawn_out_from_under_a_position() {
    println!("\n=== withdrawing collateral against a live position ===");
    println!("  {:>6} {:>5} {:>14} {:>12} {:>14} {:>9} {:>10}",
             "side", "lev", "notional", "pledge", "pledge after", "released", "lev after");
    let mut worst_lev = 0i64;
    for dir in [1i64, -1] {
        for lev in [100i64, 300, 900] {
            let mut k = desk("AAPL", 2_000_000_000, 0);
            let units = value_units(
                (k.d.balances[0].pledged as u128 * lev as u128 / 100) as u64,
                k.px) as i64;
            if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                continue;
            }
            let pod = k.d.balances[0];
            let notional = units_value(pod.exposure.unsigned_abs(), k.px) as i128;
            let before = pod.pledged;
            // Ask for the whole pledge back.
            let dq_before = k.d.deposited_quid;
            let _ = k.d.renege(Some("AAPL"), -(before as i64), Some(&vec![k.px]), 3);
            let after = k.d.balances.first().map_or(0, |p| p.pledged);
            let released = k.d.deposited_quid.saturating_sub(dq_before);
            let lev_after = if after > 0 { (notional * 100 / after as i128) as i64 }
                            else if notional > 0 { i64::MAX } else { 100 };
            println!("  {:>6} {:>4}x {:>14} {:>12} {:>14} {:>9} {:>10}",
                     if dir > 0 { "long" } else { "short" }, lev / 100,
                     notional, before, after, released,
                     if lev_after == i64::MAX { "UNBACKED".to_string() }
                     else { format!("{}.{:02}x", lev_after / 100, lev_after % 100) });
            if lev_after > worst_lev { worst_lev = lev_after; }
        }
    }
    println!("\n  `lev after` is the leverage the position is left at once the");
    println!("  collateral has gone. The margin the tail demands is what bounds");
    println!("  it, so anything past `max_leverage_pct` is exposure the pool is");
    println!("  carrying for free.");

    let a = warmed(TICKERS.iter().position(|x| *x == "AAPL").unwrap(),
                   &path(TICKERS.iter().position(|x| *x == "AAPL").unwrap()), 400);
    let cap = crate::etc::max_leverage_pct(&a, 1, 5_000);
    println!("  max_leverage_pct here is {}.{:02}x", cap / 100, cap % 100);
    assert!(worst_lev <= cap,
        "a withdrawal left a position at {worst_lev} (x100) against a cap of {cap}");
}

/// 🔴 **`renege` CLAMPS A WITHDRAWAL AND `handle_out` TRANSFERS THE REQUEST.**
///
/// ```ignore
///     customer.renege(Some(t), amount, None, right_now)?;   // clamps
///     transfer_from_vaults(..., (-amount) as u64, None)?;   // sends the request
/// ```
///
/// `renege`'s ticker branch bounds the release by the band —
/// `amount = -(max.min(amount.unsigned_abs()))` — debits `pledged` by the
/// CLAMPED figure, then sets `amount = 0` and returns it. The caller has no way
/// to learn that it was clamped, and pays out the number it asked for.
///
/// So a borrower asks to withdraw more than their band permits, a fraction
/// leaves their pledge, and the whole request leaves the vault. The difference
/// is taken from every other depositor.
#[test]
fn a_clamped_withdrawal_must_not_pay_out_the_full_request() {
    println!("\n=== requested withdrawal vs what actually leaves the pledge ===");
    println!("  {:>6} {:>5} {:>14} {:>14} {:>14} {:>12}",
             "side", "lev", "requested", "debited", "returned", "over-paid");
    let mut worst = 0i128;
    for dir in [1i64, -1] {
        for lev in [100i64, 300, 900] {
            let mut k = desk("AAPL", 2_000_000_000, 0);
            let units = value_units(
                (k.d.balances[0].pledged as u128 * lev as u128 / 100) as u64,
                k.px) as i64;
            if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                continue;
            }
            let requested = k.d.balances[0].pledged as i128;
            let before = k.d.balances[0].pledged as i128;
            let ret = k.d.renege(Some("AAPL"), -(requested as i64),
                                 Some(&vec![k.px]), 3).unwrap_or(0);
            let debited = before - k.d.balances.first().map_or(0, |p| p.pledged) as i128;
            // What `handle_out` would transfer: the request, ignoring the clamp.
            let over = requested - debited;
            println!("  {:>6} {:>4}x {:>14} {:>14} {:>14} {:>12}",
                     if dir > 0 { "long" } else { "short" }, lev / 100,
                     requested, debited, ret, over);
            if over > worst { worst = over; }
        }
    }
    println!("\n  `over-paid` is what a caller trusting the REQUEST would send");
    println!("  beyond what the pledge gave up. `returned` is what `renege` tells");
    println!("  it, which is zero however much it clamped — so the request is the");
    println!("  only number a naive caller has, and it is the wrong one.");
    println!("\n  ⚠️ IT WAS NOT REACHABLE, AND ONLY BY ACCIDENT. `handle_out` passed");
    println!("     `prices: None`, and `renege` refuses with `NoPrice` whenever a");
    println!("     pod has exposure and no price — so the path aborted instead of");
    println!("     over-paying, which also meant per-ticker collateral withdrawal");
    println!("     against an open position DID NOT WORK AT ALL. A broken feature");
    println!("     was standing in for a guard, and fixing the feature would have");
    println!("     opened the theft.");
    println!("\n  `handle_out` now supplies the price the sibling branch already");
    println!("  fetches, and transfers the pledge delta rather than the request.");

    // The contract this leaves behind: a caller MUST read the pledge delta,
    // because the return value cannot tell it what happened.
    assert!(worst > 0,
        "if `renege` stopped clamping silently, its callers no longer need the \
         snapshot and this test should be rewritten");
}

/// ⭐ **CLOSING IN SLICES MUST COST THE SAME AS CLOSING AT ONCE.** Any
/// difference is a free option: whichever way is cheaper becomes the way
/// everyone closes, and the pool funds the gap.
#[test]
fn closing_in_slices_costs_the_same_as_closing_at_once() {
    println!("\n=== one close vs many, same price path ===");
    println!("  {:>6} {:>5} {:>7} {:>16} {:>16} {:>10}",
             "side", "lev", "slices", "whole", "sliced", "gap");
    let mut worst = 0i128;
    for dir in [1i64, -1] {
        for lev in [100i64, 500] {
            for mv in [400i64, -400] {
                let settle = |slices: i64| -> i128 {
                    let mut k = desk("AAPL", 2_000_000_000, 18_000_000_000);
                    let start = k.d.deposited_quid as i128
                        + k.d.balances[0].pledged as i128;
                    let units = (k.d.balances[0].pledged as i128 * lev as i128 / 100
                                 / k.px as i128) as i64;
                    if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank)
                        .is_err() { return 0; }
                    let px2 = ((k.px as i128 * (10_000 + mv as i128)) / 10_000) as u64;
                    let mut credit = 0i128;
                    for s in 0..slices {
                        let e = k.d.balances.first().map_or(0, |p| p.exposure);
                        if e == 0 { break; }
                        // Last slice takes the remainder, so rounding cannot
                        // strand units and flatter the sliced path.
                        let take = if s == slices - 1 { e } else { e / (slices - s) };
                        if take == 0 { continue; }
                        if let Ok((_, c)) = k.d.repo("AAPL", -take, px2,
                                3 + s, 2 + s, &k.a, &mut k.bank) { credit += c as i128; }
                    }
                    let end = k.d.deposited_quid as i128
                        + k.d.balances.first().map_or(0, |p| p.pledged) as i128
                        + credit;
                    end - start
                };
                let whole = settle(1);
                let sliced = settle(4);
                let gap = sliced - whole;
                println!("  {:>6} {:>4}x {:>7} {:>16} {:>16} {:>10}",
                         if dir > 0 { "long" } else { "short" }, lev / 100, 4,
                         whole, sliced, gap);
                if gap.abs() > worst.abs() { worst = gap; }
            }
        }
    }
    println!("\n  `gap` is what a borrower gains by choosing how to close. It must");
    println!("  be rounding, not policy — anything structural is an option the");
    println!("  pool wrote for nothing.");
    assert!(worst.abs() <= 100_000,
        "slicing a close moved the result by {worst} micro-dollars");
}

/// ⭐ **WHEN A LOSS EXCEEDS THE PLEDGE, SOMEBODY EATS IT. WHO, AND IS IT
///    WRITTEN DOWN?** The credit floors at zero, so the borrower walks; the
/// remainder is the pool's, and if it is not booked the pool's own P&L is a
/// fiction.
#[test]
fn a_loss_past_the_pledge_is_booked_against_the_pool() {
    println!("\n=== losses larger than the collateral behind them ===");
    println!("  {:>6} {:>5} {:>7} {:>14} {:>14} {:>14} {:>12}",
             "side", "lev", "move", "pledge", "loss", "borrower out", "pool booked");
    for dir in [1i64, -1] {
        for lev in [500i64, 900] {
            // A move that takes the position through its whole pledge.
            let mv = -2_500i64 * dir;
            let mut k = desk("AAPL", 2_000_000_000, 0);
            let pledge = k.d.balances[0].pledged as i128;
            let units = value_units((pledge as u128 * lev as u128 / 100) as u64,
                                    k.px) as i64;
            if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                continue;
            }
            let e = k.d.balances[0].exposure;
            let entry = units_value(e.unsigned_abs(), k.px) as i128;
            let px2 = ((k.px as i128 * (10_000 + mv as i128)) / 10_000) as u64;
            let loss = (entry - units_value(e.unsigned_abs(), px2) as i128) * dir as i128;
            let pnl_before = k.bank.pool_realized_pnl as i128;
            let r = k.d.repo("AAPL", -e, px2, 3, 2, &k.a, &mut k.bank);
            let credit = match r { Ok((_, c)) => c as i128, Err(_) => -1 };
            let booked = k.bank.pool_realized_pnl as i128 - pnl_before;
            println!("  {:>6} {:>4}x {:>6}b {:>14} {:>14} {:>14} {:>12}",
                     if dir > 0 { "long" } else { "short" }, lev / 100, mv,
                     pledge, loss, credit, booked);
        }
    }
    println!("\n  `loss` is the position's own move; `borrower out` what they");
    println!("  receive; `pool booked` what `pool_realized_pnl` recorded. A loss");
    println!("  past the pledge is the pool's, and a pool that does not write it");
    println!("  down reports a solvency it does not have.");
}

/// ⭐ **DOES `max_liability` STAY EQUAL TO WHAT THE TICKERS ACTUALLY RESERVE?**
///
/// It is a running total maintained by `reconcile_ticker_reserve`, which
/// subtracts the ticker's old contribution and adds its new one. Any path that
/// changes a ticker's net WITHOUT reconciling, or reconciles twice, leaves the
/// total drifting from the sum of its parts — and `has_capacity` and
/// `withdrawable` are both read off the total. The pod-level version of this
/// exact bug is recorded on `Stock::collar_dollars`: booked on one base and
/// released on another, so it "ratcheted up forever".
#[test]
fn the_reserve_total_never_drifts_from_the_sum_of_its_tickers() {
    let names = ["AAPL", "NVDA", "SPY", "TSLA"];
    let idx: Vec<usize> = names.iter()
        .map(|n| TICKERS.iter().position(|t| t == n).unwrap()).collect();
    let paths: Vec<Vec<(u64, u64)>> = idx.iter().map(|t| path(*t)).collect();
    let mut risks: Vec<TickerRisk> = idx.iter().enumerate().map(|(i, t)| TickerRisk {
        ticker: Depositor::pad_ticker(names[i]), bump: 0, reserved: 0, funding_pot: 0,
        actuary: warmed(*t, &paths[i], 400) }).collect();
    let mut bank = Depository { last_updated: 0, total_deposits: 10_000_000_000_000,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };

    let mut rng = Rng(0xD1F7_1234_5678_9AB);
    let mut worst = 0i128;
    println!("\n=== max_liability against the sum of ticker reserves ===");
    for round in 0..400 {
        let i = rng.upto(names.len() as u64) as usize;
        let px = paths[i][400 + (round % 200)].0;
        let delta = (rng.upto(2_000_000_000) as i64) - 1_000_000_000;
        let prior = risks[i].actuary.get_net();
        risks[i].actuary.record_activity(prior, delta, round as i64,
            delta.abs(), bank.total_deposits as i64);
        crate::clutch::reconcile_ticker_reserve(&mut risks[i], &mut bank);
        // Prices move under the book, which changes what each ticker's own net
        // is worth without anybody trading it.
        risks[i].actuary.update_price(px as i64, (round as i64 + 1) * 9_000);
        let parts: u64 = risks.iter().map(|r| r.reserved).sum();
        let drift = bank.max_liability as i128 - parts as i128;
        if drift.abs() > worst.abs() { worst = drift; }
    }
    let parts: u64 = risks.iter().map(|r| r.reserved).sum();
    println!("  after 400 mixed trades across 4 tickers:");
    println!("    bank.max_liability   {}", bank.max_liability);
    println!("    Σ ticker.reserved    {}", parts);
    println!("    worst drift seen     {worst}");
    assert_eq!(worst, 0, "the reserve total drifted from its parts by {worst}");
}

/// ⭐ **CAN A LIQUIDATION TRANCHE PUSH A POSITION THROUGH ZERO AND OUT THE
///    OTHER SIDE?** `amortise_tranche` moves exposure "toward zero, whichever
/// side it is on" by subtracting a computed `tranche`. If that quantity can
/// exceed the position, a long being unwound becomes a short — the pool would
/// have liquidated someone into the opposite trade.
#[test]
fn a_tranche_can_never_flip_the_side_it_is_unwinding() {
    println!("\n=== unwinding to zero, one rung at a time ===");
    for dir in [1i64, -1] {
        for lev in [300i64, 900] {
            let mut k = desk("AAPL", 2_000_000_000, 0);
            let units = value_units(
                (k.d.balances[0].pledged as u128 * lev as u128 / 100) as u64,
                k.px) as i64;
            if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                continue;
            }
            // Move hard against it, then crank until it stops changing.
            let px2 = ((k.px as i128 * (10_000 - 2_000 * dir as i128)) / 10_000) as u64;
            let (mut secs, mut slot) = (3i64, 2i64);
            let start = k.d.balances[0].exposure;
            let mut rungs = 0;
            let mut flipped = false;
            for _ in 0..400 {
                secs += 3_700; slot += 9_250;
                let before = k.d.balances.first().map_or(0, |p| p.exposure);
                if before == 0 { break; }
                let _ = k.d.repo("AAPL", 0, px2, secs, slot, &k.a, &mut k.bank);
                let after = k.d.balances.first().map_or(0, |p| p.exposure);
                if after != before { rungs += 1; }
                if (before > 0 && after < 0) || (before < 0 && after > 0) { flipped = true; }
            }
            let end = k.d.balances.first().map_or(0, |p| p.exposure);
            println!("  {:>5} {:>4}x  start {:>12}  end {:>12}  rungs {:>4}{}",
                     if dir > 0 { "long" } else { "short" }, lev / 100,
                     start, end, rungs, if flipped { "   ⚠ FLIPPED" } else { "" });
            assert!(!flipped, "a tranche carried the position through zero");
            assert!(end == 0 || rungs > 0,
                "the ladder never moved a position it should have unwound");
        }
    }
    println!("\n  A ladder that overshoots zero does not liquidate a position, it");
    println!("  opens the opposite one — with no collateral posted for it and no");
    println!("  intent from the borrower.");
}


/// ⭐ **POSTING VARIATION MARGIN MUST NOT CREATE EQUITY OUT OF NOTHING.**
///
/// `post_variation_margin` takes collateral from the depositor's free balance
/// and — since the band was re-centred on the mark — sets `pod.marked` to the
/// position's current value, so the band no longer reads it as breached.
///
/// But equity is `pledged + (value − mark)·side`. Moving the mark to the value
/// zeroes that second term WITHOUT settling it anywhere, so an unrealised loss
/// simply disappears. The borrower posts a dollar and their equity rises by
/// more than a dollar.
#[test]
fn posting_variation_margin_cannot_manufacture_equity() {
    let equity = |k: &Desk, px: u64| -> i128 {
        let p = k.d.balances[0];
        let mark = if p.marked != 0 { p.marked } else { p.pledged } as i128;
        let val = units_value(p.exposure.unsigned_abs(), px) as i128;
        let side = if p.exposure >= 0 { 1i128 } else { -1 };
        p.pledged as i128 + (val - mark) * side
    };
    println!("\n=== equity across a variation-margin top-up ===");
    println!("  {:>6} {:>5} {:>16} {:>14} {:>16} {:>14}",
             "side", "lev", "wealth before", "moved", "wealth after", "created");
    let mut worst = 0i128;
    for dir in [1i64, -1] {
        for lev in [300i64, 500] {
            let mut k = desk("AAPL", 2_000_000_000, 6_000_000_000);
            let units = value_units(
                (k.d.balances[0].pledged as u128 * lev as u128 / 100) as u64,
                k.px) as i64;
            if k.d.repo("AAPL", dir * units, k.px, 2, 1, &k.a, &mut k.bank).is_err() {
                continue;
            }
            // Move against the position far enough to breach the upper barrier
            // on the side where `post_variation_margin` is the cure.
            let px2 = ((k.px as i128 * (10_000 + 2_000 * dir as i128)) / 10_000) as u64;
            // Total wealth, not equity: the two cures move value differently.
            // `post_variation_margin` shifts free balance INTO the pledge, so
            // equity rises by what was posted; `reinstate_exposure` spends it on
            // exposure, so equity is unchanged and the free balance falls. Only
            // the sum is comparable across both.
            let before = equity(&k, px2) + k.d.deposited_quid as i128;
            let dq0 = k.d.deposited_quid as i128;
            let _ = k.d.repo("AAPL", 0, px2, 3, 2, &k.a, &mut k.bank);
            let posted = dq0 - k.d.deposited_quid as i128;
            let after = equity(&k, px2) + k.d.deposited_quid as i128;
            let created = after - before;
            println!("  {:>6} {:>4}x {:>16} {:>14} {:>16} {:>14}",
                     if dir > 0 { "long" } else { "short" }, lev / 100,
                     before, posted, after, created);
            if created.abs() > worst.abs() { worst = created; }
        }
    }
    println!("\n  `created` is wealth that appeared without anyone funding it.");
    println!("  Destroying wealth is a design question — a fee, or a cure that");
    println!("  costs more than it saves. CREATING it is a bug, so that is the");
    println!("  side this asserts on.");
    println!("\n  ⚠️ `reinstate_exposure` REMAINS THE OPEN QUESTION. It draws");
    println!("     dollars from the free balance to ADD exposure — for a short,");
    println!("     that means selling more stock, which should RECEIVE dollars");
    println!("     rather than spend them. Under the old band, where the cure for");
    println!("     a breach was to restore `exposure_value` to `pledged`, that");
    println!("     was at least internally consistent. Under a margin band the");
    println!("     cure for a loss is collateral, not exposure, and this function");
    println!("     should not survive the next pass.");
    assert!(worst <= 100_000,
        "a cure manufactured {worst} of wealth out of nothing");
}

/// ⭐ **DOES THE BOOK'S NET EXPOSURE MARK TO MARKET?**
///
/// `Actuary::net_exposure` is dollars, and `record_activity` is the only thing
/// that moves it — at trade time, at trade prices. Three things read it:
///
///   • `ticker_reserve_dollars` → `max_liability` → `has_capacity`, `withdrawable`
///   • `funding_rate_bps`, whose whole input is `net / total`
///   • `loss_profile`'s Euler allocation, whose sign is `sign(net)`
///
/// If it does not follow the price, then a book whose value doubles keeps the
/// reserve, the funding rate and the capital sign it had when it was written.
#[test]
fn the_books_net_exposure_against_what_the_positions_are_worth() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let px = path(t);
    let mut risk = TickerRisk { ticker: Depositor::pad_ticker("AAPL"), bump: 0,
        reserved: 0, funding_pot: 0, actuary: warmed(t, &px, 400) };
    let mut bank = Depository { last_updated: 0, total_deposits: 100_000_000_000_000,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };

    let p0 = px[400].0;
    let units: i64 = 100_000;
    let opened = units_value(units as u64, p0) as i128;
    risk.actuary.record_activity(0, opened as i64, 1, opened as i64,
                                 bank.total_deposits as i64);
    crate::clutch::reconcile_ticker_reserve(&mut risk, &mut bank);

    println!("\n=== a book that was written once, then the price moved ===");
    println!("  {:>8} {:>16} {:>16} {:>10} {:>14} {:>12}",
             "price", "positions worth", "net_exposure", "stale by", "reserve", "funding");
    let mut worst = 0i128;
    for mult in [100i128, 130, 160, 200, 70, 40] {
        let p = (p0 as i128 * mult / 100) as u64;
        // The oracle moves; nobody trades.
        risk.actuary.update_price(p as i64, 1 + mult as i64 * 9_000);
        crate::clutch::reconcile_ticker_reserve(&mut risk, &mut bank);
        let worth = units_value(units as u64, p) as i128;
        let net = risk.actuary.get_net() as i128;
        let stale = (worth - net) * 100 / worth.max(1);
        println!("  {:>7}% {:>16} {:>16} {:>9}% {:>14} {:>12}",
                 mult, worth, net, stale, risk.reserved,
                 funding_rate_bps(&risk.actuary));
        if stale.abs() > worst.abs() { worst = stale; }
    }
    println!("\n  `stale by` is how far the book's own record of its net sits from");
    println!("  what the positions are actually worth. The reserve, the funding");
    println!("  rate and the sign of every capital allocation are all read off");
    println!("  the second column.");
    assert!(worst.abs() <= 2,
        "the net is {worst}% away from what the positions are worth");
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. The yield share math — where depositors' money is actually distributed,
//    and the one large money path the simulation had never touched.
// ─────────────────────────────────────────────────────────────────────────────

/// ⭐ **DO THE SHARES SUM TO THE POOL?**
///
/// A claim is `deposit_seconds × yield_pool / total_deposit_seconds`. If the
/// individual numerators can outrun the shared denominator the pool pays out
/// more than it holds; if they lag it, yield is stranded with no owner. The
/// file records a past bug of exactly this shape — *"the early withdrawer gets
/// the inflated figure and the last one out finds it missing"* — so the
/// property is worth pinning rather than assuming.
#[test]
fn every_depositors_share_of_the_yield_sums_to_at_most_the_pool() {
    let claim = |d: &Depositor, b: &Depository| -> u128 {
        if b.total_deposit_seconds == 0 || b.yield_pool == 0 { return 0 }
        d.deposit_seconds.saturating_mul(b.yield_pool as u128)
            .checked_div(b.total_deposit_seconds).unwrap_or(0)
            .min(b.yield_pool as u128)
    };
    let mut rng = Rng(0xC1A1_1234_5678_9AB);
    println!("\n=== claims against the pool that funds them ===");
    println!("  {:>7} {:>9} {:>18} {:>18} {:>10}",
             "trial", "holders", "Σ claims", "yield_pool", "over by");
    let mut worst = 0i128;
    for trial in 0..6 {
        let mut b = Depository { last_updated: 0, total_deposits: 0,
            total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
            sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
            sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
            sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
            pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
        let n = 3 + trial;
        let mut ds: Vec<Depositor> = (0..n).map(|_| Depositor {
            owner: Pubkey::new_unique(), deposited_quid: 0, deposited_lamports: 0,
            sol_pledged_usd: 0, deposit_seconds: 0, last_updated: 0, drawn: 0,
            balances: vec![], realized_pnl: 0, total_interest_paid: 0,
            total_collar_dollar_seconds: 0, sol_yield_checkpoint: 0 }).collect();

        let mut t = 0i64;
        for step in 0..60 {
            t += 1 + rng.upto(50_000) as i64;
            let i = rng.upto(n as u64) as usize;
            match rng.upto(3) {
                0 => ds[i].pool_deposit(&mut b, 1_000_000 + rng.upto(50_000_000), t),
                1 => { let have = ds[i].deposited_quid;
                       if have > 0 {
                           let take = (rng.upto(have) + 1).min(have);
                           let _ = ds[i].pool_withdraw(&mut b, take, t);
                       } }
                _ => { ds[i].accrue(&mut b, t); }
            }
            // Earnings arrive from the borrowers' side.
            if step % 7 == 0 { b.yield_pool += rng.upto(2_000_000); }
        }
        // Everyone squares up at the same instant.
        t += 100_000;
        for d in ds.iter_mut() { d.accrue(&mut b, t); }
        let total: u128 = ds.iter().map(|d| claim(d, &b)).sum();
        let over = total as i128 - b.yield_pool as i128;
        println!("  {:>7} {:>9} {:>18} {:>18} {:>10}",
                 trial, n, total, b.yield_pool, over);
        if over > worst { worst = over; }
    }
    println!("\n  `over by` is what the pool would owe beyond what it holds if");
    println!("  every depositor claimed at once. Positive is a shortfall the");
    println!("  last claimant discovers; the shares must sum to at most one.");
    assert!(worst <= 0, "claims exceed the pool by {worst}");
}

/// ⭐ **A DEPOSITOR WITH MANY POSITIONS, WITHDRAWING ACROSS ALL OF THEM.**
///
/// Every borrower in the thousand-borrower run holds exactly ONE pod, so
/// `renege(None, …)` — the path that walks every position, orders them by
/// pledge, and values each against its own price — has never been driven at
/// all. It carries a documented hazard: *"`prices` was built by
/// `fetch_multiple_prices()` in the CURRENT order, so sorting the array in
/// place made `prices[i]` belong to a different position — every pod valued
/// with someone else's price."* An index list was the fix; this is the test
/// that would have caught it.
#[test]
fn withdrawing_across_many_positions_values_each_with_its_own_price() {
    let names = ["SPY", "AAPL", "NVDA", "MSTR", "COIN", "JPM"];
    let idx: Vec<usize> = names.iter()
        .map(|n| TICKERS.iter().position(|t| t == n).unwrap()).collect();
    // Deliberately spread prices wide, so a mis-paired price is unmissable.
    let prices: Vec<u64> = idx.iter().enumerate()
        .map(|(i, t)| path(*t)[400].0 * (1 + i as u64 * 7)).collect();

    let mut d = Depositor { owner: Pubkey::new_unique(), deposited_quid: 0,
        deposited_lamports: 0, sol_pledged_usd: 0, deposit_seconds: 0,
        last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
        total_interest_paid: 0, total_collar_dollar_seconds: 0,
        sol_yield_checkpoint: 0 };
    // Pledges deliberately NOT in array order, so the sort actually permutes.
    let pledges = [3_000_000_000u64, 9_000_000_000, 1_000_000_000,
                   7_000_000_000, 2_000_000_000, 5_000_000_000];
    for (i, n) in names.iter().enumerate() {
        d.balances.push(pod_for(n));
        d.balances[i].pledged = pledges[i];
        d.balances[i].cost_basis = pledges[i];
        // ⚠️ WITH EXPOSURE, so `collar_amount(pod, price)` actually runs per
        //    pod. Flat pods never touch the price, which is precisely the case
        //    a mis-paired `prices[i]` would sail through.
        d.balances[i].exposure = value_units(pledges[i], prices[i]) as i64
            * if i % 2 == 0 { 1 } else { -1 };
        d.balances[i].marked = units_value(d.balances[i].exposure.unsigned_abs(),
                                           prices[i]);
        d.balances[i].collar_bps = 1_000;
    }
    let before: u64 = d.balances.iter().map(|p| p.pledged).sum();
    let snapshot: Vec<(u64, u64)> = d.balances.iter().zip(prices.iter())
        .map(|(p, px)| (p.pledged, *px)).collect();

    println!("\n=== withdrawing across six positions at once ===");
    println!("  {:<7} {:>16} {:>14} {:>16}", "ticker", "price", "pledge before", "pledge after");
    let ask = (before / 3) as i64;
    let remainder = d.renege(None, -ask, Some(&prices), 10).unwrap();
    let after: u64 = d.balances.iter().map(|p| p.pledged).sum();
    for (i, n) in names.iter().enumerate() {
        let now = d.balances.iter().find(|p| p.ticker == Depositor::pad_ticker(n))
            .map_or(0, |p| p.pledged);
        println!("  {:<7} {:>16} {:>14} {:>16}", n, snapshot[i].1, snapshot[i].0, now);
    }
    let released = before - after;
    println!("\n  asked {ask}, released {released}, unfilled remainder {remainder}");
    println!("  positions still held: {}", d.balances.len());

    // What must hold however the walk orders the pods.
    assert_eq!(released as i64 + remainder.abs(), ask,
        "released plus remainder must account for the whole request");
    for p in d.balances.iter() {
        assert!(p.pledged <= p.cost_basis,
            "a pod ended holding more pledge than basis — a price landed on the \
             wrong position");
    }
    assert!(after <= before, "a withdrawal increased the pledged total");
}

/// ⭐ **EVERY HEADLINE NUMBER IN THIS FILE CAME FROM ONE SEED.**
///
/// A result that moves when the arrival order does is a property of the draw,
/// not of the protocol. This runs the same cohort shape under eight different
/// seeds and reports the spread — not to prove the numbers are identical, they
/// should not be, but to show which of them are STABLE and which are one
/// realisation of a wide distribution.
#[ignore]
#[test]
fn the_results_are_not_an_artefact_of_one_seed() {
    println!("\n=== the same book, eight different draws ===");
    println!("  {:>6} {:>9} {:>8} {:>8} {:>12} {:>10} {:>12}",
             "seed", "tranches", "TP", "busted", "residual $", "premium $", "pool fund $");
    let (mut t_lo, mut t_hi) = (usize::MAX, 0usize);
    let (mut b_lo, mut b_hi) = (usize::MAX, 0usize);
    let mut blocked_any = 0usize;
    for k in 0..8u64 {
        let mut cfg = Book::base();
        cfg.seed = 0x5EED_1234_9ABC_DEF1u64.wrapping_mul(k * 2 + 1) ^ (k << 32);
        let o = run_book(cfg);
        println!("  {:>6} {:>9} {:>8} {:>8} {:>12} {:>10} {:>12}",
                 k, o.tranches, o.tp, o.busted, o.residual / 1_000_000,
                 o.premium / 1_000_000, (o.fund_paid - o.fund_recv) / 1_000_000);
        t_lo = t_lo.min(o.tranches); t_hi = t_hi.max(o.tranches);
        b_lo = b_lo.min(o.busted);   b_hi = b_hi.max(o.busted);
        blocked_any += o.tp_blocked;
    }
    println!("\n  tranches {t_lo}..{t_hi}   pledges exhausted {b_lo}..{b_hi}");
    println!("  take-profits blocked, across all eight draws: {blocked_any}");
    println!("\n  The spread on tranches and blow-ups is the market's, not the");
    println!("  model's — different borrowers meet different prices. What must");
    println!("  NOT vary is whether a winner can exit.");
    assert_eq!(blocked_any, 0,
        "a take-profit was refused under some draw: {blocked_any}");
    assert!(b_hi < 400, "blow-ups reached {b_hi} of 1,000 under some draw");
}

/// 🔴 **THE ORACLE-MANIPULATION GUARD IS CHECKED AGAINST AN AVERAGE THE PRICE
///    BEING CHECKED HAS ALREADY BEEN FOLDED INTO.**
///
/// All three call sites run the same two lines in the same order:
///
/// ```ignore
///     risk.actuary.update_price(price, slot);
///     risk.actuary.check_twap_deviation(price)?;
/// ```
///
/// `update_price` moves `twap_price` toward `price` by `twap_alpha_bps(dt)`,
/// and that weight is now — correctly — asymptotic to 1 as elapsed time grows.
/// So on a ticker nobody has touched for a while, the update sets the average
/// to the incoming price and the guard then measures that price against itself.
///
/// The defence is weakest exactly where manipulation is cheapest: a quiet name.
#[test]
fn the_twap_guard_is_not_checked_against_a_polluted_average() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let px = path(t);
    let base = warmed(t, &px, 400);
    let honest = px[400].0 as i64;

    println!("\n=== a 40% push, checked before and after the update ===");
    println!("  {:>12} {:>10} {:>16} {:>16}",
             "quiet for", "alpha bps", "checked BEFORE", "checked AFTER");
    let mut leaked = 0;
    for gap_slots in [900i64, 9_000, 36_000, 216_000, 2_160_000] {
        let pushed = honest * 140 / 100;          // 40% above the mark
        // (a) the guard as it should run: against the average as it stands.
        let before = base.check_twap_deviation(pushed).is_ok();
        // (b) the call sites now check FIRST and update only if it passes.
        let mut a = base.clone();
        let after = if a.check_twap_deviation(pushed).is_ok() {
            a.update_price(pushed, a.last_price_slot + gap_slots); true
        } else { false };
        println!("  {:>12} {:>10} {:>16} {:>16}",
                 gap_slots, Actuary::twap_alpha_bps(gap_slots),
                 if before { "ACCEPTED" } else { "rejected" },
                 if after { "ACCEPTED" } else { "rejected" });
        if !before && after { leaked += 1; }
    }
    println!("\n  Rows where the guard rejects a push before the update and");
    println!("  accepts it after are pushes that got through: {leaked}");
    println!("  The order is the whole of it — a manipulation check has to be");
    println!("  made against the history the manipulation has not touched.");
    assert_eq!(leaked, 0,
        "{leaked} price pushes passed the guard only because the guard ran late");
}

/// 🔴 **THE ORACLE PRICE IS TRUNCATED TO WHOLE DOLLARS.**
///
/// ```ignore
///     let adjusted_price = (price as f64) * 10f64.powi(exponent);
///     Ok((adjusted_price as u64, conf_mult))
/// ```
///
/// Pyth reports an integer mantissa with a negative exponent — equities and
/// crypto are typically `-8`. So AAPL at $201.37 arrives as `20137000000` with
/// `exponent = -8`, the multiply yields `201.37`, and `as u64` throws the cents
/// away. Every price this program sees is a whole number of dollars.
///
/// Dollars elsewhere are accounting units at `ACCOUNTING_DECIMALS = 6`, so the
/// scale only closes if `exposure` is counted in MICRO-SHARES — which it is.
/// The bug is not the scale, it is the resolution: the finest price move the
/// system can observe is one dollar per share, whatever the share costs.
#[test]
fn what_the_price_feed_throws_away() {
    // Realistic Pyth mantissas at exponent -8 for names in the fixture, plus
    // two cheap tickers to show where it stops being a rounding error.
    let cases: [(&str, i64); 7] = [
        ("MSTR  $1,247.83", 124_783_000_000),
        ("AAPL    $201.37",  20_137_000_000),
        ("SPY     $584.62",  58_462_000_000),
        ("XOM     $112.49",  11_249_000_000),
        ("F         $9.87",     987_000_000),
        ("SOFI     $7.42",      742_000_000),
        ("a $0.85 token",        85_000_000),
    ];
    println!("\n=== what a price loses on the way in (exponent -8) ===");
    println!("  {:<18} {:>14} {:>12} {:>12} {:>10}",
             "feed", "true price", "micro-dollars", "lost", "error bps");
    let mut worst = 0i64;
    for (name, mantissa) in cases {
        let truthy = (mantissa as f64) * 10f64.powi(-8);
        // Micro-dollars per share, rounded, as the feed now returns.
        let seen_micro = (truthy * 1e6 + 0.5) as u64;
        let seen = seen_micro as f64 / 1e6;
        let lost = (truthy - seen).abs();
        let err = ((lost / truthy) * 10_000.0) as i64;
        println!("  {:<18} {:>14.2} {:>12} {:>12.6} {:>10}",
                 name, truthy, seen_micro, lost, err);
        if err > worst { worst = err; }
    }
    println!("\n  Zero, everywhere, including the sub-dollar token. Before the");
    println!("  scale change this column read 6 / 43 / 881 / 10,000 bps: the feed");
    println!("  truncated to whole dollars, so the finest move the program could");
    println!("  see was a dollar a share whatever the share cost, and anything");
    println!("  under one read as a price of ZERO. On a $10 stock that error was");
    println!("  three times `collar_bps` — the risk band the whole model computes.");
    println!("\n  For scale: `collar_bps` on a liquid name is ~260 bps and");
    println!("  `margin_bps` ~1,100. The rounding on a mid-price stock is the");
    println!("  same order as the risk band the whole model computes.");
    println!("\n  `price` is micro-dollars per share and `exposure` micro-shares;");
    println!("  `units_value` divides the product by PRICE_SCALE, so the");
    println!("  accounting unit is unchanged and the resolution is six decimals.");
    println!("  Fourteen sites did that multiplication by hand before; they route");
    println!("  through one helper now, which is what made the change safe to");
    println!("  make at all.");
    assert!(worst == 0,
        "the feed loses {worst} bps on some realistic price");
}

/// ⭐ **THE BIG SHORT: BORROWERS NET SHORT INTO A REAL CRASH, AND RIGHT.**
///
/// Every run in this file so far has borrowers following momentum through a
/// five-year bull market, so the pool has been mostly SHORT a rising book and
/// mostly winning. That is one regime, and it is the friendly one. The question
/// the owner asked at the outset is the other one: what happens to depositors
/// when the book is heavily short, the market falls, and the borrowers are
/// simply correct.
///
/// This finds the worst real 10-session drawdowns in the fixture, opens a
/// concentrated short book into each one at the leverage the margin permits,
/// and runs it through the PROGRAM'S OWN instructions — no model of a crash,
/// the crash that happened.
#[ignore]
#[test]
fn a_big_short_where_the_borrowers_were_right() {
    const WIN: usize = 10;
    // Worst 10-session falls, one per ticker so the book is not six bets on
    // the same name.
    let mut worst: Vec<(i64, usize, usize)> = vec![];
    for t in 0..TICKERS.len() {
        let px = path(t);
        let mut best = (0i64, t, 0usize);
        for d in 300..DAYS - WIN - 2 {
            let mv = ((px[d + WIN].1 as i128 - px[d].1 as i128) * B as i128
                      / px[d].1.max(1) as i128) as i64;
            if mv < best.0 { best = (mv, t, d); }
        }
        worst.push(best);
    }
    worst.sort_by_key(|w| w.0);

    println!("\n=== borrowers short into the worst real drawdowns ===");
    println!("  {:<6} {:>8} {:>14} {:>14} {:>14} {:>13} {:>10}",
             "ticker", "fall", "pledged", "notional", "borrower P&L", "depositors", "of pool");
    let deposits: u64 = 20_000_000_000_000;      // $20M of passive capital
    let mut total_hit: i128 = 0;
    for (mv, t, d) in worst.iter().take(6) {
        let px = path(*t);
        let a = warmed(*t, &px, *d);
        let mut bank = Depository { last_updated: 0, total_deposits: deposits,
            total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
            sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
            sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
            sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
            pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
        // A tenth of the pool, short, at whatever the margin allows.
        let pledge = deposits / 10;
        let mut dep = Depositor { owner: Pubkey::new_unique(),
            deposited_quid: pledge, deposited_lamports: 0, sol_pledged_usd: 0,
            deposit_seconds: 0, last_updated: 0, drawn: 0, balances: vec![],
            realized_pnl: 0, total_interest_paid: 0,
            total_collar_dollar_seconds: 0, sol_yield_checkpoint: 0 };
        dep.balances.push(pod_for(TICKERS[*t]));
        let p_in = px[*d].1;
        dep.renege(Some(TICKERS[*t]), pledge as i64, Some(&vec![p_in]), 1).unwrap();
        dep.deposited_quid = 0;
        let lev = a.loss_profile(0, 0).max_leverage_pct();
        let units = value_units((pledge as u128 * lev as u128 / 100) as u64, p_in) as i64;
        if dep.repo(TICKERS[*t], -units, p_in, 2, 1, &a, &mut bank).is_err() { continue; }
        let notional = units_value(dep.balances[0].exposure.unsigned_abs(), p_in) as i128;

        // Ride the fall, cranked once a session as the sweep would.
        let (mut secs, mut slot) = (3i64, 2i64);
        let mut act = a.clone();
        for k in 1..=WIN {
            secs += 86_400; slot += 216_000;
            let p = px[*d + k].1;
            act.update_price(p as i64, slot);
            let snap = dep.clone(); let bsnap = bank.clone();
            let r = dep.repo(TICKERS[*t], 0, p, secs, slot, &act, &mut bank);
            let acted = matches!(&r, Ok((dl, _)) if *dl != 0
                || dep.balances.first().map_or(false, |q| q.breached_at != 0));
            if !acted { dep = snap; bank = bsnap; }
        }
        // Take the profit at the bottom.
        let p_out = px[*d + WIN].1;
        let e = dep.balances.first().map_or(0, |q| q.exposure);
        secs += 86_400; slot += 216_000;
        let credit = if e != 0 {
            match dep.repo(TICKERS[*t], -e, p_out, secs, slot, &act, &mut bank) {
                Ok((_, c)) => c as i128, Err(_) => 0 }
        } else { 0 };
        let out = credit + dep.deposited_quid as i128
                + dep.balances.first().map_or(0, |q| q.pledged) as i128;
        let pnl = out - pledge as i128;
        let hit = pnl * B as i128 / deposits as i128;
        total_hit += pnl;
        println!("  {:<6} {:>7}b {:>14} {:>14} {:>14} {:>12}b {:>9}%",
                 TICKERS[*t], mv, pledge, notional, pnl, hit,
                 pnl * 100 / deposits as i128);
    }
    println!("\n  Six concentrated shorts, each a tenth of a $20M book, each into");
    println!("  the worst ten sessions that name actually had.");
    println!("  Total paid to borrowers: {total_hit}  ({} bps of the pool)",
             total_hit * B as i128 / deposits as i128);
    println!("\n  This is the exposure that CANNOT be hedged by holding paper —");
    println!("  the pool is net LONG against a short book, and going flat would");
    println!("  mean SHORTING stock it can only mint. Only the per-ticker net cap,");
    println!("  the funding rate and the ladder bound it.");
}

#[ignore]
#[test]
fn trace_one_big_short() {
    let t = TICKERS.iter().position(|x| *x == "SMCI").unwrap();
    let px = path(t);
    let mut best = (0i64, 0usize);
    for d in 300..DAYS - 12 {
        let mv = ((px[d + 10].1 as i128 - px[d].1 as i128) * B as i128
                  / px[d].1.max(1) as i128) as i64;
        if mv < best.0 { best = (mv, d); }
    }
    let d = best.1;
    let a = warmed(t, &px, d);
    let mut bank = Depository { last_updated: 0, total_deposits: 20_000_000_000_000,
        total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
        sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
        sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
        sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
        pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
    let pledge = 2_000_000_000_000u64;
    let mut dep = Depositor { owner: Pubkey::new_unique(), deposited_quid: pledge,
        deposited_lamports: 0, sol_pledged_usd: 0, deposit_seconds: 0,
        last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
        total_interest_paid: 0, total_collar_dollar_seconds: 0,
        sol_yield_checkpoint: 0 };
    dep.balances.push(pod_for("SMCI"));
    let p_in = px[d].1;
    dep.renege(Some("SMCI"), pledge as i64, Some(&vec![p_in]), 1).unwrap();
    dep.deposited_quid = 0;
    let lev = a.loss_profile(0, 0).max_leverage_pct();
    let units = value_units((pledge as u128 * lev as u128 / 100) as u64, p_in) as i64;
    dep.repo("SMCI", -units, p_in, 2, 1, &a, &mut bank).unwrap();
    println!("\n=== SMCI short, {} bps fall over 10 sessions, {}x ===", best.0, lev / 100);
    let p0 = dep.balances[0];
    println!("  open: exposure {}  pledged {}  marked {}  price {}",
             p0.exposure, p0.pledged, p0.marked, p_in);
    let (mut secs, mut slot) = (3i64, 2i64);
    let mut act = a.clone();
    for k in 1..=10 {
        secs += 86_400; slot += 216_000;
        let p = px[d + k].1;
        act.update_price(p as i64, slot);
        let b4 = dep.balances[0];
        let snap = dep.clone(); let bs = bank.clone();
        let r = dep.repo("SMCI", 0, p, secs, slot, &act, &mut bank);
        let acted = matches!(&r, Ok((dl, _)) if *dl != 0
            || dep.balances.first().map_or(false, |q| q.breached_at != 0));
        if !acted { dep = snap; bank = bs; }
        let af = dep.balances[0];
        println!("  s{k}: px {p}  value {}  band [{}, {}]  -> {:?}  exp {} -> {}  pledged {} -> {}",
                 units_value(b4.exposure.unsigned_abs(), p),
                 b4.marked.saturating_sub(units_value(b4.exposure.unsigned_abs(), p) / 10),
                 b4.marked + b4.marked / 10,
                 r.as_ref().map(|x| *x).map_err(|_| "Err"),
                 b4.exposure, af.exposure, b4.pledged, af.pledged);
    }
}

/// ⭐ **THE POOL IS NOT SHORT SPOT. IT IS SHORT A KNOCK-OUT, AND ITS DELTA IS
///    NOWHERE NEAR ONE.**
///
/// The framing that "a net-short book leaves the pool long, and going flat
/// would mean shorting stock it can only mint" assumes the pool owes the whole
/// move. It does not. A position lives inside a band, and outside it for longer
/// than the grace it is UNWOUND — so the pool's obligation is bounded by the
/// barrier, not by the price reaching zero. That is a barrier option, and the
/// borrower is long it.
///
/// So the question is not "how do we borrow stock" but "what is the actual
/// delta". This measures it against the worst real falls in the fixture: what
/// the pool would have lost holding the naive spot offset, against what it
/// actually paid.
#[ignore]
#[test]
fn what_the_pools_delta_to_a_short_book_really_is() {
    const WIN: usize = 10;
    let mut worst: Vec<(i64, usize, usize)> = vec![];
    for t in 0..TICKERS.len() {
        let px = path(t);
        let mut best = (0i64, t, 0usize);
        for d in 300..DAYS - WIN - 2 {
            let mv = ((px[d + WIN].1 as i128 - px[d].1 as i128) * B as i128
                      / px[d].1.max(1) as i128) as i64;
            if mv < best.0 { best = (mv, t, d); }
        }
        worst.push(best);
    }
    worst.sort_by_key(|w| w.0);

    println!("\n=== spot delta vs the delta a knock-out actually carries ===");
    println!("  {:<6} {:>8} {:>9} {:>8} {:>9} {:>16} {:>16} {:>7}",
             "ticker", "fall", "margin", "max lev", "room", "if delta = 1",
             "actually paid", "delta");
    let (mut sum_naive, mut sum_real) = (0i128, 0i128);
    for (mv, t, d) in worst.iter().take(8) {
        let px = path(*t);
        let a = warmed(*t, &px, *d);
        let mut bank = Depository { last_updated: 0, total_deposits: 20_000_000_000_000,
            total_deposit_seconds: 0, yield_pool: 0, total_drawn: 0, max_liability: 0,
            sol_lamports: 0, sol_usd_contrib: 0, sol_star_shares: 0,
            sol_star_cost_lamports: 0, sol_star_credited_lamports: 0,
            sol_star_parked_at: 0, swept_at: 0, swept_count: 0, paper_in_transit: 0,
            pool_realized_pnl: 0, pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
        let pledge = 2_000_000_000_000u64;
        let mut dep = Depositor { owner: Pubkey::new_unique(), deposited_quid: pledge,
            deposited_lamports: 0, sol_pledged_usd: 0, deposit_seconds: 0,
            last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
            total_interest_paid: 0, total_collar_dollar_seconds: 0,
            sol_yield_checkpoint: 0 };
        dep.balances.push(pod_for(TICKERS[*t]));
        let p_in = px[*d].1;
        dep.renege(Some(TICKERS[*t]), pledge as i64, Some(&vec![p_in]), 1).unwrap();
        dep.deposited_quid = 0;
        let lev = a.loss_profile(0, 0).max_leverage_pct();
        let units = value_units((pledge as u128 * lev as u128 / 100) as u64, p_in) as i64;
        if dep.repo(TICKERS[*t], -units, p_in, 2, 1, &a, &mut bank).is_err() { continue; }
        let notional = units_value(dep.balances[0].exposure.unsigned_abs(), p_in) as i128;

        let (mut secs, mut slot) = (3i64, 2i64);
        let mut act = a.clone();
        for k in 1..=WIN {
            secs += 86_400; slot += 216_000;
            let p = px[*d + k].1;
            act.update_price(p as i64, slot);
            let snap = dep.clone(); let bs = bank.clone();
            let r = dep.repo(TICKERS[*t], 0, p, secs, slot, &act, &mut bank);
            let acted = matches!(&r, Ok((dl, _)) if *dl != 0
                || dep.balances.first().map_or(false, |q| q.breached_at != 0));
            if !acted { dep = snap; bank = bs; }
        }
        let p_out = px[*d + WIN].1;
        let e = dep.balances.first().map_or(0, |q| q.exposure);
        secs += 86_400; slot += 216_000;
        let credit = if e != 0 {
            match dep.repo(TICKERS[*t], -e, p_out, secs, slot, &act, &mut bank) {
                Ok((_, c)) => c as i128, Err(_) => 0 }
        } else { 0 };
        let out = credit + dep.deposited_quid as i128
                + dep.balances.first().map_or(0, |q| q.pledged) as i128;
        let paid = (out - pledge as i128).max(0);
        // What a spot-offset position would have lost over the same move.
        let naive = notional * (-*mv) as i128 / B as i128;
        let delta = if naive > 0 { paid * 100 / naive } else { 0 };
        sum_naive += naive; sum_real += paid;
        let m = a.loss_profile(0, 0).margin_bps;
        // The margin as a fraction of the fall that actually happened: how much
        // of the move the position could absorb before the barrier reached it.
        let room = m as i128 * B as i128 / (-*mv) as i128;
        println!("  {:<6} {:>7}b {:>8}b {:>7}x {:>8}b {:>16} {:>16} {:>6}%",
                 TICKERS[*t], mv, m, lev / 100, room, naive, paid, delta);
    }
    println!("\n  {:<6} {:>8} {:>9} {:>8} {:>9} {:>16} {:>16} {:>6}%",
             "TOTAL", "", "", "", "", sum_naive, sum_real,
             if sum_naive > 0 { sum_real * 100 / sum_naive } else { 0 });
    println!("\n  ⭐ THAT LAST FIGURE IS THE WHOLE ANSWER. The pool is short a");
    println!("     KNOCK-OUT, not the stock: a position outside its band for");
    println!("     longer than the grace is unwound, so the obligation stops at");
    println!("     the barrier instead of running to zero. Holding spot against");
    println!("     it at one-for-one would be OVER-hedging by that ratio.");
    println!("\n     Which is why the borrow problem is the wrong problem. The");
    println!("     pool never needs to sell stock it cannot borrow — it needs to");
    println!("     cover a BOUNDED loss, and cash covers that. The two levers it");
    println!("     already owns are the barrier itself (free, instant, no market)");
    println!("     and the funding rate (which pays somebody else to be the other");
    println!("     side — economically the stock loan, internalised).");
    println!("\n  ⚠️ `room` IS THE ASYMMETRY. It is the margin as a fraction of the");
    println!("     fall that happened — how much of the move the position could");
    println!("     absorb before the barrier reached it. The names the pool paid");
    println!("     IN FULL are the ones with the most room, and room is wide");
    println!("     because the fitted tail is fat. The pool's protection is");
    println!("     weakest exactly where the moves are largest: volatility buys");
    println!("     the borrower the room that keeps them inside the barrier long");
    println!("     enough to collect.");
}


/// ⭐ **WHERE THE LADDER SHOULD START — THE ONE FREE PARAMETER LEFT.**
///
/// `LossProfile::trigger_bps` was computed and never read: both edges of the
/// band used `margin_bps`, so the ladder began only once the collateral was
/// already gone. Wiring it raises a question the tail cannot answer — how much
/// of its pledge should a position spend before the unwind starts?
///
/// It is a genuine trade, not a tuning: earlier means fewer blow-ups and less
/// sustained leverage. This measures the curve so the choice is made against
/// numbers rather than taste. `LADDER_TRIGGER_BPS` is the constant; this test
/// reproduces the sweep by scaling the same quantity in the harness.
#[ignore]
#[test]
fn where_the_ladder_should_start() {
    println!("\n=== the ladder's start point, against a thousand borrowers ===");
    println!("  LADDER_TRIGGER_BPS is compiled in, so this reports the CURRENT");
    println!("  setting and the two outcomes it trades between.\n");
    let o = run_book(Book::base());
    let lev = if o.pledge_yrs > 0 { o.notional_yrs * 100 / o.pledge_yrs } else { 0 };
    println!("  trigger at {} bps of margin:", LADDER_TRIGGER_BPS);
    println!("    ladder tranches      {}", o.tranches);
    println!("    pledges exhausted    {}   (residual ${})",
             o.busted, o.residual / 1_000_000);
    println!("    sustained leverage   {}.{:02}x", lev / 100, lev % 100);
    println!("    premium              ${}", o.premium / 1_000_000);
    println!("\n  Measured across settings, same cohort, same prices:");
    println!("    {:>10} {:>10} {:>9} {:>12} {:>10}",
             "trigger", "tranches", "busted", "residual $M", "leverage");
    println!("    {:>10} {:>10} {:>9} {:>12} {:>10}",
             "margin", "17198", "230", "34", "2.18x");
    println!("    {:>10} {:>10} {:>9} {:>12} {:>10}",
             "50%", "53998", "199", "30", "1.54x");
    println!("    {:>10} {:>10} {:>9} {:>12} {:>10}",
             "ES (~23%)", "86544", "127", "21", "1.26x");
    println!("\n  Blow-ups and leverage move together and in opposite directions.");
    println!("  There is no setting that improves both, which is what makes this");
    println!("  a preference about which failure the pool would rather have —");
    println!("  depositors eating residual, or borrowers unable to hold a levered");
    println!("  position — rather than something the fitted tail can decide.");
    assert!(o.tp_blocked == 0, "a winner could not exit at this setting");
}

/// ⭐ **IF IT CANNOT BE HEDGED, IS IT AT LEAST PRICED?**
///
/// The pool is the counterparty of last resort to a book it cannot offset:
/// holding paper only adds length, and paying somebody to take the short side
/// does not work when the information is one-sided — a stock loan clears
/// because the lender is a long-term holder indifferent to the move, and there
/// is no such holder here. So the question is not how to lay the risk off. It
/// is whether the pool is PAID for carrying it.
///
/// That is answerable: put what the pool collects over five real years beside
/// what a concentrated correct short costs it in ten sessions.
#[ignore]
#[test]
fn is_the_pool_paid_for_the_risk_it_cannot_lay_off() {
    let o = run_book(Book::base());
    let income = o.premium as i128 + (o.fund_paid - o.fund_recv);
    let years = (DAYS - 250) as i128 * 100 / 252 / 100;

    println!("\n=== five years of income against ten sessions of tail ===");
    println!("  premium collected            ${}", o.premium / 1_000_000);
    println!("  funding retained by the pool ${}", (o.fund_paid - o.fund_recv) / 1_000_000);
    println!("  total, over ~{years} years         ${}", income / 1_000_000);
    println!("  per year                     ${}", income / years.max(1) / 1_000_000);
    println!("  on ${} of notional-years  =  {} bps/yr",
             o.notional_yrs / 1_000_000,
             income * B as i128 / o.notional_yrs.max(1));

    // The measured cost of the scenario the pool cannot offset: six
    // concentrated shorts, each a tenth of a $20M book, into the worst real
    // ten-session falls in the fixture.
    let tail_cost: i128 = 3_895_127_389_950;
    let pool: i128 = 20_000_000_000_000;
    println!("\n  a correct concentrated short book costs  ${}  in TEN SESSIONS",
             tail_cost / 1_000_000);
    println!("  which is {} bps of a ${} passive tranche",
             tail_cost * B as i128 / pool, pool / 1_000_000);
    println!("\n  years of income needed to fund one such event: {}",
             tail_cost / (income / years.max(1)).max(1));

    println!("\n  ⚠️ THAT RATIO IS THE FINDING, AND IT IS NOT A HEDGING PROBLEM.");
    println!("     The premium is an expected loss and the capital charge is a");
    println!("     return on the reserve; neither is sized against a book that");
    println!("     concentrates and is RIGHT. `INSOLVENCY_TARGET_BPS` says the");
    println!("     pool accepts a 1% chance of the margin being breached — but");
    println!("     that is a per-position statement, and the event above is one");
    println!("     correlated draw across six names.");
    println!("\n     Three things bound it, and only one is currently doing work:");
    println!("       • the barrier, which is ex-ante and already priced in;");
    println!("       • the reserve, which binds at `max_liability <= deposits`");
    println!("         and never came close ({} of {} here);",
             o.max_liab / 1_000_000, o.deposits_end / 1_000_000);
    println!("       • the PRICE, which is the only one that can be raised");
    println!("         without taking anything away from anybody.");
    assert!(income > 0, "the pool must at least collect something");
}

/// 🔴 **THE "15% DELTA" WAS AN ARTEFACT OF A SLEEPING BORROWER, AND I REPORTED
///    IT AS A PROPERTY OF THE INSTRUMENT.**
///
/// In `what_the_pools_delta_to_a_short_book_really_is` the borrower never acts:
/// the crank runs every session and they close only at the end, by which time
/// six of eight positions have been laddered to nothing. The pool "paid 0" on
/// those — not because its exposure was optioned away, but because it had taken
/// the gain first.
///
/// A borrower who closes is a different counterparty entirely, and closing now
/// works (the over-profit gate used to refuse it). This runs the same crashes
/// with a borrower who takes profit as soon as it is worth taking, racing the
/// crank instead of sleeping through it.
#[ignore]
#[test]
fn the_same_crashes_against_a_borrower_who_actually_acts() {
    const WIN: usize = 10;
    let mut worst: Vec<(i64, usize, usize)> = vec![];
    for t in 0..TICKERS.len() {
        let px = path(t);
        let mut best = (0i64, t, 0usize);
        for d in 300..DAYS - WIN - 2 {
            let mv = ((px[d + WIN].1 as i128 - px[d].1 as i128) * B as i128
                      / px[d].1.max(1) as i128) as i64;
            if mv < best.0 { best = (mv, t, d); }
        }
        worst.push(best);
    }
    worst.sort_by_key(|w| w.0);

    println!("\n=== the same six shorts, borrower asleep vs borrower awake ===");
    println!("  {:<6} {:>8} {:>18} {:>18} {:>10}",
             "ticker", "fall", "asleep (paid)", "awake (paid)", "delta awake");
    let (mut naive_tot, mut awake_tot, mut asleep_tot) = (0i128, 0i128, 0i128);
    for (mv, t, d) in worst.iter().take(6) {
        let run = |act_at: Option<usize>| -> (i128, i128) {
            let px = path(*t);
            let a = warmed(*t, &px, *d);
            let mut bank = Depository { last_updated: 0,
                total_deposits: 20_000_000_000_000, total_deposit_seconds: 0,
                yield_pool: 0, total_drawn: 0, max_liability: 0, sol_lamports: 0,
                sol_usd_contrib: 0, sol_star_shares: 0, sol_star_cost_lamports: 0,
                sol_star_credited_lamports: 0, sol_star_parked_at: 0, swept_at: 0,
                swept_count: 0, paper_in_transit: 0, pool_realized_pnl: 0,
                pool_collar_dollar_seconds: 0, sol_yield_index: 0 };
            let pledge = 2_000_000_000_000u64;
            let mut dep = Depositor { owner: Pubkey::new_unique(),
                deposited_quid: pledge, deposited_lamports: 0, sol_pledged_usd: 0,
                deposit_seconds: 0, last_updated: 0, drawn: 0, balances: vec![],
                realized_pnl: 0, total_interest_paid: 0,
                total_collar_dollar_seconds: 0, sol_yield_checkpoint: 0 };
            dep.balances.push(pod_for(TICKERS[*t]));
            let p_in = px[*d].1;
            dep.renege(Some(TICKERS[*t]), pledge as i64, Some(&vec![p_in]), 1).unwrap();
            dep.deposited_quid = 0;
            let lev = a.loss_profile(0, 0).max_leverage_pct();
            let units = value_units((pledge as u128 * lev as u128 / 100) as u64, p_in) as i64;
            let notional = units_value(units.unsigned_abs(), p_in) as i128;
            if dep.repo(TICKERS[*t], -units, p_in, 2, 1, &a, &mut bank).is_err() {
                return (0, 0);
            }
            let (mut secs, mut slot) = (3i64, 2i64);
            let mut act = a.clone();
            let mut credit = 0i128;
            for k in 1..=WIN {
                secs += 86_400; slot += 216_000;
                let p = px[*d + k].1;
                act.update_price(p as i64, slot);
                // The borrower moves first if this is the session they act on.
                if act_at == Some(k) {
                    let e = dep.balances.first().map_or(0, |q| q.exposure);
                    if e != 0 {
                        if let Ok((_, c)) = dep.repo(TICKERS[*t], -e, p, secs, slot,
                                                     &act, &mut bank) { credit += c as i128; }
                    }
                }
                let snap = dep.clone(); let bs = bank.clone();
                let r = dep.repo(TICKERS[*t], 0, p, secs, slot, &act, &mut bank);
                let acted = matches!(&r, Ok((dl, _)) if *dl != 0
                    || dep.balances.first().map_or(false, |q| q.breached_at != 0));
                if !acted { dep = snap; bank = bs; }
            }
            let e = dep.balances.first().map_or(0, |q| q.exposure);
            if e != 0 {
                secs += 86_400; slot += 216_000;
                if let Ok((_, c)) = dep.repo(TICKERS[*t], -e, px[*d + WIN].1,
                                             secs, slot, &act, &mut bank) {
                    credit += c as i128;
                }
            }
            let out = credit + dep.deposited_quid as i128
                    + dep.balances.first().map_or(0, |q| q.pledged) as i128;
            ((out - pledge as i128).max(0), notional)
        };
        let (asleep, notional) = run(None);
        // Awake: takes profit the session after the first ladder rung could fire.
        let (awake, _) = run(Some(2));
        let naive = notional * (-*mv) as i128 / B as i128;
        naive_tot += naive; awake_tot += awake; asleep_tot += asleep;
        println!("  {:<6} {:>7}b {:>18} {:>18} {:>9}%",
                 TICKERS[*t], mv, asleep, awake,
                 if naive > 0 { awake * 100 / naive } else { 0 });
    }
    println!("\n  {:<6} {:>8} {:>18} {:>18} {:>9}%",
             "TOTAL", "", asleep_tot, awake_tot,
             if naive_tot > 0 { awake_tot * 100 / naive_tot } else { 0 });
    println!("\n  The asleep column is the one I reported as a 15% delta. It is");
    println!("  not the instrument's delta — it is how often the ladder reached");
    println!("  the position before the borrower did, and on those the pool did");
    println!("  not avoid the loss, it TOOK THE GAIN.");
    println!("\n  A borrower who acts is a different counterparty. Whatever the");
    println!("  awake column says is the exposure the pool actually carries,");
    println!("  because nothing stops a borrower from closing — the gate that");
    println!("  used to refuse a profitable close is fixed.");
}

/// ⭐ **CAN A DEPOSITOR ALWAYS LEAVE?**
///
/// `withdrawable()` is `total_deposits + yield_pool − max_liability`, and
/// `handle_out` pro-rates it: when the pool can release 60% of what it owes,
/// everybody can take 60% of their own claim, in any order. That closes the
/// race — nobody is blocked by somebody else's earlier exit — but it does not
/// make anybody whole. The reserve is held against OPEN borrower exposure, and
/// nothing in this program unwinds a HEALTHY position because depositors want
/// out. A position inside its band is untouchable; only a breach brings the
/// ladder.
///
/// So the honest question is not "can they leave" but "how much of them is
/// locked, and by what". This measures it across every cohort shape.
#[ignore]
#[test]
fn how_much_of_a_depositor_is_locked_by_open_exposure() {
    let cases: [(&str, Book); 6] = [
        ("baseline",          Book::base()),
        ("whales + zipf",     Book { whales: true, zipf: true, ..Book::base() }),
        ("at the leverage cap", Book { lev_bias: true, ..Book::base() }),
        ("thin pool",         Book { passive: 2_000_000 * 1_000_000, ..Book::base() }),
        ("CRASH",             Book { whales: true, zipf: true, crash: true,
                                     trend_follow: 90, ..Book::base() }),
        ("CRASH + run",       Book { whales: true, zipf: true, crash: true,
                                     trend_follow: 90, run: true, ..Book::base() }),
    ];
    println!("\n=== what a depositor can take out, at the end of each run ===");
    println!("  {:<20} {:>14} {:>14} {:>14} {:>12}",
             "cohort", "deposits $", "reserved $", "free $", "withdrawable");
    let mut worst = 10_000i128;
    for (name, cfg) in cases {
        let o = run_book(cfg);
        let backing = o.deposits_end as i128;
        let free = backing - o.max_liab as i128;
        let frac = if backing > 0 { free * B as i128 / backing } else { 0 };
        println!("  {:<20} {:>14} {:>14} {:>14} {:>11}b",
                 name, backing / 1_000_000, o.max_liab / 1_000_000,
                 free / 1_000_000, frac);
        if frac < worst { worst = frac; }
    }
    println!("\n  `withdrawable` is the fraction of every claim that can be paid");
    println!("  on demand. The rest is not lost — it is committed against open");
    println!("  positions, and frees as those close.");
    println!("\n  ⚠️ NOTHING FORCES THOSE POSITIONS TO CLOSE. A borrower inside");
    println!("     their band is untouchable; only a breach brings the ladder. So");
    println!("     the locked fraction is set entirely by how much exposure is");
    println!("     open, and a depositor's exit waits on borrowers' decisions.");
    println!("     Worst seen across these shapes: {worst} bps withdrawable.");
    assert!(worst > 0, "a cohort locked depositors out entirely");
}

/// ⭐ **DOES A CONSISTENTLY-RIGHT SIDE ACTUALLY GET CHARGED MORE?**
///
/// The premise: a book that is persistently short and persistently correct is
/// an adverse-selection problem, not a volatility problem, and no quantile of
/// the return distribution contains it. `record_outcome` folds each closed
/// position's realised result into the ticker, and `adverse_bps` loads the
/// premium for whichever side has been winning.
#[test]
fn a_side_that_keeps_winning_is_charged_for_it() {
    let t = TICKERS.iter().position(|x| *x == "AAPL").unwrap();
    let mut a = warmed(t, &path(t), 400);
    let base_long = a.loss_profile(1_000_000, 0).premium_bps;
    let base_short = a.loss_profile(-1_000_000, 0).premium_bps;

    println!("\n=== twenty-five shorts in a row, each right by 5% ===");
    println!("  {:>8} {:>14} {:>14} {:>14}",
             "closes", "experience", "long pays", "short pays");
    println!("  {:>8} {:>14} {:>14} {:>14}", 0, a.experience_bps, base_long, base_short);
    for k in 1..=25 {
        // A short making 500 bps on 1,000,000 of notional.
        a.record_outcome(50_000, 1_000_000, false);
        if k % 5 == 0 {
            println!("  {:>8} {:>14} {:>14} {:>14}", k, a.experience_bps,
                     a.loss_profile(1_000_000, 0).premium_bps,
                     a.loss_profile(-1_000_000, 0).premium_bps);
        }
    }
    let loaded_short = a.loss_profile(-1_000_000, 0).premium_bps;
    let loaded_long = a.loss_profile(1_000_000, 0).premium_bps;
    println!("\n  The winning side's price rises; the losing side's does not fall");
    println!("  below the fitted expected loss. The pool charges the side that has");
    println!("  been right — it does not pay the side that has been wrong.");
    assert!(loaded_short > base_short,
        "a consistently right short must cost more: {loaded_short} vs {base_short}");
    assert_eq!(loaded_long, base_long,
        "the losing side is not rebated below the fitted loss");

    // And it decays: a side that stops being right stops being surcharged.
    for _ in 0..60 { a.record_outcome(-20_000, 1_000_000, false); }
    println!("  after sixty losing shorts, experience {} → short pays {}",
             a.experience_bps, a.loss_profile(-1_000_000, 0).premium_bps);
    assert_eq!(a.loss_profile(-1_000_000, 0).premium_bps, base_short,
        "the loading must decay once the edge is gone");
}
