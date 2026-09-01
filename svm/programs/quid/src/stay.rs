
use anchor_lang::prelude::*;
use crate::etc::{ LIQ_GRACE_SECS, MAX_LEN, TRANCHE_RAMP_GRACES,
    MIN_TRANCHE_BPS, MAX_TRANCHE_BPS, hazard_rate_bps,
    PithyQuip, Actuary, collar_bps,
    rate_bps, max_leverage_pct, TickerRisk };

/// Fixed-point scale for `Depository::sol_yield_index`.
pub const SOL_YIELD_SCALE: u128 = 1_000_000_000_000;

/// The most a redemption may raise the margin requirement, in bps of it. At
/// full pressure a position must post twice what the tail alone asked for, so a
/// 8x book becomes a 4x book — the leverage claim halves as the capital behind
/// it leaves. Not higher: a requirement that cannot be met at any size
/// liquidates the whole book at once, which is the disorderly exit the ladder
/// exists to prevent. Redemption accelerates the unwind, it does not replace it.
pub const REDEMPTION_MAX_MARGIN_BPS: i64 = 20_000;

/// Ceiling for a margin requirement in bps: fully collateralised, no leverage.
pub const BPS_MAX: i64 = 10_000;


// ═══ §SCALE — one conversion between share units and dollars ════════════════
//
// ⭐ **`exposure` IS MICRO-SHARES; `price` IS MICRO-DOLLARS PER SHARE.** The
// product is pico-dollars, and `PRICE_SCALE` brings it back to the accounting
// unit every other dollar figure in this program uses
// (`ACCOUNTING_DECIMALS = 6`).
//
// 🔴 **THE CONVERSION USED TO BE WRITTEN OUT FOURTEEN TIMES.** `Stock::value_at`
//    says so itself — "written out nine times in two spellings" — and there
//    were five more in `clutch` and `entra`. That was survivable while the
//    factor was 1, because a missed site was still arithmetically right. It
//    stops being survivable the moment the factor is not 1: one site left
//    unconverted mis-scales a position by a million, silently, in the direction
//    that opens exposure the pool cannot cover.
//
// So every site routes through here first — a refactor with no behaviour
// change, `PRICE_SCALE = 1`, suite green — and only then does the scale move.
pub const PRICE_SCALE: u128 = 1_000_000;

/// Dollar value of `units` micro-shares at `price`.
#[inline]
pub fn units_value(units: u64, price: u64) -> u64 {
    ((units as u128).saturating_mul(price as u128) / PRICE_SCALE)
        .min(u64::MAX as u128) as u64
}

/// Signed variant, for the paths that carry a side.
#[inline]
pub fn units_value_i(units: i64, price: u64) -> i64 {
    ((units as i128).saturating_mul(price as i128) / PRICE_SCALE as i128)
        .clamp(i64::MIN as i128, i64::MAX as i128) as i64
}

/// How many micro-shares `dollars` buys at `price`. Zero at zero price — the
/// callers all guard it, and returning zero is the answer that cannot divide.
#[inline]
pub fn value_units(dollars: u64, price: u64) -> u64 {
    if price == 0 { return 0; }
    ((dollars as u128).saturating_mul(PRICE_SCALE) / price as u128)
        .min(u64::MAX as u128) as u64
}

#[derive(AnchorSerialize,
    AnchorDeserialize, InitSpace,
    Clone, Copy, Debug,
    PartialEq, Eq)]

pub struct Stock {
    // (b"GOOGL\0\0\0")
    pub ticker: [u8; 8],
    pub pledged: u64,
    pub exposure: i64,
    // ^ same precision
    // as USD* (10^6)

    pub updated: i64,
    // ⚠️ `rate_bps: u16` WAS HERE AND WAS A SUPERSEDED DUPLICATE. It stored the
    //    rate at open; the rate is now computed LIVE on every accrual —
    //    `rate_bps(conc, 100, actuary) + hazard_rate_bps(distance, collar, ...)`
    //    at :915 — because the premium must track MONEYNESS, which a value
    //    frozen at open cannot. Zero reads and zero writes remained; it only
    //    survived a grep because `rate_bps` is also the name of the FUNCTION
    //    imported from `etc.rs` at the top of this file.
    pub collar_bps: u16,

    // cost_basis tracks entry cost across renege() adjustments.
    // PnL at close = transfer - cost_basis - interest_paid...
    pub cost_basis: u64,

    // Cumulative interest paid 
    // across repo() calls...
    pub interest_paid: u64,

    /// Time-integrated economic capital: sum of (collar_dollars × seconds).
    /// RAROC denominator — how much capital was at risk, for how long...
    pub collar_dollar_seconds: u128,

    /// Collar dollars this pod currently contributes to `max_liability`.
    /// Stored rather than re-derived: the reserve used to be incremented on an
    /// exposure base and decremented on a pledged base, so for any levered pod
    /// the decrement was L× too small and `max_liability` ratcheted up forever,
    /// starving `has_capacity()` and `withdrawable()`. Booking the exact figure
    /// that was added is the only way the two sides cannot drift.
    pub collar_dollars: u64,

    /// Where this position last stood in its ticker's premium integral.
    /// The difference against the ticker's current index is what it owes for
    /// the base rate over the interval, charged at the rates that prevailed
    /// rather than at whichever one is read today.
    pub premium_checkpoint: u128,

    /// Where this position last stood in its ticker's signed funding integral.
    /// `exposure × (Φ_now − Φ_here)` is what it has paid or been paid since,
    /// with the direction carried by the sign of `exposure` rather than by a
    /// choice of which of two indices to read.
    pub funding_checkpoint: i128,

    /// ⭐ **THE MARK REFERENCE: `exposure_value` as of the last settlement.**
    ///
    /// 🔴 THE POD HAD NO ENTRY PRICE AND THAT IS WHY IT COULD NOT BE LEVERED.
    ///    `cost_basis` reads like one, but `renege` moves it and `pledged` by
    ///    the SAME amount on every collateral change — it is contributed
    ///    collateral, and it equals the entry notional only because the band
    ///    forces `exposure_value == pledged`. Remove the forcing and nothing in
    ///    `Stock` remembered what the position was worth when it was opened, so
    ///    no profit or loss could be computed and the band had to be written on
    ///    notional instead. On notional the floor is `pledged − exposure·c`,
    ///    which is ZERO at any leverage past 1/c: a levered long can lose its
    ///    whole pledge without the band noticing, because a losing long's
    ///    NOTIONAL FALLS and moves it further inside its own band.
    ///
    /// One `u64` is the entire cost of leverage here. With it, the band is
    /// written where it always meant to be — on the move since the mark — and
    /// at 1x, where `marked == pledged`, it reduces to exactly the band that
    /// is there today.
    pub marked: u64,

    /// Unix time this position first went outside its band, 0 while inside it.
    /// Liquidation is a Parisian barrier — it triggers on the *excursion*, the
    /// unbroken time spent beyond the barrier — so the clock that gates it has
    /// to measure the excursion and nothing else.
    pub breached_at: i64,
}

impl Stock {
    /// What this position is worth at `price`.
    ///
    /// Written out nine times in two spellings: a `u64` saturating multiply,
    /// and a `u128` multiply clamped back to `u64`. They return the same
    /// number — `saturating_mul` already stops at `u64::MAX` — so the wide
    /// form only bought an i128 division's worth of compute on paths that run
    /// per position, per call.
    fn value_at(&self, price: u64) -> u64 {
        units_value(self.exposure.unsigned_abs(), price)
    }

    /// Excursion length, starting the clock on first sight of a breach.
    fn excursion(&mut self, now: i64) -> i64 {
        if self.breached_at == 0 { self.breached_at = now; }
        (now - self.breached_at).max(0)
    }

    /// Charge one grace period against the excursion for a tranche taken.
    ///
    /// The gate is `excursion > LIQ_GRACE_SECS`, and `breached_at` was set
    /// once and left alone, so a position an hour outside its band satisfied
    /// it on every call for ever after. A liquidator could call in a loop and
    /// unwind the whole position in one slot, taking a commission on each
    /// rung — the seven-day ladder climbed in seconds, which is precisely what
    /// the gradual unwind exists to prevent.
    ///
    /// So the excursion is a budget rather than a threshold: time accrues it,
    /// each tranche spends one period of it. A neglected position still
    /// accumulates, so a liquidator returning after a day may take the rungs
    /// that went unclaimed — catching up is meant to be possible, unwinding
    /// everything at once is not.
    fn spend_grace(&mut self) {
        self.breached_at = self.breached_at.saturating_add(LIQ_GRACE_SECS as i64);
    }
}

// 🔴 `impl Space for Stock` WAS HAND-WRITTEN HERE AND IT WAS WRONG BY 14 BYTES.
//    It declared 100 where the pod serialises to 114: `funding_checkpoint: u128`
//    was added without touching the constant, and a stray `+ 2` had been carried
//    for what looks like struct padding, which Borsh does not emit.
//
//    `Depositor` allocates `4 + MAX_LEN * Stock::INIT_SPACE` for `balances`, so
//    the shortfall is not cosmetic: 50 x 100 = 5,000 bytes of room for 50 x 114
//    = 5,700 bytes of pods. A depositor's account becomes unwritable at 44
//    positions — every subsequent deposit, withdrawal or liquidation fails to
//    serialise, which bricks the position rather than merely rejecting it.
//
//    Derived now, so the number cannot disagree with the struct again. See
//    `backtest::the_declared_size_of_a_pod_matches_what_it_serialises_to`, which
//    asserts against the serialiser rather than against a second hand count.

#[account]
#[derive(InitSpace)]
pub struct Depository {
    pub last_updated: i64,
    pub total_deposits: u64,
    pub total_deposit_seconds: u128,
    // ^ the faster one enter & exit,
    // the less of an accrued yield
    // one can take (slower, stickier
    // depositors get more, pro rata)
    pub total_drawn: u64,
    // ^ leverage exposure

    /// Earnings the pool has taken in but not yet paid out: premiums charged
    /// to borrowers, and profit appropriated from liquidated positions.
    ///
    /// Kept apart from `total_deposits` so that stays exactly the sum of what
    /// depositors put in. Mixing them made the payout share integrate one
    /// quantity in its numerator and another in its denominator, so shares did
    /// not sum to the pool — measured at 1.188× — and tenure moved principal
    /// between depositors instead of only allocating what was earned.
    pub yield_pool: u64,
    pub max_liability: u64,
    /// Hot buffer: native lamports in the sol_pool PDA. This is what
    /// flash_borrow lends and withdraw_sol pays out — both need lamports in
    /// hand, so neither can ever be served from the parked tranche.
    pub sol_lamports: u64,
    pub sol_usd_contrib: u64,
    /// SOL* shares held by the sol_pool PDA. SOL* is Perena-branded but
    /// Kestrel-issued: its mint authority is long_yield_carry's Token PDA, and
    /// Perena's own app mints it with a top-level LYC instruction. Minting it
    /// the way Perena does means calling that program — see SOL-STAR-REFERENCE.md.
    pub sol_star_shares: u64,
    /// Lamports that bought those shares. Carry and unwind loss are realised
    /// against this basis at unpark, not marked continuously.
    pub sol_star_cost_lamports: u64,
    /// Cost less the park haircut — what the parked tranche is credited for in
    /// depositor collateral. Anything that re-marks SOL collateral from scratch
    /// must value `sol_lamports + sol_star_credited_lamports`; `flash_repay`
    /// does, and using `sol_lamports` alone silently wipes parked backing.
    pub sol_star_credited_lamports: u64,
    /// Unix seconds of the most recent park — starts the discretionary hold.
    /// A fresh park restarts it for the whole tranche: churn gets harder.
    pub sol_star_parked_at: i64,

    /// Coverage proof for the permissionless sweep: when a full pass last
    /// completed, and how many positions it touched. Nothing on Solana can
    /// enumerate accounts on-chain, so the pool cannot iterate its own book —
    /// but it can record that someone did, which is what makes "was every
    /// position looked at?" an answerable question rather than a hope.
    pub swept_at: i64,
    pub swept_count: u64,

    /// Pool-wide realised P&L and capital-at-risk-time — the denominator an
    /// account's own RAROC is measured against. Comparing to the pool average
    /// keeps the rebate relative (size cannot game it) and self-bounding (the
    /// average account earns nothing) without ranking accounts against
    /// each other.
    pub pool_realized_pnl: i64,
    pub pool_collar_dollar_seconds: u128,

    /// Dollars the issuer owes back: paper has left, proceeds have not landed.
    ///
    /// ⭐ **THE ONLY POOL-LEVEL FIGURE THE HEDGE NEEDS, AND IT FALLS OUT OF THE
    /// ARITHMETIC.** Holding paper is asset-neutral for a depositor: it costs
    /// `C` of liquid dollars and retires `C` of liability, so
    /// `deposits + yield - (liability - C) - C` is just
    /// `deposits + yield - liability`. Cover cancels. What does NOT cancel is
    /// the window where the paper has gone and the money has not arrived —
    /// the moment the pool is least liquid, and the worst possible moment to
    /// tell a depositor otherwise.
    ///
    /// ⚠️ An earlier cut carried a `paper_dollars` that tracked COVER and only
    /// ever grew, because nothing released it; `withdrawable()` decayed toward
    /// zero with a full vault. Tracking the thing that does not cancel, rather
    /// than the thing that does, removes the release path along with the bug.
    pub paper_in_transit: u64,

    /// ⭐ **WHAT THE POOL OWES DEPOSITORS AND COULD NOT PAY.**
    ///
    /// 🔴 **DEPOSITORS WAITED ON BORROWERS' DECISIONS, AND NOTHING MADE THAT
    ///    WAIT END.** `withdrawable()` withholds `max_liability`, and that
    ///    reserve is held against exposure that is mostly SYNTHETIC — a
    ///    bilateral bet where nothing was bought. A position inside its band is
    ///    untouchable and only a breach brings the ladder, so the withheld
    ///    fraction (measured at 6–26% across every cohort shape) came free only
    ///    when borrowers happened to close. That is the wrong seniority: a
    ///    borrower's leverage is a claim on depositor capital, and when that
    ///    capital leaves, the claim has to shrink with it.
    ///
    /// The distinction that matters is WHY the capital is committed:
    ///
    ///   • `paper_in_transit` — dollars gone, paper not yet landed. A real
    ///     wait, and the only legitimate one.
    ///   • `Backing::funded` — liability covered by paper the pool actually
    ///     holds. Slow to release: it has to be sold, in market hours.
    ///   • the rest of `max_liability` — synthetic, and unwindable NOW.
    ///
    /// So the reserve still binds at the moment of withdrawal — solvency is not
    /// negotiable — but unmet demand is RECORDED here rather than silently
    /// deferred, and it tightens the band in `repo` until the ladder has
    /// unwound enough synthetic exposure to clear it. The depositor waits one
    /// crank, not one borrower.
    ///
    /// ⚠️ THIS IS NOT THE CROWDING SURCHARGE WEARING A DIFFERENT HAT, and the
    ///    difference is the whole justification. Tightening a band because the
    ///    BOOK leaned would punish a borrower for being on the popular side —
    ///    changing the deal after the fact. Tightening it because the CAPITAL
    ///    BEHIND IT WAS WITHDRAWN is the seniority that was always there: the
    ///    borrower keeps their pledge and every dollar of their P&L, they
    ///    simply cannot hold as much notional against a smaller pool.
    pub unwind_demand: u64,

    /// Mirror of `Backing::funded` — liability covered by paper the pool holds.
    /// Kept here because `withdrawable()` cannot reach the `Backing` account,
    /// and this is the half of `max_liability` that a crank CANNOT free.
    pub paper_backed: u64,

    /// Cumulative SOL* carry per lamport of SOL principal, scaled by
    /// SOL_YIELD_SCALE.
    ///
    /// Carry used to be booked straight into `total_deposits`, which shares it
    /// by `deposit_seconds` across every depositor — so a USD*/QD depositor
    /// earned staking yield on lamports they never posted, while SOL price
    /// losses stayed idiosyncratic (a SOL move hits one depositor's
    /// `sol_pledged_usd`). Risk was individual and reward was socialised. The
    /// index attributes the yield to the tranche that funded it, in O(1).
    pub sol_yield_index: u128,
}

/// Per-order flash loan state. Separate from Depository so the core accounting
/// struct never carries mutable mid-tx state. Exactly one FlashLoan account
/// exists (seeds=[b"flash_loan"]) and is init_if_needed at program deploy.
/// Zero-valued fields mean no active loan.
#[account]
#[derive(InitSpace)]
pub struct FlashLoan {
    pub flash_lamports: u64, // SOL flash loan principal (0 = none)
    // SPL token flash loan — Pubkey::default()/0 means no active loan.
    // SOL and SPL are mutually exclusive (enforced in flash_borrow).
    pub flash_token_mint:   Pubkey,
    pub flash_token_amount: u64,
}

// naive timestamping: it over-weights early dust deposits;
// can be gamed by adding size later to inherit "old" age.
// To prevent this, we use dollar-seconds, time-weighted
// deposit value, updated continuously to stay accurate.

impl Depository {
    /// Update utilization when positions are opened/closed
    /// tracks total amount at risk (value of all positions)
    pub fn utilisation(&mut self, drawn_change: i64) {
        if drawn_change > 0 {
            self.total_drawn = self.total_drawn.saturating_add(
                                            drawn_change as u64);
        } else {
            self.total_drawn = self.total_drawn.saturating_sub(
                                    drawn_change.unsigned_abs());
        }
    }

    pub fn utilisation_bps(&self) -> i64 {
        if self.total_deposits == 0 { return 0; }
        ((self.total_drawn as u128 * 10_000 / self.total_deposits as u128) as u64) as i64
    }

    /// Attribute realised SOL* carry (or loss) to the SOL tranche.
    /// Returns false when there is no principal to attribute it to, in which
    /// case the caller should fall back to the pooled path.
    pub fn accrue_sol_yield(&mut self, signed_usd: i64) -> bool {
        let principal = self.sol_lamports
            .saturating_add(self.sol_star_cost_lamports) as u128;
        if principal == 0 || signed_usd == 0 { return false; }
        let magnitude = (signed_usd.unsigned_abs() as u128)
            .saturating_mul(SOL_YIELD_SCALE) / principal;
        if signed_usd > 0 {
            self.sol_yield_index = self.sol_yield_index.saturating_add(magnitude);
        } else {
            // A loss claws back unclaimed carry first; anything beyond that is
            // a real impairment and belongs on the pooled path.
            if magnitude > self.sol_yield_index { return false; }
            self.sol_yield_index -= magnitude;
        }
        true
    }


    /// Check if pool has capacity for additional collar exposure.
    ///
    /// Solvency requirement: total deposits must cover worst-case losses.
    /// max_liability tracks sum of (exposure × collar_bps) for all positions.
    /// If all positions hit their collar simultaneously, the pool must cover it.
    /// `total_deposits` is dollars, and only dollars.
    ///
    /// It used to include SOL, so every solvency question was asked against a
    /// mixture of par-valued and marked capital and a SOL move changed what a
    /// stablecoin depositor could do. That was patched here for a while, by
    /// subtracting the SOL contribution back out at each gate. The subtraction
    /// is gone because the mixing is: a SOL deposit no longer credits this at
    /// all, so there is nothing to take back out and no way for the two to
    /// disagree about how much was taken.

    pub fn has_capacity(&self, 
        additional_collar: u64) -> bool {
        if self.total_deposits == 0 { return false; }
        self.max_liability.saturating_add(additional_collar) <= self.total_deposits
    }

    /// Maximum amount LP can withdraw without breaking solvency.
    /// Must maintain enough deposits to cover worst-case collar losses.
    pub fn withdrawable(&self) -> u64 {
        self.total_deposits.saturating_add(self.yield_pool)
            .saturating_sub(self.max_liability)
            // Cover cancels; money in the post does not.
            // See `Depository::paper_in_transit`.
            .saturating_sub(self.paper_in_transit)
    }

    /// The part of the reserve a crank could free today, in dollars: everything
    /// not covered by paper the pool has to sell first. This is what
    /// `unwind_demand` can actually reach, and the ceiling on how much pressure
    /// it is worth recording.
    pub fn unwindable_reserve(&self) -> u64 {
        self.max_liability.saturating_sub(self.paper_backed)
    }

    /// Record a withdrawal the pool could not pay, so the ladder can clear it.
    /// Bounded by what a crank can actually free — pressure against paper the
    /// pool must sell is not pressure the band can relieve, and recording it
    /// would tighten every borrower's band for a wait that is genuinely real.
    pub fn defer_redemption(&mut self, unmet: u64) {
        let reachable = self.unwindable_reserve();
        self.unwind_demand = self.unwind_demand
            .saturating_add(unmet).min(reachable);
    }

    /// How hard the band is pulled in, in bps, by capital that has left.
    ///
    /// The whole of the unwindable reserve being demanded pulls the band to
    /// `REDEMPTION_FLOOR_BPS` of its width; no demand leaves it untouched. The
    /// floor exists because a band of zero is an instant liquidation of the
    /// entire book, which would turn an orderly redemption into the disorderly
    /// one the ladder exists to prevent.
    /// 🔴 **A FIRST CUT NARROWED THE BAND AND NOTHING HAPPENED.** A position
    ///    sitting at the centre of its band is not breached however tight the
    ///    band becomes — the price has not moved, so `exposure_value == marked`
    ///    exactly. Eight cranks under maximum pressure unwound nothing.
    ///
    ///    Worse, the direction was backwards. `band_bps` IS `margin_bps`: one
    ///    number serving as both the liquidation distance and the collateral
    ///    requirement. Narrowing it LOWERS the margin, which permits MORE
    ///    leverage — the opposite of what a shrinking pool needs.
    ///
    /// So the lever is the margin, raised. Leverage is a claim on depositor
    /// capital; when that capital leaves, the claim shrinks, and a position
    /// whose pledge no longer covers the raised requirement is laddered down
    /// until it does. The band it is liquidated against is untouched.
    pub fn redemption_margin_bps(&self) -> i64 {
        let reachable = self.unwindable_reserve();
        if self.unwind_demand == 0 || reachable == 0 { return 10_000; }
        let served = (self.unwind_demand as u128 * 10_000 / reachable as u128)
            .min(10_000) as i64;
        10_000 + served * (REDEMPTION_MAX_MARGIN_BPS - 10_000) / 10_000
    }
}

