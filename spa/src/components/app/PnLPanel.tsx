'use client'

// ════════════════════════════════════════════════════════════════════════
//   PER-LP P&L CARD — the connected wallet's ETH-LP result, in plain words.
//
//   Headline = netVsQdUsd: lifetime result vs. just holding the dollars (the
//   QUI baseline). The impermanent-loss term is BUNDLED into that one number —
//   we never name it, and never say "cost basis" / "IL". Mirrors InfoTab's
//   visual style (Section/Stat helpers redefined locally, same Tailwind).
//
//   USD figures are priced at TODAY's price (no archive RPC) — when so, a tiny
//   honest note says so. The share/ETH math underneath is exact regardless.
// ════════════════════════════════════════════════════════════════════════

import { useState, useEffect } from 'react'
import { fetchLpPnl, type LpPnl } from '@/lib/pnl'
import { Empty } from '@/components/app/ui'

// ── local formatters (InfoTab's are module-local; redefine the few we need) ──
const fmt = (v: number | null, d = 2) =>
  v == null || !isFinite(v) ? '—'
  : v.toLocaleString('en-US', { maximumFractionDigits: d })
const usd = (v: number | null, d = 0) => v == null ? '—' : `$${fmt(Math.abs(v), d)}`
const signedUsd = (v: number | null, d = 0) =>
  v == null ? '—' : (v >= 0 ? '+' : '−') + '$' + fmt(Math.abs(v), d)

export default function PnLPanel({ address }: { address: string | null }) {
  const [pnl, setPnl] = useState<LpPnl | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    let cancelled = false
    if (!address) { setPnl(null); return }
    setLoading(true)
    fetchLpPnl(address)
      .then(r => { if (!cancelled) setPnl(r) })
      .catch(() => { if (!cancelled) setPnl(null) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [address])

  // ── Empty / not-connected / no-position states ──
  if (!address) {
    return (
      <Section title="Your ETH position">
        <Empty note="connect a wallet to see your result" />
      </Section>
    )
  }
  if (loading && !pnl) {
    return (
      <Section title="Your ETH position">
        <p className="text-xs opacity-40">Reading your position…</p>
      </Section>
    )
  }
  if (!pnl || !pnl.hasPosition) {
    return (
      <Section title="Your ETH position">
        <p className="text-xs opacity-40">No ETH-LP position yet.</p>
      </Section>
    )
  }

  // ── Headline read ──
  const ahead = pnl.netVsQdUsd >= 0
  const headColor = ahead ? 'text-emerald-400' : 'text-rose-400'
  const read = ahead
    ? 'You’re ahead of just holding dollars — yield and fees are outrunning the price swings.'
    : 'Behind right now — price swings outweigh the fees you’ve earned so far. This recovers as markets calm and fees accrue.'

  const feesUsd = (pnl.feesEarnedEth || 0) *
    (pnl.currentValueEth > 0 ? pnl.currentValueUsd / pnl.currentValueEth : 0)

  return (
    <Section title="Your ETH position vs. holding QUI" right={
      loading ? <span className="text-xs opacity-50">↻</span> : null
    }>
      {/* Headline */}
      <div className="mb-3">
        <div className={`text-3xl font-semibold font-mono ${headColor}`}>
          {signedUsd(pnl.netVsQdUsd, 0)}
        </div>
        <p className="text-[12px] opacity-70 mt-1">{read}</p>
      </div>

      {/* Rows */}
      <div className="space-y-1 text-sm">
        <Row label="Put in" value={usd(pnl.investedUsd, 0)} />
        <Row label="Worth now" value={usd(pnl.currentValueUsd, 0)} />
        <Row
          label="Fees earned"
          value={`${fmt(pnl.feesEarnedEth, 4)} Ξ${feesUsd > 0 ? ` · ~${usd(feesUsd, 0)}` : ''}`}
          accent="emerald"
        />
        {pnl.withdrawnUsd > 0 && (
          <Row label="Taken out" value={usd(pnl.withdrawnUsd, 0)} />
        )}
      </div>

      {pnl.costBasisApprox && (
        <p className="text-[10px] opacity-40 mt-3 pt-2 border-t border-white/10">
          Dollar figures shown at today’s price — connect an archive RPC for exact entry pricing. Your share of the pool and your ETH amounts are exact.
        </p>
      )}
    </Section>
  )
}

// ── presentational helpers (local; InfoTab keeps its own copies) ──
function Section({ title, right, children }:
  { title: string; right?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="p-4 rounded-xl bg-white/5">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-medium opacity-80">{title}</h3>
        {right}
      </div>
      {children}
    </div>
  )
}
function Row({ label, value, accent }:
  { label: string; value: string; accent?: 'emerald' }) {
  return (
    <div className="flex items-center justify-between">
      <span className="opacity-70">{label}</span>
      <span className={`font-mono ${accent === 'emerald' ? 'text-emerald-400' : ''}`}>{value}</span>
    </div>
  )
}
