// ════════════════════════════════════════════════════════════════════════
//   LP ECONOMICS — QU!D's ACTUAL model (docs/IL-VIA-BONDS + IL-CERTIFICATION),
//   not the naive "fees vs LVR" of a vanilla LP.
//
//   The QU!D ETH LP earns: ETH price exposure + venue yield on the WHOLE stack +
//   fees on the in-range slice. It is NOT made whole on rebalancing — the
//   surplus-buffer make-whole (arbETH / refillETH) was REMOVED; the deployed
//   model is R1: the LP bears its OWN impermanent loss directly through the
//   share price (its claim redeems pro-rata to the ETH/USD it holds). That IL is
//   impermanent (round-trips back on mean-reversion) and is limited by how much
//   the LP keeps in dollars (QUI) — NOT by a buffer. The basket's
//   over-collateralization protects QD holders (seniority), not the LP's price
//   exposure. [CORRECTED 2026-08-01: the leverage overlay that CANCELS the up-side
//   IL is BUILT and live — LevManager/BtcLevManager plus the Rust lev_keeper, opt-in
//   per LP on external ISOLATED Euler/Morpho/Aave/Liquity, target LTV 1-sqrt(entry/now),
//   zero at or below entry. The prior "not built yet" note was stale. R1 below still
//   describes the UNPROTECTED path, which is what an LP who declines the overlay gets.]
//   [ALSO STALE BELOW: K_LVR/CERTIFIED_THETA are keyed to a +/-2% band. The deployed
//   band is +/-0.2% (SwapLib.BAND_DELTA = 20).]
//
//   "fees ≈ IL" is FALSE once concentrated — YIELD is the load-bearer, fees are
//   margin (COVID backtest: LVR ≈ 200%/yr at ±2% vs single-digit fees).
//
//   Sustainability (sizing, not avoidance):   θ ≤ yield / (K·σ² − f)
//   IL-CERT used K≈0.71 at the ±2% band; live measurement shows K is regime-
//   dependent and higher (≈1.8–8.4), so any K·σ² shown is a conservative FLOOR.
// ════════════════════════════════════════════════════════════════════════

import type { Regime } from './regime'

export const K_LVR = 0.71            // IL-CERT §3 estimate (±2% band, guard ON). Live measurement: K is regime-dependent ≈1.8–8.4 — treat K·σ² as a conservative FLOOR, not measured truth.
export const LIFETIME_VOL = 0.88     // ETH lifetime annualized vol — the backtest basis (IL-CERT §5)
export const CERTIFIED_THETA = 0.33  // safe in-range fraction at K≈0.71, ±2% band (mid 0.25–0.40); the higher live K implies a SMALLER safe θ

// LVR rate per unit in-range value, annualized ≈ K·σ².
export function lvrRate(sigmaAnnual: number): number {
  return K_LVR * sigmaAnnual * sigmaAnnual
}

// Impermanent loss vs hold at price ratio k (the tail cost on the in-range slice).
export function ilPercent(k: number): number {
  if (k <= 0) return 0
  return 1 - (2 * Math.sqrt(k)) / (1 + k)
}

// ════════════════════════════════════════════════════════════════════════
//   AVELLANEDA–STOIKOV (2008) — ANALYTICS ONLY (NOT what the protocol does).
//   Concentrated liquidity is a discretized limit-order book, so an LP band has
//   an A-S-optimal CENTER (reservation price) and WIDTH (spread). QU!D quotes a
//   SYMMETRIC ±2% band; this shows what an inventory-aware market-maker WOULD
//   quote, for an LP's intuition — the protocol can't act on it (flow isn't
//   selectable in the internal-TWAP pools).
//     reservation:  r = mid · (1 − q·γ·σ²·(T−t))
//     spread:       δ = γσ²(T−t) + (2/γ)·ln(1 + γ/κ)
//   We work in return space (σ annualized, variance = σ²·horizonYears), so the
//   skew/spread come out as fractions of mid → ×1e4 = bps. q ∈ [−1,1] is the
//   inventory skew (+1 = max long the volatile asset). κ (order-arrival rate)
//   is NOT observable in the internal pools, so the "(2/γ)ln(1+γ/κ)" extraction
//   term is omitted unless an arrival estimate is supplied — it doesn't transfer.
// ════════════════════════════════════════════════════════════════════════
export interface ASQuote {
  reservation: number    // inventory-skewed center, price units
  skewBps: number        // how far the optimal center leans off mid (signed)
  halfSpreadBps: number  // δ/2 each side
  hasKappa: boolean      // whether the arrival/extraction term was included
}
export function avellanedaStoikov(
  mid: number, sigmaAnnual: number, q: number,
  gamma: number, horizonYears: number, kappa?: number,
): ASQuote {
  const variance = sigmaAnnual * sigmaAnnual * Math.max(horizonYears, 0)  // σ²·(T−t)
  const skewFrac = q * gamma * variance                                   // q·γ·σ²(T−t)
  let spreadFrac = gamma * variance
  const hasKappa = !!kappa && kappa > 0
  if (hasKappa) spreadFrac += (2 / gamma) * Math.log(1 + gamma / (kappa as number))
  return {
    reservation: mid * (1 - skewFrac),
    skewBps: -skewFrac * 1e4,
    halfSpreadBps: (spreadFrac / 2) * 1e4,
    hasKappa,
  }
}

