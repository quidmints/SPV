
use crate::stay::Stock;
use std::cmp::{max, min};
use anchor_lang::prelude::*;
use crate::tickers::*;
use std::str::FromStr; use phf::phf_map;

pub const SECONDS_PER_HOUR: i64 = 3600;
pub const SECONDS_PER_DAY: i64 = 86400;
pub const TWAP_PERIOD: i64 = 300;
pub const MAX_LEN: usize = 50;

/// How stale a Pyth price may be before it is refused.
///
/// This was previously the same constant as the liquidation grace below, which
/// is why that one carried an absurd 99_999_999: the local Pyth fixtures are
/// static snapshots, so the shared value had to be enormous for them to pass —
/// and enlarging it to suit the oracle silently disabled liquidation, since the
/// same constant gates `repo()`'s liquidator branches. Two policies, two knobs.
#[cfg(not(feature = "testing"))]
pub const MAX_PRICE_AGE: i64 = 300;

/// Effectively unbounded under test, and that is a gap rather than a choice.
///
/// This is the last place where the tested binary differs in behaviour from
/// the shipped one, which is the shape of two bugs already found here: the
/// mint whitelist behind a `mainnet` feature and the endpoint registration
/// behind this one. In both, the path that mattered was the one that never
/// ran. The same holds here — nothing exercises the staleness guard.
///
/// Measured rather than assumed. A one-hour bound was tried and the suite
/// failed: the price accounts read two days older than the validator's clock,
/// because the environment's date advances between fixture refreshes and a
/// fork clones at genesis while the validator takes ninety seconds to come up.
/// So the guard cannot be exercised by changing this number, only by a harness
/// that controls the clock — planting a feed with a chosen publish time and
/// asserting the refusal. Until that exists the shipped bound of five minutes
/// is unproven, and the README says so.
#[cfg(feature = "testing")]
pub const MAX_PRICE_AGE: i64 = i64::MAX / 4;


/// How long a position may sit outside its band before a liquidator may take a
/// tranche of it, and the cadence of the unwind thereafter. The clock it runs
/// against is `Stock::breached_at` — the excursion — not the last time the pod
/// was touched, so paying premiums does not buy immunity.
///
/// An hour is the borrower's window to cure under their own power, and it is
/// the unit the ladder below is calibrated in.
pub const LIQ_GRACE_SECS: u64 = 3_600;

/// Basis points constant (100% = 10000)
pub(crate) const BPS: i64 = 10_000;   // pub(crate) so tickers.rs's test modules can reach it

/// `base^n` where `base` is a bps fraction, by exponentiation by squaring.
/// Nine multiplications at the obs_count cap of 500, against a soft-float
/// `exp` that costs far more and is not reproducible across targets.
pub fn pow_bps(base_bps: i64, n: i64) -> i64 {
    if n <= 0 { return BPS; }
    let (mut result, mut b, mut e) = (BPS, base_bps.clamp(0, BPS), n);
    while e > 0 {
        if e & 1 == 1 { result = result * b / BPS; }
        b = b * b / BPS;
        e >>= 1;
        if b == 0 { break; }
    }
    result
}

/// Seconds in a year — the unit the hazard is quoted in.
pub const SECONDS_PER_YEAR: i64 = 31_536_000;

/// How much hazard an opening position prepays. One liquidation window: the
/// shortest interval after which the ladder could first act on it.
pub const MIN_HOLD_SECS: i64 = LIQ_GRACE_SECS as i64;

/// Bounds on a single liquidation tranche, as a share of the remaining
/// position, and the excursion over which the ladder climbs from one to the
/// other. These are solved, not chosen: we want a position left uncured to be
/// ~95% amortised after a week of hourly calls at full utilisation, and the
/// unwind to open gently enough that a borrower who is merely late is not
/// punished for it.
///
/// Unwinding is geometric — each tranche is a share of what is left — so with
/// N = 7d/`LIQ_GRACE_SECS` = 168 calls and a fraction f_k ramping linearly from
/// MIN to MAX over the first `TRANCHE_RAMP_GRACES` of them, MAX is the root of
/// `Π(1 − f_k) = 0.05`. At MIN = 25bps and a ramp of a quarter of the window
/// that root is 185bps: the first tranche takes 50bps of the position and the
/// last takes 185bps.
///
/// The floor and the ceiling have to be set together — the previous pair had a
/// 1% floor under a 10% ceiling, which the utilisation multiplier drove through
/// the ceiling on the very first eligible call. The ramp existed but nothing
/// ever climbed it, so what looked like a ladder was a cliff one notch down.
pub const MIN_TRANCHE_BPS: i64 = 25;     // 0.25%
pub const MAX_TRANCHE_BPS: i64 = 185;    // 1.85%
pub const TRANCHE_RAMP_GRACES: i64 = 42; // a quarter of the 7-day window

/// Target breach rate the collar is sized to: 1% of moves are expected to
/// carry through the band, which is what the ladder and the hazard premium
/// exist to handle. Sizing to zero breaches would mean an infinite band.
pub const COLLAR_BREACH_BPS: i64 = 100;

/// 100% collar is meaningless (total loss before liquidation defeats purpose)
pub(crate) const MAX_COLLAR_BPS: i64 = 5000;

const MAX_CONFIDENCE_BPS: u64 = 500; // 5%

const MAX_TWAP_DEVIATION_BPS: i64 = 500; // 5%

/// Jump multiplier table: reduces effective eta as jump count increases.
/// More jumps = expect smaller individual jumps (mean reversion).
/// Index maps to jump_count (capped at 10).
///
/// Rationale: After many jumps, the "surprise" factor diminishes.
/// Markets that jump frequently tend to have smaller individual jumps.
const JUMP_MULT: [i64; 11] = [100, 100, 85, 85, 85, 70, 70, 70, 70, 55, 55];
/// The Actuary's adaptive vol model handles asset-specific behavior
/// empirically — these are structural ceilings, not per-class priors.
const STARTING_FLOOR_BPS: i64 = 200; // conservative cold-start vol floor
const MAX_LEVERAGE_PCT:  i64 = 1000; // 10× universal ceiling
pub(crate) const MIN_FEE_BPS:        i64 = 4;   // minimum trade fee
const LEV_THRESHOLD:      i64 = 300; // 3× leverage before compound penalty

#[error_code]
pub enum PithyQuip {

    #[msg("not under-collateralised...still gains to be realised")]
    NotUndercollateralised,

    #[msg("cant be up another one pack a new gun")]
    MaxPositionsReached,

    #[msg("pass in a price or call it off twice")]
    NoPrice,

    #[msg("pass in ticker no miss it or hickups")]
    Tickers,

    #[msg("call in too often or show stops then")]
    TooSoon,

    #[msg("too many ahead take profit instead")]
    TakeProfit,

    #[msg("Зарекалась баба не меняться - замоталась баба зарекаться.")]
    PoolAtCapacity,

    #[msg("")]
    UnknownSymbol,

    #[msg("Recap...")]
    Undercollateralised,

    #[msg("Slow it up...amount is either not enough or too much.")]
    InvalidAmount,

    #[msg("Double-check who you're trying to touch.")]
    InvalidUser,

    #[msg("We only work with stars here.")]
    InvalidMint,

    #[msg("Your position is under-exposed.")]
    UnderExposed,

    #[msg("You must deposit before you can do this.")]
    DepositFirst,

    #[msg("pyth we clip")]
    InvalidPrice,

    #[msg("Invalid parameters")]
    InvalidParameters,

    #[msg("Invalid message format")]
    InvalidMessageFormat,

    #[msg("Unauthorized")]
    Unauthorized,

    #[msg("Insufficient accounts provided")]
    InsufficientAccounts,

    #[msg("Oracle price confidence too wide - price uncertain")]
    PriceUncertain,

    #[msg("Oracle price deviates too much from TWAP - possible manipulation")]
    OracleManipulated,

    #[msg("flash loan already outstanding")]
    FlashLoanActive,

    #[msg("flash_repay instruction not found in transaction")]
    FlashRepayMissing,

    #[msg("caller is not the configured flash authority")]
    InvalidSettlementProgram,

    #[msg("no active flash loan to repay")]
    NoActiveFlashLoan,

    #[msg("insufficient lamports in SOL vault")]
    InsufficientFunds,
}

/// Actuary: adaptive risk
///
/// Unlike traditional systems with preset volatility/jump parameters per asset
/// class, the Actuary starts conservative and discovers each ticker's true
/// characteristics through observation. No priors needed — only Pyth feeds
///
/// ## State Size: ~104 bytes (fits comfortably in PDA)
///
/// ## Confidence Model
///
/// The system uses observation count to build confidence:
/// - 0 obs: 0% confidence → 400 bps vol floor (conservative)
/// - 10 obs: 50% confidence → 200 bps vol floor
/// - 50 obs: 83% confidence → 68 bps vol floor
/// - 100 obs: 91% confidence → 36 bps vol floor
///
/// This prevents the "quiet start" attack where a ticker with no
/// activity gets assigned near-zero vol and offers insane leverage.
///
#[derive(Clone,
    Debug, Default,
    AnchorSerialize,
    AnchorDeserialize)]
#[derive(InitSpace)]
pub struct Actuary {
    // === Volatility Tracking (24 bytes) ===
    /// EMA of observed absolute returns (bps). Updated on each price change.
    /// Fast up, slow down — reacts quickly to vol spikes, decays gradually.
    pub observed_vol_bps: i64,

    /// Maximum single-slot price move observed recently (bps).
    /// Used for collar buffer calculation. Decays after calm periods.
    /// Initialized at 2× vol floor on first observation — the Actuary's
    /// structural memory of the black swan it has not yet seen on this ticker
    /// but has already paid for on a different one.
    pub max_drawdown_bps: i64,

    /// Last oracle price (in token's native precision).
    /// Used to calculate returns on next update.
    pub last_price: i64,

    // === Temporal (16 bytes) ===
    /// Slot number of last price update. Used for staleness penalty.
    pub last_price_slot: i64,

    /// Slot number of last trade. Used for velocity decay.
    pub last_trade_slot: i64,

    // === Jump/Velocity (16 bytes) ===
    /// Count of recent jump events [0, 20]. Jump = move > 3σ.
    /// Decays over time (1 per 1000 slots). Affects eta and collar.
    /// In the founding loss event, jump_count would have saturated to 20
    /// and stayed there — a forced liquidation cascade is precisely the
    /// multi-slot jump sequence this field is designed to detect and price.
    pub jump_count: i64,

    /// Trade velocity score [0, 255]. Higher = more urgent activity.
    /// Combines local (this ticker) and global (all tickers) activity.
    pub velocity: i64,

    // === Momentum (8 bytes) ===
    /// Open interest change rate [-10000, 10000] bps.
    /// Negative = liquidation cascade risk. Affects fee multiplier.
    /// A strongly negative momentum_bps is the on-chain signature of the
    /// shadow banking run — the exit race that turns a peg wobble into a
    /// peg collapse. The momentum multiplier in fee_bps is the protocol's
    /// structural response: discount exits, penalise entries, absorb the
    /// cascade rather than amplifying it.
    pub momentum_bps: i64,

