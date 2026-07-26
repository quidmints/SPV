'use client'

// ════════════════════════════════════════════════════════════════════════
//   COMFORT PANEL — the LP's entire action surface, one knob each.
//   The base currency is QUI (dollars, safe). Every strategy is a rotation of
//   QUI ↔ ETH/BTC. Two sliders set the TARGET; the panel shows current-vs-target
//   and ONE plain suggestion. No "hedge ratio", no jargon — moving to QUI IS the
//   hedge. The target persists locally; the smart-wallet permission layer will
//   execute against it (until then, the LP acts via the Deposit/Withdraw tabs).
// ════════════════════════════════════════════════════════════════════════

import { useState, useEffect } from 'react'
import { AllocationSlider } from './AllocationSlider'
import { stressRow } from '@/lib/leverage'
import { f0 } from '@/lib/format'

const pct = (v: number) => `${Math.round(v)}%`

export default function ComfortPanel({ safeUsd, ethUsd, btcUsd, connected }: {
  safeUsd: number; ethUsd: number; btcUsd: number; connected: boolean
}) {
  const [atWork, setAtWork] = useState(50)      // target % of my dollars at work (ETH/BTC) vs safe QUI
  const [btcShare, setBtcShare] = useState(50)  // target BTC share of the at-work slice
  const [ilProtect, setIlProtect] = useState(false) // IL-protect: keeper-managed leverage on the ETH slice
  const [comfort, setComfort] = useState(70)         // cushion knob: how much of the up-move IL to cancel

  // Persist the target locally (the smart-wallet permission layer executes against it).
  useEffect(() => {
    try {
      const a = localStorage.getItem('quid.target.atWork')
      const b = localStorage.getItem('quid.target.btcShare')
      const c = localStorage.getItem('quid.target.ilProtect')
      const d = localStorage.getItem('quid.target.comfort')
      if (a != null) setAtWork(Number(a))
      if (b != null) setBtcShare(Number(b))
      if (c != null) setIlProtect(c === '1')
      if (d != null) setComfort(Number(d))
    } catch {}
  }, [])
  useEffect(() => { try { localStorage.setItem('quid.target.atWork', String(atWork)) } catch {} }, [atWork])
  useEffect(() => { try { localStorage.setItem('quid.target.btcShare', String(btcShare)) } catch {} }, [btcShare])
  useEffect(() => { try { localStorage.setItem('quid.target.ilProtect', ilProtect ? '1' : '0') } catch {} }, [ilProtect])
  useEffect(() => { try { localStorage.setItem('quid.target.comfort', String(comfort)) } catch {} }, [comfort])

  const total = safeUsd + ethUsd + btcUsd
  const work = ethUsd + btcUsd
  const curAtWork = total > 0 ? (work / total) * 100 : 0
  const curBtcShare = work > 0 ? (btcUsd / work) * 100 : 0

  const desiredWork = total * atWork / 100
  const workDelta = desiredWork - work                 // + → deploy more; − → pull to QUI
  const desiredEth = desiredWork * (1 - btcShare / 100)
  const desiredBtc = desiredWork * (btcShare / 100)
  const ethDelta = desiredEth - ethUsd
  const btcDelta = desiredBtc - btcUsd

  // Suggest a move ONLY when you've drifted past a WIDE ~10% band. Empirically
  // (9yr ETH backtest) ~10% is the cheapest-effective band — tighter just churns
  // fees for no gain, and rebalancing isn't an edge anyway (the "premium" is a
  // fixed-anchor artifact that vanishes once a target gravitates). So this is a
  // low-churn EXECUTOR of your exposure choice, not an optimiser. IL is mitigated
  // only by how much you keep in QUI (≈ 1 − at-work %), nothing the band does.
  const band = Math.max(total * 0.10, 1)
  const lines: string[] = []
  if (total <= 0) {
    lines.push('Deposit some dollars first, then this guides how much to put to work.')
  } else {
    if (workDelta > band) lines.push(`Put about ${f0(workDelta)} of your safe QUI to work.`)
    else if (workDelta < -band) lines.push(`Move about ${f0(workDelta)} back to safe QUI.`)
    if (ethDelta > band && btcDelta < -band) lines.push(`Lean about ${f0(Math.min(ethDelta, -btcDelta))} from Bitcoin toward Ethereum.`)
    else if (btcDelta > band && ethDelta < -band) lines.push(`Lean about ${f0(Math.min(btcDelta, -ethDelta))} from Ethereum toward Bitcoin.`)
    if (lines.length === 0) lines.push('You’re within your ~10% comfort band — nothing to do.')
  }

  // Current mix bar segments.
  const seg = (v: number) => total > 0 ? (v / total) * 100 : 0

  return (
    <div className="p-4 rounded-xl bg-white/5 mb-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-medium opacity-80">Your target mix</h3>
        <span className="text-xs opacity-50">{total > 0 ? `${f0(total)} total` : 'not connected'}</span>
      </div>

      {/* Current mix, at a glance */}
      <div className="flex h-2.5 rounded overflow-hidden mb-1 bg-white/5">
        <div className="h-full bg-white/25" style={{ width: `${seg(safeUsd)}%` }} title="Safe (QUI)" />
        <div className="h-full bg-cyan-400/60" style={{ width: `${seg(ethUsd)}%` }} title="Ethereum" />
        <div className="h-full bg-amber-400/60" style={{ width: `${seg(btcUsd)}%` }} title="Bitcoin" />
      </div>
      <div className="flex justify-between text-[10px] opacity-50 mb-4">
        <span>Safe QUI {f0(safeUsd)}</span>
        <span>ETH {f0(ethUsd)}</span>
        <span>BTC {f0(btcUsd)}</span>
      </div>

      {/* Risk knob — safe vs at work */}
      <div className="mb-4">
        <AllocationSlider
          leftLabel="Safe (QUI)" rightLabel="At work (ETH/BTC)"
          value={atWork} onChange={setAtWork}
          valueLabel={`${pct(atWork)} of my dollars at work`}
          accent="accent-cyan-400" />
        <p className="text-[10px] opacity-45 mt-1 text-center">
          currently {pct(curAtWork)} at work
        </p>
      </div>

      {/* Split knob — ETH vs BTC of the at-work slice */}
      <div className="mb-3">
        <AllocationSlider
          leftLabel="Ethereum" rightLabel="Bitcoin"
          value={btcShare} onChange={setBtcShare}
          valueLabel={`${pct(100 - btcShare)} ETH · ${pct(btcShare)} BTC`}
          accent="accent-amber-400" />
        <p className="text-[10px] opacity-45 mt-1 text-center">
          currently {pct(100 - curBtcShare)} ETH · {pct(curBtcShare)} BTC at work
        </p>
      </div>

      {/* IL-protect — one more knob in the SAME frame (not a separate card). Only meaningful while you hold
          ETH at work; toggles the keeper-managed leverage overlay on your ETH slice. When on, a single
          comfort knob ("how much cushion") + a plain stress preview show what it does BEFORE you commit. */}
      {(1 - btcShare / 100) > 0 && (() => {
        const ethAtWork = total * atWork / 100 * (1 - btcShare / 100)   // the ETH slice the cushion covers
        const comfortFrac = comfort / 100
        const up = stressRow(ethAtWork, 30, comfortFrac, true)          // +30%: the cushion re-buys sold ETH
        const down = stressRow(ethAtWork, 30, comfortFrac, false)       // −30%: cushion steps back (borne, recovers)
        return (
          <div className="mb-3 rounded-lg bg-white/5 p-3">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="text-[12px] font-medium opacity-90">Protect my ETH from impermanent loss</div>
                <p className="text-[10px] opacity-45 mt-0.5">
                  A keeper re-adds the ETH the pool sells as price rises, so you keep full ETH exposure (no IL
                  vs just holding). If price falls it steps back so you’re never over-extended. Costs a small
                  borrow carry, funded by the fees your ETH earns — net-positive when trading is busy. Opt-in,
                  isolated to your position.
                </p>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={ilProtect}
                onClick={() => setIlProtect(v => !v)}
                className={`relative h-5 w-9 shrink-0 rounded-full transition-colors ${ilProtect ? 'bg-cyan-400/70' : 'bg-white/15'}`}
              >
                <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition-all ${ilProtect ? 'left-[18px]' : 'left-0.5'}`} />
              </button>
            </div>

            {ilProtect && (
              <div className="mt-3 pt-3 border-t border-white/10">
                {/* ONE knob: how much cushion (framing = comfort, not a leverage multiple) */}
                <AllocationSlider
                  leftLabel="Minimal" rightLabel="Maximum cushion"
                  value={comfort} onChange={setComfort}
                  valueLabel={`${pct(comfort)} cushion`}
                  accent="accent-cyan-400" />
                <p className="text-[10px] opacity-45 mt-1 text-center">
                  more cushion cancels more of the impermanent loss on a rally (and costs a little more carry)
                </p>

                {/* Plain stress preview — 3 numbers, no greeks. */}
                {ethAtWork > 0 ? (
                  <div className="mt-3 rounded-lg bg-black/20 p-3 text-[12px] space-y-2">
                    <div className="opacity-60 text-[10px] uppercase tracking-wide">If your ETH swings ~30%</div>
                    <div>
                      <div className="opacity-90">On the way <strong>up</strong>, the pool sells your ETH — unprotected that’s about <strong>{f0(up.ilUsd)}</strong> of impermanent loss.</div>
                      <div className="opacity-70 mt-0.5">Your cushion re-buys about <span className="text-cyan-300">{f0(up.cancelledUsd)}</span> of it → net drag <strong>≈ {f0(up.netUsd)}</strong>.</div>
                    </div>
                    <div className="opacity-70 pt-1 border-t border-white/10">
                      On the way <strong>down</strong>, about {f0(down.ilUsd)} of impermanent loss — the same with or without the cushion (it steps back so you’re never over-extended), and it recovers as price retraces.
                    </div>
                  </div>
                ) : (
                  <p className="mt-3 text-[11px] opacity-50">Put some ETH to work above to see your cushion in dollars.</p>
                )}
                <p className="text-[10px] opacity-35 mt-2">
                  Estimates from your ETH-at-work and the standard impermanent-loss curve — the actual amount depends on how far and how fast price moves.
                </p>
              </div>
            )}
          </div>
        )
      })()}

      {/* The one (or two) plain suggestion(s) */}
      <div className="rounded-lg bg-white/5 p-3 text-[12px] space-y-1">
        {lines.map((l, i) => (
          <div key={i} className="flex gap-2">
            <span className="opacity-50">→</span><span className="opacity-90">{l}</span>
          </div>
        ))}
      </div>
      <p className="text-[10px] opacity-40 mt-2">
        Moving to QUI is the safe move — it’s the dollar, it can’t lose to price swings, and how
        much you keep there is what actually limits impermanent loss. This only nudges you when
        you’ve drifted past ~10% (keeping trading costs low) — it executes your choice, it doesn’t
        time the market. Use the Deposit / Withdraw tabs to act{connected ? '' : ' once connected'};
        automatic rotation arrives with smart-wallet permissions.
      </p>
    </div>
  )
}
