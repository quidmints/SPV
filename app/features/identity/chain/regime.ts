
// ════════════════════════════════════════════════════════════════════════
//   REGIME BRAIN — the market-state characterization the dashboard consumes.
//
//   Estimation, not prediction: we characterize the CURRENT state, we do not
//   forecast price. Three regimes:
//     • chop        — range-bound, low realized move. Fees accrue, IL ≈ 0.
//     • oscillation — two-way volatility, mean-reverting (high range, low net).
//     • trend       — sustained directional move; IL / LVR elevated.
//
//   The classifier is SOURCE-AGNOSTIC — it runs on any tick (log-price) series.
//   Sources:
//     • internal pool ring — Core.observe(secondsAgos, isBTC)  [implemented here]
//     • EXTERNAL market-at-large — price feeds for ETH/BTC/total-cap, funding,
//       dominance (see lib/market.ts). The LP-facing regime must combine these:
//       internal pool state alone is circular (it's what we're protecting). The
//       external feed is what makes the read informative + the UX near-automatable.
// ════════════════════════════════════════════════════════════════════════

import { readOne, ZERO_ADDR } from './eth.ts'

const SECONDS_PER_YEAR = 365 * 24 * 3600
// (2026-08-16) TICK UNITS ARE GONE. This brain used to work in Uniswap ticks: the series was
// `ln(p)/ln(1.0001)`, vol multiplied differences back by `ln(1.0001)`, and the chop threshold was
// `CHOP_TICKS = 200` ("≈ ±2%"). With the tick vocabulary removed from the protocol, expressing a
// price series in ticks meant carrying a Uniswap constant for no reason — a unit borrowed from a
// dependency that no longer exists.
//
// Everything is now NATURAL LOG PRICE, which is what the tick series was a rescaling OF, so the
// calibration is preserved exactly rather than re-tuned: 200 ticks = 200·ln(1.0001) = 0.0199997,
// i.e. the same ±2% peak-to-trough. A log range is also directly readable — 0.02 IS 2% — where a
// tick count needed the constant to interpret.
const CHOP_LOG = 0.02                         // ±2% peak-to-trough (was CHOP_TICKS = 200)
const TREND_RATIO = 0.6                       // |net| / range above this → trend (dimensionless)

export type Regime = 'chop' | 'oscillation' | 'trend'

export interface RegimeRead {
  regime: Regime
  volAnnual: number     // realized volatility, annualized (0.62 = 62%)
  rangeLog: number    // peak-to-trough LOG-price span over the window (0.02 = 2%)
  netLog: number      // signed net move (last − first)
  trendRatio: number    // |net| / range ∈ [0,1]; →1 trend, →0 oscillation
  samples: number
  source: 'pool' | 'market' | 'blend'
}

export const regimeLabel: Record<Regime, string> = {
  chop: 'Range-bound (chop)',
  oscillation: 'Two-way (oscillation)',
  trend: 'Directional (trend)',
}

export const regimePosture: Record<Regime, string> = {
  chop: 'Calm, range-bound — in-range LP fees accrue with low IL.',
  oscillation: 'Two-way volatility, mean-reverting — fees rich, IL round-trips.',
  trend: 'Sustained directional move — IL / LVR elevated; LP with care.',
}