    // === Leverage Exposure (16 bytes) - SIGNED for direction ===
    /// Sum of (exposure × leverage) across all positions, SIGNED.
    /// Positive = net long bias, negative = net short bias.
    pub net_exposure: i64,

    /// Cumulative base premium, in bps-seconds, and the moment it last moved.
    ///
    /// A premium charged as `rate × dt` reads the rate once, from whatever
    /// state prevails when somebody finally touches the position — so a year
    /// held through a storm and settled in the calm is billed as if it had
    /// been calm throughout, and a quiet year settled during a spike is billed
    /// as if it had been a crisis. Measured at 7.5x between two states of the
    /// same ticker, which is both a mispricing and something a borrower can
    /// choose by timing when they touch.
    ///
    /// Integrating instead: every observation advances this by the rate that
    /// prevailed since the last one, and a position is charged the difference
    /// against its own checkpoint. The same accumulator shape as
    /// `sol_yield_index`, and the same one Aave and Compound use for borrow
    /// interest. It cannot capture a state nobody observed — but an
    /// unobserved price is one the pool never knew, so there was no rate to
    /// charge for it either.
    pub premium_index: u128,
    pub index_updated: i64,

    /// Sum of |exposure × leverage| across all positions, always positive.
    /// Total counterparty risk regardless of direction.
    /// This is the denominator of the solvency invariant:
    /// max_liability = Σ(total_exposure × collar_bps) ≤ total_deposits.
    /// Even under the worst correlated tail event, the pool survives.
    pub total_exposure: i64,

    // === Manipulation Resistance (8 bytes) ===
    /// EMA smoothed price for manipulation detection.
    /// Slower than spot price — large deviations indicate potential manipulation.
    /// Also the TWAP overlay that makes price manipulation
    /// prohibitively expensive: sustaining artificial price pressure across
    /// the full TWAP window requires keeping that capital at risk the entire
    /// time — the attacker is the natural short against their own manipulation.
    pub twap_price: i64,

    // === Confidence (8 bytes) ===
    /// Number of price observations. Used to compute confidence level.
    /// Capped at 255 to fit in u8 if needed for space optimization.
    /// The confidence decay from 150% vol to empirical vol is the Actuary's
    /// Bayesian update: pessimistic prior (maximum fear), empirical likelihood
    /// (observed vol), posterior interpolating between them weighted by
    /// observation count. A new ticker starts where the founding position was
    /// when the black swan hit — zero confidence, maximum assumed fragility.
    pub obs_count: i64,

    // === Peaks-over-threshold (16 bytes + 16) ===
    /// Exceedance count, and the running sum and sum-of-squares of the
    /// excesses over the threshold, all in bps.
    ///
    /// These three numbers are the sufficient statistics for a Generalised
    /// Pareto fit by method of moments — the tail model Koutsouri, Petch and
    /// Knottenbelt fit offline to standardised residuals. Keeping them online
    /// means the tail is ESTIMATED from what this ticker actually did, rather
    /// than assumed Gaussian and patched with a jump term.
    pub exceed_count: i64,
    pub exceed_sum: i64,
    pub exceed_sumsq: i128,

    /// Expected shortfall of the fitted tail at COLLAR_BREACH_BPS, in bps.
    ///
    /// Derived once per price update rather than per read. Inverting the
    /// survival function costs a bisection, and `collar_bps` is called several
    /// times per instruction — computing it on every read exhausted the
    /// compute budget outright. It is a property of the ticker's tail, so it
    /// changes when the tail estimate changes and at no other time.
    pub shortfall_bps: i64,

    /// EMA of downside-only moves, in bps. GJR's asymmetry: a negative
    /// innovation raises conditional variance more than a positive one of the
    /// same size, so the two are tracked separately rather than through one
    /// symmetric estimator over |change|.
    pub downside_vol_bps: i64,
}

impl Actuary {
    // =========================================================================
    // CONFIDENCE-BASED LEARNING
    // =========================================================================

    /// Confidence level [0, 100] - asymptotic approach to certainty.
    ///
    /// Formula: obs * 100 / (obs + 10)
    ///
    /// This gives us:
    /// - 10 obs: 50% (halfway to certainty)
    /// - 50 obs: 83% (quite confident)
    /// - 100 obs: 91% (very confident)
    /// - ∞ obs: 100% (certain)
    ///
    /// The +10 denominator term controls how quickly confidence builds.
    /// Lower values = faster confidence gain but more susceptible to noise.
    ///
    /// This asymptotic shape is also the shape of the tranche tranche
    /// recovery curve: the protocol accumulates confidence in its own solvency
    /// the same way the Actuary accumulates confidence in a ticker's true vol —
    /// asymptotically, never claiming certainty, always with a structural floor.
    #[inline]
    pub fn confidence(&self) -> i64 {
        self.obs_count * 100 / (self.obs_count + 10)
    }


    /// Prior = starting_floor × 2 (e.g. 400 bps for Equity).
    /// Decays toward observed_vol_bps as obs_count grows...
    ///
    /// K = 0.05 → prior contributes ~78% at 10 obs, ~37% at 20, ~5% at 60.
    /// Early observations count for almost nothing — the prior collapses
    /// only once enough data accumulates, then falls quickly.
    //
    /// exponential convergence from conservative prior
    /// to empirical never falls below observed_vol_bps.
    ///
    /// A 3x leveraged position in a normal market environment does not require
    /// 150% vol to manage...it requires whatever the asset's empirical vol is;
    /// the 150% floor is not a statement about normal markets, but about forced
    /// liquidation cascades where funding rates dislocate, collateral positions
    /// unwind simultaneously, and the exit race amplifies damage beyond what
    /// any empirical vol estimate from the preceding period would have
    /// predicted. Monte Carlo said 99th percentile loss was manageable.
    ///
    /// It was a 25-sigma event. The floor says: until you have enough data
    /// to know this ticker's true tail, assume the black swan is already
    /// in the distribution.
    ///
    /// Two decay constants encode two separate protections:
    /// K = 0.05 — Bayesian prior: decays as observations accumulate.
    /// K2 = 0.01 — Structural floor: decays 5× slower, protects against
    /// observed_vol_bps manipulation by an attacker feeding quiet prices
    /// to suppress the floor before opening a large position.
    #[inline]
    pub fn vol_floor(&self) -> i64 {
        // e^(−Kn) is a geometric sequence, so it is (e^−K)^n — computed by
        // squaring in fixed point rather than by two soft-float `exp` calls.
        // Those calls were the single most expensive thing in the risk engine:
        // `eff_sigma` is read inside the tail inversion, so a bisection paid
        // for forty of them and exhausted the compute budget outright.
        //   e^-0.05 = 0.951229…  → 9512 bps  (prior, half-life ≈ 14 samples)
        //   e^-0.01 = 0.990050…  → 9900 bps  (structural, half-life ≈ 70)
        const PRIOR_DECAY_BPS: i64 = 9_512;
        const STRUCT_DECAY_BPS: i64 = 9_900;
        let prior = STARTING_FLOOR_BPS * 2;
        let empirical = self.observed_vol_bps;
        let decay = pow_bps(PRIOR_DECAY_BPS, self.obs_count);
        let blended = (prior * decay + empirical * (BPS - decay)) / BPS;
        // Structural floor decays 5x slower than the Bayesian prior.
        // Protects against observed_vol_bps manipulation.
        let structural = STARTING_FLOOR_BPS
            * pow_bps(STRUCT_DECAY_BPS, self.obs_count) / BPS;
        blended.max(self.observed_vol_bps).max(structural)
    }

    /// Effective volatility: observed with confidence-decaying floor.
    ///
    /// As confidence grows, the floor shrinks, allowing low-vol assets
    /// to eventually get their true (low) vol recognized.
    ///
    /// This is the gross on-chain product surface's risk denominator.
    /// The gross on-chain product a depositor earns is the aggregate output
    /// of the basket's constituent protocols, pass-through from their
    /// independent mechanics.
    ///
    /// The Actuary governs how much of that output can be amplified
    /// through leverage before the protocol's solvency invariant is
    /// threatened. eff_sigma is the denominator in that amplification
    /// calculation — higher sigma, lower max leverage, smaller
    /// leveraged gross on-chain product surface,
    /// more conservative collar.

    // =========================================================================
    // TAIL MODEL — peaks over threshold, Generalised Pareto
    // =========================================================================
    //
    // The tail used to be a Gaussian lookup table with a jump term bolted on to
    // apologise for it. Financial returns are not Gaussian in the tail, which
    // is the entire premise of the EVT literature this follows: fit a GPD to
    // exceedances over a threshold and read the tail off the fit.
    //
    // Everything below is the standard peaks-over-threshold result, in integer
    // arithmetic. No transcendentals: the shape parameter is snapped to 1/n for
    // integer n, which turns the power law into n multiplications and costs
    // only the granularity of the shape estimate.

    /// Threshold u for exceedances: one effective sigma.
    #[inline]
    pub fn pot_threshold(&self) -> i64 { max(1, self.eff_sigma()) }

    /// ζ_u — the empirical rate of exceeding u, in bps.
    pub fn exceedance_rate_bps(&self) -> i64 {
        if self.obs_count <= 0 { return 0; }
        min(BPS, self.exceed_count * BPS / self.obs_count)
    }

    /// GPD parameters by method of moments, returned as (n, β) where ξ = 1/n.
    ///
    /// For excesses with mean ē and variance s²:
    ///     ξ = ½(1 − ē²/s²),  β = ½ē(ē²/s² + 1)
    ///
    /// Method of moments rather than maximum likelihood because it needs only
    /// the running count, sum and sum of squares — three integers updated in
    /// O(1) — where MLE would need the retained sample. It is consistent for
    /// ξ < ½, which is the range these estimates are clamped to anyway.
    ///
    /// n is clamped to [2, 12]: n = 2 is ξ = 0.5, the fattest tail with a
    /// finite mean-excess, and n = 12 is ξ ≈ 0.083, effectively exponential.
    pub fn gpd_params(&self) -> (i64, i64) {
        let count = self.exceed_count;
        // Too few exceedances to estimate a shape: assume the FATTEST tail we
        // model (n = 2, ξ = 0.5), scaled by observed vol.
        //
        // 🔴 THIS WAS n = 4, DESCRIBED AS "conservative in neither direction,
        // and it self-corrects as exceedances accumulate." Both halves were
        // true and together they were a hole: **"self-corrects" is the wrong
        // property when an adversary picks the moment.** A newly listed or
        // simply quiet ticker priced its tail off an ASSUMPTION, and the
        // cheapest time to carry size against an unmeasured tail is precisely
        // before the measurement exists. `obs_count < 5` disables the TWAP
        // guard over the same window, so the two soft spots coincide.
        //
        // n = 2 is the fattest tail with a finite mean excess, so an
        // unestimated tail is now a BOUND rather than a guess, and it RELAXES
        // as data arrives instead of having to be corrected upward. The cost
        // is a wider collar — and therefore less leverage — on an instrument
        // whose tail nobody has measured yet, which is the trade we want.
        if count < 8 { return (2, max(1, self.eff_sigma() / 2)); }

        let e_bar = self.exceed_sum / count;                       // ē
        if e_bar <= 0 { return (4, max(1, self.eff_sigma() / 2)); }

        // The accumulator is i128 so it cannot overflow over a long life; the
        // mean is bounded by the square of a bps move and lands back in i64.
        let mean_sq = (self.exceed_sumsq / count as i128)
            .clamp(0, i64::MAX as i128) as i64;                     // E[x²]
        let var = mean_sq - e_bar * e_bar;                         // s²
        if var <= 0 { return (12, max(1, e_bar)); }                // degenerate ⇒ exponential

        // ratio = ē²/s², in bps
        let ratio = (e_bar.saturating_mul(e_bar).saturating_mul(BPS) / var)
            .clamp(0, 10 * BPS);

        // ξ = ½(1 − ratio); β = ½ē(ratio + 1)
        let xi_bps = (BPS - ratio) / 2;
        let beta = max(1, e_bar.saturating_mul(ratio + BPS) / (2 * BPS));

        // ξ ≤ 0 is a bounded, thin tail. The ξ→0 limit of the GPD is the
        // exponential, whose scale is exactly the mean excess — so use that
        // rather than the moment β, which is inflated by the clamped variance
        // ratio in precisely this degenerate case and would price a thin tail
        // as heavier than a fat one.
        if xi_bps <= 0 { return (12, max(1, e_bar)); }
        let n = (BPS / xi_bps).clamp(2, 12);
        (n, beta)
    }

