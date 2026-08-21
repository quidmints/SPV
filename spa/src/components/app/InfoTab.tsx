'use client'

// ════════════════════════════════════════════════════════════════════════
//   INFO TAB — read-only protocol surface (separate from the user's actions).
//   Composition of stables in Aux · total ETH/BTC in Quid · TVL / yield /
//   fees · NET FLOW (by asset + stable-kind) shown NEXT TO the REGIME read,
//   so an LP sees protocol flow AND market context before peeling.
// ════════════════════════════════════════════════════════════════════════

import { useState, useEffect, useCallback } from 'react'
import { CONTRACTS, STABLES } from '@/lib/chains'
import { readOne } from '@/lib/eth'
import { fetchNetFlow, fetchBtcInventory, type NetFlow, type BtcInventory } from '@/lib/flow'
import { fetchMarket, type MarketSignal } from '@/lib/market'
import { ilPercent, avellanedaStoikov, K_LVR } from '@/lib/quant'
import { eventByDropMagnitude } from '@/lib/events'
import LeverageCard from '@/components/app/LeverageCard'
import { Empty } from '@/components/app/ui'

const n = (v: any, dec = 18) => v == null ? null : Number(BigInt(v)) / 10 ** dec
const fmt = (v: number | null, d = 2) =>
  v == null ? '—' : !isFinite(v) ? '—'
  : v.toLocaleString('en-US', { maximumFractionDigits: d })
const usd = (v: number | null, d = 0) => v == null ? '—' : `$${fmt(v, d)}`
const signed = (v: number | null, d = 2) => v == null ? '—' : (v >= 0 ? '+' : '') + fmt(v, d)

interface Composition { sym: string; usd: number }

