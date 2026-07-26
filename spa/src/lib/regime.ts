'use client'

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
//     • internal pool ring — Core.observe(secondsAgos)  [implemented here]
//     • EXTERNAL market-at-large — price feeds for ETH/BTC/total-cap, funding,
//       dominance (see lib/market.ts). The LP-facing regime must combine these:
//       internal pool state alone is circular (it's what we're protecting). The
//       external feed is what makes the read informative + the UX near-automatable.
// ════════════════════════════════════════════════════════════════════════

import { readOne, ZERO_ADDR } from './eth'

const LN_1_0001 = Math.log(1.0001)           // tick → ln(price)
const SECONDS_PER_YEAR = 365 * 24 * 3600
const CHOP_TICKS = 200                        // ≈ ±2% peak-to-trough → "chop"
const TREND_RATIO = 0.6                       // |net| / range above this → trend

export type Regime = 'chop' | 'oscillation' | 'trend'

export interface RegimeRead {
  regime: Regime
  volAnnual: number     // realized volatility, annualized (0.62 = 62%)
  rangeTicks: number    // peak-to-trough tick span over the window
  netTicks: number      // signed net move (last − first)
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

// Decode observe() tickCumulatives → interval-average ticks, oldest→newest.
export function decodeTickSeries(cumulatives: bigint[], stepSec: number): number[] {
  const out: number[] = []
  for (let i = 0; i < cumulatives.length - 1; i++) {
    out.push(Number(cumulatives[i + 1] - cumulatives[i]) / stepSec)
  }
  return out
}

export function realizedVol(ticks: number[], stepSec: number): number {
  if (ticks.length < 3) return 0
  const rets: number[] = []
  for (let i = 1; i < ticks.length; i++) rets.push((ticks[i] - ticks[i - 1]) * LN_1_0001)
  const mean = rets.reduce((a, b) => a + b, 0) / rets.length
  const variance = rets.reduce((a, r) => a + (r - mean) ** 2, 0) / Math.max(rets.length - 1, 1)
  return Math.sqrt(variance) * Math.sqrt(SECONDS_PER_YEAR / stepSec)
}

// Classify a tick/log-price series (source-agnostic). stepSec only annualizes vol.
export function classifyRegime(ticks: number[], stepSec = 1, source: RegimeRead['source'] = 'pool'): RegimeRead {
  const samples = ticks.length
  if (samples < 3) return { regime: 'chop', volAnnual: 0, rangeTicks: 0, netTicks: 0, trendRatio: 0, samples, source }
  const max = Math.max(...ticks), min = Math.min(...ticks)
  const rangeTicks = max - min
  const netTicks = ticks[ticks.length - 1] - ticks[0]
  const trendRatio = rangeTicks > 0 ? Math.abs(netTicks) / rangeTicks : 0

  let regime: Regime
  if (rangeTicks < CHOP_TICKS) regime = 'chop'
  else if (trendRatio > TREND_RATIO) regime = 'trend'
  else regime = 'oscillation'

  return { regime, volAnnual: realizedVol(ticks, stepSec), rangeTicks, netTicks, trendRatio, samples, source }
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
  const res = await readOne(coreAddr, isBTC ? 'observeBTC' : 'observe', [agos])
  if (!res) return null
  const cumulatives: bigint[] = (res as any[]).map((x) => BigInt(x))
  return classifyRegime(decodeTickSeries(cumulatives, stepSec), stepSec, 'pool')
}
