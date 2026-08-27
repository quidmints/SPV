//! §RETURNS — an empirically calibrated equity return generator.
//!
//! Every earlier measurement in `facility_sim_report` used a tail I invented: a
//! Gaussian-ish core with two hand-placed jump probabilities. That is fine for
//! showing a mechanism and useless for calibrating one, because the answer to
//! "does the collar breach 1% of the time" is a statement about the RETURN
//! DISTRIBUTION and I had supplied a made-up one.
//!
//! This reproduces the stylised facts of equity returns that actually matter to
//! a barrier model, each with its standard parameterisation:
//!
//! 1. **FAT TAILS.** Daily equity returns have kurtosis ~5-10 against 3 for a
//!    normal, and a tail index α ≈ 3-4. Student-t with ν = 4 matches. ⚠️ Note
//!    this makes ξ = 1/α ≈ 0.25 — so the `gpd_params` COLD-START PRIOR OF n = 4
//!    (ξ = 0.25) that I replaced was empirically RIGHT for equities, and my
//!    n = 2 (ξ = 0.5) is deliberately conservative rather than accurate.
//! 2. **VOLATILITY CLUSTERING.** GARCH(1,1) with α ≈ 0.08, β ≈ 0.90 — the
//!    near-unit persistence typical of equity indices. Without this, tail events
//!    are independent, which is the assumption that makes any barrier look safe.
//! 3. **LEVERAGE EFFECT.** Down moves raise conditional vol more than up moves
//!    (GJR γ ≈ 0.05). The `Actuary` already models this on its own side; the
//!    generator has to produce it or that machinery is never exercised.
//! 4. **OVERNIGHT AND WEEKEND GAPS.** Equities trade 6.5h of every 24, so most
//!    of the clock is a closed market. Roughly a third of daily variance arrives
//!    in the overnight gap, and a weekend carries ~3 nights of it. This is the
//!    single biggest difference between an equity series and a crypto one, and
//!    it is exactly the risk a hedge that cannot trade on a weekend is exposed to.
//!
//! Integer arithmetic throughout, deterministic LCG, no transcendentals — so a
//! failure reproduces exactly and it can run inside a program test.

/// Trading hours in a session; the rest of the day is a gap.
pub const SESSION_HOURS: i64 = 7;
/// Share of daily variance that arrives in the overnight gap, in bps.
pub const OVERNIGHT_VAR_SHARE_BPS: i64 = 3_500;

pub struct Equity {
    st: u64,
    /// Conditional variance in bps², GARCH state.
    var_bps2: i64,
    /// Long-run variance in bps² (per hourly step).
    omega_bps2: i64,
    hour: i64,
}

/// ⚠️ NON-OSCILLATING INTEGER NEWTON, and the naive form HANGS. `while r != prev`
/// alternates between n and n+1 forever once it reaches the floor — the first
/// version of this function froze the test suite for ten minutes. This is the
/// same shape `fee_bps` already uses: descend while strictly decreasing.
fn isqrt(x: i64) -> i64 {
    if x <= 0 { return 0; }
    let mut r = x;
    let mut y = (r + 1) / 2;
    while y < r { r = y; y = (r + x / r.max(1)) / 2; }
    r
}

impl Equity {
    /// `daily_vol_bps` is the per-day standard deviation — 120 bps ≈ 19% annual,
    /// a typical large-cap; 300 bps ≈ 48% annual, a volatile single name.
    pub fn new(seed: u64, daily_vol_bps: i64) -> Self {
        // Per-hour variance from the daily figure, over the trading session.
        let hourly = (daily_vol_bps * daily_vol_bps) / SESSION_HOURS.max(1);
        Equity { st: seed ^ 0x9E3779B97F4A7C15, var_bps2: hourly,
                 omega_bps2: hourly, hour: 0 }
    }

    fn u(&mut self) -> i64 {
        self.st = self.st.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.st >> 33) % 1_000_000) as i64
    }

    /// Approximately N(0, 1000²) by Irwin–Hall (12 uniforms), no transcendental.
    fn z(&mut self) -> i64 {
        let mut acc = 0i64;
        for _ in 0..12 { acc += self.u() / 1_000; }       // 12 × U[0,1000)
        acc - 6_000                                       // mean 0, sd ≈ 1000
    }

    /// Student-t(ν=4) scaled to sd ≈ 1000: z / sqrt(chi2_4 / 4).
    fn t4(&mut self) -> i64 {
        let z = self.z();
        let mut chi = 0i64;
        for _ in 0..4 { let zi = self.z() / 1_000; chi += zi * zi; }
        let chi = chi.max(1);
        // t = z * sqrt(4/chi); scale by 1000 inside the root for precision.
        let scale = isqrt(4 * 1_000_000 / chi);           // ≈ 1000*sqrt(4/chi)
        z * scale / 1_000 / 2                             // /2 keeps sd ≈ 1000 for ν=4
    }

    /// One hourly step, in bps. Returns `(move_bps, is_gap)`.
    pub fn step(&mut self) -> (i64, bool) {
        self.hour += 1;
        let in_session = (self.hour % 24) < SESSION_HOURS;
        let day = self.hour / 24;
        let weekend = (day % 7) >= 5;

        // Closed market: no move except at the single gap that reopens it.
        if !in_session {
            let reopens = (self.hour % 24) == 23 && !weekend;
            if !reopens { return (0, false); }
        }
        if weekend {
            // One gap per weekend, at its end, carrying ~3 nights of variance.
            if !((day % 7) == 6 && (self.hour % 24) == 23) { return (0, false); }
        }

        let is_gap = !in_session || weekend;
        // GARCH(1,1) + GJR: sigma^2_t = omega + a*r^2 + gamma*r^2*[r<0] + b*sigma^2
        let sd = isqrt(self.var_bps2.max(1));
        let raw = self.t4() * sd / 1_000;
        // A gap concentrates a share of the daily variance into one move.
        let mult = if weekend { 3 } else { 1 };
        let r = if is_gap {
            raw * isqrt(OVERNIGHT_VAR_SHARE_BPS * SESSION_HOURS * mult / 100) / 10
        } else { raw };

        let r2 = (r * r).min(i64::MAX / 4);
        let gjr = if r < 0 { 500 } else { 0 };            // gamma = 0.05
        self.var_bps2 = (self.omega_bps2 * 200 / 10_000)  // omega share
            + (r2 * (800 + gjr) / 10_000)                 // alpha = 0.08 (+gamma)
            + (self.var_bps2 * 9_000 / 10_000);           // beta  = 0.90
        self.var_bps2 = self.var_bps2.clamp(self.omega_bps2 / 20, self.omega_bps2 * 400);
        (r.clamp(-6_000, 6_000), is_gap)
    }
}