export default function InfoTab({ address }: { address?: string | null }) {
  const [tvl, setTvl] = useState<number | null>(null)
  const [avgYield, setAvgYield] = useState<number | null>(null)
  const [rangeEth, setQuidEth] = useState<number | null>(null)
  const [btc, setBtc] = useState<number | null>(null)
  const [feesEth, setFeesEth] = useState<number | null>(null)
  const [comp, setComp] = useState<Composition[]>([])
  const [compTotal, setCompTotal] = useState(0)
  const [flow, setFlow] = useState<NetFlow | null>(null)
  const [inventory, setInventory] = useState<BtcInventory | null>(null)
  const [market, setMarket] = useState<MarketSignal | null>(null)
  // ── REAL internal numbers (the actual on-chain state, not proxies) ──
  const [headroom, setHeadroom] = useState<number | null>(null)   // (totalLiquid−committed)/totalLiquid
  const [theta, setTheta] = useState<number | null>(null)         // POOLED / rangeETH (in-range share)
  const [poolEth, setPoolEth] = useState<number | null>(null)     // pool ETH TWAP (USD) — vs external price
  const [inv, setInv] = useState<number | null>(null)             // live inventory skew q ∈ [−1,1]: + = long ETH
  const [btcDelivered, setBtcDelivered] = useState<number | null>(null)  // live undelivered swap-out USD (BTC demand)
  const [stressDrop, setStressDrop] = useState(30)                // "what if ETH drops X%?"
  // ── Redeemable-when schedule: how sticky the basket dollars are ──
  const [redeemNow, setRedeemNow] = useState<number | null>(null) // mature now (totalSupply − immature)
  const [schedule, setSchedule] = useState<{ off: number; usd: number }[]>([]) // unlocks per future month
  const [loading, setLoading] = useState(true)
  const [advanced, setAdvanced] = useState(false)                 // reveal the raw quant (σ/φ/β/regime)

  const load = useCallback(async () => {
    setLoading(true)
    // ── Protocol metrics ──
    const metrics = await readOne(CONTRACTS.aux, 'get_metrics', [false])
    if (metrics) setTvl(n(metrics[0]))
    setAvgYield(n(await readOne(CONTRACTS.aux, 'avgYield'), 16)) // 1e18 = 100% → /1e16 = %
    setQuidEth(n(await readOne(CONTRACTS.range, 'rangeETH')))
    setBtc(n(await readOne(CONTRACTS.btcChannels, 'totalSatsLocked'), 8))
    setBtcDelivered(n(await readOne(CONTRACTS.rangeCore, 'pendingSwapOutUsd'), 6))  // live BTC swap-out demand (USD)

    // ── Protocol-total ETH-side LP fees ≈ feesPerShare × lpShares / WAD ──
    const fps = await readOne(CONTRACTS.range, 'feesPerShare')
    const lps = await readOne(CONTRACTS.range, 'lpShares')
    if (fps != null && lps != null) {
      try { setFeesEth(Number((BigInt(fps) * BigInt(lps)) / (10n ** 18n)) / 1e18) } catch {}
    }

    // ── QUI's REAL over-collateralization (basket value above ALL claims): tryCheckBacking
    //    → (committed, total). This backs QUI (seniority); it does NOT absorb the LP's IL. ──
    const cb = await readOne(CONTRACTS.aux, 'tryCheckBacking')
    if (cb) {
      const committed = Number(BigInt(cb[0])), total = Number(BigInt(cb[1]))
      setHeadroom(total > 0 ? (total - committed) / total : null)
    }
    // ── In-range share θ = POOLED / rangeETH (the short-gamma slice) ──
    // §E235-spa — `POOLED()` on the ETH engine. Was `POOLED_ETH` on a contract that carried both
    // ranges; the range is now the instance, so `rangeCore` IS the ETH selection.
    const pooledEth = n(await readOne(CONTRACTS.rangeCore, 'POOLED'))
    const vEth = n(await readOne(CONTRACTS.range, 'rangeETH'))
    if (pooledEth != null && vEth && vEth > 0) setTheta(pooledEth / vEth)
    // ── Pool ETH price (TWAP) — for the internal-vs-external comparison ──
    const ethPx = n(await readOne(CONTRACTS.aux, 'getTWAPforAsset', [CONTRACTS.weth, 1800]))
    setPoolEth(ethPx)
    // ── LIVE inventory skew q ∈ [−1,1] of the in-range (actively-quoting) slice:
    //    + = overweight ETH (long the volatile asset), − = overweight USD. Compare
    //    the ETH leg (POOLED × price) to the USD leg (POOLED_USD, 6-dec), BOTH read off the
    //    SAME instance — which is what makes the ratio a single range's skew rather than a mix.
    //    This is the real q the A-S reservation price skews on. Null pre-deploy. ──
    const usdSide = n(await readOne(CONTRACTS.rangeCore, 'POOLED_USD'), 6)
    if (pooledEth != null && ethPx != null && usdSide != null) {
      const ethVal = pooledEth * ethPx, tot = ethVal + usdSide
      setInv(tot > 0 ? Math.max(-1, Math.min(1, (ethVal - usdSide) / tot)) : null)
    } else setInv(null)

    // ── Composition of stables in Aux (get_deposits → uint[15] USD-normalized; 0..11 = stables) ──
    const dep = await readOne(CONTRACTS.aux, 'get_deposits')
    if (dep) {
      const amounts: any[] = dep[0]
      const rows: Composition[] = STABLES.map((s, i) => ({ sym: s.symbol, usd: n(amounts[i]) ?? 0 }))
      setComp(rows)
      setCompTotal(rows.reduce((a, r) => a + r.usd, 0))
    }

    // ── Redeemable-when schedule (QUI maturity ladder = deposit stickiness).
    //    QUI is the dollar (18-dec, ≈$1), so amount/1e18 ≈ USD. Redeemable-NOW =
    //    totalSupply − immatureSupply; each future month m unlocks totalSupplies[m]. ──
    const cmRaw = await readOne(CONTRACTS.basket, 'currentMonth')
    if (cmRaw != null) {
      const cm = Number(BigInt(cmRaw))
      const tot = n(await readOne(CONTRACTS.basket, 'totalSupply'))
      const imm = n(await readOne(CONTRACTS.basket, 'immatureSupply'))
      if (tot != null && imm != null) setRedeemNow(Math.max(0, tot - imm))
      const months = await Promise.all(
        Array.from({ length: 13 }, (_, i) =>
          readOne(CONTRACTS.basket, 'totalSupplies', [cm + 1 + i])))
      setSchedule(months.map((v, i) => ({ off: i + 1, usd: n(v) ?? 0 })).filter(r => r.usd > 0))
    }

    // ── Flow + market read (side by side: the LP's deposit-decision pair) ──
    const [f, m, inv] = await Promise.all([fetchNetFlow(), fetchMarket(), fetchBtcInventory()])
    setFlow(f); setMarket(m); setInventory(inv)
    setLoading(false)
  }, [])

  useEffect(() => { void load() }, [load])

  return (
    <div className="space-y-6">
      {/* ════════════════════════════════════════════════════════════════
          WHAT THIS MEANS FOR YOU — the one takeaway an LP reads first.
          Synthesizes the REAL on-chain backing cushion + blended yield +
          the (Kalman-derived) market read into a single plain verdict +
          status light. Everything below is the supporting detail.
         ════════════════════════════════════════════════════════════════ */}
      {(() => {
        const haveAny = avgYield != null || headroom != null || (market && !market.degraded)
        if (!haveAny) {
          return (
            <div className="p-4 rounded-xl bg-white/5 border-l-4 border-white/15">
              <div className="text-sm font-medium opacity-80">What this means for you</div>
              <p className="text-xs opacity-50 mt-1">Connect to a deployed protocol to see your personalized read.</p>
            </div>
          )
        }
        // Market volatility, plain — prefer the quant's own grade; fall back to σ.
        const volHi = market ? (market.plain.volatility === 'High' || market.plain.volatility === 'Elevated')
                             : false
        // Verdict driven by the REAL over-collateralization first, vol only downgrades.
        let light: 'green' | 'sky' | 'amber' = 'sky'
        if (headroom != null) {
          if (headroom > 0.25 && !volHi) light = 'green'
          else if (headroom < 0.08 || (headroom < 0.15 && volHi)) light = 'amber'
        } else if (market) {
          light = market.plain.lp.buffer === 'comfortable' ? 'green' : market.plain.lp.buffer === 'tight' ? 'amber' : 'sky'
        }
        const dot = light === 'green' ? 'bg-emerald-400' : light === 'amber' ? 'bg-amber-400' : 'bg-sky-400'
        const border = light === 'green' ? 'border-emerald-500/40' : light === 'amber' ? 'border-amber-500/40' : 'border-sky-500/40'
        const verdict =
          light === 'green' ? 'A calm moment to add — low swing risk.'
          : light === 'amber' ? 'You can add, but swings are elevated — impermanent loss runs larger, so size accordingly.'
          : 'Normal conditions for adding.'
        const yieldStr = avgYield == null ? null : `${fmt(avgYield, 1)}%`
        const mkt = market && !market.degraded
          ? `Markets are ${market.plain.phase.toLowerCase()} with ${market.plain.volatility.toLowerCase()} price swings.`
          : ''
        const cushion = headroom != null ? ` The basket holds ${fmt(headroom * 100, 0)}% more than every claim on it — that keeps QU!D fully backed (it doesn't cover your ETH's price swings).` : ''
        return (
          <div className={`p-4 rounded-xl bg-white/5 border-l-4 ${border}`}>
            <div className="flex items-center gap-2 mb-1">
              <span className={`inline-block w-2 h-2 rounded-full ${dot}`} />
              <span className="text-sm font-semibold">{verdict}</span>
            </div>
            <p className="text-sm opacity-90">
              Your ETH keeps its price exposure{yieldStr ? <> and earns about <strong>{yieldStr}</strong> a year</> : ''}, plus trading fees.
              {' '}{mkt}{cushion}
            </p>
            <p className="text-[11px] opacity-50 mt-1">
              You bear your own impermanent loss — small and recoverable in two-way markets, larger in a sustained one-way move — and you limit it by how much you keep in dollars (QUI). See the stress test below.
            </p>
          </div>
        )
      })()}

      {/* ── IL cushion (leverage overlay) — shows ONLY if this LP has one open ── */}
      <LeverageCard address={address ?? null} ethPxUsd={poolEth}
        volAnnual={market && !market.degraded ? market.eth.sigmaAnnual : 0} />

      {/* ════════════════════════════════════════════════════════════════
          WHEN TO ADD OR WITHDRAW — the highest-ROI read. ETH and BTC time
          DIFFERENTLY: ETH LPing has continuous LVR (vol-regime drives the LP's
          own IL); BTC LPing has NO continuous LVR — it's swap-out-delivery/fee
          driven (IL-CERT §1), so it follows demand, not price swings. Plain
          words only, no q/σ/bps. Relative, not market-timing.
         ════════════════════════════════════════════════════════════════ */}
      {((market && !market.degraded) || headroom != null) && (
        <Section title="When to add or withdraw">
          {(() => {
            const calmer = market?.history?.calmerThanPct ?? null
            const volHi = market ? (market.plain.volatility === 'High' || market.plain.volatility === 'Elevated') : false
            const thin = headroom != null && headroom < 0.1
            const thick = headroom != null && headroom > 0.2
            const ethLight: 'good' | 'normal' | 'cautious' = (!volHi && !thin) ? 'good' : (volHi || thin) ? 'cautious' : 'normal'
            const ethAdd = ethLight === 'good'
              ? `A relatively good time to add${calmer != null ? ` — calmer than ${calmer}% of the last decade` : ''}${thick ? ', and QU!D is well over-backed' : ''}.`
              : ethLight === 'cautious'
              ? 'You can add, but swings are elevated — impermanent loss runs larger right now, so size accordingly.'
              : 'Normal conditions to add.'
            const ethRemove = ethLight === 'cautious'
              ? 'If you’d rather de-risk, it’s calmer to withdraw now than deeper into a stretch like this — and withdrawing mid-move locks in the impermanent loss.'
              : 'No pressure to withdraw — you’re earning safely; pulling out only forfeits yield (and any impermanent loss recovers as price retraces).'
            const btcActive = btcDelivered != null && btcDelivered > 0
            return (
              <div className="space-y-3">
                <TimingBlock asset="Ethereum" light={ethLight} add={ethAdd} remove={ethRemove} />
                <TimingBlock asset="Bitcoin"
                  light={btcDelivered == null ? 'normal' : btcActive ? 'good' : 'normal'}
                  note="Bitcoin liquidity earns from swap-out delivery fees, not market-making — it follows demand, not price swings."
                  add={btcDelivered == null
                    ? 'Demand tracking begins at launch — Bitcoin pays you when others swap dollars out to BTC.'
                    : btcActive ? 'Good time to add for fee income — swap-out demand is active.'
                    : 'Quiet right now — fewer fees to earn until swap-out demand picks up.'}
                  remove="Reclaim your locked Bitcoin anytime by closing your channel; the only reason to wait is demand still paying you fees." />
                <p className="text-[10px] opacity-40">
                  Relative guidance, not market timing — your principal stays yours to withdraw either way; this is about the conditions (swing risk), not predicting the price.
                </p>
              </div>
            )
          })()}
        </Section>
      )}

      {/* ── Headline protocol state ── */}
      <Section title="Protocol" right={
        <button onClick={() => void load()} className="text-xs opacity-60 hover:opacity-100">
          {loading ? 'loading…' : '↻ refresh'}
        </button>
      }>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <Stat label="TVL" value={usd(tvl)} />
          <Stat label="Blended yield" value={avgYield == null ? '—' : `${fmt(avgYield, 2)}%`} />
          <Stat label="Basket surplus" value={headroom == null ? '—' : `${fmt(headroom * 100, 0)}% above claims`} />
          <Stat label="ETH actively trading" value={theta == null ? '—' : `${fmt(theta * 100, 0)}%`} />
          <Stat label="ETH in Quid" value={rangeEth == null ? '—' : `${fmt(rangeEth, 3)} Ξ`} />
          <Stat label="BTC locked" value={btc == null ? '—' : `${fmt(btc, 4)} ₿`} />
          <Stat label="ETH-LP fees (cum.)" value={feesEth == null ? '—' : `${fmt(feesEth, 4)} Ξ`} />
          <Stat label="Stables (basket)" value={usd(compTotal)} />
        </div>
        <p className="mt-2 text-[11px] opacity-50">
          BTC-leg LP fees accrue as native sats (settled by the hop at channel close), not shown here.
        </p>
      </Section>

      {/* ── Composition of stables in Aux ── */}
      <Section title="Stable composition (Aux basket)">
        {comp.length === 0 ? <Empty /> : (
          <div className="space-y-1">
            {comp.filter(r => r.usd > 0 || compTotal === 0).map(r => {
              const pct = compTotal > 0 ? (r.usd / compTotal) * 100 : 0
              return (
                <div key={r.sym} className="flex items-center gap-2 text-xs">
                  <div className="w-16 opacity-70">{r.sym}</div>
                  <div className="flex-1 h-2 rounded bg-white/5 overflow-hidden">
                    <div className="h-full bg-white/30" style={{ width: `${pct}%` }} />
                  </div>
                  <div className="w-24 text-right font-mono">{usd(r.usd)}</div>
                  <div className="w-12 text-right opacity-60">{fmt(pct, 1)}%</div>
                </div>
              )
            })}
          </div>
        )}
      </Section>

      {/* ── Redeemable-when schedule — how sticky the basket dollars are ── */}
      {(redeemNow != null || schedule.length > 0) && (() => {
        const locked = schedule.reduce((a, r) => a + r.usd, 0)
        const total = (redeemNow ?? 0) + locked
        if (total <= 0) return null
        const stickyPct = (locked / total) * 100
        const rows = [{ off: 0, usd: redeemNow ?? 0 }, ...schedule]
        const max = Math.max(...rows.map(r => r.usd), 1)
        const when = (off: number) => off === 0 ? 'Now' : `in ~${off} mo`
        return (
          <Section title="Redeemable schedule" right={
            <span className="text-xs opacity-50">{fmt(stickyPct, 0)}% locked 1+ mo</span>
          }>
            <div className="space-y-1">
              {rows.map(r => {
                const pct = (r.usd / max) * 100
                const sharePct = total > 0 ? (r.usd / total) * 100 : 0
                return (
                  <div key={r.off} className="flex items-center gap-2 text-xs">
                    <div className={`w-16 ${r.off === 0 ? 'text-emerald-300/90' : 'opacity-70'}`}>{when(r.off)}</div>
                    <div className="flex-1 h-2 rounded bg-white/5 overflow-hidden">
                      <div className={`h-full ${r.off === 0 ? 'bg-emerald-400/60' : 'bg-white/30'}`} style={{ width: `${pct}%` }} />
                    </div>
                    <div className="w-24 text-right font-mono">{usd(r.usd)}</div>
                    <div className="w-12 text-right opacity-60">{fmt(sharePct, 0)}%</div>
                  </div>
                )
              })}
            </div>
            <p className="mt-2 text-[11px] opacity-50">
              QUI held to a future maturity can’t redeem until it unlocks — so a higher
              “locked 1+ mo” share means the basket’s dollars are stickier (less can leave at once).
            </p>
          </Section>
        )
      })()}

      {/* ── Net flow  +  Regime  (side by side — the LP's deposit-decision pair) ── */}
      <div className="grid md:grid-cols-2 gap-4">
        <Section title="Net flow (24h)">
          {!flow || flow.partial && flow.toBlock === 0 ? <Empty note="needs a deployed protocol + RPC log access" /> : (
            <div className="space-y-2 text-sm">
              <FlowRow label="Stables (net)" value={usd(flow.stablesNetUsd, 0)} pos={flow.stablesNetUsd >= 0} />
              <FlowRow label="ETH (net)" value={`${signed(flow.ethNet, 3)} Ξ`} pos={flow.ethNet >= 0} />
              <FlowRow label="BTC (net)" value={`${signed(flow.btcNetSats / 1e8, 4)} ₿`} pos={flow.btcNetSats >= 0} />
              {inventory && inventory.levelSats > 0 && (
                <div className="flex items-center justify-between pt-2 mt-1 border-t border-white/10">
                  <span className="opacity-70">Native BTC reservoir</span>
                  <span className="font-mono">
                    {(inventory.levelSats / 1e8).toFixed(3)} ₿
                    <span className={inventory.status === 'warn' ? 'text-rose-400' : inventory.status === 'watch' ? 'text-amber-400' : 'text-emerald-400'}>
                      {' '}{inventory.status === 'ok' ? 'stable' : `${(inventory.drainRatio * 100).toFixed(0)}% drain`}
                    </span>
                  </span>
                </div>
              )}
              {flow.stables.filter(s => Math.abs(s.netUsd) > 0).length > 0 && (
                <div className="pt-2 mt-1 border-t border-white/10 space-y-1">
                  <div className="text-[11px] opacity-50">by stable kind</div>
                  {flow.stables.filter(s => Math.abs(s.netUsd) > 0).map(s => (
                    <FlowRow key={s.symbol} label={s.symbol} value={usd(s.netUsd, 0)} pos={s.netUsd >= 0} small />
                  ))}
                </div>
              )}
              {flow.partial && <p className="text-[11px] opacity-40">partial — some logs unavailable on this RPC</p>}
            </div>
          )}
        </Section>

        <Section title="Market conditions">
          {!market || market.degraded ? <Empty note="market feed unavailable" /> : (
            <div className="space-y-2 text-sm">
              {/* prices the user understands */}
              {[market.eth, market.btc].map(a => (
                <div key={a.symbol} className="flex items-center justify-between">
                  <span className="opacity-70">{a.symbol === 'ETH' ? 'Ethereum' : 'Bitcoin'}</span>
                  <span className="font-mono">
                    {usd(a.price, 0)}
                    <span className={a.change24h >= 0 ? 'text-emerald-400' : 'text-rose-400'}> {signed(a.change24h, 1)}% 24h</span>
                  </span>
                </div>
              ))}
              {/* plain market read */}
              <div className="flex items-center justify-between pt-1">
                <span className="opacity-70">Market</span>
                <span className="font-medium">
                  {market.plain.phase}{market.plain.changeWatch && <span className="opacity-50"> (shifting)</span>}
                  <span className="opacity-50"> · {market.plain.volatility.toLowerCase()} swings</span>
                </span>
              </div>
              <div className="flex items-center justify-between text-xs">
                <span className="opacity-70">Relatively calmer</span>
                <span className="font-mono">{market.plain.calmerAsset === 'ETH' ? 'Ethereum' : 'Bitcoin'}</span>
              </div>
              {market.history && (
                <div className="flex items-center justify-between text-xs">
                  <span className="opacity-70">Vs the last {market.history.years}y</span>
                  <span className="font-mono">
                    {market.history.calmerThanPct >= 50
                      ? `calmer than ${market.history.calmerThanPct}% of days`
                      : `more volatile than ${100 - market.history.calmerThanPct}% of days`}
                  </span>
                </div>
              )}
              {/* INTERNAL vs EXTERNAL: pool price vs the market price (arb pressure) */}
              {poolEth != null && market.eth.price > 0 && (() => {
                const div = (poolEth - market.eth.price) / market.eth.price
                const tracking = Math.abs(div) < 0.005
                return (
                  <div className="flex items-center justify-between text-xs">
                    <span className="opacity-70">Pool vs market price</span>
                    <span className={`font-mono ${tracking ? 'text-emerald-400' : 'text-amber-400'}`}>
                      {tracking ? 'tracking' : `${signed(div * 100, 2)}% off`}
                    </span>
                  </div>
                )
              })()}
              {/* QU!D LP economics — R1: the LP's IL exposure is VOL-driven (lpHealth grades
                  it off σ). The on-chain headroom is QUI's backing, shown as context only — it
                  does NOT lower the LP's own impermanent loss. */}
              {(() => {
                // Swing risk = the LP's IL exposure, graded off σ (lpHealth.buffer).
                let label = market.plain.lp.buffer === 'comfortable' ? 'Calm'
                          : market.plain.lp.buffer === 'tight' ? 'Elevated' : 'Normal'
                let col = market.plain.lp.buffer === 'comfortable' ? 'text-emerald-400'
                        : market.plain.lp.buffer === 'tight' ? 'text-amber-400' : 'text-sky-400'
                // GRIND OVERRIDE: the low-vol trend is the ONE regime where the position
                // quietly drifts behind holding while σ reads "calm". It must not show green
                // here — surface the hold-don't-exit guidance instead.
                const grind = market.plain.lp.grind
                if (grind) { label = 'Quiet grind'; col = 'text-amber-400' }
                const real = headroom != null ? ` (QU!D ${fmt(headroom * 100, 0)}% over-backed)` : ''
                return (
                  <div className="pt-2 mt-1 border-t border-white/10">
                    <div className="flex items-center justify-between">
                      <span className="opacity-70">Providing liquidity</span>
                      <span className={`font-medium ${col}`}>{grind ? 'Hold — quiet grind' : `Swing risk: ${label}`}</span>
                    </div>
                    <p className="text-[11px] opacity-70 mt-1">{market.plain.lp.headline}</p>
                    <p className="text-[11px] opacity-50 mt-1">{market.plain.lp.detail}{real}</p>
                    {grind && (
                      <p className="text-[11px] text-amber-400/80 mt-1">
                        Tip: avoid withdrawing while the move is stretched — exiting mid-grind locks in the gap; it narrows again if price pulls back.
                      </p>
                    )}
                  </div>
                )
              })()}
            </div>
          )}
        </Section>
      </div>

      {/* ── Stress test — "what if BTC/ETH drops?" in plain language ── */}
      <Section title="Stress test" right={
        <span className="text-xs opacity-50">if ETH drops {stressDrop}%</span>
      }>
        <input type="range" min={5} max={60} step={5} value={stressDrop}
          onChange={e => setStressDrop(Number(e.target.value))}
          className="w-full accent-white/70 mb-1" />
        {(() => {
          const e = eventByDropMagnitude(stressDrop)
          return (
            <p className="text-[10px] opacity-50 mb-3 h-3">
              {e ? <>A move this size last looked like <strong>{e.label}</strong> ({e.date}) — {e.cause}</> : null}
            </p>
          )
        })()}
        {(() => {
          const k = 1 - stressDrop / 100
          const slice = ilPercent(k) * 100            // IL on the actively-LPing slice (LP bears it, R1)
          const onPosition = theta != null ? slice * theta : null  // ≈ IL on the whole position (rest just holds + yields)
          // R1: the LP bears this IL via the share price — it is NOT absorbed by the basket
          // surplus (that surplus backs QUI's seniority). The IL is impermanent: it recovers
          // as price retraces. QUI stays fully backed regardless (headroom = QUI over-collateral).
          const mild = onPosition != null ? onPosition < 3 : stressDrop <= 52
          const col = mild ? 'text-emerald-400' : 'text-amber-400'
          return (
            <div className="space-y-2 text-sm">
              <div className="flex items-center justify-between">
                <span className="opacity-70">Impermanent loss to you</span>
                <span className={`font-medium ${col}`}>{onPosition != null ? `~${fmt(onPosition, 1)}% of your position` : `${fmt(slice, 1)}% on the trading slice`}</span>
              </div>
              <FlowRow label="Loss on the actively-trading slice" value={`${fmt(slice, 1)}%`} pos={mild} />
              {theta != null && <FlowRow label="Your ETH actively trading (θ)" value={`${fmt(theta * 100, 0)}%`} pos />}
              {headroom != null && <FlowRow label="QUI backing (unaffected)" value={`${fmt(headroom * 100, 0)}% over-collateral`} pos />}
              <p className="text-[11px] opacity-60 pt-1 border-t border-white/10 mt-1">
                {mild
                  ? 'You bear this impermanent loss yourself — but it’s small (only the actively-trading slice is exposed; the rest just holds ETH and earns yield) and it recovers as price retraces. QUI holders are unaffected — the basket’s surplus keeps QUI fully backed.'
                  : 'A drop this size puts real impermanent loss on your position — still impermanent (it narrows as price retraces), and withdrawing mid-drop is what locks it in. QUI stays fully backed; this is your own price exposure, not QUI’s.'}
              </p>
              <p className="text-[10px] opacity-40">
                {market?.history
                  ? `ETH’s worst day in the last ${market.history.years}y: ${fmt(market.history.worstDayPct, 0)}%${market.history.worstDayEvent ? ` — ${market.history.worstDayEvent.label} (${market.history.worstDayEvent.date})` : ''}. The protocol is certified to hold a −52% day (which realized only −2.3% to LPs).`
                  : 'Certified to hold through Bitcoin/ETH’s worst-ever day (−52%, which realized only −2.3%).'}
              </p>
            </div>
          )
        })()}
      </Section>

      {/* ════════════════════════════════════════════════════════════════
          ADVANCED — the raw quant for LPs who want to dig. The same Kalman
          state estimates (σ/φ/β) that drive the plain read above, each with
          a one-line explanation so the jargon is decoded, not just dumped.
         ════════════════════════════════════════════════════════════════ */}
      {market && !market.degraded && (
        <div className="rounded-xl bg-white/5">
          <button onClick={() => setAdvanced(a => !a)}
            className="w-full flex items-center justify-between p-4 text-sm font-medium opacity-80 hover:opacity-100">
            <span>Advanced — the market model behind the read</span>
            <span className="opacity-60 text-xs">{advanced ? 'hide ▲' : 'show ▼'}</span>
          </button>
          {advanced && (
            <div className="px-4 pb-4 space-y-3 text-sm">
              <p className="text-[11px] opacity-50">
                These come from a Kalman filter run over 90 days of real ETH/BTC prices — current-state estimates,
                not long-run averages. They’re what we grade your swing risk (impermanent-loss exposure) from; you don’t need them to use QU!D.
              </p>
              <Adv label="Volatility (σ, annualized)"
                value={`ETH ${fmt(market.eth.sigmaAnnual * 100, 0)}% · BTC ${fmt(market.btc.sigmaAnnual * 100, 0)}%`}
                note={`How much prices are swinging right now. Higher σ means larger impermanent loss on the in-range slice.${market.eth.sigmaDivergent ? ' (ETH estimate unstable — markets transitioning.)' : ''}`} />
              <Adv label="Trend (φ, AR(1))"
                value={`ETH ${market.eth.phiLabel} · BTC ${market.btc.phiLabel}`}
                note="Whether moves tend to continue (trending), reverse (mean-reverting), or neither (random walk)." />
              <Adv label="ETH-vs-BTC beta (β)"
                value={`${fmt(market.betaEthBtc, 2)}×${market.betaDivergent ? ' (unstable)' : ''}`}
                note="How much ETH moves for a given BTC move — the factor exposure of the LP's primary asset." />
              <Adv label="Regime"
                value={`${market.regime} · ${market.quadrant}`}
                note="Synthesized from σ and φ: chop / oscillation / trend, mapped to the calm↔stressed quadrant." />
              <Adv label="In-range share (θ)"
                value={theta == null ? '—' : `${fmt(theta * 100, 0)}% of Quid ETH`}
                note="The slice of ETH actively market-making (short-gamma). The rest just earns yield. LVR risk scales with θ × σ²." />
              <Adv label="BTC dominance"
                value={market.dominanceBtc ? `${fmt(market.dominanceBtc, 1)}%` : '—'}
                note="BTC share of total crypto market cap — broad risk-on/off context." />

              {/* ── A-S re-tilted to the READER's benefit: lead with the plain
                     conclusion (you're not skewed against; the market-making cost
                     is small); the model/jargon lives in a collapsed <details>. ── */}
              {(() => {
                // Inventory cost priced at K·σ² (K_LVR=0.71, IL-CERT estimate — live K is
                // regime-dependent ≈1.8–8.4, so this is a conservative floor) — NOT an
                // assumed A-S risk-aversion γ. Same σ² structure, grounded coefficient.
                const sigma = market.eth.sigmaAnnual, mid = market.eth.price || 0
                const sens = avellanedaStoikov(mid, sigma, 0.1, K_LVR, 1 / 365)          // per-10% sensitivity
                const live = inv != null ? avellanedaStoikov(mid, sigma, inv, K_LVR, 1 / 365) : null
                const longEth = (inv ?? 0) > 0
                return (
                  <div className="pt-3 mt-2 border-t border-white/10 space-y-2">
                    <div className="text-xs font-medium text-emerald-300/90">No one here is quoting against you</div>
                    <p className="text-[11px] opacity-70">
                      On most venues a desk constantly shifts its prices <em>against</em> your order to offload its own
                      inventory — that hidden skew is how it earns from your flow. QU!D can’t do that: it quotes a
                      <strong> symmetric range</strong>, so you pay one <strong>flat, bounded cost</strong> (a small price
                      lag, capped near 0.5%) — the same whether your trade helps or hurts the pool.
                    </p>
                    {live != null && Math.abs(inv as number) > 0.005 ? (
                      <p className="text-[11px] opacity-70">
                        Right now the in-range book is <strong>{Math.abs((inv as number) * 100).toFixed(0)}% overweight {longEth ? 'ETH' : 'USD'}</strong>.
                        A desk would lean its center <strong>{longEth ? 'down' : 'up'} ~{fmt(Math.abs(live.skewBps), 1)} bps</strong> to
                        {longEth ? ' offload ETH' : ' buy ETH back'} at your expense. QU!D holds symmetric — it never skews against you; the only cost you bear is the small symmetric price lag.
                      </p>
                    ) : (
                      <p className="text-[11px] opacity-70">
                        {inv != null
                          ? 'The in-range book is currently balanced — no inventory to skew against you.'
                          : 'Live inventory reads on-chain after deploy; until then this shows the model, not a live position.'}
                      </p>
                    )}
                    <p className="text-[11px] opacity-70">
                      And your day-to-day market-making cost is small: the inventory cost this model prices is
                      only ~{fmt(sens.halfSpreadBps, 0)} bps over a day{avgYield != null ? <> — comfortably inside your ~{fmt(avgYield, 1)}% yield</> : ''}. (Your larger risk is directional impermanent loss in a sustained move, not this skew.)
                    </p>
                    <details className="text-[10px] opacity-45">
                      <summary className="cursor-pointer hover:opacity-70">show the market-making math (Avellaneda–Stoikov)</summary>
                      <p className="mt-1 leading-relaxed">
                        A concentrated range is a limit-order book, so it has an optimal center r = mid − q·K·σ²(T−t) and
                        width δ. At QU!D’s short rebalance horizon the skew is ~{fmt(Math.abs(sens.skewBps), 1)} bps per
                        10% inventory — negligible, which is why a symmetric range is near-optimal. The inventory cost is
                        priced at <strong>K=0.71</strong> (IL-CERT estimate; live K is regime-dependent ≈1.8–8.4, repack-on-exit ±2%
                        with the 30-min-TWAP guard — not an assumed risk-aversion γ). The (2/K)·ln(1+K/κ) profit term
                        needs an order-arrival rate κ of informed takers; the internal TWAP-priced pools have none, so it
                        has no counterparty here. 1-day horizon — analytics only, the protocol quotes symmetric.
                      </p>
                    </details>
                  </div>
                )
              })()}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ── small presentational helpers (local; page.tsx has its own) ──
function Section({ title, right, children }: { title: string; right?: React.ReactNode; children: React.ReactNode }) {
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
function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="p-2 rounded-lg bg-white/5">
      <div className="text-[11px] opacity-60">{label}</div>
      <div className="text-sm font-mono mt-0.5">{value}</div>
    </div>
  )
}
function FlowRow({ label, value, pos, small }: { label: string; value: string; pos: boolean; small?: boolean }) {
  return (
    <div className={`flex items-center justify-between ${small ? 'text-xs' : ''}`}>
      <span className="opacity-70">{label}</span>
      <span className={`font-mono ${pos ? 'text-emerald-400' : 'text-rose-400'}`}>{value}</span>
    </div>
  )
}
function TimingBlock({ asset, light, add, remove, note }:
  { asset: string; light: 'good' | 'normal' | 'cautious'; add: string; remove: string; note?: string }) {
  const dot = light === 'good' ? 'bg-emerald-400' : light === 'cautious' ? 'bg-amber-400' : 'bg-sky-400'
  return (
    <div className="rounded-lg bg-white/5 p-3">
      <div className="flex items-center gap-2 mb-1">
        <span className={`inline-block w-2 h-2 rounded-full ${dot}`} />
        <span className="text-sm font-medium">{asset}</span>
      </div>
      {note && <p className="text-[11px] opacity-50 mb-2">{note}</p>}
      <div className="space-y-1 text-[12px]">
        <div className="flex gap-2"><span className="opacity-50 w-20 shrink-0">Adding</span><span className="opacity-90">{add}</span></div>
        <div className="flex gap-2"><span className="opacity-50 w-20 shrink-0">Withdrawing</span><span className="opacity-90">{remove}</span></div>
      </div>
    </div>
  )
}
function Adv({ label, value, note }: { label: string; value: string; note: string }) {
  return (
    <div>
      <div className="flex items-center justify-between">
        <span className="opacity-70">{label}</span>
        <span className="font-mono text-xs">{value}</span>
      </div>
      <p className="text-[11px] opacity-45 mt-0.5">{note}</p>
    </div>
  )
}