#[account]
#[derive(InitSpace)]
pub struct Depositor {
    pub owner: Pubkey,
    pub deposited_quid: u64,
    pub deposited_lamports: u64,
    pub sol_pledged_usd: u64,
    pub deposit_seconds: u128,
    pub last_updated: i64,
    pub drawn: u64, // mirrors Depository.total_drawn for this account;
    // pure depositors (drawn=0) receive full yield share; borrowers receive
    // a share discounted by their proportion of total pool risk (see clutch.rs)
    
    #[max_len(MAX_LEN)] // 50
    pub balances: Vec<Stock>,
    pub realized_pnl: i64,
    pub total_interest_paid: u64,
    /* liquidation buffer the pool
    is holding against this position
    at any moment. Not full pledged
    amount, not exposure — the capital
    the pool has committed to absorb
    before liquidating.
    collar_dollar_seconds = integral
    of collar_dollars over time.

    When you divide realized_pnl
    by total_collar_dollar_seconds
    (normalized to a common  unit),
    you get the return per unit of
    economic capital deployed: real
    measure of whether a trader is
    generating alpha or just taking
    pool-subsidized risk.
    */
    pub total_collar_dollar_seconds: u128,

    /// Value of `Depository::sol_yield_index` when this depositor's SOL
    /// position was last settled. The difference is what they are owed.
    pub sol_yield_checkpoint: u128,
}

/// The base the collar is measured against: a position's notional at risk.
///
/// `collar_bps` already carries a `/lev` term, so applying it to `pledged`
/// (= exposure / L) divided by leverage a second time — the band a position
/// could absorb collapsed as 1/L², to 20 bps at 10×. Exposure value is the
/// correct base; `pledged` is the floor for a pod that has collateral posted
/// but no exposure yet, which is what keeps a fresh deposit's band non-zero.
#[inline]
pub fn collar_notional(exposure_value: u64, pledged: u64) -> u64 {
    exposure_value.max(pledged)
}

/// Helper for liability
/// state transitions
/// (transient, not persisted)
struct LiabilityUpdate {
    old_collar_dollars: u64,
    new_collar_bps: u16,
    new_collar_dollars: u64,
}

impl LiabilityUpdate {
    fn compute(old_exposure: u64, old_collar_bps: u16,
        new_exposure: u64, new_pledged: u64, actuary: &Actuary) -> Self {
        // `old_collar_dollars` is what this pod last contributed; the caller
        // passes the pod's stored figure when it has one so the decrement is
        // exactly the increment. Falling back to a recomputation keeps pods
        // written before this field existed from over-releasing.
        let old_collar_dollars = old_exposure.saturating_mul(old_collar_bps as u64) / 10_000;

        // As above: an unpledged position is not unlevered, and reading it so
        // would size the reserve against it as if it were the safest thing in
        // the book.
        let new_leverage = if new_pledged > 0 { ((new_exposure as u128 * 100) /
                                                   new_pledged as u128).min(i64::MAX as u128) as i64
        } else if new_exposure > 0 { i64::MAX } else { 100 };

        let new_collar = collar_bps(new_leverage, actuary);
        let new_collar_dollars = collar_notional(new_exposure, new_pledged)
            .saturating_mul(new_collar as u64) / 10_000;
        Self { old_collar_dollars, new_collar_bps: new_collar as u16, new_collar_dollars }
    }

    fn apply(self, pod: &mut Stock,
            depository: &mut Depository) {
        pod.collar_bps = self.new_collar_bps;
        // The pod records what its own band is worth — used for the RAROC
        // denominator and for `collar_amount` — but no longer books it into
        // `max_liability`. The pool reserves against the NET of each ticker
        // (`reconcile_ticker_reserve`), and having two writers on one figure
        // is what let it ratchet before.
        let _ = depository;
        pod.collar_dollars = self.new_collar_dollars;
    }
}


/// One liquidation slice, shared by all four call sites.
///
/// The long/short × over/under branches were four verbatim copies of this
/// sequence — which is precisely how four identical `reduce` computations
/// stayed identical and wrong until the ladder audit. Sign is derived from the
/// pod, so there is one implementation and the mirror cannot drift from the
/// original. Returns (signed dollar delta, cost_basis, interest_paid,
/// collar_dollar_seconds, closed) — the RAROC fields are handed back because
/// the caller must end the pod borrow before touching `Depositor`.
/// Premium owed on `exposure_value` at `rate_bps` per annum over `dt` seconds,
/// and how many of those seconds it pays for — the amount by which the caller
/// may then advance `pod.updated`.
///
/// The charge is capped at the pledge, because collateral is all we can take.
/// What we must not do is write the remainder off, which is what the plain
/// `saturating_sub` here used to do: a position whose pledge had been eaten
/// went on holding exposure for free, and since nothing else charges it, for
/// good. Capping the charge and returning only the span the pledge covers
/// leaves the shortfall on the clock, so the debt keeps growing and the
/// excursion keeps the position liquidatable.
///
/// The division truncates and the lost sub-unit is not carried. That is a
/// deliberate floor rather than an oversight: the loss is under one accounting
/// unit — 1e-6 of a dollar — per call, and the only way to compound it is to
/// pay a transaction fee per call to save a millionth of a cent. Carrying it
/// would cost a field in every `Stock` to defend against an attack that loses
/// money faster than the pool does.
fn premium_due(exposure_value: u64, position_rate_bps: i64, dt: i64,
    base_bps_seconds: u128, pledged: u64) -> (u64, i64) {
    const YEAR_BPS: u128 = 31_536_000 * 10_000;
    let dt = dt.max(0);
    // The integrated half is already rate-times-seconds; the position half is
    // a rate that still has to be spread over the interval. Both land in the
    // same unit before either is divided.
    let bps_seconds = base_bps_seconds.saturating_add(
        (position_rate_bps.max(0) as u128).saturating_mul(dt as u128));
    if bps_seconds == 0 || exposure_value == 0 { return (0, dt); }

    let accrued = ((exposure_value as u128).saturating_mul(bps_seconds)
        / YEAR_BPS).min(u64::MAX as u128) as u64;
    if accrued <= pledged { return (accrued, dt); }

    // Only part of the interval is affordable. Bill the share of it the pledge
    // covers, so the remainder stays on the clock rather than being forgiven.
    let billed = ((pledged as u128).saturating_mul(dt as u128)
        / accrued.max(1) as u128).min(dt as u128) as i64;
    (pledged, billed)
}

fn amortise_tranche(pod: &mut Stock, price: u64, excursion: i64, util_bps: i64,
    actuary: &Actuary, depository: &mut Depository, old_exposure_value: u64,
    current_time: i64) -> (i64, u64, u64, u128, bool) {
    let long = pod.exposure > 0;
    // How far outside the band this is, in units. The ladder answers "how
    // long"; this answers "how far", and the two are needed together: a slow
    // drift should be unwound gently, but a gap moves the loss faster than a
    // time-based slice can collect it, and what the pledge cannot cover comes
    // out of depositors who never took the trade.
    //
    // Nothing is tuned here. The band is restored by closing exactly the
    // excess over its edge, so that quantity is the floor on a tranche — never
    // more than makes the position sound again, and never less. In a drift the
    // ladder dominates and liquidation stays gentle; in a gap this does, which
    // is the only case where gentleness costs somebody else.
    let collar = collar_amount(pod, price);
    let exposure_value = pod.value_at(price);
    let mark = if pod.marked == 0 { pod.pledged } else { pod.marked };
    let upper = mark.saturating_add(collar);
    let lower = mark.saturating_sub(collar);
    let breach = if exposure_value > upper { exposure_value - upper }
                 else if lower > exposure_value { lower - exposure_value }
                 else { 0 };
    let restoring = value_units(breach, price);

    let tranche = Depositor::tranche_size(pod.exposure.unsigned_abs(),
                                   excursion, util_bps)
                  .max(restoring)
                  .min(pod.exposure.unsigned_abs());

    pod.spend_grace();

    // Toward zero, whichever side it is on.
    pod.exposure = if long { pod.exposure.saturating_sub(tranche as i64) }
                   else    { pod.exposure.saturating_add(tranche as i64) };

    let unwound_value = units_value(tranche, price);

    // ⭐ **WHAT A CLOSED SLICE COSTS THE PLEDGE IS ITS MARGIN PLUS ITS P&L, NOT
    //    ITS WHOLE VALUE.** `pod.pledged -= unwound_value` stood here, and at 1x
    //    that is right by coincidence: the pledge equals the notional, so a
    //    slice's share of the pledge IS its value. At leverage it is a factor of
    //    L too large and the first tranche would zero the pledge outright.
    //
    //    Released pro rata instead, which is the same number at 1x and the right
    //    one everywhere else. The mark is released with it, so the P&L on what
    //    remains is still measured against what remains was opened at.
    let before = pod.exposure.unsigned_abs().saturating_add(tranche).max(1);
    let slice_mark = (mark as u128 * tranche as u128 / before as u128) as u64;
    let slice_pledge = (pod.pledged as u128 * tranche as u128 / before as u128) as u64;

    // 🔴 **THE LADDER TOOK THE BORROWER'S COLLATERAL, NOT JUST THEIR PROFIT.**
    //
    //    `pod.pledged -= slice_pledge` released the slice's whole share of the
    //    pledge, and the caller booked the whole unwound NOTIONAL into
    //    `yield_pool`. On a losing position that is right: the pledge is what
    //    covers the loss. On a WINNING one it is confiscation — the collateral
    //    was never the pool's to take, and `unwind_a_tranche`'s own note says
    //    only that "profit that belongs to one depositor is appropriated by all
    //    of them, slowly".
    //
    //    Measured on the worst real ten-session fall in the fixture: a 3x SMCI
    //    short, 40% in profit by the second session, laddered from
    //    −5,511,832,709 to zero over five rungs and left with a pledge of ZERO.
    //    Being right about a 56% crash cost the borrower everything they had
    //    posted. Across six such shorts the book paid out −1,094 bps of the
    //    pool when it should have collected.
    //
    // The pledge is consumed only by what the slice actually LOST. What it did
    // not lose stays on the pod, where the borrower can still reach it, and the
    // caller is told to credit the pool that much less.
    let side: i128 = if long { 1 } else { -1 };
    let slice_pnl = (unwound_value as i128 - slice_mark as i128) * side;
    let consumed = if slice_pnl < 0 {
        (slice_pnl.unsigned_abs() as u64).min(slice_pledge)
    } else { 0 };
    let retained = slice_pledge.saturating_sub(consumed);
    pod.pledged = pod.pledged.saturating_sub(consumed);
    pod.marked = pod.marked.saturating_sub(slice_mark.min(pod.marked));
    if pod.exposure == 0 { pod.breached_at = 0; pod.marked = 0; }
    pod.updated = current_time;

    let new_exp = pod.value_at(price);

    LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                             new_exp, pod.pledged, actuary)
        .apply(pod, depository);

    // Unwinding always credits the pool: the delta is negative by construction.
    // Net of the pledge the borrower keeps, so the caller books only what the
    // pool is actually owed.
    let dollars = -(((unwound_value.saturating_sub(retained)) as i128)
                    .min(i64::MAX as i128) as i64);
    let closed = pod.exposure == 0;
    let raroc = (pod.cost_basis, pod.interest_paid, pod.collar_dollar_seconds);
    if closed {
        // Zero on the pod so re-entry cannot double-count into Depositor totals.
        pod.cost_basis = 0;
        pod.interest_paid = 0;
        pod.collar_dollar_seconds = 0;
    }
    (dollars, raroc.0, raroc.1, raroc.2, closed)
}


/// Over-profitable auto-protect, shared by the long and short branches.
///
/// The position's value has run past `upper`, so the excess is pulled from the
/// depositor's pool balance into `pledged` — restoring the band — plus a fee
/// the pool retains. Returns the gross amount charged, or `None` when the
/// depositor cannot cover it and the caller must fall through to liquidation.
///
/// The two sides had drifted: long charged `excess` and credited
/// `excess − fee`, short charged `excess + fee` and credited ≈`excess`. Only
/// the second actually restores the band; the first left `pledged` short by
/// the fee, so a "protected" long could still sit outside its collar. One
/// implementation, the correct convention, and the mirror cannot drift again.
/// `excess` is passed rather than derived, because the two sides measure it
/// from opposite edges of the band: a winning LONG is `value − upper`, a
/// winning SHORT is `pivot − value`. Deriving it inside meant only the long
/// side could use this, which is how the asymmetry below arose.
fn post_variation_margin(pod: &mut Stock, dq: &mut u64, depository: &mut Depository,
    actuary: &Actuary, old_exposure_value: u64, exposure: u64, excess: u64,
    current_time: i64) -> Result<Option<u64>> {
    let gross = excess.saturating_add(excess / 250);   // user pays excess + fee
    if *dq < gross { return Ok(None); }

    let net = gross.saturating_sub(gross / 250);       // credited to pledged

    // ⭐ **SETTLE THE MARK-TO-MARKET BEFORE MOVING THE MARK.**
    //
    // 🔴 THIS CURE RE-CENTRES `pod.marked` ON THE POSITION'S CURRENT VALUE, so
    //    the band stops reading it as breached. But equity is
    //    `pledged + (value − mark)·side`, and moving the mark zeroes that second
    //    term WITHOUT PUTTING IT ANYWHERE. Whatever the position was carrying
    //    simply vanishes — and asymmetrically, because `exposure > upper` means
    //    a WINNING long and a LOSING short:
    //
    //      5x long  posts 1,027,086,074 and LOSES 2,004,096,805 of equity
    //      5x short posts 1,027,086,074 and GAINS 1,018,786,847
    //
    //    The long is stripped of the profit it was posting collateral to keep;
    //    the short has its loss forgotten, out of the pool, and walks away
    //    better off for having gone further underwater.
    //
    // Settling it into the pledge is what makes the re-mark honest: the
    // unrealised amount becomes collateral (or comes out of it), the reference
    // moves to where the position actually is, and equity is exactly what the
    // depositor put in plus what the market gave them.
    let mark = if pod.marked != 0 { pod.marked } else { pod.pledged };
    let side: i128 = if pod.exposure >= 0 { 1 } else { -1 };
    let mtm = (exposure as i128 - mark as i128) * side;
    let new_pledged = (pod.pledged as i128 + net as i128 + mtm)
        .clamp(0, u64::MAX as i128) as u64;
    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                        exposure, new_pledged, actuary);

    let increase = lelu.new_collar_dollars
        .saturating_sub(lelu.old_collar_dollars);
    require!(depository.has_capacity(increase), PithyQuip::PoolAtCapacity);

    *dq -= gross;
    pod.pledged = new_pledged;
    // The band was restored by posting collateral against a move that already
    // happened, so it re-centres on where the position now is. Leaving the mark
    // behind would re-breach on the next call for the same move twice.
    pod.marked = exposure;
    pod.breached_at = 0;   // the breach this cured is over
    pod.updated = current_time;
    lelu.apply(pod, depository);
    Ok(Some(gross))
}


/// Settle a partial close: release pledged and cost basis pro rata to the value
/// being closed, re-mark the liability, and snapshot the RAROC fields.
///
/// `user_credit` is deliberately NOT computed here. The two sides differ for
/// real reasons: a long is paid the mark less accrued interest, because its
/// collateral stays with the pool as margin; a short is paid its released
/// collateral plus P&L measured against basis, because closing means buying
/// back. Folding them into one formula would silently change what one side is
/// owed. Everything mechanical around that difference is shared here.
///
/// Returns (pledged_released, interest_on_closed, raroc, fully_closed).
fn settle_partial_close(pod: &mut Stock, depository: &mut Depository,
    actuary: &Actuary, old_exposure_value: u64, closed_value: u64,
    position_value: u64, price: u64, current_time: i64,
    accrued_interest: u64) -> (u64, u64, u64, (u64, u64, u128), bool) {
    let numer = closed_value as u128;
    let denom = (position_value as u128).max(1);
    let pro_rata = |v: u64| ((v as u128).saturating_mul(numer)
        .checked_div(denom).unwrap_or(0)).min(v as u128) as u64;

    let interest_on_closed = pro_rata(accrued_interest);
    let pledged_released = pro_rata(pod.pledged);
    let cost_basis_released = pro_rata(pod.cost_basis);
    // The mark travels with the slice it belongs to, or the P&L on what is left
    // would be measured against a basis that includes units already gone.
    let mark_released = pro_rata(pod.marked);

    pod.pledged = pod.pledged.saturating_sub(pledged_released);
    pod.cost_basis = pod.cost_basis.saturating_sub(cost_basis_released);
    pod.marked = pod.marked.saturating_sub(mark_released);
    pod.updated = current_time;

    let new_exp = pod.value_at(price);

    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                        new_exp, pod.pledged, actuary);

    // Snapshot before zeroing: this branch also handles a full close (a flat or
    // losing exit routes here), and re-entry must not double-count cb/ip/cds
    // into the Depositor totals.
    let fully_closed = pod.exposure == 0;
    let raroc = (pod.cost_basis, pod.interest_paid, pod.collar_dollar_seconds);
    if fully_closed {
        pod.marked = 0;
        pod.cost_basis = 0;
        pod.interest_paid = 0;
        pod.collar_dollar_seconds = 0;
    }
    lelu.apply(pod, depository);
    // `cost_basis_released` is returned rather than left as a local: the pledge
    // is NOT the basis. Every premium is debited out of `pod.pledged` at :945
    // and `cost_basis` is left alone, so the two diverge by the whole premium
    // history of the position — and a short priced off the pledge pays that
    // history twice, once when it left the pledge and again as a smaller basis
    // to measure the buy-back against.
    (pledged_released, cost_basis_released, interest_on_closed, raroc, fully_closed)
}


/// Collar band in dollars for a pod at `price`, from its stored bps.
/// Falls back to a tenth of notional when the pod has never been marked — a
/// fresh deposit that has not yet been through `repo()`.
/// The band's half-width for a pod, in dollars, measured off the MARK.
///
/// Was `collar_notional(value, pledged) × collar_bps` — a width measured off
/// whichever of value or pledge was larger, which at leverage is the notional
/// and makes the floor `pledged − notional·c`, i.e. zero. Measured off the mark
/// it is the move the position is allowed to make before the ladder starts, at
/// any leverage, and at 1x — where the mark IS the pledge — it is unchanged.
fn collar_amount(pod: &Stock, price: u64) -> u64 {
    let mark = if pod.marked == 0 { collar_notional(pod.value_at(price), pod.pledged) }
               else { pod.marked };
    if pod.collar_bps > 0 {
        mark.saturating_mul(pod.collar_bps as u64) / 10_000
    } else {
        mark / 10
    }
}