    /// P(move > d), in bps.
    ///
    /// Above the threshold this is the GPD survival function
    ///     ζ_u · (1 + ξ(d−u)/β)^(−1/ξ)
    /// which with ξ = 1/n is exactly ζ_u · (nβ / (nβ + d − u))^n.
    ///
    /// Below the threshold the POT model says nothing by construction, so the
    /// interior is interpolated between certainty at zero and ζ_u at u — the
    /// integer counterpart of the kernel-smoothed interior used offline.
    pub fn tail_prob_bps(&self, d_bps: i64) -> i64 {
        let (n, beta) = self.gpd_params();
        self.tail_with(d_bps, n, beta)
    }

    /// Survival function with the fit already in hand.
    ///
    /// Split out because inverting it bisects, and recomputing the fit inside
    /// the loop — in i128, whose division is a software routine on this target
    /// — cost the entire compute budget. Every value here is bounded: ζ ≤ 1e4,
    /// nβ ≤ 12·MAX_COLLAR_BPS, so q·nβ stays under 1e9 and i64 is exact.
    #[inline]
    pub fn tail_with(&self, d_bps: i64, n: i64, beta: i64) -> i64 {
        self.tail_at(d_bps, n, beta, self.pot_threshold(),
                     self.exceedance_rate_bps())
    }

    /// Survival function with the fit AND the threshold/rate already in hand,
    /// so an inversion loop recomputes none of them.
    #[inline]
    pub fn tail_at(&self, d_bps: i64, n: i64, beta: i64, u: i64, zeta: i64) -> i64 {
        if d_bps <= 0 { return BPS; }
        if d_bps <= u {
            return BPS - (BPS - zeta) * d_bps / u;
        }
        let nb = n.saturating_mul(beta);
        let den = nb.saturating_add(d_bps - u);
        if den <= 0 { return 0; }
        let mut q = zeta;
        for _ in 0..n {
            q = q.saturating_mul(nb) / den;
            if q == 0 { break; }
        }
        q.clamp(0, BPS)
    }

    /// e(d) = E[X − d | X > d], the GPD mean excess, in bps.
    ///
    /// For a GPD this is linear in the threshold: (β + ξ(d−u))/(1−ξ). That
    /// linearity is what makes it the diagnostic for choosing u, and it is
    /// exactly the loss-given-breach the pool is exposed to once price is
    /// through the collar — derived, where it used to be
    /// `max(0, max_drawdown − collar)`.
    pub fn mean_excess_bps(&self, d_bps: i64) -> i64 {
        let (n, beta) = self.gpd_params();
        let u = self.pot_threshold();
        let excess = max(0, d_bps - u);
        // (β + excess/n)/(1 − 1/n) = (nβ + excess)/(n − 1)
        max(1, (n.saturating_mul(beta).saturating_add(excess)) / max(1, n - 1))
    }

    /// The level whose exceedance probability is `p_bps`, in bps.
    ///
    /// Inverting the survival function by bisection rather than by an nth
    /// root: same answer, no root-finding primitive, and it cannot disagree
    /// with `tail_prob_bps` because it calls it.
    pub fn quantile_bps(&self, p_bps: i64) -> i64 {
        // Fit, threshold and exceedance rate are all constant across the
        // search; only the level moves.
        let (n, beta) = self.gpd_params();
        let (u, zeta) = (self.pot_threshold(), self.exceedance_rate_bps());
        let (mut lo, mut hi) = (0i64, max(100, self.eff_sigma() * 50));
        for _ in 0..20 {
            let mid = lo + (hi - lo) / 2;
            if mid == lo { break; }
            if self.tail_at(mid, n, beta, u, zeta) > p_bps { lo = mid; } else { hi = mid; }
        }
        hi
    }

    /// Expected shortfall at `p_bps`, in bps: ES = x_p + e(x_p).
    ///
    /// The GPD identity ES_α = (x_α + β − ξu)/(1 − ξ) written as quantile plus
    /// mean excess, which is the same quantity and reuses the two functions
    /// above instead of restating their parameters.
    pub fn expected_shortfall_bps(&self, p_bps: i64) -> i64 {
        let x = self.quantile_bps(p_bps);
        x.saturating_add(self.mean_excess_bps(x))
    }

    pub fn eff_sigma(&self) -> i64 {
         self.vol_floor()
    }

    /// Effective jump size (eta): expected gap magnitude.
    ///
    /// Tightened by jump history — more jumps = expect smaller individual jumps.
    /// Uses max_drawdown as base, floored by 2× vol floor for safety.
    ///
    /// In the shadow banking run that produces a forced liquidation cascade,
    /// eta is the gap that opens between the last traded price and the
    /// liquidation price when the order book evaporates.
    #[inline]
    pub fn eff_eta(&self) -> i64 {
        let base = max(self.vol_floor() * 2, self.max_drawdown_bps);
        max(100, base * JUMP_MULT[min(10, self.jump_count as usize)] / 100)
    }

    /// Jump regime intensity [0, 100].
    ///
    /// Linear scale: 0 jumps = 0, 20 jumps = 100.
    /// Used to adjust fees and rates during volatile periods.
    ///
    /// A jump regime at 100 is the on-chain encoding of the condition
    /// under which new leverage effectively blocked: saturated jump_count,
    /// maximum intensity, every fee component elevated, every collar
    /// widened. System has seen this, even if a specific ticker hasn't

    #[inline]
    pub fn jump_regime(&self) -> i64 { min(100, self.jump_count * 5) }

    /// Net exposure (signed).
    #[inline]
    pub fn get_net(&self) -> i64 { self.net_exposure }

    /// Total exposure (absolute).
    #[inline]
    pub fn get_total(&self) -> i64 { self.total_exposure }
    /// i128 to avoid overflow on large exposures
    /// Imbalance as bps of total [-10000, 10000].
    ///
    /// +10000 = 100% long bias
    /// -10000 = 100% short bias
    /// 0 = perfectly balanced
    ///
    /// Toward a Balancing Cross-Chain RFQ Venue for Real-World Assets
    ///
    /// imbalance_bps currently operates through stay.rs (synthetic position takers)
    /// The architectural path toward a full RFQ venue covering tokenised equity,
    /// FX, commodities, and rates runs through this field — not yet built...
    ///
    /// Step 1: is already complete: USYC wraps every USDC entering the basket,
    /// giving every USDC a T-bill floor yield. The basket already has rates
    /// exposure embedded in its composition: Morpho vaults on L2 (Base &
    /// Polygon), AAVE on Arbitrum, generate yield while bridging to L1 
    ///
    /// Step 2 — NOT BUILT, and stated that way on purpose. What would need to
    /// exist is a maker network quoting and physically delivering tokenised FX,
    /// equity or commodity positions. No such network is wired here; the flash
    /// gate is venue-agnostic and holds no integration.
    ///
    /// The competitive distinction is composability vs proprietary stack;
    /// Circle's StableFX runs on Arc — Circle's own L1 — with Circle as the
    /// settlement counterparty. QU!D's basket is open: the flash gate is
    /// available to whoever holds `flash_authority`, the constituent issuers'
    /// redemption mechanics are exposed as PMM quotes without requiring a
    /// proprietary chain, and the risk floor is the distributed stablecoin
    /// ecosystem rather than only Circle/Hashnote overnight repo rate...
    ///
    /// The OTC energy derivatives market before ICE had large positions
    /// held overnight with no centralised clearing, no transparent pricing,
    /// and no way to offset exposure without bilateral negotiation.
    ///
    /// ICE brought price transparency, centralised clearing through a CCP,
    /// and standardised funding rates that made hedge costs legible
    /// and comparable across participants.
    ///
    /// What is already built and being utilised:
    ///
    /// The Actuary computes a funding rate — rate_bps() — on open positions
    /// based on pool utilisation (conc), imbalance, vol, leverage, and jump
    /// regime. This rate is published on-chain before any position is opened.
    ///
    /// The core tension in order book design is between commitment credibility
    /// and adverse selection protection. A maker who quotes commits to filling at
    /// that price; if the commitment can be revoked freely — as HFT firms revoke
    /// resting limit orders — the quote is not a commitment but a free option
    /// written against the taker. RFQ removes the cancel game by construction:
    /// the quote answers one taker request, the commitment is point-in-time, and
    /// execution is atomic, so there is no resting order to pull.
    ///
    /// ⚠️ WHAT ATOMIC SETTLEMENT DOES NOT FIX, AND WHY IT MOTIVATES `rate_bps()`:
    /// a maker who wins the auction still carries the move between committing and
    /// block inclusion. That narrows the exposure window to about one block; it
    /// does not close it, and it does nothing at all over multi-day horizons.
    /// This is the residual adverse selection problem that atomic settlement does
    /// not fully eliminate — narrows the window to 1 block time but doen't close it.
    /// The situation becomes considerably more tricky over longer time horizons...
    ///
    /// Institutions seeking RFQ for multi-day tokenised equity unwinds need
    /// a synthetic hedge on Solana prior to commitment. Cost of the hedge is
    /// not bilaterally negotiated — it is a deterministic function of the
    /// pool's current state. That is what ICE standardised for energy: a
    /// published clearing price replacing opaque bilateral negotiation...
    ///
    /// The hedge is useful for cancellations mid-way during the unwind...
    /// in case the market suddenly turns in the opposite direction. With
    /// the hedge, the unwind portion that was completed (rendered a loss)
    /// could recover either partially, or in some cases even in full...
    ///
    /// The utilisation term (conc = exposure / pool) is the key input. As
    /// more sidecar positions open against the pool, conc rises, rate_bps()
    /// rises, and the cost of the next sidecar increases. The pool self-
    /// prices its own capacity. The market mechanism is already encoded
    /// in rate_bps().
    ///
    /// The solvency invariant — max_liability ≤ total_deposits — means the
    /// pool cannot be oversubscribed. An institution opening a sidecar knows
    /// the pool will cover the position because the invariant is enforced
    /// by the contract, not by a CCP's balance sheet.
    ///
    /// ICE's CCP concentrated clearing risk in a single regulated entity
    /// whose failure would be systemic. This pool distributes clearing
    /// across an entire basket, sized by collar_bps() so that even
    /// correlated worst-case scenarios remain within total_deposits.
    ///
    /// Dual recourse is architectural rather than contractual.
    /// QD holders have 2 independent settlement paths: redeem
    /// through the basket on Ethereum, extracting proportional
    /// share of the stablecoin pool, or take profit on Solana
    /// against the leveraged position pool's surplus.
    /// Neither path depends on the other's solvency.
    ///
    /// What still needs to be built for RWA unwinds
    /// across physical delivery sequences:
    ///
    /// (a) a permissionless crank called daily as each physical
    ///     delivery reduces residual exposure, or
    ///     automatically as confirmed deliveries arrive.
    ///
    /// (c) delivery confirmation signal for (b) — how the sidecar
    ///     knows each day's physical delivery completed so it can adjust
    ///     notional.
    ///
    #[inline]
    pub fn imbalance_bps(&self) -> i64 {
        let t = self.get_total();
        if t == 0 { 0 } else {
            ((self.get_net() as i128) * 
          (BPS as i128) / (t as i128)) as i64
        }
    }

