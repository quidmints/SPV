// ════════════════════════════════════════════════════════════════════════
//   /api/market — the off-chain quant worker (server-side).
//   Pulls market-at-large data (CoinGecko: price + 90d history, total-cap,
//   BTC dominance), runs the Kalman bank (σ/β/φ) + regime synthesis, returns
//   the MarketSignal the dashboard consumes. Cached to respect the free tier.
//
//   This is the "regime isn't just internal pool state" fix: the read is driven
//   by the broader market, not the pool we're protecting.
// ════════════════════════════════════════════════════════════════════════

import { NextResponse } from 'next/server'
import { logReturns, estimateVol, estimateMeanReversion, estimateBeta, volPercentile } from '@/lib/kalman'
import { marketRegime, quadrant, marketPhase, lpHealth, inverseVolTilt } from '@/lib/quant'
import { nearestEvent } from '@/lib/events'
import type { MarketSignal, AssetSignal, PlainSummary, HistoryContext } from '@/lib/market'
import type { Regime } from '@/lib/regime'

export const revalidate = 120   // seconds — cache the upstream fetch

// Translate the quant into plain language for the user (no σ/β/φ/θ/LVR jargon).
function toPlain(eth: AssetSignal, btc: AssetSignal, regime: Regime): PlainSummary {
  const s = eth.sigmaAnnual
  const volatility: PlainSummary['volatility'] =
    s < 0.35 ? 'Calm' : s < 0.55 ? 'Normal' : s < 0.8 ? 'Elevated' : 'High'
  const trend: PlainSummary['trend'] =
    regime === 'chop' ? 'Range-bound'
    : regime === 'oscillation' ? 'Choppy'
    : eth.change7d >= 0 ? 'Trending up' : 'Trending down'
  const { phase, changeWatch } = marketPhase(s, eth.change7d, eth.sigmaDivergent)
  const { calmer } = inverseVolTilt(s, btc.sigmaAnnual)
  const h = lpHealth(s, eth.phi)
  const headline = `ETH is ${trend.toLowerCase()} with ${volatility.toLowerCase()} volatility.`
  return {
    headline, volatility, trend, phase, changeWatch, calmerAsset: calmer,
    lp: { headline: h.headline, detail: h.detail, buffer: h.buffer, grind: h.grind },
  }
}

const CG = 'https://api.coingecko.com/api/v3'

async function cg(path: string): Promise<any | null> {
  try {
    const r = await fetch(`${CG}${path}`, { next: { revalidate: 120 }, headers: { accept: 'application/json' } })
    if (!r.ok) return null
    return await r.json()
  } catch { return null }
}

const DEGRADED: MarketSignal = {
  eth: blank('ETH'), btc: blank('BTC'),
  betaEthBtc: 1, betaDivergent: false, dominanceBtc: 0, totalCapUsd: 0,
  regime: 'chop', quadrant: 'calm reversion',
  plain: {
    headline: '', volatility: 'Normal', trend: 'Range-bound', phase: 'Sideways',
    changeWatch: false, calmerAsset: 'BTC',
    lp: { headline: '', detail: '', buffer: 'normal', grind: false },
  },
  asOf: 0, degraded: true,
}
function blank(symbol: 'ETH' | 'BTC'): AssetSignal {
  return { symbol, price: 0, change24h: 0, change7d: 0, sigmaAnnual: 0, sigmaBand: 0, sigmaDivergent: false, phi: 0, phiLabel: 'random walk' }
}

// ── 10-year perspective (best-effort): place today's vol against the full
//    history + surface the worst single-day move on record and its cause.
//    CoinGecko's KEYLESS API caps history at 365 days, so the decade-long
//    baseline comes from Coin Metrics' free, keyless COMMUNITY API (a reputable
//    institutional data provider) — full daily PriceUSD back to ETH's 2015
//    inception (~11y). Cached an hour (the baseline barely moves). Never gates
//    the response. Returns [[ms, price]] pairs oldest→newest. ──
async function coinMetricsDaily(asset: string): Promise<number[][] | null> {
  try {
    const url = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics'
      + `?assets=${asset}&metrics=PriceUSD&frequency=1d&page_size=10000&start_time=2015-08-01`
    const r = await fetch(url, { next: { revalidate: 3600 }, headers: { accept: 'application/json' } })
    if (!r.ok) return null
    const data: any[] = (await r.json())?.data || []
    const pairs = data
      .map(d => [Date.parse(d.time), Number(d.PriceUSD)] as number[])
      .filter(p => isFinite(p[0]) && p[1] > 0)
    return pairs.length ? pairs : null
  } catch { return null }
}