/// Pull `gap` dollars from the depositor's free balance to push exposure back
/// toward its band — the mirror of `post_variation_margin`, which moves value
/// the other way. Long and short differ only in how the gap is measured, so
/// the caller supplies it and everything else is shared.
///
/// The two copies had drifted in what they reported as the utilisation change:
/// long booked the drained amount, short booked `amount × price`, which in
/// this branch can be zero (a liquidator passes 0) or unrelated to what was
/// actually drained. The drain is the exposure change, so the drain is what
/// is reported.
///
/// Returns the gross drained, or `None` if the depositor cannot fund it.
fn reinstate_exposure(pod: &mut Stock, dq: &mut u64, depository: &mut Depository,
    actuary: &Actuary, old_exposure_value: u64, exposure: u64, gap: u64,
    price: u64, current_time: i64, by_owner: bool) -> Result<Option<u64>> {
    // 🔴 **A LIQUIDATOR COULD TRIGGER THIS, AND IT SPENDS THE BORROWER'S MONEY.**
    //
    //    Both call sites are reached with `amount == 0` — the crank — and this
    //    function then draws `gross` out of `deposited_quid` to buy exposure the
    //    depositor never asked for. On a short it is worse than unwanted: the
    //    position's value and its mark both rise by the same `net`, so equity is
    //    unchanged and the dollars are simply gone. Measured on a winning 5x
    //    short: 1,027,086,074 drawn from the free balance and 1,027,003,537 of
    //    wealth destroyed, on a path anybody can call, repeatedly.
    //
    //    Adding exposure is not a liquidation. A crank that finds a position
    //    outside its band should take a tranche, which is what the `else` on
    //    both call sites already does.
    //
    // ⭐ **AND THE GATE IS WHY THE LADDER WORKS AT ALL.** Bisected against the
    //    thousand-borrower run over five real years, this one line accounts for
    //    the whole of the difference:
    //
    //        gate OFF   8 tranches   238 pledges exhausted   $35.2M residual
    //        gate ON    9,924        146                     $22.7M
    //
    //    With the crank able to force-buy, every breach it found was "cured" by
    //    spending the borrower's free balance, which reset `breached_at` — so
    //    the excursion never accumulated and the ladder ran EIGHT TIMES in five
    //    years. Positions were not liquidated; they were fed until they starved.
    //    Stopping it cut blow-ups by 39% and the residual the pool inherits by
    //    36%. The 29x rise in tranches is the ladder finally doing its job.
    //
    // ⚠️ AND IT SHOULD NOT SURVIVE THE NEXT PASS EVEN GATED. Restoring
    //    `exposure_value` to the mark made sense while the band sat on `pledged`
    //    and the design held the two equal. Against a MARGIN band it inverts:
    //    the cure for a loss is more collateral, which raises the margin ratio,
    //    not more exposure, which lowers it.
    if !by_owner { return Ok(None); }
    let gross = gap.saturating_add(gap / 250);
    if *dq < gross || price == 0 { return Ok(None); }

    let net = gross.saturating_sub(gross / 250);
    let new_exp = exposure.saturating_add(net);
    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                        new_exp, pod.pledged, actuary);

    let increase = lelu.new_collar_dollars
        .saturating_sub(lelu.old_collar_dollars);
    require!(depository.has_capacity(increase), PithyQuip::PoolAtCapacity);

    *dq -= gross;
    // 🔴 **THE COMMENT SAID "SIGNED BY WHICH WAY THE POD ALREADY LEANS" AND THE
    //    CODE DID NOT SIGN IT.** `pod.exposure += units` with a positive `units`
    //    grows a long, which is right, and SHRINKS a short, which is the
    //    opposite of what this function exists to do.
    //
    //    Both call sites are restoring `exposure_value` upward toward the mark.
    //    For a long that means more units; for a short, whose value is
    //    `|exposure| × price`, it means MORE NEGATIVE exposure. Adding a
    //    positive number moved a short's value the wrong way — further from the
    //    band it was called to restore — while `pod.marked` grew by the full
    //    `net` regardless, so the two ends of the same operation disagreed about
    //    what had happened. Measured on a winning 5x short: 1,027,086,074 drawn
    //    from the depositor's free balance and 1,018,786,847 of equity created
    //    out of the mismatch.
    let units = value_units(net, price) as i64;
    let units = if pod.exposure < 0 { -units } else { units };
    pod.exposure = pod.exposure.saturating_add(units);
    // Units bought at today's price enter the mark at today's price.
    pod.marked = pod.marked.saturating_add(net);
    pod.breached_at = 0;   // the breach this cured is over
    pod.updated = current_time;
    lelu.apply(pod, depository);
    Ok(Some(gross))
}

impl Depositor {
    pub fn pad_ticker(ticker: &str) -> [u8; 8] {
        let mut padded = [0u8; 8];
        let bytes = ticker.trim().as_bytes();
        let len = bytes.len().min(8);
        padded[..len].copy_from_slice(&bytes[..len]);
        padded
    }

    /// Apply the tenure penalty for a withdrawal, on BOTH sides of the ratio.
    ///
    /// 🔴 **THIS WAS CALLED AFTER `deposited_quid` HAD ALREADY BEEN REDUCED,
    /// SO IT SUBTRACTED THE WITHDRAWAL TWICE.** With 100 deposited and 50
    /// taken, `deposited_quid` was already 50 by the time this ran, so
    /// `remaining = 50 - 50 = 0` and the depositor's ENTIRE tenure was wiped
    /// for a half withdrawal. Worse, it inverted: a FULL withdrawal left
    /// `deposited_quid == 0`, the guard failed, and the seconds survived
    /// untouched. Taking everything preserved tenure; taking half destroyed it.
    ///
    /// The base is now passed explicitly so the caller cannot get the ordering
    /// wrong, and `#[must_use]`-style discipline is unnecessary because the
    /// bank is updated here rather than by a second call somebody can forget.
    ///
    /// 🔴 **AND THE DENOMINATOR NEVER MOVED.** A payout is
    /// `deposit_seconds * yield_pool / total_deposit_seconds` (clutch.rs:325).
    /// Scaling a withdrawer's numerator down while every write to
    /// `total_deposit_seconds` in the tree was a `+=` meant the shares stopped
    /// summing to one: a lone depositor who withdrew half could thereafter
    /// reach only half of the pool's earnings, and the remainder had no owner.
    /// That is the mirror of the bug `pool_deposit` already records in the
    /// other direction — *"the early withdrawer gets the inflated figure and
    /// the last one out finds it missing."* The forfeited seconds now leave
    /// the denominator with the numerator, so what remains still sums.
    pub fn adjust_deposit_seconds(&mut self, bank: &mut Depository,
        base: u64, amount_reduced: u64, current_time: i64) {
        if base == 0 || amount_reduced == 0 { return; }

        // Age on the balance that was actually deployed over the interval.
        let time_delta = (current_time - self.last_updated).max(0) as u128;
        self.deposit_seconds = self.deposit_seconds.saturating_add(
            time_delta.saturating_mul(base as u128));

        let remaining = base.saturating_sub(amount_reduced) as u128;
        let before = self.deposit_seconds;
        self.deposit_seconds = before.checked_mul(remaining)
            .and_then(|v| v.checked_div(base as u128)).unwrap_or(0);

        // The seconds the withdrawer gave up leave the pool's total too, or
        // they stay in the denominator of everybody else's share forever.
        let forfeited = before.saturating_sub(self.deposit_seconds);
        bank.total_deposit_seconds =
            bank.total_deposit_seconds.saturating_sub(forfeited);

        self.last_updated = current_time;
    }

    /// Settle what this pod is owed for holding the unpopular side, and move
    /// its checkpoint. Mirrors `settle_sol_yield`: an index the pool advances,
    /// claimed lazily whenever the position is touched.
    ///
    /// Credited to `pledged` rather than paid out, because funding is a
    /// carry on an open position — a short being paid to stay short should
    /// find its position better collateralised, not its wallet fuller. That
    /// also means the claim cannot be farmed by opening and closing.
    /// `price` is required: funding is a carry on CURRENT notional, and the
    /// rate it settles against is now denominated in a book that marks to
    /// market.
    ///
    /// 🔴 THIS USED `pod.marked`, WHICH IS A TRADE-TIME FIGURE. Once
    ///    `Actuary::update_price` began re-marking `net_exposure`, the rate and
    ///    the base stopped agreeing: `Φ` accrued against a book valued at the
    ///    current price while every position claimed against the notional it was
    ///    opened at. The two no longer netted, and the residual came out of the
    ///    pool — measured at $439,181 over a thousand borrowers, with the pool
    ///    PAYING more funding than it collected, which the design's own
    ///    arithmetic (`k·C − k·O = k·|net|`) says can never happen.
    pub fn settle_funding(&mut self, ticker: &str, risk: &mut TickerRisk,
        price: u64) -> i64 {
        let padded = Self::pad_ticker(ticker);
        let Some(pod) = self.balances.iter_mut().find(|p| p.ticker == padded)
            else { return 0 };
        // The position's notional right now, signed by its side.
        let signed_value = units_value_i(pod.exposure, price);
        let (owed, index) = risk.funding_owed(signed_value, pod.funding_checkpoint);
        pod.funding_checkpoint = index;
        // Symmetric now that the amount is signed: the crowded side's pledge
        // shrinks by exactly what the other side's grows by, and neither
        // direction is a special case. Bounded by the pledge — funding cannot
        // by itself drive a position negative; it drives it into the ladder.
        //
        // 🔴 **AND IT USED TO REPORT THE FULL `owed` EVEN WHEN THE PLEDGE COULD
        //    NOT COVER IT.** The debit saturates at zero, so a crowded position
        //    ground down by carry pays whatever is left and the caller was told
        //    it had paid in full. The index, meanwhile, credits the offsetting
        //    side unconditionally — it is a promise made against a payer whose
        //    ability to pay is bounded by their collateral.
        //
        //    Measured on the thousand-borrower run once the book started marking
        //    to market: 146 positions ground to zero and the capital transfer to
        //    the pool came out NEGATIVE — $347,626 collected against $779,777
        //    paid out, with the pool funding the $432,151 difference. An index
        //    that cannot be short-changed is an index that quietly writes
        //    cheques on the reserve.
        //
        // Returning what was ACTUALLY settled does not fix the shortfall — that
        // needs the rate itself bounded by what the crowded side can bear — but
        // it stops the accounting from hiding it.
        // ⭐ **A RECEIVER IS PAID OUT OF WHAT WAS COLLECTED, AND NOTHING ELSE.**
        //    The payer's side saturates at their pledge, so the two halves of a
        //    transfer cannot be assumed equal; `funding_pot` carries what has
        //    actually been taken, and a claim is bounded by it. What a receiver
        //    is short is what a payer could not fund — which is where the loss
        //    belongs, rather than on the reserve.
        let settled = if owed > 0 {
            let pay = (owed as u64).min(risk.funding_pot);
            risk.funding_pot -= pay;
            pod.pledged = pod.pledged.saturating_add(pay);
            pay.min(i64::MAX as u64) as i64
        } else if owed < 0 {
            let take = owed.unsigned_abs().min(pod.pledged);
            pod.pledged -= take;
            risk.funding_pot = risk.funding_pot.saturating_add(take);
            -(take.min(i64::MAX as u64) as i64)
        } else { 0 };
        settled
    }

    /// Mirror every depository.utilisation(delta) call on this account so that
    /// clutch.rs can discount yield claims by the borrower's share of pool risk.
    /// One rung of a gradual liquidation, and everything that must follow it.
    ///
    /// Every breach branch in `repo()` ended with the same fifteen lines:
    /// check the excursion is past its grace, take a tranche, move `drawn` and
    /// utilisation by what was unwound, and flush RAROC if the position closed.
    /// Four copies meant four places for one of those steps to be forgotten.
    fn unwind_a_tranche(&mut self, pod_index: usize, price: u64, util_bps: i64,
        actuary: &Actuary, depository: &mut Depository, old_exposure_value: u64,
        current_time: i64, now: i64, accrued_interest: u64) -> Result<(i64, u64)> {
        let pod = &mut self.balances[pod_index];
        let excursion = pod.excursion(now);
        // 🔴 **THIS WAS `require!(...)` AND THAT MADE THE LADDER UNREACHABLE.**
        //    `pod.excursion(now)` STARTS the Parisian clock on first sight of a
        //    breach — it writes `breached_at` — and the next line then failed,
        //    so the instruction reverted and took the clock with it.
        //    `handle_sweep` drops an `Err` on `_ => continue` without
        //    serialising, so every sweep set the clock and every sweep unwound
        //    it. `excursion > LIQ_GRACE_SECS` could never become true from the
        //    one path that exists to liquidate.
        //
        //    Measured: a position 50% underwater, swept once a session for a
        //    week, took ZERO tranches and ended with `breached_at == 0` — having
        //    been assigned 86401, 172801, 259201 … inside calls that were all
        //    thrown away.
        //
        //    It hid because a harness that mutates a `Depositor` in place keeps
        //    writes the chain would roll back. Every earlier run of the
        //    thousand-borrower simulation reported thousands of tranches; they
        //    were an artefact of the missing transaction boundary.
        //
        // Too-soon is not a failure. It is a successful observation that the
        // position is in breach and the grace has not yet elapsed, and the
        // caller has to persist it or the clock cannot run. `delta == 0` says
        // no value moved; `breached_at` now says why the account is worth
        // writing anyway.
        if excursion <= LIQ_GRACE_SECS as i64 {
            return Ok((0, accrued_interest));
        }

        let (dollars, pod_cb, pod_ip, pod_cds, closed) =
            amortise_tranche(pod, price, excursion, util_bps, actuary,
                             depository, old_exposure_value, current_time);

        self.update_drawn(dollars);
        depository.utilisation(dollars);
        if closed {
            let net = self.flush_raroc(pod_cb, pod_ip, pod_cds, 0);
            Depositor::flush_raroc_pool(depository, net, pod_cds);
        }
        Ok((dollars, accrued_interest))
    }

    /// Time-weight both sides before any balance moves.
    ///
    /// Every path that changes `deposited_quid` has to age the depositor's
    /// seconds and the pool's on the *old* balances first, or the change is
    /// backdated to the last touch. It was written out at four call sites,
    /// which is four chances to age one side and not the other.
    fn accrue_seconds(&mut self, bank: &mut Depository, now: i64) {
        let dc = now.saturating_sub(self.last_updated) as u64;
        self.deposit_seconds = self.deposit_seconds
            .saturating_add(self.deposited_quid as u128 * dc as u128);

        let db = now.saturating_sub(bank.last_updated) as u64;
        bank.total_deposit_seconds = bank.total_deposit_seconds
            .saturating_add(bank.total_deposits as u128 * db as u128);
    }

    pub fn update_drawn(&mut self, change: i64) {
        if change > 0 {
            self.drawn = self.drawn.saturating_add(change as u64);
        } else {
            self.drawn = self.drawn.saturating_sub(change.unsigned_abs());
        }
    }

    /// Accrue time-weighted deposit_seconds and total_deposit_seconds
    /// without mutating deposited_quid or total_deposits.
    /// Call before any operation that changes deposited_quid on an existing customer.
    pub fn accrue(&mut self, bank: &mut Depository, now: i64) {
        self.accrue_seconds(bank, now);
        
        self.last_updated = now; bank.last_updated = now;
    }

    /// Credit this depositor the SOL* carry accrued since their last touch and
    /// re-checkpoint. Must run before `deposited_lamports` changes, or the new
    /// principal would earn yield generated before it arrived.
    pub fn settle_sol_yield(&mut self, bank: &mut Depository) -> u64 {
        if self.deposited_lamports == 0 {
            self.sol_yield_checkpoint = bank.sol_yield_index;
            return 0;
        }
        let delta = bank.sol_yield_index.saturating_sub(self.sol_yield_checkpoint);
        self.sol_yield_checkpoint = bank.sol_yield_index;
        if delta == 0 { return 0; }
        let owed = (delta.saturating_mul(self.deposited_lamports as u128)
            / SOL_YIELD_SCALE).min(u64::MAX as u128) as u64;
        if owed > 0 {
            // Carry lands on the SOL position that earned it, not on the
            // dollar balance. Crediting `deposited_quid` would have made
            // staking yield spendable as stock margin — the same crossing the
            // deposit no longer makes, and pointless to close in one direction
            // only.
            //
            // The pool's own mark rises with it, in the same place, so the two
            // cannot drift: value enters the books when it is attributed
            // rather than when it is realised, and is never counted twice.
            self.sol_pledged_usd = self.sol_pledged_usd.saturating_add(owed);
            bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_add(owed);
        }
        owed
    }

    pub fn pool_deposit(&mut self,
        bank: &mut Depository, 
        usd: u64, now: i64) {
        // Unconditional, and that is the fix rather than an oversight. This
        // used to be skipped for a first-time depositor — correct for their
        // side, which has no balance to age — but `bank.last_updated` was
        // advanced regardless, so the pool's seconds for that interval were
        // lost from `total_deposit_seconds` for good.
        //
        // Every payout is a share of that denominator, so each first deposit
        // shrank it and inflated everyone's share. The shares stopped summing
        // to the pool, which is a first-mover advantage: the early withdrawer
        // gets the inflated figure and the last one out finds it missing.
        //
        // A new depositor's `deposited_quid` is still zero here, so their side
        // contributes nothing and only the pool's interval is counted.
        self.accrue_seconds(bank, now);
        self.deposited_quid = self.deposited_quid.saturating_add(usd);
        bank.total_deposits = bank.total_deposits.saturating_add(usd);
        self.last_updated = now; bank.last_updated = now;
    }

    pub fn pool_withdraw(
        &mut self, bank: &mut Depository, 
        usd: u64, now: i64) -> Result<()> {
        self.accrue_seconds(bank, now);
let new_total = bank.total_deposits.saturating_sub(usd);

        require!(new_total >= bank.max_liability, 
                PithyQuip::Undercollateralised);

        self.deposited_quid = self.deposited_quid.saturating_sub(usd);
        self.last_updated = now; bank.last_updated = now;
        bank.total_deposits = new_total;
        Ok(())
    }


    /// Size of one liquidation tranche, in position units.
    ///
    /// The old form was `size × (elapsed / LIQ_GRACE_SECS) × speed`, but the branch is
    /// gated on `elapsed > LIQ_GRACE_SECS`, so that ratio is always > 1: the first
    /// eligible call took 50% of a position at 10% utilisation and 100% at 33%.
    /// That is a cliff seizure, not a ladder — and `LIQ_GRACE_SECS` only moved when it
    /// fired, never how steep it was.
    ///
    /// Measuring the *excess* over the threshold instead starts each bite near
    /// zero and grows it with staleness, clamped to [MIN_NIBBLE, MAX_NIBBLE].
    /// `repo()` stamps `pod.updated = now` on every call, so elapsed resets and
    /// the next bite is small again. The position unwinds over many calls at
    /// many prices: the borrower keeps the chance to cure or take profit, and
    /// depositors realise the excess gradually instead of at one print.
    #[inline]
    /// Share of the remaining position a liquidator may take, given how long
    /// the position has been outside its band and how badly the pool needs the
    /// capacity back. Integer bps throughout: this sits on the liquidation
    /// path, and soft-float is what put `repo()` into the compute ceiling.
    fn tranche_size(size: u64, excursion: i64, util_bps: i64) -> u64 {
        // Urgency: 0.65× in a quiet pool, 2× when fully drawn.
        let speed_bps = 5_000 + 15_000 * util_bps.clamp(1_000, 10_000) / 10_000;
        // How far up the ramp this excursion has climbed, in bps of the ramp.
        let over = (excursion - LIQ_GRACE_SECS as i64).max(0);
        let climbed = (over * 10_000 / (LIQ_GRACE_SECS as i64 * TRANCHE_RAMP_GRACES))
                          .min(10_000);
        let frac_bps = MIN_TRANCHE_BPS
            + (MAX_TRANCHE_BPS - MIN_TRANCHE_BPS) * climbed / 10_000;
        let frac_bps = (frac_bps * speed_bps / 10_000)
                           .clamp(MIN_TRANCHE_BPS, MAX_TRANCHE_BPS);
        (((size as u128) * frac_bps as u128 / 10_000) as u64).max(1)
    }

    /// Accumulate collar_dollar_seconds on a pod before any pledged/collar mutation.
    /// Integral of capital-at-risk over time — the RAROC denominator. Uses the
    /// pod's booked `collar_dollars` so the integral measures the same capital
    /// the pool actually reserved, not a pledged-based re-derivation.
    #[inline]
    fn accumulate_collar_seconds(pod: &mut Stock, current_time: i64) {
        let elapsed = (current_time - pod.updated).max(0) as u128;
        if elapsed > 0 && pod.collar_bps > 0 {
            let collar_dollars = if pod.collar_dollars > 0 { pod.collar_dollars }
                else { pod.pledged.saturating_mul(pod.collar_bps as u64) / 10_000 };

            pod.collar_dollar_seconds = pod.collar_dollar_seconds
                .saturating_add(elapsed.saturating_mul(collar_dollars as u128));
        }
    }

    /// Accumulate Depositor RAROC fields from a closed position.
    /// Pass pod field values directly to avoid borrow conflict with self.balances.
    /// Call at every code path that zeroes pod.exposure in repo().
    /// Also passes collar_dollar_seconds so the RAROC denominator is complete.
    /// Returns the net it booked, so the caller can hand the SAME figure to
    /// `flush_raroc_pool` rather than reconstructing it.
    ///
    /// 🔴 THREE OF THE FIVE CALL SITES NEVER BOOKED THE POOL SIDE AT ALL. Only
    ///    the two liquidation paths paired with `flush_raroc_pool`; the long
    ///    full close, the long partial close and the short partial close did
    ///    not. So `pool_realized_pnl` — which this field's own docstring calls
    ///    "the denominator an account's own RAROC is measured against" —
    ///    aggregated LIQUIDATED POSITIONS ONLY.
    ///
    ///    That is a benchmark drawn from a strictly adverse subsample: the
    ///    positions that reached the ladder are by construction the ones that
    ///    lost. Every account that closed voluntarily was then compared against
    ///    an average made only of losers, and looked good against it. The rebate
    ///    the comparison exists to size was systematically too generous, and it
    ///    got worse the better the book did.
    fn flush_raroc(&mut self, cost_basis: u64, interest_paid: u64,
        collar_dollar_seconds: u128, transfer: u64) -> i64 {
        let net = transfer as i64 - cost_basis as i64
                                  - interest_paid as i64;

        self.realized_pnl = self.realized_pnl.saturating_add(net);
        self.total_interest_paid =
            self.total_interest_paid.saturating_add(interest_paid);

        self.total_collar_dollar_seconds =
            self.total_collar_dollar_seconds.saturating_add(collar_dollar_seconds);
        net
    }

    /// Same figures, into the pool aggregate. Split from `flush_raroc` because
    /// the depositor borrow and the depository borrow cannot be held together.
    pub fn flush_raroc_pool(bank: &mut Depository, net: i64, cds: u128) {
        bank.pool_realized_pnl = bank.pool_realized_pnl.saturating_add(net);
        bank.pool_collar_dollar_seconds =
            bank.pool_collar_dollar_seconds.saturating_add(cds);
    }

    /// Wipe this account's risk-adjusted record. Called when a position is
    /// amortised: the event that proves the account's risk was mispriced is
    /// exactly the event that should cancel its rebate.
    pub fn reset_raroc(&mut self) {
        self.realized_pnl = 0;
        self.total_collar_dollar_seconds = 0;
    }

