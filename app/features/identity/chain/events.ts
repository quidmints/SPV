// ════════════════════════════════════════════════════════════════════════
//   MAJOR MARKET EVENTS — curated, dated context for the historical read.
//   Prices in isolation don't "put things in perspective"; the EVENTS behind
//   the big moves do. This is a hand-maintained set (more reliable than a news
//   API for *attribution*) used to annotate the worst drawdowns the 10-year
//   lookback surfaces. ETH-centric (the protocol's primary LP asset), with the
//   approximate worst single-day ETH move where it was a crash.
//
//   Maintained by hand: add the next regime-defining event as it happens.
// ════════════════════════════════════════════════════════════════════════

export interface MarketEvent {
  date: string        // ISO yyyy-mm-dd (the peak-impact day)
  label: string       // short name
  cause: string       // one-line plain cause
  ethDropPct?: number // approximate worst single-day ETH move, % (negative = drop)
}

// Ordered oldest→newest. Keep it to genuinely regime-defining moves.
export const MAJOR_EVENTS: MarketEvent[] = [
  { date: '2017-12-17', label: 'Cycle top (2017)', cause: 'ICO mania peak; the blow-off top before the 2018 bear.' },
  { date: '2018-11-14', label: 'Crypto winter', cause: 'Bitcoin breaks $6k support — capitulation into the 2018–19 bottom.', ethDropPct: -15 },
  { date: '2020-03-12', label: 'COVID “Black Thursday”', cause: 'Global pandemic liquidity crash — everything sold at once.', ethDropPct: -44 },
  { date: '2021-05-19', label: 'Leverage flush / China ban', cause: 'China mining-ban headlines trigger a cascading liquidation of over-leveraged longs.', ethDropPct: -40 },
  { date: '2021-09-07', label: 'El Salvador / over-heat shakeout', cause: 'Leverage reset mid-bull.', ethDropPct: -18 },
  { date: '2021-11-10', label: 'Cycle top (2021)', cause: 'The bull-market high; macro tightening turns the tide.' },
  { date: '2022-01-21', label: 'Macro repricing', cause: 'Fed hawkish pivot — risk assets de-rate.', ethDropPct: -15 },
  { date: '2022-05-12', label: 'LUNA / UST collapse', cause: 'A $40B algorithmic stablecoin unravels — first big contagion.', ethDropPct: -20 },
  { date: '2022-06-13', label: 'Celsius freeze / 3AC', cause: 'Lender insolvencies and a hedge-fund blow-up force deleveraging.', ethDropPct: -16 },
  { date: '2022-11-09', label: 'FTX collapse', cause: 'A top-3 exchange becomes insolvent overnight — trust shock.', ethDropPct: -23 },
  { date: '2023-03-11', label: 'USDC depeg (SVB)', cause: 'Silicon Valley Bank fails; USDC briefly trades to ~$0.88 — a stablecoin-basket-relevant scare.', ethDropPct: -7 },
  { date: '2024-01-11', label: 'Spot BTC ETF approval', cause: 'US ETFs go live — a structural new-demand regime (positive).' },
  { date: '2024-08-05', label: 'Yen carry unwind', cause: 'A global FX deleveraging spills into crypto.', ethDropPct: -22 },
]

const DAY_MS = 86_400_000

// The event nearest a given timestamp, within `withinDays`. Used to label a
// drawdown date the price history surfaces with the reason it happened.
export function nearestEvent(dateMs: number, withinDays = 12): MarketEvent | null {
  let best: MarketEvent | null = null
  let bestGap = Infinity
  for (const e of MAJOR_EVENTS) {
    const gap = Math.abs(Date.parse(e.date) - dateMs)
    if (gap < bestGap) { bestGap = gap; best = e }
  }
  return best && bestGap <= withinDays * DAY_MS ? best : null
}

// The historical event whose worst-day ETH crash is closest in MAGNITUDE to
// `dropPct` (a positive %). Lets the stress slider say "a move this size
// last looked like the FTX collapse" — events, not abstract percentages.
export function eventByDropMagnitude(dropPct: number, tolerance = 8): MarketEvent | null {
  let best: MarketEvent | null = null
  let bestGap = Infinity
  for (const e of MAJOR_EVENTS) {
    if (e.ethDropPct == null) continue
    const gap = Math.abs(Math.abs(e.ethDropPct) - dropPct)
    if (gap < bestGap) { bestGap = gap; best = e }
  }
  return best && bestGap <= tolerance ? best : null
}
