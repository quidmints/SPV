// Market signal — types + client fetch. The heavy quant runs server-side in
// /api/market (no CORS, cached); the .tsx consumes this shape.

import type { Regime } from './regime'
import type { MarketEvent } from './events'

// Long-horizon perspective (the 10-year lookback): today's vol placed against
// the full history, plus the worst single-day move on record + the event that
// caused it. Optional — best-effort (the recent quant works without it).
export interface HistoryContext {
  years: number              // span of the lookback actually available
  calmerThanPct: number      // % of the decade's days MORE volatile than today
  worstDayPct: number        // worst single-day ETH move over the lookback (negative)
  worstDayDateMs: number     // when it happened
  worstDayEvent: MarketEvent | null  // why it happened (nearest curated event)
}

export interface AssetSignal {
  symbol: 'ETH' | 'BTC'
  price: number
  change24h: number       // %
  change7d: number        // %
  sigmaAnnual: number     // Kalman dynamic vol, annualized (0.62 = 62%)
  sigmaBand: number       // ±band
  sigmaDivergent: boolean // innovation-divergence flag → retune
  phi: number             // AR(1) mean-reversion coefficient
  phiLabel: string        // trending / random walk / mean reverting
}

// PLAIN, user-facing translation of the quant. The user never sees σ/β/φ/LVR/
// "Kalman" — those are our backend assessment; this is what we show them.
export interface PlainSummary {
  headline: string                                          // one friendly line
  volatility: 'Calm' | 'Normal' | 'Elevated' | 'High'
  trend: 'Trending up' | 'Trending down' | 'Range-bound' | 'Choppy'
  phase: string                                             // plain market phase
  changeWatch: boolean                                      // phase shifting
  calmerAsset: 'ETH' | 'BTC'                                // inverse-vol tilt
  lp: {                                                     // QU!D LP economics (correct model)
    headline: string
    detail: string
    buffer: 'comfortable' | 'normal' | 'tight'
    grind: boolean
  }
}

export interface MarketSignal {
  // ── raw quant — for OUR backend assessment, not shown to the user ──
  eth: AssetSignal
  btc: AssetSignal
  betaEthBtc: number
  betaDivergent: boolean
  dominanceBtc: number
  totalCapUsd: number
  regime: Regime
  quadrant: string
  // ── what we actually show ──
  plain: PlainSummary
  history?: HistoryContext   // 10-year perspective (best-effort)
  asOf: number
  degraded: boolean
}

export async function fetchMarket(): Promise<MarketSignal | null> {
  try {
    const r = await fetch('/api/market', { cache: 'no-store' })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}