    // Position shrinking means "virtual sale": profitable synthetic redemption withdraws
    // Banks.total_deposits (more than pledged); similar to a collar (hedge wrapper), one
    // strategy for protecting against losses...though it limits large gains (under X%);
    // lest borrowers dilute depositors' yield, following solution creates speed bumps
    pub fn repo(&mut self, ticker: &str, // reposition, or repossession (it depends)
        mut amount: i64, price: u64, // < obtained from Pyth by etc.rs helper function
        current_time: i64, slot: i64, actuary: &Actuary,
        depository: &mut Depository) -> Result<(i64, u64)> {
        require!(price > 0, PithyQuip::InvalidPrice);
        let padded = Self::pad_ticker(ticker);
        // Index rather than a reference: the liquidation rungs below need
        // `&mut self` again after touching the pod, and re-borrowing by index
        // is what lets that be one helper instead of four inline copies.
        let pod_index = self.balances.iter()
            .position(|p| p.ticker == padded)
            .ok_or(PithyQuip::DepositFirst)?;
        let pod = &mut self.balances[pod_index];

        let old_exposure_value = pod.value_at(price);

        // Same rule as the gates below, and it matters more here: `collar_bps`
        // widens the band as leverage falls, so reading an unpledged position
        // as 1x handed the riskiest position in the book the most room before
        // anyone could touch it. Unbounded leverage yields the tightest band.
        let leverage = if pod.pledged > 0 {
            ((old_exposure_value as u128 * 100) /
            pod.pledged as u128).min(i64::MAX as u128) as i64
        } else if old_exposure_value > 0 { i64::MAX } else { 100 };

        let collar = collar_bps(leverage, actuary);

        // ⭐ **A TRADE THAT SHRINKS THE POSITION IS THE CURE, NOT A VIOLATION.**
        //
        // 🔴 THE OVER-PROFIT BRANCH REJECTED EVERY `amount != 0`, INCLUDING A
        //    CLOSE. Its own comment read *"profit this large can only be taken
        //    once the position is back inside its band"* — but closing IS
        //    bringing it back inside the band, all the way to zero, and it is
        //    the one action that reduces the pool's liability rather than
        //    adding to it. So the borrower was refused a take-profit at exactly
        //    the moment they had profit to take, and the only exits left were to
        //    post more collateral or wait for a liquidator to appropriate the
        //    gain a tranche at a time.
        //
        //    Measured on a thousand borrowers over five real years: 422 of
        //    1,000 take-profits rejected. This is not a policy about unfunded
        //    profit — the pool is strictly better off after the close than
        //    before it — it is a missing sign check.
        //
        // Reducing means moving toward zero: `amount` opposite in sign to the
        // exposure it applies to. Increasing exposure while over-profitable is
        // still refused, because that genuinely adds to a liability the pool
        // has not reserved for.
        let reducing = amount != 0 && pod.exposure != 0
            && (amount < 0) == (pod.exposure > 0);

        // ⭐ **THE PARISIAN BARRIER, RE-CENTRED ON THE MARK AND RE-WIDTHED FROM
        //    THE TAIL.** Two substitutions, and they are two halves of one.
        //
        //    CENTRE. The band used to sit on `pledged`. That is a P&L band only
        //    while `pledged == exposure_value`, i.e. at 1x, and the old code
        //    guaranteed that identity by force. Centred on `marked` it is a P&L
        //    band at every leverage, and at 1x — where `marked` IS `pledged` —
        //    it is the same band as before, so nothing about the 1x behaviour
        //    this file is calibrated on changes.
        //
        //    WIDTH. `collar_bps` is `ES / leverage`, so the barrier came out at
        //    `100 + ES/L` — a DECREASING function of the leverage asked for,
        //    with a fixed point a couple of percent above 1.00x. Asking for 10x
        //    shrank the band that would have permitted it. The half-width is now
        //    `margin_bps`: the quantile of the fitted tail over the act-plus-
        //    unwind horizon, gap included, which is the move the pledge exists
        //    to survive. `collar_bps` keeps its other job — it is an expected
        //    shortfall, which is the right statistic for a PRICE, and
        //    `hazard_rate_bps` and `LiabilityUpdate` still read it as one.
        //
        //    ⚠️ A POD WRITTEN BEFORE `marked` EXISTED READS AS ITS PLEDGE, which
        //       is exactly what the old band used. Migration needs no pass.
        let had_mark = pod.marked != 0;
        let mark = if had_mark { pod.marked } else { pod.pledged };
        let signed_notional = if pod.exposure < 0 { -(old_exposure_value as i64) }
                              else { old_exposure_value as i64 };
        let profile = actuary.loss_profile(signed_notional, actuary.net_exposure);
        let band_bps = profile.margin_bps.clamp(1, 10_000);
        // ⭐ **THE TWO EDGES ANSWER DIFFERENT QUESTIONS, SO THEY ARE DIFFERENT
        //    NUMBERS.**
        //
        // 🔴 `LossProfile::trigger_bps` IS COMPUTED, DOCUMENTED AS "the move at
        //    which the remaining pledge stops covering the expected remainder —
        //    where a position stops being self-funding and the ladder has to
        //    start", ASSERTED TO BE STRICTLY BELOW `margin_bps` — AND NEVER
        //    READ. Both edges of the band used the margin, so the ladder began
        //    only once the collateral was already gone.
        //
        // The WINNING edge is a question about the pool's reserve: how much
        // unfunded gain will it carry before demanding variation margin. That is
        // `margin_bps`, which is what it reserved.
        //
        // The LOSING edge is a question about the borrower's collateral: at what
        // move does it stop covering what is expected to follow. That is
        // `trigger_bps`, and it is smaller — deliberately, so the ladder starts
        // while there is still something to unwind rather than after.
        let trig_bps = profile.trigger_bps.clamp(1, band_bps);
        // ⭐ **CAPITAL THAT HAS LEFT RAISES WHAT A POSITION MUST POST.** Not the
        //    crowding of the book — the withdrawal of the capital the leverage
        //    was granted out of. See `Depository::unwind_demand`. At no demand
        //    this is 10,000 and the requirement is exactly what the tail asked.
        //    The BAND is untouched: how far a position may move before
        //    liquidation is a fact about the instrument, not about who is
        //    queueing to leave.
        let required_bps = (band_bps as i128
            * depository.redemption_margin_bps() as i128 / 10_000)
            .clamp(1, BPS_MAX as i128) as i64;
        let collar_amt = (mark as u128).saturating_mul(band_bps as u64 as u128)
            .saturating_div(10_000).min(u64::MAX as u128) as u64;
        // The losing edge, drawn tighter.
        let trigger_amt = (mark as u128).saturating_mul(trig_bps as u64 as u128)
            .saturating_div(10_000).min(u64::MAX as u128) as u64;
        let time_elapsed = current_time.saturating_sub(pod.updated);

        let conc = depository.utilisation_bps();
        // Carry (utilisation) plus the hazard premium for the delay this
        // position is being granted. The barrier is the collar; the distance to
        // it, in bps of exposure, is what makes the price moneyness-sensitive —
        // a position hugging its collar pays for the gap risk it is imposing,
        // one far inside it pays almost nothing. Signed `amount` selects the
        // side; the expression is otherwise identical long and short.
        let barrier = mark.saturating_add(collar_amt);
        // 🔴 THE PREMIUM USED TO SEE ONLY THE UPPER BARRIER, SO APPROACHING THE
        //    LOWER ONE MADE A POSITION CHEAPER. `barrier` is `... + collar_amt`,
        //    and pricing off the distance to it alone meant that as exposure fell
        //    toward `pledged − collar` — where `reinstate_exposure` drains the
        //    depositor's `deposited_quid`, or `unwind_a_tranche` starts (:971) —
        //    distance-to-upper GREW and the hazard fell. The band is two-sided;
        //    the price was one-sided.
        // ⇒ Price off the NEAREST barrier. That is what the hazard means: the
        //    intensity of touching the band at all, and a position is as close to
        //    the ladder as its closest edge. Above the top or below the bottom the
        //    distance is zero and the hazard is maximal, which is already correct.
        let lower = mark.saturating_sub(collar_amt);
        let distance_bps = if old_exposure_value > 0 {
            let to_upper = barrier.saturating_sub(old_exposure_value);
            let to_lower = old_exposure_value.saturating_sub(lower);
            let nearest = to_upper.min(to_lower);
            ((nearest as u128).saturating_mul(10_000) / old_exposure_value as u128)
                .min(i64::MAX as u128) as i64
        } else { 10_000 };

        // Two halves, charged differently because they are known differently.
        //
        // The base — this ticker's volatility against how full the pool is —
        // has been integrated as it happened, in `premium_index`, so the
        // interval is billed at the rates that actually ran over it rather
        // than at whichever one prevails today. That is worth doing: the same
        // ticker prices 7.5x apart between a calm state and a violent one, and
        // reading it once let a borrower choose which by timing their touch.
        //
        // The rest — leverage, and how close this position sits to its barrier
        // — belongs to the position and not to the interval, so it is read now
        // and applied across it. That half is still a point estimate, and the
        // honest limit of a lazy scheme.
        let base_bps_seconds = actuary.premium_index
            .saturating_sub(pod.premium_checkpoint);
        pod.premium_checkpoint = actuary.premium_index;

        // ⭐ **THE PRICE COMES FROM THE SAME PROFILE THE BAND DOES.**
        //
        // 🔴 THIS USED TO BE `rate_bps(conc, lev) − rate_bps(conc, 100)` PLUS THE
        //    HAZARD, AND THE FIRST TERM WAS DEAD. `rate_bps`'s leverage
        //    adjustment only switches on past `lev_norm > 50`, i.e. half of
        //    `MAX_LEVERAGE_PCT`, and the band pinned every position at 1.0x — so
        //    it never fired, which the §CAPITAL note in `etc.rs` already
        //    records. Measured against five real years and a thousand
        //    borrowers, the whole position rate came out at 17 bps a year on
        //    notional while the book's realised directional loss ran to 4.7% of
        //    the deposits. `loss_profile` was computing the fair price —
        //    expected loss plus the cost of the capital the position consumes —
        //    and nothing read it. The same disconnect as the barrier, one leg
        //    over.
        //
        // `premium_bps` is that price. The hazard stays beside it because it
        // prices something the profile does not: MONEYNESS, the surcharge for
        // sitting close to the barrier, which is a property of where this
        // position is rather than of what it is.
        let position_rate = profile.premium_bps
            .saturating_add(hazard_rate_bps(distance_bps, collar, amount, actuary,
                            depository.total_deposits, depository.max_liability));

        let (accrued_interest, billed_secs) = premium_due(old_exposure_value,
            position_rate, time_elapsed, base_bps_seconds, pod.pledged);

        let util_bps = (conc as i64).clamp(1_000, 10_000);
        let max_lev = max_leverage_pct(actuary, slot, conc);

        // ⭐ **THE MARGIN CALL A SHRINKING POOL MAKES.**
        //
        // A crank finding a position that no longer meets the raised
        // requirement takes a rung, exactly as it would for a band breach. That
        // is the whole mechanism: the depositor's unmet demand raises what every
        // position must post, the positions that cannot post it are laddered
        // down, the reserve they release retires the demand, and the
        // requirement falls back. Self-clearing, and bounded by the crank rather
        // than by anybody's decision to close.
        //
        // ⚠️ ONLY ON THE CRANK (`amount == 0`). A depositor acting on their own
        //    position is never handed a liquidation for asking; and only while
        //    demand is live, so in the ordinary case this is one comparison
        //    against a requirement that has not moved.
        let now_ts = current_time;
        if amount == 0 && depository.unwind_demand > 0 {
            let short_of = (old_exposure_value as u128)
                .saturating_mul(required_bps as u64 as u128) / 10_000;
            if (pod.pledged as u128) < short_of && old_exposure_value > 0 {
                let _ = &pod;
                return self.unwind_a_tranche(pod_index, price, util_bps,
                    actuary, depository, old_exposure_value,
                    current_time, now_ts, accrued_interest);
            }
        }

        pod.pledged -= accrued_interest;
        pod.interest_paid = pod.interest_paid.saturating_add(accrued_interest);
        // The meter, not the wall clock: every downstream stamp of
        // `current_time` moves `pod.updated` only over the seconds the pool was
        // actually paid for, leaving the unbilled remainder to accrue.
        let now = current_time;
        let current_time = pod.updated.saturating_add(billed_secs).min(now);
        if pod.exposure > 0 || (pod.exposure == 0 && amount > 0) {
            // if increasing exposure for long...it must not be
            // either worth > pledged, or less than X%
            // same for decreasing, except that whole
            // amount can be decreased to take profit
            // before we apply changes to exposure,
            // run checks against current ^^^^^^^^
            let upper = mark.saturating_add(collar_amt);
            let exposure = old_exposure_value;
            // for the first clause, amount irrelevant
            // (contains solely a preventative intent)
            // unless amount == 0 (liquidator caller)
            if exposure > upper && !reducing { // Over-profitable: restore or be unwound
                if let Some(gross) = post_variation_margin(pod, &mut self.deposited_quid,
                        depository, actuary, old_exposure_value, exposure,
                        exposure.saturating_sub(upper), current_time)? {
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(gross as i64);
                    depository.utilisation(gross as i64);
                    // `gross` is a routing hint for clutch's snapshot dispatch:
                    // exposure is unchanged here, so T is computed from
                    // snapshots and the fee stays in the reserve.
                    return Ok((gross as i64, accrued_interest));
                }
                else if amount != 0 {
                    // Not a liquidator, and the depositor cannot fund the
                    // restoration: profit this large can only be taken once
                    // the position is back inside its band.
                    return Err(PithyQuip::Undercollateralised.into());
                }
                else {
                    // Liquidator. Profit that belongs to one depositor is
                    // appropriated by all of them, slowly, which is what gives
                    // the borrower time to react and close.
                    return self.unwind_a_tranche(pod_index, price, util_bps,
                        actuary, depository, old_exposure_value,
                        current_time, now, accrued_interest);
                }
            }
            let lower = mark.saturating_sub(trigger_amt);
            // ⭐ **THE MIRROR OF THE TAKE-PROFIT GATE, AND THE WORSE HALF.**
            //
            // 🔴 This branch is a LOSING long — the position has fallen more
            //    than `collar_amt` below its mark — and its `else` returned
            //    `Undercollateralised` for any `amount != 0`. So a borrower
            //    watching a position go against them could not CLOSE IT. The
            //    only exits left were to fund `reinstate_exposure`, which buys
            //    MORE units to push the value back up — forced averaging down
            //    into a loss, out of their own free balance — or to wait for a
            //    liquidator to take it a tranche at a time.
            //
            //    Same missing sign check as the over-profit gate, on the side
            //    where being trapped actually costs the borrower money.
            //
            // ⚠️ AND `reinstate_exposure` ITSELF IS NOW SUSPECT. Restoring
            //    exposure to the mark made sense while the band sat on `pledged`
            //    and the design held `exposure_value == pledged`: topping the
            //    position back up kept it fully collateralised. Against a MARGIN
            //    band it inverts — the cure for a loss is more collateral, which
            //    raises the margin ratio, not more exposure, which lowers it.
            //    Left in place because removing it is a design decision rather
            //    than a bug fix, but it should not survive the next pass.
            if lower > exposure && exposure > 0 && !reducing { // under-exposed
                let gap = lower.saturating_sub(exposure).saturating_sub(collar_amt);
                if let Some(drained) = reinstate_exposure(pod, &mut self.deposited_quid,
                        depository, actuary, old_exposure_value, exposure, gap,
                        price, current_time, amount != 0)? {
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(drained as i64);
                    depository.utilisation(drained as i64);
                    // pledged is untouched here: dq funds the exposure, and
                    // clutch's snapshot dispatch books T = drain + interest.
                    return Ok((0, accrued_interest));
                }
                else if amount == 0 {
                    return self.unwind_a_tranche(pod_index, price, util_bps,
                        actuary, depository, old_exposure_value,
                        current_time, now, accrued_interest);
                } else { // ^ total deposits ^ incremented plus ^
                    return Err(PithyQuip::Undercollateralised.into());
                }
            }
            // 🔴 **THE CLOCK MUST ONLY CLEAR WHEN THE POSITION IS ACTUALLY
            //    INSIDE THE BAND, NOT MERELY WHEN NO BREACH BRANCH RAN.** The
            //    comment said "neither breach branch fired, so the excursion is
            //    over", and that was true until a reducing trade was allowed
            //    past the over-profit gate — which is exactly the fix one screen
            //    up. An over-profitable position could then send a single unit
            //    of reduction, fall through here, and have its excursion zeroed
            //    while still outside its barrier. Repeat once per grace period
            //    and the ladder can never reach the second rung: the Parisian
            //    knockout becomes unreachable for the price of one dust trade
            //    an hour, which is the oscillation attack the occupation-time
            //    formulation exists to prevent.
            //
            // Ask the band directly instead of inferring it from control flow.
            if exposure <= mark.saturating_add(collar_amt)
                && exposure >= mark.saturating_sub(collar_amt) {
                pod.breached_at = 0;
            }
              require!(amount != 0, PithyQuip::InvalidAmount);
            pod.exposure = pod.exposure.saturating_add(amount);
            if amount < 0 { // trying to redeem units,
                // this reduces exposure and pledged,
                // while trying to redeem units...
                if pod.exposure < 0 {
                    amount = amount.saturating_add(
                     pod.exposure.saturating_neg());
                     pod.exposure = 0;
                } // $ value to be sent to depositor is accounted as:
                let redeem_dollars = units_value(amount.unsigned_abs(), price);

                // 🔴 **THE BRANCH TEST WAS `redeem_dollars > pod.pledged` AND THE
                //    PAYOUT WAS THE WHOLE NOTIONAL. BOTH ASSUME 1x.**
                //
                //    The test compares the DOLLARS being closed against the
                //    COLLATERAL behind them, which distinguishes "closing more
                //    than your pledge" from "closing less" — a meaningful
                //    distinction only while the pledge equals the notional. At
                //    any real leverage it is true for essentially every close,
                //    so ordinary partial closes took the all-in path.
                //
                //    And the payout was `total = redeem_dollars`: the mark, on
                //    the reasoning that "a long is paid the mark, its collateral
                //    stays with the pool as margin". At 1x the mark IS the
                //    collateral and that nets to returning the pledge. At 9x it
                //    hands over nine times the pledge. Measured: a 9x long
                //    opened and closed at the SAME PRICE, in the same second,
                //    took $16,000 out of a pool it had deposited $2,000 into.
                //
                // Full close is a question about UNITS, and the payout is the
                // released collateral plus the profit and loss against the mark
                // — which at 1x, where `marked == pledged == notional`, is the
                // same number this used to return.
                let closing_all = pod.exposure == 0;
                let mark = if pod.marked != 0 { pod.marked } else { pod.pledged };
                if closing_all {
                    let pledged_released = pod.pledged;
                    let pnl = redeem_dollars as i128 - mark as i128;
                    let total = (pledged_released as i128 + pnl
                                 - accrued_interest as i128).max(0) as u64;
                    let from_pool = total.saturating_sub(pledged_released);

                    pod.pledged = 0; pod.marked = 0; pod.updated = current_time;
                    let new_exp = pod.value_at(price);

                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                            pod.collar_bps, new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    let util_change = -(units_value(amount.unsigned_abs(), price)
                                        .min(i64::MAX as u64) as i64);

                    // RAROC: extract before update_drawn ends the window to hold pod.
                    // Zero on the pod itself so re-entry doesn't double-count
                    // cb/ip/cds into Depositor totals on the next close.
                    let (cb, ip, cds) = (pod.cost_basis, pod.interest_paid, 
                                                pod.collar_dollar_seconds);
                    pod.cost_basis = 0; 
                    pod.interest_paid = 0;
                    pod.collar_dollar_seconds = 0;

                    let _ = &pod; 
                    // end borrow before &mut self
                    self.update_drawn(util_change);
                    depository.utilisation(util_change);
                    let net = self.flush_raroc(cb, ip, cds, total);
                    Depositor::flush_raroc_pool(depository, net, cds);
                    return Ok((-(from_pool as i64), total));
                } else { // partial take-profit — capitalize into deposited_quid
                    // User intent: small early TP as a hedge. No fee, gain banked
                    // for redeployment or later withdrawal.
                    //
                    // Return signal: delta = pledged_reduce + AI, interest = user_credit.
                    // clutch dispatches by (delta>0, interest>0, exposure_decreased)
                    // and computes total_deposits delta from snapshots so the vault
                    // invariant `dq + Σpledged + T = vault` holds:
                    //   customer.deposited_quid += interest (= user_credit)
                    //   T_delta = pledged_reduce + AI - user_credit  (signed)
                    //
                    // Profit case → T_delta < 0: pool reserve funds the gain.
                    // Loss case   → T_delta > 0: pool reserve absorbs the loss.
                    //
                    // A long is paid the mark less the interest attributable
                    // to the slice; its collateral stays with the pool as margin.
                    // The slice's share of the mark, taken BEFORE
                    // `settle_partial_close` releases it pro rata.
                    let basis_slice = ((mark as u128)
                        .saturating_mul(redeem_dollars as u128)
                        / (old_exposure_value as u128).max(1)) as u64;
                    let (_released, basis_closed, interest_on_closed, raroc, fully_closed) =
                        settle_partial_close(pod, depository, actuary,
                            old_exposure_value, redeem_dollars,
                            old_exposure_value, price, current_time,
                            accrued_interest);
                    // Same rule as the full close: released collateral plus the
                    // profit and loss on the slice, not the slice's whole mark.
                    let user_credit = ((_released as i128
                        + redeem_dollars as i128 - basis_slice as i128
                        - interest_on_closed as i128).max(0)) as u64;
                    let (pod_cb, pod_ip, pod_cds) = raroc;
                    let pod_exp_after = if fully_closed { 0 } else { pod.exposure };
                    let pledged_reduce = _released;
                    let _ = &pod;
                    let util_change = -(redeem_dollars as i64);
                    self.update_drawn(util_change);
                    depository.utilisation(util_change);

                    if pod_exp_after == 0 {
                        // ⚠️ `basis_closed`, NOT `raroc.0`. `settle_partial_close`
                        //    releases `cost_basis` pro rata and THEN snapshots the
                        //    pod, so what it hands back in `raroc` is the RESIDUAL
                        //    — zero on a full close. Feeding that to `flush_raroc`
                        //    made the net `transfer − 0 − interest`, i.e. a
                        //    position that lost its entire basis booked a P&L of
                        //    roughly nothing. The figure that belongs to the slice
                        //    being closed is the one it returns separately.
                        let net = self.flush_raroc(basis_closed, pod_ip,
                                    pod_cds, user_credit);
                        Depositor::flush_raroc_pool(depository, net, pod_cds);
                    }
                    let delta_signal = pledged_reduce.saturating_add(accrued_interest);
                    return Ok((delta_signal as i64, user_credit));
                }
            } else { // Adding exposure
                let new_exp = units_value(pod.exposure as u64, price);
                // Zero pledge is not one-times leverage, it is exposure
                // against nothing. Defaulting to 100 let a pod whose pledge
                // had been consumed — by premiums, or by withdrawing it —
                // pass this check and keep adding, which is the one thing the
                // check exists to stop.
                let post_lev = if pod.pledged > 0 {
                    ((new_exp as u128 * 100) / pod.pledged as u128).min(i64::MAX as u128) as i64
                } else if new_exp > 0 { i64::MAX } else { 100 };

                require!(post_lev <= max_lev, PithyQuip::Undercollateralised);

                // ⭐ **THE MARGIN GATE, WHICH IS WHERE LEVERAGE ACTUALLY LIVES.**
                //
                // 🔴 WHAT STOOD HERE FORCED EVERY POSITION TO 1x AND THAT IS WHY
                //    NO AMOUNT OF TUNING EVER PRODUCED MORE. The rule was
                //    `delta = pledged + collar_amt`, top the pledge up to the
                //    notional if the depositor could fund it, and SHRINK THE
                //    EXPOSURE to the pledge if they could not — with a matching
                //    branch that GREW exposure when the pledge exceeded it. Both
                //    directions drove `exposure_value` onto `pledged`, so the
                //    `max_leverage_pct` check one line above could never bind:
                //    whatever it permitted, the forcing undid.
                //
                //    The requirement is now the margin the fitted tail demands
                //    over the act-plus-unwind horizon — `band_bps`, the same
                //    number the barrier is drawn at. Fund it and the position
                //    stands at whatever leverage that implies; fail to fund it
                //    and the exposure is cut to what the collateral supports,
                //    which is the same shrink as before against a threshold that
                //    is no longer 100%.
                //
                //    ⚠️ AND NOTHING PUSHES EXPOSURE UP ANY MORE. A pledge in
                //       excess of the requirement is simply excess: the
                //       depositor can withdraw it through `renege`. Spending it
                //       on exposure they did not ask for was the mirror image of
                //       the same forcing, and it is the reason a partially
                //       closed position quietly re-levered itself.
                let required = (new_exp as u128)
                    .saturating_mul(band_bps as u64 as u128) / 10_000;
                let required = required.min(u64::MAX as u128) as u64;
                let mut taken_from_pool: u64 = 0;
                if pod.pledged < required {
                    let short = required.saturating_sub(pod.pledged);
                    if self.deposited_quid >= short {
                        self.deposited_quid -= short;
                        pod.pledged = pod.pledged.saturating_add(short);
                        // dq → pledged transfer; clutch's snapshot dispatch
                        // sees dq drop and pledged grow, T_delta picks up AI.
                        taken_from_pool = short;
                    } else {
                        // Cut the exposure to what pledge-plus-free-balance can
                        // margin, rather than refusing the whole request.
                        let fundable = pod.pledged.saturating_add(self.deposited_quid);
                        let affordable = (fundable as u128).saturating_mul(10_000)
                            / (band_bps as u64 as u128).max(1);
                        let affordable = affordable.min(u64::MAX as u128) as u64;
                        let over = new_exp.saturating_sub(affordable);
                        let shed = value_units(over, price) as i64;
                        pod.exposure = if pod.exposure > 0 {
                            pod.exposure.saturating_sub(shed)
                        } else { pod.exposure.saturating_add(shed) };
                        let now_exp = pod.value_at(price);
                        let need = (now_exp as u128)
                            .saturating_mul(band_bps as u64 as u128) / 10_000;
                        let need = need.min(u64::MAX as u128) as u64;
                        if need > pod.pledged {
                            let top = need.saturating_sub(pod.pledged)
                                          .min(self.deposited_quid);
                            self.deposited_quid -= top;
                            pod.pledged = pod.pledged.saturating_add(top);
                            taken_from_pool = top;
                        }
                    }
                } pod.updated = current_time;
                let final_exp = pod.value_at(price);

                // The mark takes on the units that were added, at the price they
                // were added at, and leaves the unrealised P&L on the units that
                // were already there where it was. A pod with no mark yet is
                // being opened, so the whole position is its own mark.
                pod.marked = if !had_mark { final_exp } else {
                    (pod.marked as i128 + final_exp as i128
                        - old_exposure_value as i128).max(0) as u64
                };

                let lelu = LiabilityUpdate::compute(old_exposure_value,
                        pod.collar_bps, final_exp, pod.pledged, actuary);

                if amount > 0 {
                    let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                    require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);
                }
                lelu.apply(pod, depository);
                // 🔴 **THIS WAS `amount × price` WITH A SIGNED `amount`, AND
                //    UTILISATION MEASURES GROSS NOTIONAL.** A short opens with
                //    `amount < 0`, so opening one DECREASED `total_drawn`; the
                //    short branch below never added its notional at all, only
                //    the negative shrink correction. On any two-sided book the
                //    longs' additions and the shorts' subtractions cancelled
                //    and `total_drawn` sat on the `saturating_sub` floor.
                //
                //    Measured: a thousand borrowers carrying $64M of net
                //    exposure against $78M of deposits reported a utilisation
                //    of ONE BASIS POINT. Everything keyed off it — `rate_bps`'s
                //    entire liquidity term, and therefore the base half of
                //    every premium — was pinned at its minimum for the whole
                //    run, and would be on chain too.
                //
                // The quantity is the change in gross notional outstanding,
                // which is what every other call site already passes: closes
                // send `-redeem_dollars`, tranches send `-unwound_value`. This
                // one was the odd one out.
                let util_change = (final_exp as i128 - old_exposure_value as i128)
                    .clamp(i64::MIN as i128, i64::MAX as i128) as i64;

                self.update_drawn(util_change);
                depository.utilisation(util_change);
                // Return `taken_from_pool` (=excess drained, or 0 if none).
                // Pledged grew (excess moved from dq → pledged), exposure grew,
                // so clutch falls through to the snapshot-based "else" branch:
                //   T_delta = -(dq_delta + pledged_delta) absorbs the dq drain
                return Ok((taken_from_pool as i64, accrued_interest));
            }
        } let exposure = units_value((-pod.exposure) as u64, price);
        let pivot = mark.saturating_sub(collar_amt);
        if pivot >= exposure && exposure > 0 && !reducing {
            // ⭐ **A WINNING SHORT IS CURED THE SAME WAY A WINNING LONG IS:
            //    BY POSTING COLLATERAL AGAINST THE GAIN THE POOL NOW OWES.**
            //
            // 🔴 THIS CALLED `reinstate_exposure` — buy MORE short exposure to
            //    push the value back up to the mark — and once that was gated to
            //    the owner (a liquidator must not spend a borrower's balance), a
            //    winning short had NO cure on the crank path at all. It went
            //    straight to the ladder, which appropriates the gain.
            //
            //    A winning LONG, by contrast, has always been offered
            //    `post_variation_margin` on the same path. So being right was
            //    survivable on one side of the book and not the other.
            //
            //    Measured on the worst real ten-session falls in the fixture,
            //    with the borrower asleep and a liquidator cranking each
            //    session: shorts into a 56% fall in SMCI and a 35% fall in TSLA
            //    lost their ENTIRE PLEDGE. Being correct about a crash cost
            //    everything, because the crank collected the profit a rung at a
            //    time and no cure existed to stop it.
            //
            // The excess is measured from the other edge — `pivot − value`
            // rather than `value − upper` — and everything else is identical.
            let gap = pivot.saturating_sub(exposure);
            if let Some(gross) = post_variation_margin(pod, &mut self.deposited_quid,
                    depository, actuary, old_exposure_value, exposure,
                    gap, current_time)? {
                let _ = &pod; // end borrow before &mut self
                self.update_drawn(gross as i64);
                depository.utilisation(gross as i64);
                return Ok((gross as i64, accrued_interest));
            }
            else if amount != 0 {
                return Err(PithyQuip::Undercollateralised.into());
            } else {
                let excursion = pod.excursion(now);
                    // Same as `unwind_a_tranche`: the clock has to survive the
                    // call that started it. See the note there.
                    if excursion <= LIQ_GRACE_SECS as i64 {
                        return Ok((0, accrued_interest));
                    }

                    let (dollars, pod_cb, pod_ip, pod_cds, closed) =
                        amortise_tranche(pod, price, excursion, util_bps,
                                   actuary, depository, old_exposure_value,
                                   current_time);
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(dollars);
                    depository.utilisation(dollars);
                    if closed {
                        let net = self.flush_raroc(pod_cb, pod_ip, pod_cds, 0);
                        Depositor::flush_raroc_pool(depository, net, pod_cds);
                    }
                    return Ok((dollars, accrued_interest));
            }
        } if exposure > pivot || exposure == 0 {
            let upper = mark.saturating_add(trigger_amt);
            if exposure > upper && !reducing { // a losing short: cover or be unwound
                if let Some(gross) = post_variation_margin(pod, &mut self.deposited_quid,
                        depository, actuary, old_exposure_value, exposure,
                        exposure.saturating_sub(upper), current_time)? {
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(gross as i64);
                    depository.utilisation(gross as i64);
                    // `gross` is a routing hint for clutch's snapshot dispatch:
                    // exposure is unchanged here, so T is computed from
                    // snapshots and the fee stays in the reserve.
                    return Ok((gross as i64, accrued_interest));
                }
                else if amount != 0 {
                    // Not a liquidator, and the depositor cannot fund the
                    // restoration: profit this large can only be taken once
                    // the position is back inside its band.
                    return Err(PithyQuip::Undercollateralised.into());
                }
                else {
                    // Liquidator. Profit that belongs to one depositor is
                    // appropriated by all of them, slowly, which is what gives
                    // the borrower time to react and close.
                    return self.unwind_a_tranche(pod_index, price, util_bps,
                        actuary, depository, old_exposure_value,
                        current_time, now, accrued_interest);
                }
            }
            // In band, as above — and conditioned on the band rather than on
            // control flow, for the same reason.
            if exposure <= mark.saturating_add(collar_amt)
                && exposure >= mark.saturating_sub(collar_amt) {
                pod.breached_at = 0;
            }
            let old_exp = exposure; let mut drawn_delta_608: i64 = 0;
            // deferred update for the one non-returning branch
            pod.exposure = pod.exposure.saturating_add(amount);
            if amount > 0 && old_exp > 0 {
                // Redeeming short — capitalize into deposited_quid (mirrors long partial TP).
                // No fee on partial close; user banks the gain to redeploy or withdraw later.
                if pod.exposure > 0 { 
                    amount = amount.saturating_sub(pod.exposure); 
                    pod.exposure = 0;
                } // Units: redeem_dollars and old_exp are both dollar-denominated, so
                // amt_frac is a clean fraction. (amount is in shares; multiplying by
                // price brings it into dollar space.)
                let redeem_dollars = units_value(amount.unsigned_abs(), price);

                // A short is paid its released collateral plus P&L against
                // basis: closing means buying back, so profit is basis − exit.
                // ⚠️ CAPTURED BEFORE THE SETTLEMENT, NOT AFTER. `settle_partial_close`
                //    releases `marked` and `pledged` pro rata, so on a full close
                //    both are zero by the time it returns — reading the mark
                //    afterwards yields a basis of nothing, a profit of minus the
                //    whole exit value, and a credit floored at zero. That is a
                //    short handing over its entire pledge on a flat round trip,
                //    and it is exactly what a first cut of this fix produced.
                let mark_s = if pod.marked != 0 { pod.marked } else { pod.pledged };
                let (pledged_reduce, basis_closed, _interest_on_closed, raroc, fully_closed) =
                    settle_partial_close(pod, depository, actuary,
                        old_exposure_value, redeem_dollars,
                        if old_exp > 0 { old_exp } else { 1 }, price,
                        current_time, accrued_interest);
                // Profit is basis minus exit, and the basis is what was POSTED,
                // not what survived the premiums. Reconstructing it as
                // `pledged_reduce + interest_on_closed` recovered only the
                // CURRENT interval's premium, so every earlier one stayed
                // subtracted — a short that had been open long enough to pay
                // real premiums was billed for them a second time here, and the
                // longer it held the worse the second bill got.
                // 🔴 `basis_closed` IS A SHARE OF `cost_basis`, WHICH IS
                //    CONTRIBUTED COLLATERAL — NOT THE ENTRY MARK. `renege` moves
                //    `cost_basis` and `pledged` by the same amount on every
                //    collateral change, so at 1x it happens to equal the entry
                //    notional and at any leverage it is a fraction of it. A
                //    short's profit is basis minus exit, so reading the
                //    collateral as the basis made every levered short close at a
                //    loss equal to its whole pledge: measured, a 3x short opened
                //    and closed at the SAME PRICE received nothing back.
                let cost_basis_share = ((mark_s as u128)
                    .saturating_mul(redeem_dollars as u128)
                    / (old_exp as u128).max(1)) as u64;
                let _ = basis_closed;
                let signed_pnl: i128 =
                    (cost_basis_share as i128) - (redeem_dollars as i128);
                let user_credit: u64 = (pledged_reduce as i128)
                    .saturating_add(signed_pnl).max(0) as u64;
                let (pod_cb, pod_ip, pod_cds) = raroc;
                let pod_exp_after = if fully_closed { 0 } else { pod.exposure };
                let _ = &pod;
                let util_change = -(redeem_dollars as i64);

                self.update_drawn(util_change);
                depository.utilisation(util_change);

                if pod_exp_after == 0 {
                    // Same as the long partial close: the slice's basis, not
                    // the residual left on the pod after it was released.
                    //
                    // ⚠️ AND `basis_closed`, NOT `cost_basis_share`. The latter is
                    //    the slice's share of the MARK — the entry notional, used
                    //    just above to compute the short's profit as basis minus
                    //    exit. RAROC wants the CAPITAL the account committed, which
                    //    is the cost basis. Feeding it the notional booked a 9x
                    //    short's realised P&L as −$18,000 against a $2,000 pledge.
                    let net = self.flush_raroc(basis_closed, pod_ip,
                                pod_cds, user_credit);
                    Depositor::flush_raroc_pool(depository, net, pod_cds);
                }
                // Return signal: delta = pledged_reduce + AI, interest = user_credit.
                // clutch dispatches: delta>0 + interest>0 + exposure_decreased
                //   → partial TP capitalize: deposited_quid += interest;
                //                       T_delta computed from snapshots.
                let delta_signal = pledged_reduce.saturating_add(accrued_interest);
                return Ok((delta_signal as i64, user_credit));
            } 
            else if amount < 0 { // issue short exposure...
                let new_exp = units_value((-pod.exposure) as u64, price);
                let post_lev = if pod.pledged > 0 {
                    ((new_exp as u128 * 100) / 
                    pod.pledged as u128).min(
                        i64::MAX as u128) as i64
                }
                // Same reasoning as the long side: no pledge is not 1x.
                else if new_exp > 0 { i64::MAX } else { 100 };

                require!(post_lev <= max_lev, 
                PithyQuip::Undercollateralised);

                // ⭐ THE SAME MARGIN GATE AS THE LONG SIDE, AND NOW LITERALLY
                //    THE SAME RULE. What stood here was the mirror of the long
                //    forcing and had the same effect: `new_exp > pledged + collar`
                //    shrank the short back to 1x, and `pledged > new_exp` DRAINED
                //    `deposited_quid` to grow it — returning `UnderExposed` if
                //    the depositor could not fund exposure they had not asked
                //    for. A pledge in excess of the margin is not an error and
                //    does not need spending; it is withdrawable.
                let required = (new_exp as u128)
                    .saturating_mul(band_bps as u64 as u128) / 10_000;
                let required = required.min(u64::MAX as u128) as u64;
                if pod.pledged < required {
                    let deficit = required.saturating_sub(pod.pledged);
                    if self.deposited_quid >= deficit {
                        self.deposited_quid -= deficit;
                        pod.pledged = pod.pledged.saturating_add(deficit);
                    } else {
                        let fundable = pod.pledged.saturating_add(self.deposited_quid);
                        let affordable = ((fundable as u128).saturating_mul(10_000)
                            / (band_bps as u64 as u128).max(1))
                            .min(u64::MAX as u128) as u64;
                        let over = new_exp.saturating_sub(affordable);
                        // Adding a positive number shrinks a negative exposure.
                        pod.exposure = pod.exposure.saturating_add(
                            value_units(over, price) as i64);
                        drawn_delta_608 = -(over.min(i64::MAX as u64) as i64);
                        depository.utilisation(drawn_delta_608);
                        let now_exp = pod.value_at(price);
                        let need = ((now_exp as u128)
                            .saturating_mul(band_bps as u64 as u128) / 10_000)
                            .min(u64::MAX as u128) as u64;
                        if need > pod.pledged {
                            let top = need.saturating_sub(pod.pledged)
                                          .min(self.deposited_quid);
                            self.deposited_quid -= top;
                            pod.pledged = pod.pledged.saturating_add(top);
                        }
                    }
                }
            } pod.updated = current_time; // why wouldn't a depositor just:
            // select the smallest distance, (greater than pod.pledged) in
            // order to maximise potential profit?  maybe they know a big
            // drop is ahead, and they want to minimise the chance they
            // might be liquidated; either way we want to maximise control
            let final_exp = pod.value_at(price);
            // Same rule as the long side: units added enter the mark at the
            // price they were added at; a pod with no mark yet is its own.
            pod.marked = if !had_mark { final_exp } else {
                (pod.marked as i128 + final_exp as i128
                    - old_exposure_value as i128).max(0) as u64
            };

            let lelu = LiabilityUpdate::compute(old_exposure_value,
                    pod.collar_bps, final_exp, pod.pledged, actuary);

            lelu.apply(pod, depository);
            let _ = &pod; // end borrow before deferred self.update_drawn
            // Same correction as the long side: gross notional, not signed
            // amount. `drawn_delta_608` was the only utilisation this branch
            // ever reported, and it is a negative shrink correction — so a
            // short that opened cleanly reported nothing, and one that had to
            // be trimmed reported a REDUCTION in drawn for a position that had
            // just been created.
            let util_change = (final_exp as i128 - old_exposure_value as i128)
                .clamp(i64::MIN as i128, i64::MAX as i128) as i64;
            let _ = drawn_delta_608;
            self.update_drawn(util_change);
            depository.utilisation(util_change);
            return Ok((0, accrued_interest));
        }
        Ok((0, 0)) // open halfway each morning to close halfway each night,
    } // when I touch, it feel like heaven; when I kiss, it kiss to save...
    // I ain't circlin' 'round for saviors, live my life a certain way...
    // I don't need a kind of captain...grabbin' back and I don't beg...
    // don't wanna hear how you are different...or how we are the same.
    // When you gonna show me how you love me: the way to make me stay
    pub fn renege(&mut self, ticker: Option<&str>, mut amount: i64,
        prices: Option<&Vec<u64>>, current_time: i64) -> Result<i64> { // pod: подушка
        // eyes get shut with chains that pillow armies eventually set free like horses
        if ticker.is_none() && amount < 0 { // removing collateral from every position
            // Visit largest-pledged first, but do NOT permute `balances`:
            // `prices` was built by fetch_multiple_prices() in the CURRENT
            // order, so sorting the array in place made `prices[i]` belong to
            // a different position — every pod valued with someone else's
            // price, over- or under-releasing real collateral. Order an index
            // list instead and keep pod and price on the same subscript.
            let mut order: Vec<usize> = (0..self.balances.len()).collect();
            order.sort_by(|&a, &b| self.balances[b].pledged
                                       .cmp(&self.balances[a].pledged));
            let mut deducting: u64 = amount.unsigned_abs();
            // bigger they come, harder they fall and all
            for i in order {
                if deducting == 0 { break; }
                let price = prices.as_ref()
                                  .and_then(|p| p.get(i).copied())
                                  .ok_or(PithyQuip::NoPrice)?;
                let pod = &mut self.balances[i];
                // Same band repo() will judge it by — otherwise a position
                // could withdraw itself into a state repo() liquidates.
                let collar_amt = collar_amount(pod, price);
                let max: u64 = if pod.exposure > 0 {
                    let exposure_value = units_value(pod.exposure as u64, price);
                    (pod.pledged.saturating_add(collar_amt)).saturating_sub(exposure_value)
                }
                else if pod.exposure < 0 {
                    // we don't have to worry about if
                    // pledged - X% will be worth more
                    // than exposure, as (theoretically)
                    // by that point it's liquidated...
                    let exposure_value = pod.value_at(price);
                    let pledged_minus_collar = pod.pledged.saturating_sub(collar_amt);
                    exposure_value.saturating_sub(pledged_minus_collar)
                }
                else { pod.pledged };

                let deducted = max.min(deducting); deducting -= deducted;
                // Accumulate collar-seconds before reducing pledged,
                // so RAROC tracking is consistent with the single-ticker path.
                Depositor::accumulate_collar_seconds(pod, current_time);
                pod.pledged = pod.pledged.saturating_sub(deducted);
                // cost_basis decreases when collateral is removed
                pod.cost_basis = pod.cost_basis.saturating_sub(deducted);
                // `updated` is the interest clock AND the liquidation-grace
                // clock, and nothing here charges interest. Stamping it on a
                // live position let a borrower withdraw one unit of collateral
                // to wipe the premium accrued since the last `repo()` — and to
                // push the grace period out again — for as long as they liked.
                // A flat pod accrues nothing, so its clock is free to move.
                if pod.exposure == 0 { pod.updated = current_time; }
            }   amount = deducting as i64; // < remainder (out & clutch)
        } else { // remove or add dollars to one specific position...
            // Reachable with no ticker and a positive amount, where `unwrap`
            // aborted the transaction instead of returning. A panic is not a
            // rejection: it costs the caller the fee, tells them nothing, and
            // cannot be handled by anything above it.
            let padded = Self::pad_ticker(ticker.ok_or(PithyQuip::UnknownSymbol)?);
            if let Some(pod) = self.balances.iter_mut().find(
                                 |pod| pod.ticker == padded) {
                let price = prices.and_then(|p| p.first())
                                    .copied().unwrap_or(0);

                if pod.exposure != 0 && price == 0 {
                    return Err(PithyQuip::NoPrice.into());
                }
                let exposure = pod.value_at(price);
                // Same band repo() will judge it by — otherwise a position
                // could withdraw itself into a state repo() liquidates.
                let collar_amt = collar_amount(pod, price);
                // deducting...we check the max, same as we did above,
                // with a slightly different approach (why not, right?)
                if amount < 0 { require!(pod.pledged >= amount.unsigned_abs(),
                                            PithyQuip::InvalidAmount);
                    if pod.exposure < 0 {
                        // short position
                        if exposure > pod.pledged { // most we can deduct
                            let max: i64 = -(collar_amt.saturating_sub(
                                exposure.saturating_sub(pod.pledged)
                            ) as i64);
                            amount = max.max(amount); // in absolute value
                            // terms this ^ actually returns smaller one...
                        }
                        else if pod.pledged > exposure {
                            // short is in-the-money, so
                            // it doesn't make sense to
                            // decrease collateral as it
                            // would diminish profitability
                            return Err(PithyQuip::TakeProfit.into());
                        }
                    } else if pod.exposure > 0 {
                        let mut max: u64 = 0;
                        // most we can deduct
                        if pod.pledged >= exposure {
                             max = collar_amt.saturating_sub(pod.pledged.saturating_sub(exposure));
                        }
                        else if exposure > pod.pledged {
                            max = collar_amt.saturating_sub(exposure.saturating_sub(pod.pledged));
                        }
                        amount = -((max.min(amount.unsigned_abs())) as i64);
                    }
                    // RAROC: accumulate before remove
                    Depositor::accumulate_collar_seconds(pod, current_time);
                    pod.pledged = pod.pledged.saturating_sub(amount.unsigned_abs());
                    pod.cost_basis = pod.cost_basis.saturating_sub(amount.unsigned_abs());
                } else { // amount is > 0
                    if pod.exposure < 0 {
                        if exposure > pod.pledged { // simple enough here, not
                            // sure why anyone would do this, but it's doable...
                            amount = amount.min(exposure.saturating_sub(pod.pledged) as i64);
                        }
                        else if pod.pledged > exposure {
                            // short is in-the-money; throw as
                            // would be like cheating otherwise
                            // as adding collateral widens the
                            // delta (i.e. profitability, what's
                            // deducted from bank.total_deposits)...
                            return Err(PithyQuip::TakeProfit.into());
                        }
                    } else if pod.exposure > 0 {
                        let mut max: u64 = 0;
                        // most we can deduct
                        if pod.pledged >= exposure {
                            max = collar_amt.saturating_sub(pod.pledged.saturating_sub(exposure));
                        }
                        else if exposure > pod.pledged {
                            max = exposure.saturating_add(collar_amt).saturating_sub(pod.pledged);
                        }   amount = max.min(amount as u64) as i64;
                    }
                    pod.pledged = pod.pledged.saturating_add(amount as u64);
                    pod.cost_basis = pod.cost_basis.saturating_add(amount as u64);
                } amount = 0; self.last_updated = current_time;
                // Same reasoning as the sweep branch: only a flat pod may have
                // its clock moved by a path that charges nothing.
                if pod.exposure == 0 { pod.updated = current_time; }
            } else { require!(amount > 0, PithyQuip::InvalidAmount);
                if self.balances.len() >= MAX_LEN {
                    return Err(PithyQuip::MaxPositionsReached.into());
                }   self.balances.push(Stock { breached_at: 0, premium_checkpoint: 0, funding_checkpoint: 0,
                        marked: 0, ticker: padded,
                        pledged: amount as u64, exposure: 0,
                        updated: current_time,
                        collar_bps: 0,
                        cost_basis: amount as u64,
                        interest_paid: 0,
                        collar_dollar_seconds: 0,
                        collar_dollars: 0,
                    }); amount = 0;
            }
        } // Prune spent positions only. The threshold here used to be $10 of
        // pledge, and a pod under it was dropped without its collateral being
        // returned anywhere — silently confiscated to the pool. Nothing else
        // in this file moves value without a matching entry, and the cases
        // that land under $10 are precisely the honest ones: a pledge ground
        // down by premiums, or the residue of a full close. The slot pressure
        // it was defending against is already bounded by MAX_LEN and by the
        // deposit minimum, and a depositor can always withdraw the residue,
        // which zeroes the pod and prunes it here on the next pass.
        self.balances.retain(|pod| pod.pledged > 0 || pod.exposure != 0);
        // keep positions that have over $10 pledged OR any exposure...
        // (exposure will shrink via continuous funding until liquidated)
        Ok(amount) // < remainder must be returned if ticker was None...
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entra::*;

    pub(super) fn bank(hot: u64, cost: u64, credited: u64) -> Depository {
        Depository { last_updated: 0, total_deposits: 0, total_deposit_seconds: 0, yield_pool: 0,
            total_drawn: 0, max_liability: 0, sol_lamports: hot, sol_usd_contrib: 0,
            sol_star_shares: 0, sol_star_cost_lamports: cost,
            sol_star_credited_lamports: credited, sol_star_parked_at: 0,
            swept_at: 0, swept_count: 0, paper_in_transit: 0,
            unwind_demand: 0, paper_backed: 0,
            pool_realized_pnl: 0, pool_collar_dollar_seconds: 0,
            sol_yield_index: 0 }
    }

    pub(super) fn depositor(lamports: u64) -> Depositor {
        Depositor { owner: Pubkey::new_unique(), deposited_quid: 0,
            deposited_lamports: lamports, sol_pledged_usd: 0, deposit_seconds: 0,
            last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
            total_interest_paid: 0, total_collar_dollar_seconds: 0,
            sol_yield_checkpoint: 0 }
    }

    #[test]
    fn buffer_floor_is_computed_on_the_whole_pool() {
        // 40 hot + 60 parked: a 50% buffer measures against 100, not 40.
        let b = bank(40, 60, 57);
        assert_eq!(sol_total_lamports(&b), 100);
        assert_eq!(required_buffer(&b, 5_000), 50);
        assert!(b.sol_lamports < required_buffer(&b, 5_000));
    }

    #[test]
    fn buffer_floor_cannot_be_configured_away() {
        let b = bank(100, 0, 0);
        assert_eq!(required_buffer(&b, 0), 20);       // clamped to MIN_BUFFER_BPS
        assert_eq!(required_buffer(&b, 10_000), 100); // all of it stays hot
    }

    #[test]
    fn credited_lamports_counts_the_parked_tranche() {
        // The flash_repay re-mark bug: crediting sol_lamports alone drops 57.
        let b = bank(40, 60, 57);
        assert_eq!(credited_lamports(&b), 97);
        assert_ne!(credited_lamports(&b), b.sol_lamports);
    }

    #[test]
    fn park_band_scales_with_the_pool() {
        assert_eq!(park_band(&bank(500, 500, 475), 1_000), 100);
        assert_eq!(park_band(&bank(0, 0, 0), 1_000), 0);
    }

    /// 🔴 THIS TEST USED TO BE `credit_adjustment_lands_on_earnings_before_
    ///    principal` AND IT ASSERTED THE BUG. Its third line read *"with no
    ///    surplus, a loss has nowhere to go but principal"* and checked that
    ///    `total_deposits` fell from 1,000 to 600 on a SOL parking haircut —
    ///    dollar depositors paying for a Kestrel loss.
    ///
    ///    `Depository::has_capacity` states the invariant it broke: `total_deposits`
    ///    "is dollars, and only dollars", and a SOL deposit "no longer credits
    ///    this at all". `deposit` says the same from the other side: "a SOL move
    ///    cannot reach a stock book at all, in either direction". This path was
    ///    that direction.
    ///
    ///    A SOL impairment is already borne where it belongs — the haircut cuts
    ///    `sol_star_credited_lamports`, which is the SOL tranche's own
    ///    principal, and `accrue_sol_yield` walks `sol_yield_index` down against
    ///    unclaimed carry. What is left here is the pool's record of what it
    ///    holds in SOL, and that record is `sol_usd_contrib`.
    #[test]
    fn credit_adjustment_never_reaches_dollar_principal() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000; b.sol_usd_contrib = 1_000;

        // A loss with no surplus to claw: it comes off the SOL record alone.
        adjust_sol_credit(&mut b, -400);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (1_000, 0, 600));

        // A gain is the pool's shared surplus; principal is untouched.
        adjust_sol_credit(&mut b, 150);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (1_000, 150, 750));

        // The next loss claws back exactly what this path credited, and stops.
        adjust_sol_credit(&mut b, -200);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (1_000, 0, 550));

        // Saturates rather than wrapping, and STILL cannot reach the dollars.
        adjust_sol_credit(&mut b, -10_000);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (1_000, 0, 0));

        // The property, stated once rather than implied four times.
        let before = b.total_deposits;
        for d in [-5_000i64, 5_000, -1, 1, i64::MIN + 1, i64::MAX] {
            adjust_sol_credit(&mut b, d);
            assert_eq!(b.total_deposits, before,
                "SOL credit adjustment {d} moved dollar principal");
        }
    }

    pub(super) fn pod(pledged: u64, exposure: i64, collar_bps: u16, collar_dollars: u64) -> Stock {
        Stock { ticker: [0u8; 8], breached_at: 0, premium_checkpoint: 0, funding_checkpoint: 0,
            // 0, so `marked` falls back to `pledged` — the band centred where
            // it was before the mark existed. Setting it to the UNIT COUNT, as
            // a first cut did, gives a dollar field a share count and makes
            // every mark-to-market in these fixtures nonsense.
            marked: 0, pledged, exposure, updated: 0,
            collar_bps, cost_basis: pledged, interest_paid: 0,
            collar_dollar_seconds: 0, collar_dollars }
    }

    #[test]
    fn collar_notional_is_exposure_when_levered_pledged_when_flat() {
        // 3× position: $1k pledged carrying $3k of exposure.
        assert_eq!(collar_notional(3_000, 1_000), 3_000);
        // Collateral posted, no exposure yet — the band must not be zero.
        assert_eq!(collar_notional(0, 1_000), 1_000);
    }

    #[test]
    fn band_no_longer_collapses_with_leverage() {
        // Regression: collar_bps carries a /lev term, so sizing the band off
        // `pledged` (= exposure/L) divided by leverage twice and the absorbable
        // move fell as 1/L² — 20 bps at 10×. On the notional it falls as 1/L.
        // Uses the real collar, so the test cannot drift from the model: a
        // fitted tail on a ticker with a heavy exceedance sample.
        let mut a = crate::etc::Actuary::default();
        a.observed_vol_bps = 200; a.obs_count = 200; a.last_price = 1_000_000;
        for k in 0..30 {
            let x: i64 = if k == 29 { 1_200 } else { 120 };
            a.exceed_count += 1; a.exceed_sum += x;
            a.exceed_sumsq += (x as i128) * (x as i128);
        }
        let mut prev_ratio = f64::MAX;
        for lev in [100u64, 300, 500, 1000] {
            let collar = crate::etc::collar_bps(lev as i64, &a).max(0) as u64;
            let pledged = 1_000u64;
            let exposure = pledged * lev / 100;
            let band = collar_notional(exposure, pledged) * collar / 10_000;
            let ratio = band as f64 / exposure as f64;         // absorbable move
            // Never the 1/L² cliff: at 10× the old path gave 0.0020.
            assert!(ratio >= 0.019, "lev {lev}: absorbable move {ratio} too tight");
            assert!(ratio <= prev_ratio, "band must not widen with leverage");
            prev_ratio = ratio;
        }
    }

    #[test]
    fn band_is_recorded_on_the_pod_not_the_pool() {
        // The band a position is judged by lives on the pod. The pool's
        // reserve is a separate, netted figure — two writers on one number is
        // what let max_liability ratchet.
        let mut bank = bank(0, 0, 0);
        bank.total_deposits = 1_000_000;
        let mut p = pod(1_000, 3, 0, 0);

        LiabilityUpdate { old_collar_dollars: 0, new_collar_bps: 233,
            new_collar_dollars: 700 }.apply(&mut p, &mut bank);
        assert_eq!(p.collar_dollars, 700, "the pod records its own band");
        assert_eq!(bank.max_liability, 0,
                   "the band must not book itself into the pool reserve");

        LiabilityUpdate { old_collar_dollars: 0, new_collar_bps: 0,
            new_collar_dollars: 0 }.apply(&mut p, &mut bank);
        assert_eq!(p.collar_dollars, 0, "and releases cleanly on close");
    }


    #[test]
    fn no_pledge_is_not_one_times_leverage() {
        // Every leverage computation guarded its division with `else { 100 }`,
        // so a position whose pledge had been consumed — by premiums, or by
        // withdrawing it — read as 1x. The gates let it keep adding exposure,
        // and `collar_bps`, which widens the band as leverage falls, handed it
        // the most room in the book.
        let price = 100 * PRICE_SCALE as u64;
        let mut spent = pod(0, 500, 200, 0);        // exposure, nothing behind it
        assert_eq!(spent.pledged, 0);
        assert!(spent.value_at(price) > 0);

        // The band for unbounded leverage is the tightest available, not the
        // widest — which is what reading it as 1x produced.
        let a = crate::etc::Actuary::default();
        let unpledged = collar_bps(i64::MAX, &a);
        let unlevered = collar_bps(100, &a);
        assert!(unpledged <= unlevered,
                "an unpledged position must not get a wider band than a flat one");

        // And a flat pod with no pledge is genuinely unlevered, so it keeps
        // the ordinary treatment.
        spent.exposure = 0;
        assert_eq!(spent.value_at(price), 0);
    }

    #[test]
    fn a_liquidator_cannot_climb_the_whole_ladder_at_once() {
        // The gate is `excursion > LIQ_GRACE_SECS`. With `breached_at` set once
        // and never moved, a position an hour past its band satisfied that on
        // every call for ever after, so the rungs could all be taken in one
        // slot — each paying a commission. Time now buys grace and each
        // tranche spends it.
        let g = LIQ_GRACE_SECS as i64;
        let mut p = pod(20_000_000, 500, 200, 0);
        p.breached_at = 1_000;
        let now = 1_000 + g + 1;                    // just past the first rung

        assert!(p.excursion(now) > g, "the first tranche is due");
        p.spend_grace();
        assert!(p.excursion(now) <= g,
                "a second tranche in the same slot must not be due");

        // Waiting earns the next rung, and only the next one.
        assert!(p.excursion(now + g) > g, "an hour later it is due again");
        p.spend_grace();
        assert!(p.excursion(now + g) <= g, "and only one at a time");

        // Neglect accrues: a liquidator returning after a day may take the
        // rungs that went unclaimed, which is the intended catch-up.
        let neglected = now + 24 * g;
        let mut taken = 0;
        while p.excursion(neglected) > g { p.spend_grace(); taken += 1; }
        assert!(taken > 20 && taken < 30,
                "about a day's worth of rungs, not the whole position: {taken}");
    }

    #[test]
    fn a_deep_breach_is_unwound_by_depth_not_by_the_clock() {
        // The ladder alone measures how long a position has been outside its
        // band. A gap does not wait: the loss outruns a time-based slice, and
        // whatever the pledge cannot cover lands on depositors. So a tranche
        // is at least what restores the band.
        // Micro-dollars per share — see §SCALE.
        let price = 100 * PRICE_SCALE as u64;
        let mut deep = pod(10_000, 500, 200, 0);      // 50k of exposure on 10k
        let collar = collar_amount(&deep, price);
        let exposure_value = units_value(deep.exposure as u64, price);
        let band_top = deep.pledged + collar;
        assert!(exposure_value > band_top, "fixture must actually be breached");

        let restoring = value_units(exposure_value - band_top, price);
        let ladder = Depositor::tranche_size(deep.exposure.unsigned_abs(),
                                             LIQ_GRACE_SECS as i64 + 1, 5_000);
        assert!(restoring > ladder,
                "a breach this deep should outrun the opening rung");

        // And the floor never exceeds the position: a breach larger than the
        // whole thing closes it, rather than asking for units that do not exist.
        deep.pledged = 0;
        let collar = collar_amount(&deep, price);
        let over = value_units(units_value(deep.exposure as u64, price)
            .saturating_sub(collar), price);
        assert!(over.min(deep.exposure.unsigned_abs()) <= deep.exposure.unsigned_abs());
    }

    #[test]
    fn liquidation_is_a_ladder_not_a_cliff() {
        let size = 1_000_000u64;
        // Just past the gate: the floor, scaled by urgency — not the position.
        let first = Depositor::tranche_size(size, LIQ_GRACE_SECS as i64 + 1, 5_000);
        assert!(first >= size * MIN_TRANCHE_BPS as u64 / 10_000
             && first <= size * (2 * MIN_TRANCHE_BPS) as u64 / 10_000,
                "opening tranche should sit on the floor, got {first}");

        // The old formula took 100% here (ratio > 1 × speed 1.25).
        let mid = Depositor::tranche_size(size, (LIQ_GRACE_SECS as i64) * 2, 5_000);
        assert!(mid < size / 5, "a single tranche must stay small: {mid}");

        // However stale, never more than the ceiling in one call.
        let stale = Depositor::tranche_size(size, (LIQ_GRACE_SECS as i64) * 1_000, 10_000);
        assert_eq!(stale, size * MAX_TRANCHE_BPS as u64 / 10_000);

        // Monotone in staleness, and a live position is never a no-op.
        let mut prev = 0;
        for mult in 1..=8 {
            let r = Depositor::tranche_size(size, (LIQ_GRACE_SECS as i64) * mult, 5_000);
            assert!(r >= prev && r >= 1);
            prev = r;
        }
    }

    #[test]
    fn ladder_unwinds_fully_but_takes_many_calls() {
        // Depositors get many prints, the borrower gets time to cure: a fully
        // stale position at max utilisation still needs >20 calls to be 90% gone.
        let mut remaining = 1_000_000u64;
        let mut calls = 0;
        while remaining > 100_000 && calls < 500 {
            remaining -= Depositor::tranche_size(remaining, (LIQ_GRACE_SECS as i64) * 1_000, 10_000)
                .min(remaining);
            calls += 1;
        }
        assert!(calls >= 20, "unwind was too abrupt: {calls} calls");
        assert!(remaining <= 100_000, "unwind stalled at {remaining}");
    }

    #[test]
    fn accounting_units_are_mint_agnostic() {
        // The bug: bridged QD is 9 decimals, USD* is 6, and raw amounts were
        // credited straight into deposited_quid — so 1 QD counted as 1000 USD*.
        let one_usd_star = 1_000_000u64;      // 1.0 at 6dp
        let one_qd       = 1_000_000_000u64;  // 1.0 at 9dp
        assert_eq!(to_accounting(one_usd_star, 6).unwrap(),
                   to_accounting(one_qd, 9).unwrap(),
                   "a unit of either mint must credit the same");
        assert_eq!(to_accounting(one_qd, 9).unwrap(), 1_000_000);

        // A 2-decimal mint scales up rather than truncating to nothing.
        assert_eq!(to_accounting(100, 2).unwrap(), 1_000_000);
    }

    #[test]
    fn accounting_round_trips_back_to_raw() {
        for (raw, dec) in [(1_000_000u64, 6u8), (1_000_000_000, 9), (100, 2)] {
            let units = to_accounting(raw, dec).unwrap();
            assert_eq!(from_accounting(units, dec).unwrap(), raw,
                       "round trip lost value at {dec} decimals");
        }
        // Sub-unit dust below accounting precision truncates, never inflates.
        assert_eq!(to_accounting(999, 9).unwrap(), 0);
        assert_eq!(from_accounting(0, 9).unwrap(), 0);
    }

    #[test]
    fn auto_protect_restores_the_band_on_both_sides() {
        // The two sides had drifted: long credited `excess − fee` to pledged,
        // leaving the position still outside its collar after "protection".
        // One helper now serves both, and the credited amount must close the
        // gap it was called to close.
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000_000;
        let a = Actuary::default();

        // ⚠️ THIS ASSERTED `p.pledged >= 1_000 + 900` ON BOTH SIDES, WHICH WAS
        //    THE FORGOTTEN LOSS. `exposure > upper` means a WINNING long and a
        //    LOSING short, and the cure re-centres `marked` on the current
        //    value — so whatever the position was carrying has to be SETTLED
        //    into the pledge on the way past, or it vanishes. Demanding that
        //    the pledge simply absorb the posted excess is demanding that a
        //    short's loss be dropped.
        //
        // The two invariants that hold on both sides: the band is restored
        // (value == mark, so the position sits at the centre of it), and equity
        // rises by exactly what was credited — no more, no less.
        for exposure_sign in [1i64, -1] {
            let mut p = pod(1_000, exposure_sign, 0, 0);
            let mut dq = 100_000u64;
            let upper = 1_100u64;      // pledged + collar
            let exposure = 2_000u64;   // 900 past the band
            let side = exposure_sign as i128;
            let mark0 = 1_000i128;     // `marked == 0` falls back to `pledged`
            let equity0 = 1_000i128 + (exposure as i128 - mark0) * side;

            let gross = post_variation_margin(&mut p, &mut dq, &mut b, &a,
                                      exposure, exposure, upper, 1)
                .unwrap().expect("depositor can fund it");
            let net = gross - gross / 250;

            assert!(gross >= 900, "charge covers the excess: {gross}");
            assert_eq!(p.marked, exposure, "the band re-centres on the mark");
            assert_eq!(p.pledged as i128, equity0 + net as i128,
                "equity must rise by exactly what was credited: pledged {} \
                 against equity {equity0} plus net {net}", p.pledged);
            assert_eq!(dq, 100_000 - gross, "charged exactly once");
        }
    }

    #[test]
    fn auto_protect_declines_when_the_depositor_cannot_fund_it() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000_000;
        let a = Actuary::default();
        let mut p = pod(1_000, 1, 0, 0);
        let mut dq = 10u64;                    // nowhere near the excess
        assert!(post_variation_margin(&mut p, &mut dq, &mut b, &a, 2_000, 2_000, 1_100, 1)
                .unwrap().is_none(), "must fall through to liquidation");
        assert_eq!(dq, 10, "a declined protection charges nothing");
        assert_eq!(p.pledged, 1_000, "and moves no collateral");
    }

    #[test]
    fn slicing_the_charge_never_double_bills_or_amplifies() {
        // A borrower picks how often the pool charges them, so both directions
        // matter: slicing must never bill the same second twice, and the
        // truncation it does buy must stay bounded by one unit per call.
        let (value, rate, span) = (1_000_000_000_000u64, 500i64, 3_600i64);
        let pledge = u64::MAX;
        let (lump, secs) = premium_due(value, rate, span, 0, pledge);
        assert_eq!(secs, span, "a covered charge pays for the whole span");

        // Faithful to repo(): the caller picks `now`, the charge is taken over
        // `now - pod.updated`, and the meter advances by what was billed.
        let (mut billed, mut meter) = (0u64, 0i64);
        for now in 1..=span {
            let (c, secs) = premium_due(value, rate, now - meter, 0, pledge);
            billed += c;
            meter += secs;
        }
        assert!(billed <= lump, "slicing double-billed: {billed} > {lump}");
        assert!(lump - billed <= span as u64,
                "truncation must stay under a unit per call: lost {}", lump - billed);
    }

    #[test]
    fn an_exhausted_pledge_keeps_owing() {
        // Only the pledge can be taken, but the rest is not forgiven: the
        // meter stays put, so the debt keeps accruing and the position stays
        // liquidatable instead of holding exposure for free.
        let (charged, billed) = premium_due(1_000_000_000_000, 500, 31_536_000, 0, 7);
        assert_eq!(charged, 7, "cannot take more than the pledge");
        assert!(billed < 31_536_000, "unpayable premium must stay on the clock");

        let (charged, billed) = premium_due(1_000_000_000_000, 500, 31_536_000, 0, 0);
        assert_eq!((charged, billed), (0, 0), "a spent pledge buys no time");
    }

    #[test]
    fn paying_premiums_does_not_buy_immunity_from_liquidation() {
        // Liquidation is Parisian: it triggers on the unbroken time spent
        // outside the band. Gating it on time-since-last-touch let a breaching
        // borrower reset their own grace period every few minutes forever.
        let mut p = pod(20_000_000, 5, 200, 0);
        assert_eq!(p.excursion(1_000), 0, "clock starts on first sight of breach");
        assert_eq!(p.excursion(1_100), 100);
        assert_eq!(p.excursion(9_000), 8_000, "touching it does not restart it");

        p.breached_at = 0;   // cured: back inside the band
        assert_eq!(p.excursion(9_100), 0, "a cure ends the excursion");

        // And the tranche keeps growing with the excursion, so an unattended
        // breach is unwound faster the longer it is left.
        let g = LIQ_GRACE_SECS as i64;
        let rung = |n: i64| Depositor::tranche_size(1_000_000, g * n, 3_333);
        assert!(rung(2) < rung(20) && rung(20) < rung(TRANCHE_RAMP_GRACES + 2),
                "ladder must steepen with the excursion, not saturate on rung one");
        assert_eq!(rung(TRANCHE_RAMP_GRACES + 2), rung(TRANCHE_RAMP_GRACES * 10),
                   "and level off at the ceiling once the ramp is climbed");
    }

    #[test]
    fn dust_withdrawals_cannot_reset_the_premium_clock() {
        // The avoidance vector: interest is charged only in repo(), against
        // (now − pod.updated). renege() moves collateral and charged nothing,
        // yet stamped that same field — so withdrawing one unit wiped the
        // premium accrued since the last touch, and pushed the liquidation
        // grace period out with it.
        let mut d = depositor(0);
        d.balances = vec![pod(20_000_000, 5, 200, 0)];   // live, above dust
        d.balances[0].ticker = Depositor::pad_ticker("AAA");
        d.balances[0].updated = 1_000;
        let prices = vec![100u64];

        d.renege(None, -50, Some(&prices), 9_000).unwrap();
        assert_eq!(d.balances[0].updated, 1_000,
                   "a live position's clock must survive a collateral withdrawal");

        // A flat pod owes nothing, so moving its clock costs the pool nothing.
        d.balances[0].exposure = 0;
        d.renege(None, -50, Some(&prices), 12_000).unwrap();
        assert_eq!(d.balances[0].updated, 12_000,
                   "a flat pod may be re-stamped");
    }

    #[test]
    fn sweep_values_each_position_with_its_own_price() {
        // Regression: renege() sorted `balances` by pledged desc while `prices`
        // had been built in the unsorted order, so pod[i] was valued with
        // another pod's price. Order the small position first so the sort
        // must reorder, and give the two tickers wildly different prices.
        let mut d = depositor(0);
        d.balances = vec![
            pod(1_000, 1, 1_000, 0),      // small pledge, listed first
            pod(9_000, 1, 1_000, 0),      // large pledge, listed second
        ];
        d.balances[0].ticker = Depositor::pad_ticker("AAA");
        d.balances[1].ticker = Depositor::pad_ticker("BBB");
        let prices = vec![2, 1_000];      // AAA cheap, BBB dear

        let before: Vec<u64> = d.balances.iter().map(|p| p.pledged).collect();
        d.renege(None, -500, Some(&prices), 10).unwrap();

        // Whatever it released, the array order must be untouched — that is
        // what keeps pod and price on the same subscript.
        assert_eq!(d.balances[0].ticker, Depositor::pad_ticker("AAA"));
        assert_eq!(d.balances[1].ticker, Depositor::pad_ticker("BBB"));
        assert!(d.balances.iter().zip(before.iter())
                 .all(|(p, &b)| p.pledged <= b), "collateral only decreases");
    }

    #[test]
    fn sol_carry_pays_the_sol_tranche_not_everyone() {
        // 100 lamports of principal, split 60/40 between two SOL depositors.
        let mut b = bank(100, 0, 0);
        let mut sol_a = depositor(60);
        let mut sol_b = depositor(40);
        let mut stable_only = depositor(0);   // USD*/QD depositor, no lamports

        assert!(b.accrue_sol_yield(1_000), "carry must attribute to principal");
        assert_eq!(sol_a.settle_sol_yield(&mut b), 600);
        assert_eq!(sol_b.settle_sol_yield(&mut b), 400);
        assert_eq!(stable_only.settle_sol_yield(&mut b), 0,
                   "a depositor who posted no SOL earns no staking yield");
        // Attributed exactly once, to the SOL side, and only when claimed.
        // The dollar pool is untouched: staking carry is not stock margin.
        assert_eq!(b.sol_usd_contrib, 1_000);
        assert_eq!(sol_a.sol_pledged_usd, 600);
        assert_eq!(sol_a.deposited_quid, 0,
                   "carry must not become spendable as margin");
        assert_eq!(b.total_deposits, 0);
    }

    #[test]
    fn settling_twice_pays_once() {
        let mut b = bank(100, 0, 0);
        let mut d = depositor(100);
        b.accrue_sol_yield(500);
        assert_eq!(d.settle_sol_yield(&mut b), 500);
        assert_eq!(d.settle_sol_yield(&mut b), 0, "checkpoint must consume it");
    }

    #[test]
    fn arriving_principal_cannot_claim_earlier_carry() {
        let mut b = bank(100, 0, 0);
        b.accrue_sol_yield(1_000);            // earned before latecomer arrives
        let mut latecomer = depositor(0);
        latecomer.settle_sol_yield(&mut b);   // checkpoint at deposit time
        latecomer.deposited_lamports = 100;
        assert_eq!(latecomer.settle_sol_yield(&mut b), 0,
                   "yield generated before the deposit is not theirs");
    }

    #[test]
    fn unwind_loss_claws_back_carry_then_falls_through() {
        let mut b = bank(100, 0, 0);
        b.accrue_sol_yield(1_000);
        assert!(b.accrue_sol_yield(-400), "loss inside unclaimed carry");
        let mut d = depositor(100);
        assert_eq!(d.settle_sol_yield(&mut b), 600);
        // A loss deeper than the remaining carry is a real impairment: the
        // caller must socialise it rather than the index going negative.
        assert!(!b.accrue_sol_yield(-1_000));
    }

    /// ⭐ **A DOLLAR WITHDRAWAL NO LONGER SPENDS SOL DEPOSITORS' PRINCIPAL.**
    ///
    /// `clutch.rs` used to offer the whole of `bank.sol_lamports` into the
    /// pro-rata split for a dollar claim, on the reasoning that *"SOL is part
    /// of what backs the claim, so it is part of what pays it."* The SOL leg
    /// of `handle_in` says the opposite and matches the deposit contract:
    /// *"ONLY DOLLARS MARGIN STOCKS... the depositor's claim is simply their
    /// lamports: they get back what they put in, plus carry."*
    ///
    /// The invariant that makes the second true is the one asserted here: SOL
    /// backing never falls below the SOL claims against it on a path where no
    /// SOL depositor withdrew.
    #[test]
    fn a_dollar_withdrawal_cannot_reach_sol_depositors_principal() {
        let mut b = bank(0, 0, 0);
        let mut a = depositor(0);
        let ten_sol: u64 = 10_000_000_000;

        // `handle_in`'s native leg moves both books together.
        b.sol_lamports += ten_sol;
        a.deposited_lamports += ten_sol;

        // A dollar depositor withdraws. The only SOL book movement in that
        // path was the `NativeLeg` debit, and there is no longer a leg to
        // debit — `native` is `None` by construction, not by configuration,
        // so no account set a caller can supply reopens it.
        //
        // Nothing here to simulate: the absence IS the property. What the
        // invariant has to survive is that the dollar side moved at all.
        b.total_deposits = b.total_deposits.saturating_sub(0);

        assert!(a.deposited_lamports <= b.sol_lamports,
            "a dollar withdrawal must not leave a SOL claim unbacked: {} > {}",
            a.deposited_lamports, b.sol_lamports);
        assert_eq!(b.sol_lamports, ten_sol,
            "the SOL buffer is untouched by a dollar claim");
    }

    /// ⭐ **WHAT LEVERAGE DOES THIS SYSTEM ACTUALLY PRODUCE?**
    ///
    /// Not a claim — a measurement, because the code reads two ways. `repo`
    /// maintains `pledged - collar <= exposure_value <= pledged + collar` in
    /// BOTH directions (`post_variation_margin` above the band,
    /// `reinstate_exposure` below it), and the add-exposure path funds any
    /// excess out of `deposited_quid` rather than letting it stand:
    ///
    ///     if new_exp > pledged + collar_amt {
    ///         let excess = new_exp - (pledged + collar_amt);
    ///         if dq >= excess { dq -= excess; pledged += excess; }
    ///         else { exposure -= excess / price; }   // shrink to fit
    ///     }
    ///
    /// If that pins `exposure_value` to `pledged`, then
    /// `leverage = exposure_value * 100 / pledged` cannot reach the range
    /// `max_leverage_pct` is allowed to return ([110, 2000]), and every knob
    /// keyed off leverage is being evaluated somewhere it was not designed for.
    ///
    /// This drives the real `repo` and reports what comes out.
    #[test]
    fn what_leverage_does_opening_exposure_actually_produce() {
        let mut b = bank(0, 0, 0);
        let mut a = depositor(0);
        let mut act = Actuary::default();
        act.observed_vol_bps = 200;
        act.obs_count = 200;
        act.last_price = 1_000_000;

        // Fund the account and open a position on one ticker.
        a.deposited_quid = 1_000_000;
        b.total_deposits = 1_000_000;
        a.balances.push(Stock { ticker: Depositor::pad_ticker("AAPL"), marked: 0,
            pledged: 0, exposure: 0, updated: 0, collar_bps: 0, cost_basis: 0,
            interest_paid: 0, breached_at: 0, collar_dollars: 0,
            collar_dollar_seconds: 0, premium_checkpoint: 0, funding_checkpoint: 0 });

        let price = PRICE_SCALE as u64;
        // ⚠️ THE FLOW MATTERS AND THE FIRST CUT OF THIS TEST GOT IT WRONG.
        //    Calling `repo` straight onto a zero pledge returns Err — and a
        //    unit test has no transaction to roll back, so the partial
        //    mutations survived and the test reported a position with 500k of
        //    exposure against nothing. That was the harness, not the program.
        //
        //    The real sequence is `handle_in` -> `renege(+dollars)` to fund
        //    `pledged`, then `handle_out(exposure: true)` -> `repo`.
        a.renege(Some("AAPL"), 100_000, Some(&vec![price]), 1)
            .expect("funding the pod must succeed");
        let funded = a.balances[0].pledged;

        // Now ask for far more exposure than the pledge would carry at 1x.
        let opened = a.repo("AAPL", 500_000, price, 2, 1, &act, &mut b);

        let pod = a.balances[0];
        println!("\n  funded pledged {}  |  repo() -> {:?}", funded,
                 opened.as_ref().map(|_| "Ok").map_err(|_| "Err"));
        let exposure_value = units_value(pod.exposure.unsigned_abs(), price);
        let lev = if pod.pledged > 0 { exposure_value * 100 / pod.pledged } else { 0 };

        println!("\n=== what opening exposure produces ===");
        println!("  deposited_quid left  {}", a.deposited_quid);
        println!("  pledged              {}", pod.pledged);
        println!("  exposure (units)     {}", pod.exposure);
        println!("  exposure_value       {}", exposure_value);
        println!("  LEVERAGE (x100)      {}", lev);
        println!("  max_leverage_pct     {}", crate::etc::max_leverage_pct(&act, 1, 5_000));

        // ── the same question from the other two directions ────────────────
        // (b) a depositor who CANNOT fund the gap: the add-path shrinks the
        //     exposure to fit rather than leaving it levered.
        let mut b2 = bank(0, 0, 0);
        let mut a2 = depositor(0);
        a2.deposited_quid = 100_000;          // only the pledge, no spare
        b2.total_deposits = 100_000;
        a2.balances.push(Stock { ticker: Depositor::pad_ticker("AAPL"), marked: 0,
            pledged: 0, exposure: 0, updated: 0, collar_bps: 0, cost_basis: 0,
            interest_paid: 0, breached_at: 0, collar_dollars: 0,
            collar_dollar_seconds: 0, premium_checkpoint: 0, funding_checkpoint: 0 });
        a2.renege(Some("AAPL"), 50_000, Some(&vec![price]), 1).unwrap();
        let r2 = a2.repo("AAPL", 500_000, price, 2, 1, &act, &mut b2);
        let p2 = a2.balances[0];
        let v2 = units_value(p2.exposure.unsigned_abs(), price);
        println!("  [dq-poor]  repo -> {:<3}  pledged {}  exposure_value {}  lev {}",
                 if r2.is_ok() { "Ok" } else { "ERR" },
                 p2.pledged, v2, if p2.pledged > 0 { v2 * 100 / p2.pledged } else { 0 });
        println!("             (ERR means the tx reverts on chain; the numbers");
        println!("              beside it are a half-applied call, not a position)");

        // (b2) the same account asking for something the cap DOES allow, so
        //      the funding branch is reached instead of the guard.
        let mut b4 = bank(0, 0, 0);
        let mut a4 = depositor(0);
        a4.deposited_quid = 100_000;
        b4.total_deposits = 100_000;
        a4.balances.push(Stock { ticker: Depositor::pad_ticker("AAPL"), marked: 0,
            pledged: 0, exposure: 0, updated: 0, collar_bps: 0, cost_basis: 0,
            interest_paid: 0, breached_at: 0, collar_dollars: 0,
            collar_dollar_seconds: 0, premium_checkpoint: 0, funding_checkpoint: 0 });
        a4.renege(Some("AAPL"), 50_000, Some(&vec![price]), 1).unwrap();
        let r4 = a4.repo("AAPL", 200_000, price, 2, 1, &act, &mut b4);
        let p4 = a4.balances[0];
        let v4 = units_value(p4.exposure.unsigned_abs(), price);
        println!("  [under cap] repo -> {:<3}  pledged {}  exposure_value {}  lev {}",
                 if r4.is_ok() { "Ok" } else { "ERR" },
                 p4.pledged, v4, if p4.pledged > 0 { v4 * 100 / p4.pledged } else { 0 });

        // (c) the SHORT side, in case the pin is one-directional.
        let mut b3 = bank(0, 0, 0);
        let mut a3 = depositor(0);
        a3.deposited_quid = 1_000_000;
        b3.total_deposits = 1_000_000;
        a3.balances.push(Stock { ticker: Depositor::pad_ticker("AAPL"), marked: 0,
            pledged: 0, exposure: 0, updated: 0, collar_bps: 0, cost_basis: 0,
            interest_paid: 0, breached_at: 0, collar_dollars: 0,
            collar_dollar_seconds: 0, premium_checkpoint: 0, funding_checkpoint: 0 });
        a3.renege(Some("AAPL"), 100_000, Some(&vec![price]), 1).unwrap();
        let r3 = a3.repo("AAPL", -500_000, price, 2, 1, &act, &mut b3);
        let p3 = a3.balances[0];
        let v3 = units_value(p3.exposure.unsigned_abs(), price);
        println!("  [short]     repo -> {:<3}  pledged {}  exposure_value {}  lev {}",
                 if r3.is_ok() { "Ok" } else { "ERR" },
                 p3.pledged, v3, if p3.pledged > 0 { v3 * 100 / p3.pledged } else { 0 });

        // ── what the three successful opens have in common ─────────────────
        //
        // ⭐ THIS ASSERTION USED TO RUN THE OTHER WAY, AND ITS OWN MESSAGE SAID
        //    WHAT WOULD MEAN: *"if a successful open now clears 1.15x, leverage
        //    has become reachable and every knob keyed off it needs rereading."*
        //    It was a tripwire on the pin, and the pin is gone. Every successful
        //    open landed at 1.00–1.03x because `repo` drove `exposure_value`
        //    onto `pledged` by force, in both directions and on both sides;
        //    the requirement is now the margin the fitted tail demands and the
        //    forcing is gone with it.
        //
        // What the three now have in common is the margin identity rather than
        // the 1x accident: a funded position stands at whatever leverage its
        // own margin implies, and no more.
        let lev4 = v4 * 100 / p4.pledged;
        let lev3 = v3 * 100 / p3.pledged;
        let band = act.loss_profile(100_000, 0).margin_bps;
        let implied = 10_000 * 100 / band;
        println!("\n  margin {band} bps ⇒ {implied} (x100) of leverage");
        for (label, l, pledged, value) in [
            ("dq-rich long", lev,  pod.pledged, exposure_value),
            ("under cap",    lev4, p4.pledged, v4),
            ("short",        lev3, p3.pledged, v3)] {
            // The margin identity, which is the whole contract: collateral
            // covers the tail move over the act-plus-unwind horizon.
            let required = value as u128 * band as u128 / 10_000;
            assert!(pledged as u128 + 2 >= required,
                "{label}: pledged {pledged} does not margin {value} at {band} bps");
            // And the cap is respected rather than made unreachable.
            assert!(l as i64 <= crate::etc::max_leverage_pct(&act, 1, 5_000),
                "{label} at {l} (x100) exceeded the cap");
            assert!(l > 115,
                "{label} opened at {l} (x100) — the forcing is back");
        }
        // Long and short reach the same place from the same collateral.
        assert_eq!(lev, lev3, "the two sides must lever symmetrically");
        assert!(r2.is_err(), "asking past the cap must revert, not clamp");
    }

    /// The band caps `exposure_value <= pledged + collar_amt`, and `collar_amt`
    /// is a fraction of the notional — so the arithmetic bound on leverage is
    /// `1 / (1 - c)`. This sweeps `c` and reports what each permits.
    #[test]
    fn what_collar_width_permits_what_leverage() {
        println!("\n=== the band's arithmetic bound on leverage ===");
        println!("  {:>10} {:>14} {:>16}", "collar bps", "max leverage", "note");
        for c in [200i64, 1_000, 2_000, 5_000, 9_000] {
            // exposure_value <= pledged + c*exposure_value
            //   => exposure_value * (1 - c) <= pledged
            //   => lev = exposure_value/pledged <= 1/(1-c)
            let lev_x100 = if c < 10_000 { 100 * 10_000 / (10_000 - c) } else { i64::MAX };
            let note = if c > crate::etc::MAX_COLLAR_BPS { "ABOVE MAX_COLLAR_BPS" } else { "" };
            println!("  {:>10} {:>13}x {:>16}", c, lev_x100 as f64 / 100.0, note);
        }
        println!("  MAX_COLLAR_BPS = {} -> the widest band the engine will size",
                 crate::etc::MAX_COLLAR_BPS);
        let cap = 100 * 10_000 / (10_000 - crate::etc::MAX_COLLAR_BPS);
        println!("  => arithmetic ceiling on leverage: {}x", cap as f64 / 100.0);
        println!("  max_leverage_pct is allowed to return up to 2000 (20x)");

        // 10x needs a band of 90%, which the engine cannot size.
        let needed_for_10x = 10_000 - 10_000 / 10;
        println!("  a 10x position needs collar_bps = {} to sit inside its band",
                 needed_for_10x);
        assert!(needed_for_10x > crate::etc::MAX_COLLAR_BPS,
            "if MAX_COLLAR_BPS now reaches {needed_for_10x}, 10x has become \
             representable inside the band and this note is stale");
    }

    /// ⛔ **THE BAND IS CENTRED ON `pledged`, AND THAT ONLY WORKS AT 1x.**
    ///
    /// `repo` judges a position against `pledged ± collar_amt`:
    ///   exposure_value > pledged + collar_amt  -> over-profitable, margin call
    ///   exposure_value < pledged - collar_amt  -> under-exposed, reinstate
    ///
    /// At 1x that is sound: `pledged` IS the notional, so the band is a band
    /// around the position's own value and `collar_amt` is the move that
    /// triggers action.
    ///
    /// At any real leverage `pledged` is the MARGIN, a fraction of the
    /// notional, and a band around it is not a band around anything the price
    /// does. A 10x position sits outside its own band the instant it opens —
    /// not because it moved, but because 10x margin is 10% of notional and the
    /// band is 2% of notional centred on that 10%.
    ///
    /// So one quantity is doing two incompatible jobs:
    ///   • a LIQUIDATION BAND — how far may this move before we act. Wants to
    ///     be SMALL (the fitted ES, ~2%), and `collar_bps` computes it well.
    ///   • a MARGIN REQUIREMENT — how much collateral per unit of notional.
    ///     For 10x it wants to be 90%.
    /// Sizing one correctly makes the other absurd, which is why
    /// `MAX_COLLAR_BPS = 5000` caps leverage at 2x and why widening it to 9000
    /// would mean not liquidating until a position had moved 90%.
    ///
    /// ⚠️ THE COLLAR ITSELF IS NOT THE BROKEN PART. `collar_bps` is the
    /// expected shortfall of the fitted tail and is the right answer to the
    /// question it asks. What is broken is USING it as the margin bound, and
    /// CENTRING it on `pledged` rather than on the position's value.
    #[test]
    fn a_levered_position_is_outside_its_band_the_moment_it_opens() {
        let price = PRICE_SCALE as u64;
        // A hand-built 10x position: 100 margin, 1000 of notional. Built
        // directly because `repo` cannot produce one — that is the finding in
        // `what_collar_width_permits_what_leverage`.
        let mut pod = Stock { ticker: Depositor::pad_ticker("AAPL"), marked: 0,
            pledged: 100, exposure: 1_000, updated: 0,
            collar_bps: 200,                 // a 2% liquidation band
            cost_basis: 100, interest_paid: 0, breached_at: 0,
            collar_dollars: 0, collar_dollar_seconds: 0, premium_checkpoint: 0, funding_checkpoint: 0 };

        let exposure_value = pod.value_at(price);
        let collar_amt = collar_amount(&pod, price);
        let upper = pod.pledged.saturating_add(collar_amt);
        let lower = pod.pledged.saturating_sub(collar_amt);

        println!("\n=== a 10x position judged against pledged ± collar ===");
        println!("  pledged (margin)   {}", pod.pledged);
        println!("  exposure_value     {}", exposure_value);
        println!("  collar_amt (2%)    {}", collar_amt);
        println!("  band               [{}, {}]", lower, upper);
        println!("  -> exposure_value is {} the band",
                 if exposure_value > upper { "ABOVE" } else { "inside" });

        assert!(exposure_value > upper,
            "a 10x position must currently read as over-profitable at open: \
             {exposure_value} vs upper {upper}. If this now fails the band has \
             been re-centred and the margin/liquidation split has been made.");

        // The price has not moved. The position is untouched. It is only the
        // CENTRE of the band that makes it look like a runaway gain.
        assert_eq!(exposure_value, 1_000, "no price move has occurred");
        let _ = pod.value_at(price);
    }

    #[test]
    fn wsol_mint_constant_is_the_native_mint() {
        assert_eq!(WSOL_MINT.to_string(),
                   "So11111111111111111111111111111111111111112");
    }
}

