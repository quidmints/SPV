'use client'

// ════════════════════════════════════════════════════════════════════════
//   LEVERAGE (IL-protect) — the DURING card, shown on the Dashboard only when
//   the connected LP has an OPEN overlay position. Turns the LevManager view
//   reads into the plain surface: a regime word (calm/choppy/stormy), a one-line
//   "+$Z after IL so far", and a small stress projection. All the bps/LTV live
//   in the collapsed "details" — never the headline.
// ════════════════════════════════════════════════════════════════════════

import { useState, useEffect } from 'react'
import { readLevPosition, levRegime, stressBuffer, type LevPosition, type LevRegime } from '@/lib/leverage'
import { f0 } from '@/lib/format'

const signed0 = (v: number) => (v >= 0 ? '+' : '−') + f0(v)

const REGIME: Record<LevRegime, { word: string; dot: string; border: string; text: string; line: string }> = {
  calm:   { word: 'Calm',   dot: 'bg-emerald-400', border: 'border-emerald-500/40', text: 'text-emerald-300',
            line: 'Plenty of room — your cushion is well clear of any stress.' },
  choppy: { word: 'Choppy', dot: 'bg-sky-400',     border: 'border-sky-500/40',     text: 'text-sky-300',
            line: 'Normal two-way swings — the cushion is doing its job, nothing to do.' },
  stormy: { word: 'Stormy', dot: 'bg-amber-400',   border: 'border-amber-500/40',   text: 'text-amber-300',
            line: 'Swings are large and your buffer is tighter — the keeper is de-levering to keep you clear.' },
}

export default function LeverageCard({ address, ethPxUsd, volAnnual }:
  { address: string | null; ethPxUsd?: number | null; volAnnual?: number }) {
  const [pos, setPos] = useState<LevPosition | null>(null)
  const [open, setOpen] = useState(false)   // advanced details

  useEffect(() => {
    let cancelled = false
    if (!address) { setPos(null); return }
    readLevPosition(address).then(p => { if (!cancelled) setPos(p) }).catch(() => { if (!cancelled) setPos(null) })
    return () => { cancelled = true }
  }, [address])

  // Only render when there's a live open position — otherwise stay out of the way.
  if (!pos || !pos.open) return null

  const reg = REGIME[levRegime(pos, volAnnual ?? 0)]

  // "+$Z after IL so far" = current net equity vs. just holding the deposit ETH.
  // Same oracle price on both legs, so this nets out raw ETH price change and
  // leaves fees + the IL the cushion cancelled − borrow carry.
  const px = ethPxUsd && ethPxUsd > 0 ? ethPxUsd : (pos.entryPriceUsd || 0)
  const hodlUsd = pos.e0Eth * px
  const earnedAfterIl = pos.netEquityUsd - hodlUsd
  const ahead = earnedAfterIl >= 0

  // Stress projection at −30%.
  const sb = stressBuffer(pos, 30)

  return (
    <div className={`p-4 rounded-xl bg-white/5 border-l-4 ${reg.border}`}>
      <div className="flex items-center justify-between mb-1">
        <div className="flex items-center gap-2">
          <span className={`inline-block w-2 h-2 rounded-full ${reg.dot}`} />
          <span className="text-sm font-semibold">Your IL cushion — <span className={reg.text}>{reg.word}</span></span>
        </div>
        <span className="text-[11px] opacity-50">active</span>
      </div>
      <p className="text-[12px] opacity-70">{reg.line}</p>

      {/* The one dollar line the LP reads. */}
      <div className="mt-2 flex items-baseline gap-2">
        <span className={`text-2xl font-semibold font-mono ${ahead ? 'text-emerald-400' : 'text-rose-400'}`}>
          {signed0(earnedAfterIl)}
        </span>
        <span className="text-[12px] opacity-70">
          {ahead ? 'ahead of just holding your ETH so far' : 'behind holding right now'}
        </span>
      </div>
      <p className="text-[11px] opacity-50 mt-1">
        {ahead
          ? 'Fees plus the impermanent loss your cushion has cancelled, net of borrow carry.'
          : 'Mostly borrow carry during a quiet stretch — it narrows as fees accrue and the market moves.'}
      </p>

      {/* Small stress projection — plain words, no LTV. */}
      <div className="mt-3 rounded-lg bg-black/20 p-3 text-[12px]">
        <div className="opacity-60 text-[10px] uppercase tracking-wide mb-1">If ETH dropped another 30%</div>
        <div className={sb.clear ? 'text-emerald-300' : 'text-amber-300'}>
          {sb.clear
            ? 'You’d still be comfortably clear — the cushion steps back automatically to stay safe.'
            : 'It would get tight — the keeper de-levers you toward zero to stay clear of liquidation; keeping more in dollars adds margin.'}
        </div>
      </div>

      {/* Advanced — the raw numbers for LPs who want them, collapsed by default. */}
      <button onClick={() => setOpen(o => !o)}
        className="mt-3 text-[11px] opacity-50 hover:opacity-90">
        {open ? 'hide the numbers ▲' : 'show the numbers ▼'}
      </button>
      {open && (
        <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-[11px] font-mono">
          <Row label="Net equity" value={f0(pos.netEquityUsd)} />
          <Row label="Borrowed (debt)" value={f0(pos.debtUsd)} />
          <Row label="Current LTV" value={`${(pos.currentLtvBps / 100).toFixed(1)}%`} />
          <Row label="Liquidation at" value={`${(pos.liqThresholdBps / 100).toFixed(0)}%`} />
          <Row label="IL-target LTV" value={`${(pos.ilTargetBps / 100).toFixed(1)}%`} />
          <Row label="Your cap" value={`${(pos.targetCapBps / 100).toFixed(0)}%`} />
          <Row label="Collateral" value={`${pos.grossCollateralEth.toFixed(3)} Ξ`} />
          <Row label="At −30%, LTV" value={`${(sb.projLtvBps / 100).toFixed(1)}%`} />
        </div>
      )}
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="opacity-50">{label}</span>
      <span>{value}</span>
    </div>
  )
}