    /// Oracle staleness penalty [50, 100].
    ///
    /// Fresh oracle (< 2000 slots): 100% (no penalty)
    /// Stale oracle (> 2000 slots): Decays toward 50%
    ///
    /// Reduces max leverage when oracle is stale to prevent
    /// trading on outdated prices.
    ///
    /// Staleness is also the condition under which the TWAP-based
    /// manipulation detection loses its anchor. A stale oracle combined
    /// with a large synthetic price feed position is the attack surface
    /// that exposure mining through rehypothecated basket dollars would
    /// attempt to exploit — hence the hard gate at 3000 slots in
    /// max_leverage_pct that blocks new positions entirely.
    #[inline]
    pub fn staleness_mult(&self, slot: i64) -> i64 {
        let stale = max(0, slot - self.last_price_slot);
        if stale > 2000 { max(50, 100 - stale / 400) } else { 100 }
    }

    /// Returns Ok(confidence_multiplier) or Err if manipulation detected.
    ///
    /// TWAP deviation check is the protocol's defence against the specific
    /// attack pattern where bonded basket dollars — locked against redemption
    /// but not against movement — are rehypothecated through synthetic price
    /// feeds to create artificial TWAP pressure. The check ensures that any
    /// spot price more than MAX_TWAP_DEVIATION_BPS from the smoothed TWAP
    /// is treated as manipulation rather than genuine price discovery.
    /// The attacker cannot move both spot and TWAP simultaneously because
    /// TWAP accumulates over time: manipulating TWAP requires sustaining
    /// the artificial price for the full window with capital at risk throughout.
    pub fn check_twap_deviation(&self, spot: i64) -> Result<i64> {
        if self.twap_price == 0 || self.obs_count < 5 {
            return Ok(100); // Not enough data
        }
        let deviation_bps = (spot - self.twap_price).abs() * BPS / max(1, self.twap_price);

        if deviation_bps > MAX_TWAP_DEVIATION_BPS {
            return Err(PithyQuip::OracleManipulated.into());
        }
        // Soft penalty: 100 + (deviation/50), capped at 150
        Ok(100 + min(50, deviation_bps / 50) as i64)
    }

    /// Classify a trade by its risk characteristics.
    /// Returns: (is_adding_risk, is_reducing_imbalance)
    ///
    /// This is the KEY insight: two independent dimensions.
    /// 1. Total risk: are we adding new counterparty exposure?
    /// 2. Directional risk: are we moving toward or away from balance?
    ///
    /// The 4 combinations create different fee structures:
    /// - Add + Concentrate: WORST (new risk, wrong direction)
    /// - Add + Hedge: HIGH but lower (new risk, helps balance)
    /// - Reduce + Concentrate: MEDIUM (less risk, hurts balance)
    /// - Reduce + Hedge: BEST (less risk, helps balance)
    ///
    /// The L1 basket is the underwriter holding bonded dollar deposits
    /// locked against redemption for dollars, but not locked against
    /// movement or rehypothecation through synthetic exposure...
    ///
    /// bonded dollars can be borrowed by a flash caller within
    /// a single block, routed through multi-hop sequence,
    /// and repaid from the proceeds of cleared execution.
    /// capitalize on the rhythm at your own frequency...
    ///
    #[inline]
    pub fn classify(&self, exposure: i64, amount: i64) -> (bool, bool) {
        // Adding = opening new OR extending existing in same direction
        let is_adding = exposure == 0 || (exposure > 0 && amount > 0) || (exposure < 0 && amount < 0);

        // Reducing imbalance = moving net toward zero
        let current_net = self.get_net();
        let new_net = current_net + amount;
        let is_reducing_imbalance = new_net.abs() < current_net.abs();

        (is_adding, is_reducing_imbalance)
    }


    /// Update on oracle price change
    /// call ONCE per slot, BEFORE any trades.
    ///
    /// This is the core learning function. It:
    /// 1. Calculates price change (return)
    /// 2. Detects jumps (moves > 3σ)
    /// 3. Updates volatility EMA (fast up, slow down)
    /// 4. Tracks max drawdown
    /// 5. Decays jump count and velocity over time
    ///
    /// The confidence-based vol floor ensures we never assume zero vol
    /// on a new ticker, preventing "quiet start" attacks.
    ///
    /// Bootstrap initialization at first observation sets observed_vol_bps
    /// and max_drawdown_bps from priors rather than zero.
    /// This is the Actuary's cold-start position: maximum fear, prior dominant,
    /// no observations yet. The bootstrap is the protocol's promise
    /// that it will never again be caught with zero observations
    /// and zero floor when the first price move arrives.
    /// Advance the premium integral to `now`, at the rate implied by the
    /// state that has prevailed since it last moved. Call before mutating that
    /// state, so the interval is billed at the rate it actually ran at.
    pub fn accrue_premium_index(&mut self, now: i64, util_bps: i64) {
        if self.index_updated == 0 { self.index_updated = now; return; }
        let dt = (now - self.index_updated).max(0);
        if dt == 0 { return; }
        // The position-independent half of the rate: this ticker's volatility
        // against how full the pool is. What is left — leverage, and distance
        // to the barrier — belongs to a position rather than to the interval,
        // and is applied when the position is charged.
        let base = rate_bps(util_bps, 100, self) as u128;
        self.premium_index = self.premium_index
            .saturating_add(base.saturating_mul(dt as u128));
        self.index_updated = now;
    }

    pub fn update_price(&mut self, price: i64, slot: i64) {
        // First observation: record price and bootstrap vol estimates
        if self.last_price == 0 {
            self.last_price = price;
            self.last_price_slot = slot;
            self.twap_price = price;
            self.last_trade_slot = slot;
            // Bootstrap vol estimates from  priors so that
            // max_leverage_pct doesn't return an unreasonably low cap.
            // Without this, observed_vol stays 0 and eff_sigma returns
            // only the decaying floor, making new positions impossible.
            let floor = self.vol_floor();
            self.observed_vol_bps = floor;
            self.max_drawdown_bps = floor * 2;
            self.obs_count = min(500, self.obs_count + 1);
            self.shortfall_bps = self.expected_shortfall_bps(COLLAR_BREACH_BPS);
            return;
        }
        let old = self.last_price;
        let dt = max(1, slot - self.last_price_slot);
        // In i128: `(price - old).abs() * BPS` overflows i64 as soon as the
        // move is large against a small base — a recovery from near-zero is
        // enough — and this runs on every deposit, withdrawal, liquidation and
        // sweep, so the panic would take the ticker with it.
        // |Δp| / max(p₀, p₁) rather than |Δp| / p₀.
        //
        // The simple return is the wrong measure and the overflow was the
        // symptom. It is unbounded above and bounded below by −100%, so a
        // price recovering from near zero produces an arbitrarily large
        // "move", and a doubling registers twice as violent as the halving
        // that undoes it. Every consumer downstream — the volatility EMAs, the
        // exceedance accumulators, the tail fit — inherited both problems.
        //
        // Dividing by the larger of the two prices fixes both at the source
        // and needs no clamp, because |p₁ − p₀| ≤ max(p₀, p₁) is arithmetic
        // rather than policy: the result cannot leave [0, BPS]. It is
        // symmetric the way a log return is — a doubling and a halving both
        // register 5000bps — and agrees with the simple return to first order
        // for the small moves that dominate, so the calibration beneath it
        // still means what it meant. It is a monotone function of |ln(p₁/p₀)|,
        // so the ordering the tail fit depends on is preserved exactly, with
        // no transcendental to evaluate on chain.
        let change = ((price - old).abs() as i128 * BPS as i128
            / max(1, max(old, price)) as i128) as i64;
        let vol_floor = self.vol_floor();

        // === Qualified observation: only count moves above noise threshold ===
        // An attacker submitting price+0 or price+1 repeatedly accumulates
        // obs_count while keeping observed_vol_bps near zero, eroding the
        // Bayesian prior and structural floor. Require change > floor/4 to
        // qualify — a move too small to affect risk state doesn't count...
        //
        // Upward spikes always qualify regardless of threshold (never suppress
        // jump detection). Threshold = floor/4 chosen so that genuine low-vol
        // instruments (Rates at 5bps true vol) still qualify by obs=60
        //
        // This is also the defence against the exposure mining attack:
        // an actor feeding synthetic price feeds with micro-moves to
        // suppress vol_floor before opening a large leveraged position
        //
        let noise_threshold = max(1, vol_floor / 4);
        let qualifies = change >= noise_threshold;
        if qualifies {
            self.obs_count = min(500, self.obs_count + 1);
        }
        if self.observed_vol_bps == 0 {
            if qualifies {
                self.observed_vol_bps = max(vol_floor, change);
                self.max_drawdown_bps = max(vol_floor * 2, change);
            }
        } else {
            // Jump detection: always active regardless of threshold
            if change > self.observed_vol_bps * 3 {
                self.jump_count = min(20, self.jump_count + 1);
            }
            if change > self.max_drawdown_bps {
                self.max_drawdown_bps = min(5000, change);
            }
            // Vol EMA: only update on qualified moves.
            // Unqualified (near-zero) moves are ignored — they cannot
            // pull vol_ema downward, preventing systematic suppression.
            if qualifies {
                // GJR asymmetry: a downward innovation carries more weight
                // than an upward one of equal size. Glosten–Jagannathan–Runkle
                // model this by adding a term that only switches on for
                // negative shocks; the EMA counterpart is a larger alpha on
                // the downside. Symmetric updating over |change| understates
                // conditional variance in exactly the regime the collar and
                // the hazard exist for.
                let base = max(5, min(100, 1000 / (10 + dt)));
                let down = price < old;
                let alpha = if down { min(100, base * 3 / 2) } else { base };
                let raw_vol = (self.observed_vol_bps * (100 - alpha) + change * alpha) / 100;
                self.observed_vol_bps = max(vol_floor, min(3000, raw_vol));

                // Downside-only EMA, kept beside the two-sided one so the
                // asymmetry is observable rather than just baked in.
                if down {
                    self.downside_vol_bps =
                        (self.downside_vol_bps * (100 - alpha) + change * alpha) / 100;
                }

                // Peaks over threshold: everything above u feeds the GPD fit.
                // Recorded on the qualified path only, so the same noise gate
                // that protects the vol estimate protects the tail estimate.
                let u = self.pot_threshold();
                if change > u {
                    let excess = change - u;
                    self.exceed_count = self.exceed_count.saturating_add(1);
                    self.exceed_sum = self.exceed_sum.saturating_add(excess);
                    self.exceed_sumsq = self.exceed_sumsq
                        .saturating_add((excess as i128) * (excess as i128));
                }
            }
            // Drawdown memory fades with ELAPSED TIME, not with observation
            // count.
            //
            // 🔴 THIS DECAYED ONCE PER CALL, GATED ON `dt > 2000` — so the rate
            // depended on who called `update_price` and how often, which is not
            // a property of the market. Twenty updates spaced 2,000 slots apart
            // decayed ~64%; ONE update after the same 40,000 slots decayed 5%.
            // Same elapsed time, thirteen times the effect.
            // ⇒ An adversary keeping a ticker QUIET (their own sparse deposits
            // are enough — every one calls through here) could accelerate the
            // fade, narrow the collar, and only then take size. Cadence was a
            // free lever on the risk model.
            //
            // Stepping by `dt / 2000` makes decay depend on time rather than on
            // observation count.
            // ⚠️ THE STEP CAP IS 128, AND A SMALLER ONE REINTRODUCES THE BUG IT
            //    WAS MEANT TO BOUND. A first attempt capped at 20 "so a long
            //    silence fades the memory rather than erasing it in one call" —
            //    but the cap binds ONLY on the single-long-gap path. Measured:
            //    sixty updates 2,500 slots apart fell to the floor (400) while
            //    ONE update after the same 150,000 slots stopped at 1,442. The
            //    splitter still won, which is the whole attack.
            //    128 cannot bind before the floor: each step removes 5% (or 10bps
            //    flat, whichever is larger) and `max_drawdown_bps` is clamped to
            //    5000, so the floor is always reached first. The cap is a compute
            //    bound, never a behavioural one — which is the only kind that is
            //    safe here.
            //    Residual: integer truncation of `dt / 2000` makes a split path
            //    decay slightly LESS than a whole one. That direction is
            //    conservative (wider collar), and it is the direction the
            //    security property demands.
            let drawdown_floor = max(vol_floor * 2, self.observed_vol_bps * 2);
            if dt > 2000 && self.max_drawdown_bps > drawdown_floor {
                let steps = min(128, dt / 2000);
                let mut dd = self.max_drawdown_bps;
                for _ in 0..steps {
                    dd = max(drawdown_floor, dd - max(10, dd / 20));
                    if dd <= drawdown_floor { break; }
                }
                self.max_drawdown_bps = dd;
            }
        }
        // The tail estimate has moved, so the shortfall derived from it is
        // stale. This is the one place it is recomputed.
        self.shortfall_bps = self.expected_shortfall_bps(COLLAR_BREACH_BPS);

        // Decay: jumps (1 per 1000 slots), velocity (10 per 500 slots)
        self.jump_count = max(0, self.jump_count - dt / 1000);
        self.velocity = max(0, self.velocity - dt / 500 * 10);

        let twap_alpha = max(5, min(20, 200 / (10 + dt)));
        // Same reason as `change` above: both terms are a price times a
        // percentage, which overflows i64 at prices this arithmetic is
        // otherwise happy to accept.
        self.twap_price = ((self.twap_price as i128 * (100 - twap_alpha) as i128 / 100)
            + (price as i128 * twap_alpha as i128 / 100))
            .min(i64::MAX as i128) as i64;

        self.last_price = price;
        self.last_price_slot = slot;
    }