// Decode observe() PRICE-cumulatives → an interval-average TICK series, oldest→newest.
//
// 🔴 (2026-08-15) THE TICK REMOVAL CHANGED WHAT THIS RECEIVES, AND THE OLD VERSION WAS
// SILENTLY WRONG FOR EVERY READ IN BETWEEN. `Core.observe` once returned Uniswap-style
// `int56[] tickCumulatives`; it now returns `uint192[]` cumulative **usd18-price·seconds**
// (`OracleLib.Observation.priceCumulative`, built as `priceCumulative + lastPrice*dt`, where
// the struct doc states the value is a "usd18 price" carrying the BTC leg's ×1e10 lift).
//
// The DIFFERENCING was always right — these are still cumulatives, so
// `(cum[i+1] - cum[i]) / dt` is a time-weighted average. What broke is the UNIT: it now
// yields a PRICE where everything downstream expects a TICK.
//
// ⚠️ Fixing it downstream would have meant touching three calibrated things —
// `realizedVol`'s `* LN_1_0001` (the tick→log-price constant), `CHOP_TICKS = 200` (≈ ±2%
// peak-to-trough, i.e. 200 × 1bp) and `TREND_RATIO` — and `classifyRegime` documents itself
// as running on "any tick (log-price) series". So the honest fix is ONE conversion at this
// boundary: put the series back into tick units and every consumer is correct as written,
// including `realizedVol`, whose `(t[i]-t[i-1]) * LN_1_0001` becomes exactly the log return
// `ln(p_i) - ln(p_{i-1})` again.
//
// The `/1e18` is for interpretability only — every downstream use is a DIFFERENCE, and a
// constant log offset cancels in all of them.
export function decodeTwapLogPrices(cumulatives: bigint[], stepSec: number): number[] {
  const out: number[] = []
  for (let i = 0; i < cumulatives.length - 1; i++) {
    const twapUsd18 = Number(cumulatives[i + 1] - cumulatives[i]) / stepSec
    // A non-positive TWAP means two `secondsAgos` resolved to the same observation (or the
    // ring is not yet warm). `Math.log` would yield -Infinity/NaN and poison range, net and
    // vol alike, so bail on the WHOLE series rather than emit a shorter one — dropping a
    // sample would silently misalign the remaining points from `stepSec`.
    if (!(twapUsd18 > 0)) return []
    out.push(Math.log(twapUsd18 / 1e18))
  }
  return out
}

export function realizedVol(logPrices: number[], stepSec: number): number {
  if (logPrices.length < 3) return 0
  const rets: number[] = []
  // A difference of natural logs IS the log return. In tick units this needed a
  // `* ln(1.0001)` to undo the tick scaling; there is nothing to undo now.
  for (let i = 1; i < logPrices.length; i++) rets.push(logPrices[i] - logPrices[i - 1])
  const mean = rets.reduce((a, b) => a + b, 0) / rets.length
  const variance = rets.reduce((a, r) => a + (r - mean) ** 2, 0) / Math.max(rets.length - 1, 1)
  return Math.sqrt(variance) * Math.sqrt(SECONDS_PER_YEAR / stepSec)
}

// Classify a NATURAL-LOG-PRICE series (source-agnostic). stepSec only annualizes vol.
export function classifyRegime(logPrices: number[], stepSec = 1, source: RegimeRead['source'] = 'pool'): RegimeRead {
  const samples = logPrices.length
  if (samples < 3) return { regime: 'chop', volAnnual: 0, rangeLog: 0, netLog: 0, trendRatio: 0, samples, source }
  const max = Math.max(...logPrices), min = Math.min(...logPrices)
  const rangeLog = max - min
  const netLog = logPrices[logPrices.length - 1] - logPrices[0]
  const trendRatio = rangeLog > 0 ? Math.abs(netLog) / rangeLog : 0

  let regime: Regime
  if (rangeLog < CHOP_LOG) regime = 'chop'
  else if (trendRatio > TREND_RATIO) regime = 'trend'
  else regime = 'oscillation'

  return { regime, volAnnual: realizedVol(logPrices, stepSec), rangeLog, netLog, trendRatio, samples, source }
}

// ── Internal pool source. NOTE: pool-only is a partial view (it is the thing we
//    protect). The external-market blend (lib/market.ts) is the informative one. ──
export async function fetchRegime(
  coreAddr: string, isBTC: boolean, windowSec = 6 * 3600, samples = 24,
): Promise<RegimeRead | null> {
  if (!coreAddr || coreAddr === ZERO_ADDR) return null
  const stepSec = Math.max(Math.floor(windowSec / samples), 60)
  const agos: number[] = []
  for (let i = samples; i >= 0; i--) agos.push(i * stepSec)   // descending → [N·step … 0]
  const res = await readOne(coreAddr, 'observe', [agos, isBTC])   // §E63: one entry, band as an arg
  if (!res) return null
  const cumulatives: bigint[] = (res as any[]).map((x) => BigInt(x))
  return classifyRegime(decodeTwapLogPrices(cumulatives, stepSec), stepSec, 'pool')
}
