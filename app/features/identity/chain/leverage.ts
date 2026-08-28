
// ════════════════════════════════════════════════════════════════════════
//   LEVERAGE (IL-protect) — the LP-facing surface for the opt-in YB overlay.
//
//   Design rule (kept DEAD SIMPLE): the LP never sees "hedge ratio", raw LTV,
//   sold-fraction, or a debt figure as the headline. They see a plain regime
//   word (calm / choppy / stormy), ONE comfort knob ("how much cushion"), and a
//   dollar outcome ("+$Z after IL"). The bps live only in a collapsed detail.
//
//   What the overlay actually does (so the copy stays honest): as ETH RISES the
//   band sells the LP's ETH; the overlay re-buys it (borrow stable → buy ETH),
//   cancelling that impermanent loss up to the LP's chosen comfort cap. As ETH
//   FALLS the IL-target LTV goes to zero — it de-levers — so the LP is never
//   levered into a crash. Down-move IL is therefore small, borne, and recovers
//   on retrace (same as a plain LP); the cushion's job is the up-move IL.
// ════════════════════════════════════════════════════════════════════════

import { CONTRACTS } from './chains.ts'
import { readOne, ZERO_ADDR } from './eth.ts'
import { ilPercent } from './quant.ts'

// ── Pure client-side stress math ────────────────────────────────────────
// IL on a 50/50-style band for a price move of `movePct` (standard 2√k/(1+k)−1
// shape, per the certified IL model). `comfortFrac` ∈ [0,1] is the LP's cushion
// choice = the fraction of the up-move IL the overlay cancels. On a fall the
// cushion steps back (cancels 0; the IL is borne and recovers on retrace).
export interface StressRow { movePct: number; up: boolean; ilUsd: number; cancelledUsd: number; netUsd: number }
export function stressRow(posUsd: number, movePct: number, comfortFrac: number, up: boolean): StressRow {
  const k = up ? 1 + movePct / 100 : 1 - movePct / 100
  const ilUsd = Math.max(0, ilPercent(k)) * Math.max(0, posUsd)
  const cancelledUsd = up ? Math.min(Math.max(comfortFrac, 0), 1) * ilUsd : 0
  return { movePct, up, ilUsd, cancelledUsd, netUsd: ilUsd - cancelledUsd }
}

// ── Live position read (all six views + the venue liq threshold) ─────────
export interface LevPosition {
  open: boolean
  currentLtvBps: number   // venue-safety LTV (debt / actual collateral)
  ilTargetBps: number     // IL-cancelling target (sold fraction, capped)
  liqThresholdBps: number // venue LLTV — the liquidation line
  targetCapBps: number    // the LP's chosen comfort cap
  netEquityUsd: number
  debtUsd: number
  grossCollateralEth: number
  entryPriceUsd: number
  e0Eth: number           // the deposit (IL base), ETH
}

const wad = (v: any) => (v == null ? 0 : Number(BigInt(v)) / 1e18)
const raw = (v: any) => (v == null ? 0 : Number(BigInt(v)))

export async function readLevPosition(address: string | null): Promise<LevPosition | null> {
  const lm = CONTRACTS.levManager
  if (!lm || lm === ZERO_ADDR || !address) return null
  const p = await readOne(lm, 'pos', [address])
  if (!p) return null
  const open = Boolean(p[5])
  if (!open) return { open: false } as LevPosition
  const venue = p[0] as string
  const [ltv, ilT, ne, d, gc, liq] = await Promise.all([
    readOne(lm, 'getCurrentLtvBps', [address]),
    readOne(lm, 'ilTargetLtvBps', [address]),
    readOne(lm, 'netEquityUsd', [address]),
    readOne(lm, 'debtUsd', [address]),
    readOne(lm, 'grossCollateralEth', [address]),
    readOne(venue, 'liqThresholdBps', []),
  ])
  return {
    open: true,
    currentLtvBps: raw(ltv),
    ilTargetBps: raw(ilT),
    liqThresholdBps: raw(liq) || 8000,   // conservative default if the venue read is unavailable
    targetCapBps: raw(p[1]),
    netEquityUsd: wad(ne),
    debtUsd: wad(d),
    grossCollateralEth: wad(gc),
    entryPriceUsd: wad(p[2]),
    e0Eth: wad(p[3]),
  }
}

// ── Regime word (calm / choppy / stormy) from the liquidation buffer + vol ──
// Headroom to liquidation is the primary driver (how safe the position is right
// now); recent volatility only nudges the word toward caution.
export type LevRegime = 'calm' | 'choppy' | 'stormy'
export function levRegime(pos: LevPosition, volAnnual = 0): LevRegime {
  const buffer = pos.liqThresholdBps > 0
    ? (pos.liqThresholdBps - pos.currentLtvBps) / pos.liqThresholdBps
    : 1
  const volHi = volAnnual > 0.9
  const volMed = volAnnual > 0.6
  if (buffer < 0.2 || (buffer < 0.35 && volHi)) return 'stormy'
  if (buffer < 0.45 || volMed) return 'choppy'
  return 'calm'
}

// Projected liquidation buffer after a price drop of `dropPct` (collateral value
// falls with price, debt is fixed, so LTV rises ≈ current / (1 − drop)). Returns
// the projected buffer fraction and whether it stays clear of the liq line.
export function stressBuffer(pos: LevPosition, dropPct: number): { projLtvBps: number; buffer: number; clear: boolean } {
  const k = Math.max(0.01, 1 - dropPct / 100)
  const projLtvBps = pos.currentLtvBps / k
  const buffer = pos.liqThresholdBps > 0 ? (pos.liqThresholdBps - projLtvBps) / pos.liqThresholdBps : 0
  return { projLtvBps, buffer, clear: projLtvBps < pos.liqThresholdBps * 0.9 }
}