    /// Record trade activity - updates exposure, velocity, and momentum.
    ///
    /// Call ONCE per trade. State updates immediately (no batching).
    /// Parameters:
    /// - exposure: current position (signed, before this trade)
    /// - amount: trade amount (signed per stay.rs convention)
    /// - lev: leverage × 100
    /// - slot: current slot
    /// - size: trade size in base units
    /// - pool: total pool size for relative sizing
    ///
    /// The velocity field is therefore a real-time signal of the scale
    /// of flash-borrow activity relative to pool depth — a size-weighted
    /// intensity measure that scales correctly across pool sizes.
    /// Record a trade against this ticker's risk state.
    ///
    /// `value_delta` and `size` are DOLLAR quantities, and `net_exposure` /
    /// `total_exposure` are dollar-denominated as a result. They used not to
    /// be: `handle_out` passed the instruction's `amount` (asset units) while
    /// `amortise` passed `delta` (dollars), and both were then multiplied by
    /// leverage — so the book's net was a sum of incompatible quantities, and
    /// every consumer of it (`imbalance_bps`, `crowding_bps`, momentum) read a
    /// number that meant different things depending on which path wrote it.
    ///
    /// The leverage multiplication is gone too. A dollar of exposure is a
    /// dollar of exposure to the pool regardless of how much collateral sits
    /// behind it; multiplying by leverage double-counted it, the same error
    /// the collar carried before the notional fix.
    pub fn record_activity(&mut self, exposure: i64, value_delta: i64,
        slot: i64, size: i64, pool: i64) {
        let (is_adding, _) = self.classify(exposure, value_delta);
        let signed_risk = value_delta;
        let abs_risk = value_delta.abs();
        // Update state directly
        self.net_exposure += signed_risk;
        if is_adding {
            self.total_exposure += abs_risk;
        } else {
            self.total_exposure = max(0, self.total_exposure - abs_risk);
        }
        // === Velocity/Momentum Recording ===
        let dt = max(0, slot - self.last_trade_slot);
        if dt > 0 {
            // Decay existing velocity based on time since last trade
            self.velocity = self.velocity * max(10, 100 - dt * 20) / 100;
        }
        // Add new velocity contribution (local only, not globally)...
        // Minimum size gate: trades < pool/1000 contribute 0 velocity...
        // Wash traders submitting many tiny trades cannot inflate velocity
        // because each contributes nothing. The gate is pool-relative so
        // it scales correctly across pool sizes — not an absolute threshold.
        let min_size_for_vel = max(1, pool / 1000);
        let local = if size < min_size_for_vel {
            0 // below noise floor — no velocity contribution
        } else if pool > 0 {
            min(50, size * 50 / pool)
        } else {
            5
        };
        // Only add to velocity if there's a meaningful contribution.
        // Eliminates the max(3, local) floor that was giving every trade
        // at least 3 velocity units regardless of size.
        if local > 0 {
            self.velocity = min(255, self.velocity + local);
        }
        let oi = self.total_exposure;
        let last_oi = if self.last_trade_slot == 0 { oi } else { oi - abs_risk };
        if last_oi > 0 {
            let delta = (oi - last_oi) * BPS / last_oi;
            let new_momentum = max(-BPS, min(BPS, delta));
            self.momentum_bps = self.momentum_bps * 70 / 100 + new_momentum * 30 / 100;
        }
        self.last_trade_slot = slot;
    }
}

#[account]
#[derive(InitSpace)]
pub struct TickerRisk {
    pub ticker: [u8; 8],
    pub actuary: Actuary,
    pub bump: u8,
    /// Dollars this ticker currently contributes to `Depository::max_liability`.
    /// Stored so the contribution can be replaced rather than recomputed from
    /// per-pod figures — the same discipline that stopped `max_liability`
    /// ratcheting when it was booked on one base and released on another.
    pub reserved: u64,
}

/// Maximum leverage given current conditions.
///
/// Returns: leverage × 100, range [110, 2000] (1.1x to 20x)
///
/// Factors:
/// - **vol** (primary): Higher vol = lower max leverage
/// - **staleness**: Stale oracle = reduced leverage
/// - **jump regime**: Many jumps = reduced leverage
///
/// ## Why 3x Is the Starting Leverage
///
/// In 2022 QuidMint Foundation was 3x long NEAR. The Actuary's cold-start
/// parameters — 150% vol floor, zero confidence, max fear — are calibrated
/// so that a depositor opening the first position on a new ticker faces the
/// similar conditions, but with a full risk model present for self-adjustment.
///
/// Higher leverage = more output potential but higher collar cost and
/// higher fee. The protocol's fee structure is designed so that the gross
/// on-chain product net of fees is maximised at moderate leverage —
/// the incentive-compatible equilibrium where depositors earn the most
/// by taking on neither too little nor too much risk.
pub fn max_leverage_pct(s: &Actuary,
    slot: i64, util: i64) -> i64 {
    let class_max = MAX_LEVERAGE_PCT;
    let floor = STARTING_FLOOR_BPS;
    let sig = s.eff_sigma();
    // Hard gate: reject ALL new leverage when oracle is critically stale.
    // This is also the gate that blocks exposure mining through stale
    // synthetic price feeds: an actor who has manipulated a price feed
    // to show artificial calm cannot open new leveraged positions once
    // the real oracle goes stale. The attack requires a live, accurate
    // oracle — which the manipulation itself makes unavailable.
    let staleness = max(0,
    slot - s.last_price_slot);
    if staleness > 3000 {
        return 110; // minimum: effectively blocks new positions
    }
    let k = class_max * (BPS + 8 * floor) / BPS;
    let base = k * BPS / (BPS + 8 * sig);
    // Additive penalties (not multiplicative — avoids triple-stack punishment)
    let stale_penalty = max(0, (100 - s.staleness_mult(slot)) * base / 200);
    let conf_penalty = base * (100 - s.confidence()) / 300;
    let util_penalty = if util > 7500 {
        base * (util - 7500) / 10000
    } else { 0 };

    let result = base - stale_penalty - conf_penalty - util_penalty;
    max(110, min(class_max, result))
}

/// Liquidation collar: how far price can move before liquidation.
///
/// Returns: collar in bps, range [σ, MAX_COLLAR_BPS]
///
/// Factors:
/// - **vol**: Higher vol = wider collar (more room)
/// - **eta**: Expected jump size affects gap risk component
/// - **drawdown**: Recent large moves widen buffer
/// - **leverage**: Higher leverage = tighter collar (less room)
///
/// CVaR scales in proportion to observed tail thickness (drawdown/sigma ratio).
///
/// tail_ratio = max_drawdown / sigma. In the founding event, this ratio
/// was extreme — the drawdown far exceeded any sigma estimate from the
/// preceding period. The CVaR multiplier (350–500) encodes the
/// structural response: even in a calm period, assume the tail is fatter
/// than sigma alone suggests, because sigma alone suggested calm in 2022
/// right up until it wasn't.
///
pub fn collar_bps(lev: i64, s: &Actuary) -> i64 {
    let sig = s.eff_sigma();
    if sig == 0 { return STARTING_FLOOR_BPS; }

    // The band is the expected shortfall of the fitted tail at the target
    // breach rate, divided by leverage.
    //
    // It used to be `sig × cvar_k / lev` with
    //     cvar_k = min(500, max(350, 200 + tail_ratio/50))
    // — an invented map from observed-drawdown-over-sigma onto a 3.5σ–5σ
    // multiplier, plus a separate hand-built jump buffer. Both were standing in
    // for the shape of the tail, which is now estimated: ES at COLLAR_BREACH_BPS
    // already contains the fat-tail and the jump contribution, because the GPD
    // was fitted to the moves that produced them.
    // Cached at the last price update; recomputed here only for an Actuary
    // that has never seen one (a fresh ticker, or a unit test).
    let es = if s.shortfall_bps > 0 { s.shortfall_bps }
             else { s.expected_shortfall_bps(COLLAR_BREACH_BPS) };

    // Per unit of exposure the pool holds; a position's own leverage governs
    // how much of its collateral that band consumes.
    let base = if lev > 0 { es * 100 / lev } else { es };
    max(sig, min(MAX_COLLAR_BPS, base))
}