function buildHistory(pairs: number[][] | null): HistoryContext | undefined {
  if (!pairs || pairs.length < 400) return undefined  // need a few years of daily points
  const prices = pairs.map(p => p[1])
  const vp = volPercentile(logReturns(prices), 30, 365)
  let worstPct = 0, worstTs = pairs[0][0]
  for (let i = 1; i < pairs.length; i++) {
    if (pairs[i][1] > 0 && pairs[i - 1][1] > 0) {
      const ch = ((pairs[i][1] - pairs[i - 1][1]) / pairs[i - 1][1]) * 100
      if (ch < worstPct) { worstPct = ch; worstTs = pairs[i][0] }
    }
  }
  const years = (pairs[pairs.length - 1][0] - pairs[0][0]) / (365.25 * 864e5)
  return {
    years: Math.round(years * 10) / 10,
    calmerThanPct: Math.round(vp.calmerThanPct),
    worstDayPct: Math.round(worstPct * 10) / 10,
    worstDayDateMs: worstTs,
    worstDayEvent: nearestEvent(worstTs),
  }
}

export async function GET() {
  const [markets, global, ethChart, btcChart, ethHist] = await Promise.all([
    cg('/coins/markets?vs_currency=usd&ids=ethereum,bitcoin&price_change_percentage=24h,7d'),
    cg('/global'),
    cg('/coins/ethereum/market_chart?vs_currency=usd&days=90&interval=daily'),
    cg('/coins/bitcoin/market_chart?vs_currency=usd&days=90&interval=daily'),
    coinMetricsDaily('eth'),                                       // 10y baseline (best-effort, keyless)
  ])
  if (!markets || !ethChart || !btcChart) return NextResponse.json(DEGRADED)

  const row = (id: string) => (markets as any[]).find(m => m.id === id) || {}
  const ethRow = row('ethereum'), btcRow = row('bitcoin')
  const ethPrices: number[] = (ethChart.prices || []).map((p: number[]) => p[1])
  const btcPrices: number[] = (btcChart.prices || []).map((p: number[]) => p[1])
  const ethRets = logReturns(ethPrices)
  const btcRets = logReturns(btcPrices)

  const ethVol = estimateVol(ethRets, 365)
  const btcVol = estimateVol(btcRets, 365)
  const ethPhi = estimateMeanReversion(ethRets)
  const btcPhi = estimateMeanReversion(btcRets)
  const beta = estimateBeta(ethRets, btcRets)   // ETH on BTC (§3.2.1)

  const eth: AssetSignal = {
    symbol: 'ETH', price: ethRow.current_price || 0,
    change24h: ethRow.price_change_percentage_24h_in_currency ?? ethRow.price_change_percentage_24h ?? 0,
    change7d: ethRow.price_change_percentage_7d_in_currency ?? 0,
    sigmaAnnual: ethVol.sigmaAnnual, sigmaBand: ethVol.band, sigmaDivergent: ethVol.divergent,
    phi: ethPhi.phi, phiLabel: ethPhi.label,
  }
  const btc: AssetSignal = {
    symbol: 'BTC', price: btcRow.current_price || 0,
    change24h: btcRow.price_change_percentage_24h_in_currency ?? btcRow.price_change_percentage_24h ?? 0,
    change7d: btcRow.price_change_percentage_7d_in_currency ?? 0,
    sigmaAnnual: btcVol.sigmaAnnual, sigmaBand: btcVol.band, sigmaDivergent: btcVol.divergent,
    phi: btcPhi.phi, phiLabel: btcPhi.label,
  }

  // Regime/quadrant off ETH (the protocol's primary LP asset).
  const signal: MarketSignal = {
    eth, btc,
    betaEthBtc: beta.beta, betaDivergent: beta.divergent,
    dominanceBtc: global?.data?.market_cap_percentage?.btc ?? 0,
    totalCapUsd: global?.data?.total_market_cap?.usd ?? 0,
    regime: marketRegime(eth.sigmaAnnual, eth.phi),
    quadrant: quadrant(eth.sigmaAnnual, eth.phi),
    plain: toPlain(eth, btc, marketRegime(eth.sigmaAnnual, eth.phi)),
    history: buildHistory(ethHist),
    asOf: Math.floor(Date.now() / 1000),
    degraded: false,
  }
  return NextResponse.json(signal)
}