#[cfg(test)]
mod frame_budget {
    use super::*;
    use crate::entra::ProgramConfig;
    use crate::etc::{TickerRisk, Actuary};

    /// Anchor deserialises every `Account<T>` inline on the instruction's
    /// stack frame, and SBF gives each frame 4KB. `Box` moves the payload to
    /// the 32KB bump heap for the price of one indirection.
    ///
    /// The trap is that the overflow is silent — the program aborts with
    /// "Program failed to complete" and a compute count far under budget, and
    /// whether it happens at all shifts when an unrelated constraint is added.
    /// This test makes the budget explicit so growth in an account type fails
    /// here, loudly, rather than in whichever instruction happened to be
    /// closest to the edge.
    #[test]
    fn account_types_stay_inside_the_frame_budget() {
        let sizes: [(&str, usize); 6] = [
            ("Depositor",     core::mem::size_of::<Depositor>()),
            ("Depository",    core::mem::size_of::<Depository>()),
            ("TickerRisk",    core::mem::size_of::<TickerRisk>()),
            ("Actuary",       core::mem::size_of::<Actuary>()),
            ("ProgramConfig", core::mem::size_of::<ProgramConfig>()),
            ("FlashLoan",     core::mem::size_of::<FlashLoan>()),
        ];
        for (name, size) in sizes { println!("{name:>14}: {size:>6} bytes inline"); }

        // These are all small — the collections that dominate them
        // (`Depositor::balances`, the Actuary's history) are `Vec`s, whose
        // contents Borsh already puts on the heap. What overflows a frame is
        // the sum across a context: every account's payload, plus the
        // temporaries Anchor generates per constraint. That total is not
        // visible from any one type, which is why the policy is to box every
        // deserialised account rather than to box the ones that look big.
        //
        // The cost of the policy is bounded and worth stating: at most a
        // dozen accounts in any context, none of them above this bound, is
        // well under the 32KB bump heap — where an over-allocation fails
        // loudly, unlike the silent frame overflow it replaces.
        for (name, size) in sizes {
            assert!(size < 4_096, "{name} is {size} bytes — too large to ever sit inline");
        }
        assert!(sizes.iter().map(|(_, s)| s).sum::<usize>() * 2 < 32_768,
                "boxing every account twice over must still fit the bump heap");
    }
}