/// Compound factor: 2D risk matrix scoring.
///
/// Returns: multiplier in range [70, 300] (0.7x to 3x)
///
/// This is the "hidden gem" of the fee model. Trades are scored on
/// TWO independent dimensions, creating a 4-way matrix:
///
/// | Add + Concentrate    | WORST  | 100-300 | New risk, wrong direction      |
/// | Add + Hedge          | HIGH   | 100-200 | New risk, but helps balance    |
/// | Reduce + Concentrate | MEDIUM | 100-150 | Less risk, but hurts balance   |
/// | Reduce + Hedge       | BEST   | 70-100  | Less risk, helps balance       |
///
/// The middle two can swap order based on conditions!
/// When imbalance is severe and jump risk high, add+hedge CAN be
/// cheaper than reduce+concentrate because rebalancing is urgent.
///
/// The compound_factor is the protocol's mechanism for ensuring that
/// gross on-chain product — the aggregate output of the basket's
/// productive capital deployment — flows to depositors rather than
/// being extracted by traders who concentrate risk at the pool's
/// expense. The BEST quadrant (reduce + hedge) receives a discount
///
#[inline]
fn compound_factor(exposure: i64,
    amount: i64, lev: i64, s: &Actuary) -> i64 {
    let (is_adding, is_hedging) = s.classify(exposure, amount);
    let lev_excess = max(0, lev - LEV_THRESHOLD);
    let imb_mag = min(BPS, s.imbalance_bps().abs());
    let jump = s.jump_regime();
    match (is_adding, is_hedging) {
        (true, false) => {
            // WORST: adding risk + concentrating imbalance
            let penalty = lev_excess * imb_mag / (BPS * 15) + lev_excess * jump / 400;
            min(300, 100 + max(10, penalty))
        }
        (true, true) => {
            // Add risk but hedge imbalance - moderate penalty
            // This CAN be cheaper than reduce+concentrate when imbalance is severe!
            let penalty = lev_excess * imb_mag / (BPS * 30) + lev_excess * jump / 600;
            min(200, 100 + max(3, penalty))
        }
        (false, false) => {
            // Reduce risk but concentrate imbalance - small penalty
            let penalty = lev_excess * imb_mag / (BPS * 40);
            min(150, 100 + penalty)
        }
        (false, true) => {
            // BEST: reduce risk + hedge imbalance - can get discount
            // This is the fee structure's expression of gross on-chain product:
            // trades that reduce total counterparty exposure AND hedge directional
            // imbalance receive the maximum discount because they are doing the
            // work that dollar depositor bonds were designed to enable —
            // stabilising the conditions under which every constituent issuer
            // can deploy more aggressively and generate more output.
            let discount = lev_excess * imb_mag / (BPS * 50);
            max(70, 100 - discount)
        }
    }
}

/// Trade fee calculation.
///
/// Returns: fee in bps, range [4, 200] (0.04% to 2%)
///
/// ## Factors (all verified present)
///
/// - **conc** (cp): Concentration penalty - piecewise quadratic
/// - **imb** (ip): Imbalance penalty - quadratic
/// - **vol**: Via risk_mult
/// - **lev**: Via risk_mult and compound_factor
/// - **direction**: Via classify() in compound_factor and risk_mult
/// - **velocity** (vp): Trade urgency - quadratic
/// - **momentum** (mp): Cascade risk via momentum_mult()
/// - **compound** (cf): 2D risk matrix
/// - **jump_premium**: Discrete gap risk
/// Call at BOTH entry AND exit with current state!
///
/// When momentum_bps < 0 — when open interest is collapsing, positions are
/// being closed faster than they are being opened, the cascade signature
/// is present — the fee structure inverts: adding risk becomes expensive
/// (up to 2.5x normal fee), reducing risk becomes cheap (down to 0.7x).
///
/// This is the protocol pricing the exit race the same way a central
/// bank's lender-of-last-resort facility prices it: penalise pile-on,
/// reward the stabiliser. The difference is that no human decides...
/// the Actuary observes momentum_bps, fee model responds continuously
///
/// Entry charge. Execution costs (spread, impact, adverse selection, hedging)
/// plus a PREPAYMENT of the same hazard the carry charges — `distance_bps` is
/// the position's barrier distance, identical to the input `hazard_rate_bps`
/// takes. One model, two horizons: opening prepays MIN_HOLD_SECS of gap risk
/// so a position that jumps before its first accrual tick is not free, and
/// every tick after that is billed by the carry. The old parallel `gap_bps`
/// here computed the same economics from `eff_eta` with different constants,
/// which is how the two could disagree.
pub fn fee_bps(conc: i64, exposure: i64,
    amount: i64, s: &Actuary, lev: i64, distance_bps: i64) -> i64 {
    let sig = s.eff_sigma();

    if sig == 0 { return MIN_FEE_BPS; }
    let trade_size = (amount.abs() as i128 * lev as i128 / 100) as i64;
    if trade_size == 0 { return MIN_FEE_BPS; }

    // === Component 1: Adverse selection spread ===
    // LP faces informed traders. Cost ∝ vol × sqrt(trade_fraction) × info_signal
    let pool_frac = min(BPS, trade_size * BPS / max(1, s.get_total() + trade_size));
    let sqrt_frac = {
        let mut x = pool_frac;
        let mut y = (x + 1) / 2;
        while y < x { x = y; y = (x + pool_frac / max(1, x)) / 2; }
        x
    };
    let impact_mult = 100 + sqrt_frac * 50 / 100;
    let imb_abs = s.imbalance_bps().abs();
    let info_mult = 100 + imb_abs * imb_abs / (BPS * 50);
    let spread_bps = sig * impact_mult * info_mult / (10000 * 150);
    // === Component 1b: Direct leverage hedging cost ===
    // LP delta-hedging a levered position faces rebalancing cost ∝ σ·lev.
    let (is_adding_risk, _) = s.classify(exposure, amount);
    // Hedging cost scales with how soon the ladder will have to act: a position
    // opened against its barrier will be unwound in days, one deep inside may
    // never be touched. `hazard_bps` is the shared intensity the carry uses, so
    // the entry fee inherits moneyness from the same model rather than from a
    // second one with its own constants. This is the material entry-side
    // signal — the literal prepayment below is exact but tiny, which is the
    // argument for gap risk being a carry cost in the first place.
    let intensity = hazard_bps(distance_bps, s);
    let lev_fee = if is_adding_risk {
        (sig * lev / max(1, MAX_LEVERAGE_PCT * 10))
            .saturating_mul(BPS + intensity) / BPS
    } else {
        0
    };
    // === Component 2: utilisation base charge (direction-neutral) ===
    // Linear only. The quadratic used to live here AND in rate_bps AND, in
    // risk-weighted form, in solvency_bps — the same "pool is filling up"
    // signal charged three times. Solvency owns the convexity now, because it
    // measures actual collar dollars rather than raw drawn notional.
    let conc_bps = max(2, conc / 300);
    // === Component 3: gap premium — prepaid from the shared hazard ===
    let collar = collar_bps(lev, s);
    let gap_bps = (intensity as i128 * lgd_bps(collar, s) as i128
        * MIN_HOLD_SECS as i128 / (BPS as i128 * SECONDS_PER_YEAR as i128)) as i64;

    // === Component 4: Velocity premium ===
    let vel_bps = s.velocity * s.velocity / 1000;
    // === Aggregate, then apply 2D risk multiplier and momentum ===
    let base = spread_bps + lev_fee + conc_bps + gap_bps + vel_bps;
    let cf = compound_factor(exposure, amount, lev, s);
    // Direction-gated momentum multiplier — the shadow banking defence.
    // During a cascade (momentum_bps < 0):
    // Adding trades: emergency premium (100 → 250)
    // Reducing+hedging trades: stability discount (100 → 70)
    let mom_mult = if s.momentum_bps < 0 {
        let cascade_intensity = s.momentum_bps.saturating_neg();
        if is_adding_risk {
            100 + min(150, cascade_intensity / 15)
        } else {
            max(70, 100 - min(30, cascade_intensity / 333))
        }
    } else { 100 };
    let total = base * cf / 100 * mom_mult / 100;

    // Dynamic fee cap: scales with vol × leverage.
    // In extreme vol the ceiling rises, preventing the exploit where
    // an informed trader enters at a capped fee that understates true risk —
    // the same information asymmetry that makes shadow banking runs possible.
    let dynamic_cap = max(200, sig * lev / max(1,
                            MAX_LEVERAGE_PCT));

    max(MIN_FEE_BPS, min(dynamic_cap, total))
}

/// Funding rate calculation.
///
/// Returns: rate in bps, range [0, 50000] (0% to 500%)
///
/// ## Factors (all verified present)
///
/// - **conc**: Quadratic base rate
/// - **imb**: Imbalance adjustment
/// - **vol**: Volatility adjustment
/// - **lev**: Leverage adjustment
/// - **jump**: Jump regime adjustment
///
/// This rate is charged continuously on open positions.
/// Higher concentration, imbalance, vol, leverage, or jump activity
/// all increase the funding rate to compensate liquidity providers.
///
// =============================================================================
// HAZARD PRICING — the premium for delay, charged per unit time
// =============================================================================
//
// What the pool sells a position is TIME IN BREACH. `repo()` will not touch a
// position until `LIQ_GRACE_SECS` has elapsed, and then unwinds it at most
// MAX_TRANCHE_BPS per call — so the pool has written a Parisian knock-out: the
// collar is the barrier, the grace period is the window, and the ladder is a
// gradual (tranched) knock-out rather than an instant one.
//
// A per-unit-time good has a per-unit-time price, so the premium is a HAZARD
// RATE, not an option premium converted to one. That removes the artefact in
// the C++ this replaces, which prices a T=1 European put and then charges it as
// an annualised rate: a position closed in a day pays a slice of a year's
// premium for optionality it never received, and needs Min/MaxTesPrice clamps
// to hide the mismatch. A hazard has units of 1/time natively; `repo()` already
// integrates it correctly as `exposure × rate × dt / year`.
//
// Under pure diffusion a ladder always outruns the barrier, so the residual
// risk is entirely the GAP — price jumping through the collar faster than the
// unwind. That is why the intensity below is a sum of two terms and why the
// jump term carries real weight: it is the part Black-Scholes cannot see, and
// the part the Actuary already measures.

/// Instantaneous intensity of breaching the barrier, in bps.
///
/// Two changes from what stood here. The diffusion term was a Gaussian upper
/// tail read off an eleven-entry table, and the jump term was a separate
/// hand-built addend that existed because the Gaussian could not see fat tails.
/// Both are now one number: the survival function of the GPD fitted to this
/// ticker's own exceedances, which prices the fat tail because it was estimated
/// from it.
///
/// The reflection factor stays: the chance of *touching* a barrier within a
/// horizon is about twice the chance of ending beyond it, and it is touching
/// that starts the ladder.
pub fn hazard_bps(distance_bps: i64, s: &Actuary) -> i64 {
    min(BPS, 2 * s.tail_prob_bps(max(0, distance_bps)))
}