// ── The deposit signal, QU!D-correct. Under R1 the LP bears its OWN impermanent
//    loss (via the share price); that exposure rises as vol rises above the
//    lifetime basis. We grade the at-work slice's IL EXPOSURE, not a (wrong)
//    fee-vs-LVR sign — and the only mitigation is the dollar (QUI) share. ──
export interface LpHealth {
  buffer: 'comfortable' | 'normal' | 'tight'   // IL-EXPOSURE grade (low/med/high vol); field name kept for callers
  volRatio: number       // current σ / lifetime-vol basis
  headline: string       // plain, user-facing
  detail: string         // plain, user-facing
  grind: boolean         // low-vol trend ("grind") — the under-warned exposure regime
}
// `phi` = mean-reversion/trend coefficient (>0.1 ⇒ trending). The LOW-VOL GRIND
// (calm vol + sustained trend) is the regime that actually exposes the LP: because
// the in-range slice θ = yield/(K·σ²) stays LARGE when σ is low, a smooth rally
// quietly sells the LP's ETH off cheap. Raw-vol health reads "comfortable" there
// and UNDER-warns — so trend overrides the vol-only buffer with grind guidance.
export function lpHealth(sigmaAnnual: number, phi = 0): LpHealth {
  const volRatio = LIFETIME_VOL > 0 ? sigmaAnnual / LIFETIME_VOL : 1
  const buffer: LpHealth['buffer'] = volRatio < 0.85 ? 'comfortable' : volRatio < 1.2 ? 'normal' : 'tight'
  const grind = sigmaAnnual < 0.55 && phi > 0.1   // calm/normal vol + trending = the grind
  const headline =
    'Your ETH earns staking yield plus trading fees; any impermanent loss is exactly that — impermanent, narrowing when price retraces.'
  const detail = grind
    ? 'The market is grinding in one direction on low volatility — the kind of move where the pool steadily trades your ETH and your position can drift behind simply holding. This gap is impermanent: it narrows again if price pulls back. If you can, avoid withdrawing while the trend is stretched — exiting mid-move is what locks the gap in.'
    : buffer === 'comfortable'
      ? 'Markets are calmer than usual — impermanent loss is minimal and round-trips on the normal two-way chop. The real gaps only open in a sustained one-way move.'
      : buffer === 'normal'
      ? 'Conditions are normal — the usual two-way swings make impermanent loss that round-trips back. It only bites in a sustained one-way move or an extreme crash.'
      : 'Markets are unusually volatile — impermanent loss runs larger right now. Your ETH is still yours to withdraw; to limit the gap, keep more in dollars (QUI) until it calms.'
  return { buffer, volRatio, headline, detail, grind }
}

// Four-quadrant regime map (§3.2.6): σ × mean-reversion(φ). Backend label.
export type Quadrant = 'calm reversion' | 'stressed mean-reversion' | 'low-vol trend' | 'regime change'
export function quadrant(sigmaAnnual: number, phi: number): Quadrant {
  const hiVol = sigmaAnnual >= 0.6
  const trending = phi > 0.1
  if (!hiVol && !trending) return 'calm reversion'
  if (hiVol && !trending) return 'stressed mean-reversion'
  if (!hiVol && trending) return 'low-vol trend'
  return 'regime change'
}

// Synthesize the market regime (chop/oscillation/trend) from σ + φ.
export function marketRegime(sigmaAnnual: number, phi: number): Regime {
  if (sigmaAnnual < 0.35) return 'chop'
  if (phi > 0.1) return 'trend'
  return 'oscillation'
}

// ── Discrete market PHASE (§3.2 HMM layer, reduced). The spec's six regimes
//    {strong_bull, weak_bull, crab, weak_bear, capitulation, recovery} via a
//    seeded classifier over (σ, recent return) — a lightweight stand-in for the
//    full Baum-Welch HMM. Returned as PLAIN phase labels, never the codes.
//    changeWatch = transition-in-progress flag (vol estimate unstable). ──
export type Phase = 'Strong uptrend' | 'Mild uptrend' | 'Sideways' | 'Mild downtrend' | 'Sharp selloff' | 'Recovering'
export function marketPhase(sigmaAnnual: number, change7d: number, sigmaUnstable: boolean): { phase: Phase; changeWatch: boolean } {
  const hiVol = sigmaAnnual >= 0.75
  let phase: Phase
  if (change7d <= -15 && hiVol) phase = 'Sharp selloff'
  else if (change7d >= 12 && hiVol) phase = 'Recovering'
  else if (change7d >= 10) phase = 'Strong uptrend'
  else if (change7d >= 2) phase = 'Mild uptrend'
  else if (change7d <= -2) phase = 'Mild downtrend'
  else phase = 'Sideways'
  return { phase, changeWatch: sigmaUnstable }
}

// ── Inverse-vol cross-asset tilt (§A.4 Eq.10): the lower-σ asset is the safer
//    place to accumulate; weight ∝ 1/σ². The one alpha-framework principle that
//    survives N=2. Backend; surfaced plainly ("relatively calmer: Bitcoin"). ──
export function inverseVolTilt(sigmaEth: number, sigmaBtc: number): { eth: number; btc: number; calmer: 'ETH' | 'BTC' } {
  const we = sigmaEth > 0 ? 1 / (sigmaEth * sigmaEth) : 0
  const wb = sigmaBtc > 0 ? 1 / (sigmaBtc * sigmaBtc) : 0
  const tot = we + wb || 1
  return { eth: we / tot, btc: wb / tot, calmer: sigmaEth <= sigmaBtc ? 'ETH' : 'BTC' }
}