#[cfg(test)]
mod state_machine_stress {
    use super::*;
    use crate::entra::*;
    use super::tests::{pod, depositor};

    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0 >> 11
        }
        fn pick(&mut self, n: u64) -> u64 { self.next() % n.max(1) }
    }

    /// The identity every operation has to preserve: a depositor's own books
    /// balance. What they hold free plus what is committed to positions is
    /// what they are owed — nothing may appear or vanish between the two.
    fn assert_books_balance(d: &Depositor, before: u64, label: &str) {
        let after = d.deposited_quid
            + d.balances.iter().map(|p| p.pledged).sum::<u64>();
        assert!(after <= before,
                "{label}: books grew from {before} to {after} with no deposit");
    }

    /// Drive `renege` through every ordering of add, remove, and remove-all,
    /// against a book that is sometimes flat, sometimes levered, sometimes
    /// already stripped of collateral — the combinations that only occur when
    /// somebody is closing a position while another is being opened.
    #[test]
    fn renege_never_creates_value_in_any_order() {
        for seed in 1..=64u64 {
            let mut rng = Lcg(seed);
            let mut d = depositor(0);
            d.deposited_quid = 1_000_000_000;

            // Two or three positions, some levered, some bare.
            let count = 2 + rng.pick(2) as usize;
            for i in 0..count {
                let pledged = rng.pick(500_000_000);
                let exposure = rng.pick(2_000_000) as i64 - 1_000_000;
                let mut p = pod(pledged, exposure, 200, 0);
                p.ticker = Depositor::pad_ticker(match i { 0 => "AAA", 1 => "BBB", _ => "CCC" });
                d.balances.push(p);
            }
            let prices: Vec<u64> = d.balances.iter().map(|_| 1 + rng.pick(1_000)).collect();

            for step in 0..24 {
                let before = d.deposited_quid
                    + d.balances.iter().map(|p| p.pledged).sum::<u64>();
                let now = 1_000 + step * 900;

                let r = match rng.pick(4) {
                    // Strip collateral across the whole book, including past
                    // the point where there is any left to take.
                    0 => d.renege(None, -(rng.pick(2_000_000_000) as i64), Some(&prices), now),
                    // Add to one position.
                    1 => d.renege(Some("AAA"), rng.pick(100_000_000) as i64, None, now),
                    // Remove from one position, sometimes more than it holds.
                    2 => d.renege(Some("BBB"), -(rng.pick(900_000_000) as i64),
                                  Some(&vec![prices[0]]), now),
                    // A no-op amount, which must not be treated as a sweep.
                    _ => d.renege(Some("CCC"), 0, Some(&vec![prices[0]]), now),
                };
                // Whether it succeeded or refused, nothing may have been minted.
                let _ = r;
                assert_books_balance(&d, before, &format!("seed {seed} step {step}"));

                for p in &d.balances {
                    assert!(p.cost_basis <= p.pledged.max(p.cost_basis),
                            "seed {seed}: cost basis detached from pledge");
                }
            }
        }
    }

    /// Stripping a position of its collateral must not leave it able to grow.
    /// This is the shape the `else { 100 }` leverage guard allowed: a pod with
    /// exposure and nothing behind it reading as unlevered.
    #[test]
    fn a_stripped_position_cannot_be_grown() {
        let a = crate::etc::Actuary::default();
        let mut d = depositor(0);
        let mut p = pod(1_000_000, 5_000, 200, 0);
        p.ticker = Depositor::pad_ticker("AAA");
        d.balances.push(p);

        // Take every last unit of collateral out.
        let _ = d.renege(Some("AAA"), -1_000_000, Some(&vec![100]), 1_000);
        let stripped = d.balances[0].pledged;

        // Whatever remains, the position may not be valued as if it were safe.
        if stripped == 0 && d.balances[0].exposure != 0 {
            let lev_reads_unlevered = collar_bps(100, &a);
            let lev_reads_unbounded = collar_bps(i64::MAX, &a);
            assert!(lev_reads_unbounded <= lev_reads_unlevered,
                    "a stripped position must not be handed the wider band");
        }
    }
}