/// Loss given breach, in bps of exposure.
///
/// The GPD mean excess at the barrier — E[move − d | move > d] — less what the
/// ladder unwinds while the position is being worked off. This replaces
/// `max(0, max_drawdown − collar)`, which used a single historical extreme as
/// though it were an expectation.
pub fn lgd_bps(collar: i64, s: &Actuary) -> i64 {
    let overshoot = s.mean_excess_bps(collar);
    let residual = BPS - min(BPS, MAX_TRANCHE_BPS);   // still exposed per window
    max(1, overshoot * residual / BPS)
}

/// Crowding multiplier in bps of 10_000 (10_000 = neutral).
///
/// A position that leans the same way as the book makes the pool's unwind
/// harder — the same squeeze risk the C++ prices via `lentpct` scarcity, but
/// measured from our own book instead of a whitelist parameter, and directional,
/// so it can tell a crowded short from a crowded long. Offsetting flow is
/// genuinely cheaper for the pool to carry and is charged accordingly.
pub fn crowding_bps(s: &Actuary, amount: i64) -> i64 {
    let net = s.get_net();
    let total = s.get_total();
    if total <= 0 || amount == 0 { return BPS; }
    let lean = (net.abs() * BPS / total).min(BPS);      // 0 = balanced book
    let same_side = (net > 0 && amount > 0) || (net < 0 && amount < 0);
    if same_side { BPS + lean / 2 } else { max(BPS / 2, BPS - lean / 2) }
}

/// Solvency multiplier in bps of 10_000. Replaces a binary capacity gate with
/// a curve that leans against risk *before* the gate is reached: as reserves
/// approach the requirement the whole rate curve lifts.
pub fn solvency_bps(total_deposits: u64, max_liability: u64) -> i64 {
    if total_deposits == 0 { return 4 * BPS; }
    let coverage = (max_liability as u128 * BPS as u128
                    / total_deposits as u128).min(4 * BPS as u128) as i64;
    // coverage 0 → 1.0×, coverage 100% → 2.0×, beyond → up to 4.0×
    BPS + coverage
}

/// What the pool must reserve against one ticker, in dollars.
///
/// The pool is short the NET of its book on that ticker, not the gross: Alice
/// long 100 and Bob short 100 leaves the pool flat, however much collateral
/// sits behind either position. Reserving against the gross — which is what
/// summing each pod's collar does — over-reserves by the entire offset.
///
/// Netting within a ticker needs no correlation input at all: it is the same
/// asset, so the offset is exact rather than modelled. Across tickers we stay
/// deliberately additive, because a published correlation matrix lags regime
/// change and converges to 1 in exactly the crises the reserve exists for.
///
/// The collar here is taken at 1× because the POOL is not levered — a
/// position's own leverage governs when its band is breached, which is a
/// different question from how much the pool must hold against it.
pub fn ticker_reserve_dollars(net_value: u64, s: &Actuary) -> u64 {
    let collar = collar_bps(100, s).max(0) as u64;
    ((net_value as u128).saturating_mul(collar as u128) / BPS as u128)
        .min(u64::MAX as u128) as u64
}

/// The premium: intensity × loss-given-breach, scaled by crowding and solvency.
/// Signed `amount` selects the direction; the formula is otherwise identical
/// for longs and shorts, because the barrier is symmetric by construction.
pub fn hazard_rate_bps(distance_bps: i64, collar: i64, amount: i64,
    s: &Actuary, total_deposits: u64, max_liability: u64) -> i64 {
    let intensity = hazard_bps(distance_bps, s) as i128;
    let lgd = lgd_bps(collar, s) as i128;
    let crowd = crowding_bps(s, amount) as i128;
    let solv = solvency_bps(total_deposits, max_liability) as i128;
    // One division at the end, in i128. Chaining `× / BPS` per factor truncated
    // a thin loss-given-breach to zero before the scalings could apply, so a
    // position hugging its barrier priced identically to one far inside it —
    // the exact sensitivity this function exists to provide.
    let scaled = intensity * lgd * crowd * solv
        / (BPS as i128 * BPS as i128 * BPS as i128);
    scaled.clamp(0, 50_000) as i64
}

/// `util` is drawn/deposits in bps — utilisation, not portfolio concentration.
/// It was called `conc`, which implied a crowding measure this codebase does
/// not compute; the closest real signal is `Actuary::imbalance_bps`.
pub fn rate_bps(util: i64,
    lev: i64, s: &Actuary) -> i64 {
    let sig = s.eff_sigma();

    // Liquidity only. The quadratic risk-convexity term that used to live here
    // is now `solvency_bps`, which measures the same "pool is filling up"
    // signal but risk-weighted (max_liability, i.e. actual collar dollars)
    // rather than by raw drawn notional. Keeping both charged it twice.
    let base = sig * util / max(1, BPS * BPS / 4000);

    // Imbalance is priced twice already — `fee_bps`'s info_mult at entry
    // (adverse selection) and `hazard_rate_bps`'s crowding term continuously
    // (squeeze risk, and directional where this was not). Carry is liquidity.
    let lev_norm = lev * 100 / max(1, MAX_LEVERAGE_PCT);
    let lev_adj = if lev_norm > 50 { base * (lev_norm - 50) / 200 } else { 0 };

    max(MIN_FEE_BPS, min(50000, base + lev_adj))
}

/// Price + confidence multiplier, refusing anything older than `max_age`.
/// The bound is a parameter because "stale" means two different things here:
/// a broken feed, and a market that has simply closed.
fn fetch_price_inner(ticker: &str,
    account_info: Option<&AccountInfo>, max_age: i64) -> Result<(u64, i64)> {
    let hex = get_hex(ticker).ok_or(PithyQuip::UnknownSymbol)?;
    let account = account_info.ok_or(PithyQuip::NoPrice)?;
    let data = account.try_borrow_data()?;
    if data.len() < 101 {
        return Err(PithyQuip::NoPrice.into());
    }
    let feed_offset = 41;
    let feed_id = &data[feed_offset..feed_offset + 32];
    let expected_hex = hex.strip_prefix("0x").unwrap_or(hex);

    let mut expected_bytes = [0u8; 32];
    for (i, chunk) in expected_hex.as_bytes().chunks(2).enumerate() {
        if i >= 32 { break; }
        let hex_str = std::str::from_utf8(chunk).map_err(|_| PithyQuip::UnknownSymbol)?;
        expected_bytes[i] = u8::from_str_radix(hex_str, 16).map_err(|_| PithyQuip::UnknownSymbol)?;
    }
    if feed_id != &expected_bytes {
        return Err(PithyQuip::NoPrice.into());
    }
    let price_offset = 73;
    let price = i64::from_le_bytes(data[price_offset..price_offset + 8].try_into().unwrap());

    let conf_offset = 81;
    let confidence = u64::from_le_bytes(data[conf_offset..conf_offset + 8].try_into().unwrap());

    let exp_offset = 89;
    let exponent = i32::from_le_bytes(data[exp_offset..exp_offset + 4].try_into().unwrap());

    let time_offset = 93;
    let publish_time = i64::from_le_bytes(data[time_offset..time_offset + 8].try_into().unwrap());

    let clock = Clock::get()?;
    let age = clock.unix_timestamp - publish_time;
    if age.abs() > max_age {
        msg!("Price stale: {} seconds old", age);
        return Err(PithyQuip::NoPrice.into());
    }
    let price_abs = price.unsigned_abs();
    let conf_ratio_bps = if price_abs > 0 {
        (confidence * BPS as u64) / price_abs
    } else {
        MAX_CONFIDENCE_BPS + 1
    };
    if conf_ratio_bps > MAX_CONFIDENCE_BPS {
        msg!("Price confidence too wide: {} bps", conf_ratio_bps);
        return Err(PithyQuip::PriceUncertain.into());
    }
    let conf_mult = 100 + min(100, (conf_ratio_bps * 100 / MAX_CONFIDENCE_BPS) as i64);
    let adjusted_price = (price as f64) * 10f64.powi(exponent);
    Ok((adjusted_price as u64, conf_mult))
}

pub fn fetch_price_with_confidence(ticker: &str,
    account_info: Option<&AccountInfo>) -> Result<(u64, i64)> {
    fetch_price_inner(ticker, account_info, MAX_PRICE_AGE)
}

pub fn fetch_price(ticker: &str,
    account_info: Option<&AccountInfo>) -> Result<u64> {
    // For collateral valuation only — renege(), fetch_multiple_prices().
    // These paths price existing pledged assets where oracle confidence
    // doesn't gate leverage; we just need the price itself.
    //
    // For new exposure (handle_out / amortise in clutch.rs), call
    // fetch_price_with_confidence directly: conf_mult ∈ [100, 200] is
    // passed to repo() to penalise leverage when the oracle spread is wide.
    let (price, _) = fetch_price_with_confidence(ticker, account_info)?;
    Ok(price)
}

pub fn fetch_multiple_prices(positions: &[Stock],
    remaining_accounts: &[AccountInfo]) -> Result<Vec<u64>> {
    let mut prices = Vec::new();
    for pod in positions {
        let ticker = std::str::from_utf8(&pod.ticker)
            .map_err(|_| PithyQuip::UnknownSymbol)?
            .trim_end_matches('\0');
        let key = get_account(ticker).ok_or(
                   PithyQuip::UnknownSymbol)?;

        let pubkey = Pubkey::from_str(key).map_err(
                      |_| PithyQuip::UnknownSymbol)?;

        let acct_info = remaining_accounts
            .iter().find(|a| a.key == &pubkey)
            .ok_or(PithyQuip::Tickers)?;

        prices.push(fetch_price(ticker,
                    Some(acct_info))?);
    } Ok(prices)
}


pub fn get_hex(ticker: &str) -> Option<&'static str> {
    if ticker == "SOL" {
        return Some("0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d");
    }
    // Ordered by expected frequency
    US_EQUITIES_HEX_MAP.get(ticker)
        .or_else(|| COMMODITIES_HEX_MAP.get(ticker))
        .or_else(|| METALS_HEX_MAP.get(ticker))
        .or_else(|| RATES_HEX_MAP.get(ticker))
        .or_else(|| FX_USD_HEX_MAP.get(ticker))
        .copied()
}

pub fn get_account(ticker: &str) -> Option<&'static str> {
    if ticker == "SOL" {
        return Some("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE");
    }
    US_EQUITIES_ACCOUNT_MAP.get(ticker)
        .or_else(|| COMMODITIES_ACCOUNT_MAP.get(ticker))
        .or_else(|| METALS_ACCOUNT_MAP.get(ticker))
        .or_else(|| RATES_ACCOUNT_MAP.get(ticker))
        .or_else(|| FX_USD_ACCOUNT_MAP.get(ticker))
        .copied()
}

