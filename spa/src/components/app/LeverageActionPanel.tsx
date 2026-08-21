'use client'

// ════════════════════════════════════════════════════════════════════════
//   LEVERAGE ACTION PANEL — the WRITE surface for the opt-in YB overlay (#65).
//   Sits right beside LeverageCard (the read-only "how's my cushion" display).
//   Lets an LP OPEN a leveraged position (pick a borrow venue + pledge collateral
//   + choose a leverage level), ADJUST the level, or CLOSE it — all real txs.
//
//   Framing rule (kept honest): 2× = delta-1 = IL-NEUTRAL (the overlay cancels the
//   range's up-move IL, no directional bet). Above 2× is DIRECTIONAL — the LP takes
//   isolated, own-risk long exposure. The bps/LTV are shown as the detail, never
//   the whole story. The panel owns its input state; the actual approve+send lives
//   in page.tsx (doOpenLev / doAdjustLev / doCloseLev), passed in as callbacks so
//   this component stays presentational and reuses the page's tx plumbing.
// ════════════════════════════════════════════════════════════════════════

import { useState, useMemo } from 'react'
import { ethers } from 'ethers'
import { CONTRACTS, LEV_VENUES, type LevVenue } from '@/lib/chains'
import { ZERO_ADDR } from '@/lib/eth'
import { stressRow, type LevPosition } from '@/lib/leverage'
import { f0 } from '@/lib/format'

// Leverage L → target LTV bps: LTV = (L−1)/L · 10000. 2× = 5000 (IL-neutral),
// 3× ≈ 6667, 4× = 7500. Slider works in L; bps is derived + capped on-chain.
const lToBps = (L: number) => Math.round((L - 1) / L * 10000)
const bpsToL = (bps: number) => (bps >= 10000 ? Infinity : 10000 / (10000 - bps))