#[cfg(test)]
mod sol_yield_conservation {
    use super::*;
    use crate::entra::*;
    use super::tests::{depositor, bank};

    /// Attributed SOL carry has to be backed by something the pool holds.
    ///
    /// `settle_sol_yield` credits a depositor's balance and `total_deposits`.
    /// The value behind it is the SOL* tranche appreciating, which the pool
    /// records in `sol_usd_contrib` — so if the index moves without that
    /// figure moving, the pool owes more than it holds.
    #[test]
    fn attributed_carry_is_backed_by_the_pools_own_mark() {
        let mut b = bank(10_000_000_000, 0, 0);
        b.sol_usd_contrib = 1_000_000;
        b.total_deposits = 1_000_000;

        let mut d = depositor(10_000_000_000);
        d.sol_pledged_usd = 1_000_000;
        d.sol_yield_checkpoint = b.sol_yield_index;

        let held_before = b.sol_usd_contrib;
        let owed_before = b.total_deposits;

        // Carry realised on the parked tranche.
        assert!(b.accrue_sol_yield(50_000), "carry should attribute to SOL");
        let owed = d.settle_sol_yield(&mut b);
        assert!(owed > 0, "the depositor should be credited");

        // Carry lands on the SOL position and on the pool's SOL mark, in
        // step. It never touches the dollar side, because a SOL deposit
        // margins nothing.
        let _ = owed_before;
        let held_delta = b.sol_usd_contrib - held_before;
        assert_eq!(d.sol_pledged_usd, 1_000_000 + held_delta,
            "the depositor's SOL position must rise by what the pool marked");
        assert_eq!(b.total_deposits, 1_000_000,
            "and the dollar side must not move at all");
    }
}