/// Backed Finance xStocks on Solana — the tokenised share of each underlying,
/// keyed by the ticker this program already trades.
///
/// This is the delivery set. Everything else in the ticker table is priced and
/// tradeable but has no token on this chain, so the pool's net exposure to it
/// can only ever be carried, never handed over. Netting against a real share
/// is possible exactly here.
///
/// Hardcoded for the same reason `USD_STAR` and `LZ_ENDPOINT_PROGRAM` are:
/// delivering against a wrong mint is delivering something worthless, and the
/// name "AAPLx" is not scarce — a token-list lookup returns several, only one
/// of which is Backed's. Every address below was resolved from Jupiter's token
/// service and confirmed live on mainnet; all 80 are Token-2022 mints, which
/// is why the program's token handling has to stay interface-generic rather
/// than assuming the legacy SPL program.
pub static XSTOCK_MINTS: phf::Map<&'static str, &'static str> = phf_map! {
    "AAPL" => "XsbEhLAtcf6HdfpFZ5xEMdqW8nfAvcsP5bdudRLJzJp",
    "ABBV" => "XswbinNKyPmzTa5CskMbCPvMW6G5CMnZXZEeQSSQoie",
    "ABT" => "XsHtf5RpxsQ7jeJ9ivNewouZKJHbPxhPoEy6yYvULr7",
    "ACN" => "Xs5UJzmCRQ8DWZjskExdSQDnbE6iLkRu2jjrRAB1JSU",
    "AMAT" => "XsQZdaWUAGC4R3fgD2N1fupKvJfJq6YM51ccnsLUWFA",
    "AMD" => "XsXcJ6GZ9kVnjqGsjBnktRcuwMBmvKWh8S93RefZ1rF",
    "AMZN" => "Xs3eBt7uRfJX8QUs4suhyU8p2M6DoUDrJyWBa8LLZsg",
    "ANET" => "XsrsM2RgtYxXqxmy4iWgxQJUkkHG1U5wzi74sVNUW8m",
    "APP" => "XsPdAVBi8Zc1xvv53k4JcMrQaEDTgkGqKYeh7AYgPHV",
    "ASML" => "XshuHQ6o6SVpUNawvnnTMxsZ4tacZsNgVCLorv7TkFq",
    "AVGO" => "XsgSaSvNSqLTtFuyWPBhK9196Xb9Bbdyjj4fH3cPJGo",
    "AZN" => "Xs3ZFkPYT2BN7qBMqf1j1bfTeTm1rFzEFSsQ1z3wAKU",
    "BAC" => "XswsQk4duEQmCbGzfqUUWYmi7pV7xpJ9eEmLHXCaEQP",
    "BALL" => "Xsy9RdWC26fp8c84BB2SD4eE74vG1478YKjxAwjRRQY",
    "BMNR" => "XsrBCwaH8c46xiqXBChzobgufRKxQxAWUWbndgBNzFn",
    "BTBT" => "XsPLBFy59Q3hY59KLAJur8QyvziMF4xUxGTxXqXE7cT",
    "CEG" => "Xssu2cDLdZXZYrq17frTVrb3meumRCAzEf7pXyxoWVN",
    "CMCSA" => "XsvKCaNsxg2GN8jjUmq71qukMJr7Q1c5R2Mk9P8kcS8",
    "COIN" => "Xs7ZdzSHLU9ftNJsii5fCeJhoRWSC32SQGzGQtePxNu",
    "CRCL" => "XsueG8BtpquVJX9LVLLEGuViXUungE6WmK5YZ3p3bd1",
    "CRWD" => "Xs7xXqkcK7K8urEqGg52SECi79dRp2cEKKuYjUePYDw",
    "CSCO" => "Xsr3pdLQyXvDJBFgpR5nexCEZwXvigb8wbPYp4YoNFf",
    "CVX" => "XsNNMt7WTNA2sV3jrb1NNfNgapxRF5i4i6GcnTRRHts",
    "DFDV" => "Xs2yquAgsHByNzx68WJC55WHjHBvG9JsMB7CWjTLyPy",
    "GLD" => "Xsv9hRk1z5ystj9MhnA7Lq4vjSsLwzL2nxrwmwtD3re",
    "GME" => "Xsf9mBktVB9BSU5kf4nHxPq5hCBJ2j2ui3ecFGxPRGc",
    "GOOGL" => "XsCPL9dNWBMvFtTmwcCA5v3xWPSMEBCszbQdiLLq6aN",
    "GS" => "XsgaUyp4jd1fNBCxgtTKkW64xnnhQcvgaxzsbAq5ZD1",
    "HD" => "XszjVtyhowGjSC5odCqBpW1CtXXwXjYokymrk7fGKD3",
    "HON" => "XsRbLZthfABAPAfumWNEJhPyiKDW6TvDVeAeW7oKqA2",
    "HOOD" => "XsvNBAYkrDRNhA7wPHQfX3ZUXZyZLdnCQDfHZ56bzpg",
    "IBM" => "XspwhyYPdWVM8XBHZnpS9hgyag9MKjLRyE3tVfmCbSr",
    "IJR" => "XsyZcb97BzETAqi9BoP2C9D196MiMNBisGMVNje2Thz",
    "INTC" => "XshPgPdXFRWB8tP1j82rebb2Q9rPgGX37RuqzohmArM",
    "IWM" => "XsbELVbLGBkn7xfMfyYuUipKGt1iRUc2B7pYRvFTFu3",
    "JNJ" => "XsGVi5eo1Dh2zUpic4qACcjuWGjNv8GCt3dm5XcX6Dn",
    "JPM" => "XsMAqkcKsUewDrzVkait4e5u4y8REgtyS7jWgCpLV2C",
    "KLAC" => "Xsw2uU1i8tHjbgstUbtt3m6kg7BS7AgG5aj8z7ddmmN",
    "KO" => "XsaBXg8dU5cPM6ehmVctMkVqoiRG2ZjMo1cyBJ3AykQ",
    "LIN" => "XsSr8anD1hkvNMu8XQiVcmiaTP7XGvYu7Q58LdmtE8Z",
    "LLY" => "Xsnuv4omNoHozR6EEW5mXkw8Nrny5rB3jVfLqi6gKMH",
    "MA" => "XsApJFV9MAktqnAc6jqzsHVujxkGm9xcSUffaBoYLKC",
    "MCD" => "XsqE9cRRpzxcGKDXj1BJ7Xmg4GRhZoyY1KpmGSxAWT2",
    "MDT" => "XsDgw22qRLTv5Uwuzn6T63cW69exG41T6gwQhEK22u2",
    "META" => "Xsa62P5mvPszXL1krVUnU5ar38bBSVcWAB6fmPCo5Zu",
    "MRK" => "XsnQnU7AdbRZYe2akqqpibDdXjkieGFfSkbkjX1Sd1X",
    "MRVL" => "XsuxRGDzbLjnJ72v74b7p9VY6N66uYgTCyfwwRjVCJA",
    "MSFT" => "XspzcW1PRtgf6Wj92HCiZdjzKCyFekVD8P5Ueh3dRMX",
    "MSTR" => "XsP7xzNPvEHS1m6qfanPUGjNmdnmsLKEoNAnHjdxxyZ",
    "MU" => "XsQLZycSZ7QnBBdBXQaTbQdiUcbRqjNJgyBGAMzhHav",
    "NFLX" => "XsEH7wWfJJu2ZT3UCFeVfALnVA6CP5ur7Ee11KmzVpL",
    "NVDA" => "Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh",
    "NVO" => "XsfAzPzYrYjd4Dpa9BU3cusBsvWfVB9gBcyGC87S57n",
    "ORCL" => "XsjFwUPiLofddX5cWFHW35GCbXcSu1BCUGfxoQAQjeL",
    "PEP" => "Xsv99frTRUeornyvCfvhnDesQDWuvns1M852Pez91vF",
    "PFE" => "XsAtbqkAP1HJxy7hFDeq7ok6yM43DQ9mQ1Rh861X8rw",
    "PG" => "XsYdjDjNUygZ7yGKfQaB6TxLh2gC6RRjzLtLAGJrhzV",
    "PLTR" => "XsoBhf2ufR8fTyNSjqfU71DYGaE6Z3SUGAidpzriAA4",
    "PM" => "Xsba6tUnSjDae2VcopDB6FGGDaxRrewFCDa5hKn5vT3",
    "QQQ" => "Xs8S1uUs1zvS2p7iwtsG3b6fkhpvmwz4GYU3gWAmWHZ",
    "RBLX" => "Xss5RAku5EH6UViFdvW7ss9xQjwQLsrs2opPMhb3k43",
    "RIOT" => "Xs31mE5EiqjSHEaiX9QDKCN6NvSGCqpJ6f1FNq2wri5",
    "SBET" => "XsEoih2x6nZuUjFwzGoba6MFmtzCkzW2c4YAm6baQbq",
    "SGOV" => "XsYD72ntjj7ZwoFDZCDmN2gamTcLpnywqvG7PQN5vCN",
    "SNDK" => "Xswbpc8UqU6e1j9QZEWCjBMjyvz4twqD7PCy6j2e7jj",
    "SPY" => "XsoCS1TfEyfFhfvj8EtZ528L3CaKBDBRqRapnBbDF2W",
    "STRC" => "Xs78JED6PFZxWc2wCEPspZW9kL3Se5J7L5TChKgsidH",
    "TMO" => "Xs8drBWy3Sd5QY3aifG9kt9KFs2K3PGZmx7jWrsrk57",
    "TQQQ" => "XsjQP3iMAaQ3kQScQKthQpx9ALRbjKAjQtHg6TFomoc",
    "TSLA" => "XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB",
    "TSM" => "XsafvsGtzFqqHgTnA3aPC83EAMkacU5mcGtcSayhpVV",
    "UBER" => "XsAsZLF4MmsvS1sDxRMrUz7REjHfwbC9UAMXSRBqgEB",
    "UNH" => "XszvaiXGPwvk2nwb3o9C1CX4K6zH8sez11E6uyup6fe",
    "V" => "XsqgsbXwWogGJsNcVZ3TyVouy2MbTkfCFhCGGGcQZ2p",
    "VT" => "XsEdDDTcVGJU6nvdRdVnj53eKTrsCkvtrVfXGmUK68V",
    "VTI" => "XsssYEQjzxBCFgvYFFNuhJFBeHNdLWYeUSP8F45cDr9",
    "VUG" => "XsNVBwVGqtDqmA2Waoiux5mfykH8nepLK74z3ZoQWK2",
    "WMT" => "Xs151QeqTCiuKtinzfRATnUESM2xTU6V9Wy8Vy538ci",
    "XLE" => "Xs54CrhmpVp6uxZXwgSTegrRH2kShh88XFPzgf4BExu",
    "XOM" => "XsaHND8sHyfMfsWPj6kSdd5VwvCayZvjYgKmmcNL5qh",
};

/// The mint that settles this ticker, if one exists on Solana.
pub fn deliverable_mint(ticker: &str) -> Option<&'static str> {
    XSTOCK_MINTS.get(ticker).copied()
}

/// Whether the pool's net exposure to this ticker could be netted against a
/// real share rather than carried. Deliberately not a gate on opening a
/// position: a synthetic book is the product, and most of the ticker universe
/// has no token. It is the input to that decision, not the decision.
pub fn is_deliverable(ticker: &str) -> bool {
    XSTOCK_MINTS.contains_key(ticker)
}