export default function LeverageActionPanel({
  connected, address, pos, capBps, ethPxUsd, busy,
  onOpen, onAdjust, onClose,
}: {
  connected: boolean
  address: string
  pos: LevPosition | null
  capBps: number            // on-chain TARGET_LTV_CAP_BPS (hard cap, default 7500)
  ethPxUsd: number
  busy: boolean
  onOpen: (targetLtvBps: number, venue: LevVenue, amount: bigint) => void
  onAdjust: (capBps: number) => void
  onClose: () => void
}) {
  const deployed = CONTRACTS.levManager !== ZERO_ADDR && LEV_VENUES.length > 0
  const isOpen = Boolean(pos?.open)

  // Max leverage the on-chain cap allows (cap defaults to 7500 = 4×). Follow the CONTRACT's cap so the slider
  // always matches the on-chain limit — guard the near-100%-LTV edge where bpsToL → Infinity.
  const cap = capBps > 0 ? capBps : 7500
  const capL = bpsToL(cap)
  const maxL = Math.max(2, Number.isFinite(capL) ? capL : 4)

  const [venueId, setVenueId] = useState<number>(LEV_VENUES[0]?.id ?? 0)
  const [amount, setAmount] = useState('')
  // Leverage as a multiple (2.0 … maxL). When a position is open we seed from its cap.
  const [levL, setLevL] = useState<number>(isOpen ? Math.min(maxL, bpsToL(pos?.targetCapBps || 5000)) : 2)

  const venue = useMemo(
    () => LEV_VENUES.find(v => v.id === venueId) ?? LEV_VENUES[0] ?? null,
    [venueId],
  )

  // Chosen target LTV bps, clamped to the on-chain hard cap.
  const targetBps = Math.min(cap, lToBps(levL))
  const collSym = venue?.collateral ?? 'WETH'
  const amountNum = parseFloat(amount) || 0
  // Parse to wei safely (both WETH and weETH are 18-dec) — null on malformed input
  // so a bad string can't throw in the click handler.
  const amountWei = useMemo(() => {
    try { return amount.trim() ? ethers.parseEther(amount.trim()) : 0n } catch { return null }
  }, [amount])

  // Preview via the same IL stress model the display uses. At 2× the overlay is
  // delta-1 (cancels the full up-move IL → comfortFrac 1); higher L still cancels
  // the up IL and adds directional upside (isolated risk).
  const collUsd = amountNum * (ethPxUsd || 0)
  const comfortFrac = Math.min(1, Math.max(0, levL - 1))
  const up = stressRow(collUsd, 30, comfortFrac, true)
  const down = stressRow(collUsd, 30, comfortFrac, false)

  if (!deployed) {
    return (
      <div className="p-4 rounded-xl bg-white/5">
        <h3 className="text-sm font-medium opacity-80 mb-1">Leverage (IL-protect)</h3>
        <p className="text-[12px] opacity-50">
          Leverage is not deployed on this network yet — the overlay contract or its borrow
          venues aren’t configured. This turns on once QU!D’s LevManager and at least one
          venue are live.
        </p>
      </div>
    )
  }

  const canOpen = connected && !busy && venue != null && amountWei != null && amountWei > 0n
  const directional = levL > 2.001

  return (
    <div className="p-4 rounded-xl bg-white/5">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-medium opacity-80">
          {isOpen ? 'Adjust your leverage' : 'Add leverage (IL-protect)'}
        </h3>
        <span className="text-xs opacity-50">{isOpen ? 'position open' : 'opt-in'}</span>
      </div>

      {!isOpen && (
        <>
          {/* Venue */}
          <label className="block text-sm mb-1">Borrow venue</label>
          <select value={venueId} onChange={e => setVenueId(Number(e.target.value))}
            className="w-full mb-1 p-2 rounded bg-black/30 border border-white/10 text-sm">
            {LEV_VENUES.map(v => (
              <option key={v.id} value={v.id}>{v.label} · pledge {v.collateral}</option>
            ))}
          </select>
          <p className="text-[11px] opacity-50 mb-3">
            {venue?.blurb} Isolated to your position — your own venue, your own risk.
          </p>

          {/* Collateral amount */}
          <label className="block text-sm mb-1">Collateral ({collSym})</label>
          <input value={amount} onChange={e => setAmount(e.target.value)}
            className="w-full mb-3 p-2 rounded bg-black/30 border border-white/10" placeholder="0.00" />
        </>
      )}

      {/* Leverage level slider (L → LTV bps) */}
      <label className="block text-sm mb-1">
        Leverage: {levL.toFixed(1)}× <span className="opacity-50">(target LTV {(targetBps / 100).toFixed(1)}%)</span>
      </label>
      <input type="range" min={2} max={maxL} step={0.1} value={levL}
        onChange={e => setLevL(Number(e.target.value))}
        className="w-full mb-1 accent-cyan-400" />
      <div className={`text-[11px] mb-3 ${directional ? 'text-amber-300' : 'text-emerald-300'}`}>
        {directional
          ? `${levL.toFixed(1)}× — directional. Above 2× you take isolated long exposure — your own risk, not just IL protection.`
          : '2× — IL-neutral (delta-1). The overlay just cancels the pool’s up-move IL; no directional bet.'}
      </div>
      {lToBps(levL) > cap && (
        <p className="text-[10px] text-amber-300/80 mb-3">
          Capped at the protocol’s {(cap / 100).toFixed(0)}% LTV hard limit.
        </p>
      )}

      {/* Stress preview — same IL model as the display card. */}
      {collUsd > 0 && !isOpen && (
        <div className="mb-3 rounded-lg bg-black/20 p-3 text-[12px] space-y-1.5">
          <div className="opacity-60 text-[10px] uppercase tracking-wide">If your ETH swings ~30%</div>
          <div>
            On the way <strong>up</strong>, the pool sells your ETH — about <strong>{f0(up.ilUsd)}</strong> of
            impermanent loss unprotected; the overlay re-buys about{' '}
            <span className="text-cyan-300">{f0(up.cancelledUsd)}</span> of it → net drag ≈ <strong>{f0(up.netUsd)}</strong>.
          </div>
          <div className="opacity-70 pt-1 border-t border-white/10">
            On the way <strong>down</strong>, about {f0(down.ilUsd)} of impermanent loss — the target LTV
            steps toward zero so you’re never levered into a crash; it recovers on retrace.
          </div>
        </div>
      )}

      {/* Actions */}
      {isOpen ? (
        <div className="flex gap-2">
          <button onClick={() => onAdjust(targetBps)} disabled={busy || !connected}
            className="flex-1 py-3 rounded-lg bg-gradient-to-r from-cyan-600 to-blue-600 hover:opacity-90 disabled:opacity-40 font-semibold text-sm">
            {busy ? 'Working…' : `Set leverage to ${levL.toFixed(1)}×`}
          </button>
          <button onClick={onClose} disabled={busy || !connected}
            className="flex-1 py-3 rounded-lg bg-gradient-to-r from-orange-600 to-red-600 hover:opacity-90 disabled:opacity-40 font-semibold text-sm">
            {busy ? 'Working…' : 'Close position'}
          </button>
        </div>
      ) : (
        <button
          onClick={() => { if (venue && amountWei != null && amountWei > 0n) onOpen(targetBps, venue, amountWei) }}
          disabled={!canOpen}
          className="w-full py-3 rounded-lg bg-gradient-to-r from-cyan-600 to-blue-600 hover:opacity-90 disabled:opacity-40 font-semibold">
          {busy ? 'Working…' : !connected ? 'Connect to open' : `Open at ${levL.toFixed(1)}× on ${venue?.label ?? '—'}`}
        </button>
      )}

      <p className="text-[10px] opacity-40 mt-2">
        Opening pledges your {collSym} and opens at zero leverage; a keeper then levers up to your chosen
        level as the pool sells on a rally (cancelling that impermanent loss) and de-levers on a fall. The
        borrow carry is funded by the fees your ETH earns. Opt-in and isolated to your position.
      </p>
    </div>
  )
}