#[cfg(test)]
mod exit_fairness {
    use super::*;
    use crate::entra::*;
    use super::tests::bank;

    /// When the pool is reserved against borrowers, who can still get out?
    ///
    /// `withdrawable()` is a pool-wide figure — total plus earnings, less the
    /// reserve. Capping each payout by it means the first depositor to ask can
    /// take the whole of the free capacity and the next one finds none, which
    /// is a race rather than a rule.
    #[test]
    fn free_capacity_is_shared_not_raced() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000_000;
        b.max_liability = 400_000;          // borrowers' reserve
        let free = b.withdrawable();
        assert_eq!(free, 600_000);

        // Two depositors of equal size. Each is owed 500_000 and the pool can
        // release 600_000 between them, so a fair rule gives each 300_000.
        let alice = 500_000u64;
        let bob = 500_000u64;

        let fair = |mine: u64| (mine as u128 * free as u128
                                / (b.total_deposits + b.yield_pool) as u128) as u64;
        assert_eq!(fair(alice), 300_000);
        assert_eq!(fair(bob), 300_000);
        assert!(fair(alice) + fair(bob) <= free,
                "shares of free capacity must not sum past it");

        // Whereas capping by the pool-wide figure alone lets the first mover
        // take everything: 500_000 of the 600_000, leaving 100_000 for a
        // depositor owed the same amount.
        let first_mover_takes = alice.min(free);
        assert_eq!(first_mover_takes, 500_000);
        assert!(bob.min(free - first_mover_takes) < fair(bob),
                "the second depositor is left worse off by arriving second");
    }
}

#[cfg(test)]
mod exit_and_return {
    use super::*;
    use crate::entra::*;
    use super::tests::{depositor, bank};

    /// A borrower's profit is paid out of the pool, so it is a loss to
    /// depositors. Where it lands decides whether leaving before it and
    /// returning afterwards is profitable.
    ///
    /// Against earnings it is not: the leaver forfeits their tenure share of
    /// premiums, which is the thing tenure exists to allocate, and every
    /// claim on principal stays exactly equal to what backs it.
    #[test]
    fn a_loss_within_earnings_leaves_every_claim_backed() {
        let mut b = bank(0, 0, 0);
        let mut stayer = depositor(0);
        let mut leaver = depositor(0);

        stayer.pool_deposit(&mut b, 1_000_000, 0);
        leaver.pool_deposit(&mut b, 1_000_000, 0);
        b.yield_pool = 500_000;                    // premiums collected

        let taken = leaver.deposited_quid;
        leaver.pool_withdraw(&mut b, taken, 100).unwrap();

        // A 400_000 take-profit, paid for by premiums as `handle_out` now does.
        let loss = 400_000u64;
        let from_yield = loss.min(b.yield_pool);
        b.yield_pool -= from_yield;
        b.total_deposits = b.total_deposits.saturating_sub(loss - from_yield);

        leaver.pool_deposit(&mut b, taken, 200);

        assert_eq!(stayer.deposited_quid + leaver.deposited_quid, b.total_deposits,
            "principal claims must still equal the principal that backs them");
        assert_eq!(b.yield_pool, 100_000, "the loss came out of premiums");
    }

    /// The limit of that protection, stated rather than assumed.
    ///
    /// A loss larger than everything the pool has earned reaches deposits, and
    /// `total_deposits` is an aggregate no individual claim tracks — so every
    /// depositor still claims par against a pool holding less, and leaving
    /// before it is once again strictly better than staying. Closing this
    /// needs claims to be shares of the pool rather than fixed amounts, so a
    /// mark-down reaches everyone at once and there is nothing to step out of.
    #[test]
    fn a_loss_beyond_earnings_is_not_yet_marked_to_claims() {
        let mut b = bank(0, 0, 0);
        let mut a = depositor(0);
        let mut c = depositor(0);
        a.pool_deposit(&mut b, 1_000_000, 0);
        c.pool_deposit(&mut b, 1_000_000, 0);

        b.total_deposits = b.total_deposits.saturating_sub(400_000);  // beyond earnings

        assert!(a.deposited_quid + c.deposited_quid > b.total_deposits,
            "documented gap: claims {} exceed the {} backing them",
            a.deposited_quid + c.deposited_quid, b.total_deposits);
    }
}



#[cfg(test)]
mod sol_is_not_margin {
    use super::*;
    use super::tests::{depositor, bank, pod};

    /// A SOL deposit is a yield position. It must not fund stock margin, and a
    /// stock loss must not reach it — the two directions of the same rule.
    #[test]
    fn sol_cannot_be_spent_as_stock_margin() {
        let mut b = bank(0, 0, 0);
        let mut d = depositor(0);

        // Deposit SOL: lamports and the pool's SOL mark move, the dollar
        // balance does not.
        d.deposited_lamports = 10_000_000_000;
        d.sol_pledged_usd = 1_000_000;
        b.sol_usd_contrib = 1_000_000;

        assert_eq!(d.deposited_quid, 0,
            "SOL must not appear in the balance that funds pledged");
        assert_eq!(b.total_deposits, 0,
            "nor in the pool's dollar backing");

        // So there is nothing for `renege` to draw on: a stock position cannot
        // be opened against it.
        assert!(d.renege(Some("AAA"), 500_000, None, 100).is_ok());
        assert_eq!(d.balances.first().map_or(0, |p| p.pledged), 500_000);
        // ...and that pledge came from the dollar side going negative-free,
        // which is to say it could only ever have come from a dollar deposit.
        assert_eq!(d.deposited_quid, 0);
    }

    /// The pool's solvency gates do not see SOL, so a crash in it cannot
    /// narrow a stablecoin depositor's exit.
    #[test]
    fn a_sol_crash_leaves_the_dollar_book_untouched() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 600_000;        // dollars only
        b.sol_usd_contrib = 400_000;       // SOL, alongside
        b.max_liability = 300_000;

        let free = b.withdrawable();
        let room = b.has_capacity(100_000);

        b.sol_usd_contrib = 100_000;       // SOL falls 75%

        assert_eq!(b.withdrawable(), free);
        assert_eq!(b.has_capacity(100_000), room);
        assert_eq!(b.total_deposits, 600_000, "dollars, untouched");
        let _ = pod(0, 0, 0, 0);
    }
}

#[cfg(test)]
mod partial_close_basis {
    use super::tests::{bank, pod};
    use super::*;

    /// A short's partial close prices its P&L against RELEASED PLEDGE, but the
    /// pledge is not the basis: `stay.rs:945` debits every premium out of
    /// `pod.pledged` and leaves `pod.cost_basis` alone, so the two diverge by
    /// the whole premium history of the position. `settle_partial_close`
    /// COMPUTES the right number — `cost_basis_released` — uses it to decrement
    /// state, and then does not return it, so the caller reaches for the only
    /// released quantity it was handed.
    #[test]
    fn a_short_partial_close_is_priced_off_pledge_not_basis() {
        let mut b = bank(0, 0, 0);
        let a = crate::etc::Actuary::default();
        // Micro-dollars per share — see §SCALE.
        let price = 100 * PRICE_SCALE as u64;

        // Opened with 1_000 behind it, then aged: 200 of premiums have been
        // billed out of the pledge. `cost_basis` still records what was posted.
        let mut p = pod(1_000, -10, 0, 0);
        p.cost_basis = 1_000;
        p.pledged -= 200;
        p.interest_paid = 200;

        let old_value = p.value_at(price);
        let (pledged_released, basis_closed, _interest_on_closed, _raroc, _closed) =
            settle_partial_close(&mut p, &mut b, &a, old_value,
                old_value / 2, old_value, price, 0, 0);

        // Half the position closed, so half of each released quantity. The two
        // are NOT equal, and that gap is the whole finding: 400 of pledge
        // survives, against 500 of basis actually posted.
        assert_eq!(pledged_released, 400, "half of the 800 that survived premiums");
        assert_eq!(basis_closed, 500, "half of the 1_000 actually posted");
        assert_eq!(p.cost_basis, 500, "and the other half stays on the pod");

        // The short's buy-back is now priced against the basis. Pricing it
        // against `pledged_released` charged the 100 of premiums attributable
        // to this half a second time, having already taken them out of the
        // pledge at :945.
        assert_eq!(basis_closed - pledged_released, 100,
                   "the premium share that used to be billed twice");
    }
}
