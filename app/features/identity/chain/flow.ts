
// ════════════════════════════════════════════════════════════════════════
//   FLOW (subgraph-lite) — net inflow / outflow by asset and stable-kind.
//
//   The protocol emits no domain flow events (by design, this thread adds no
//   Solidity), so net flow is RECONSTRUCTED from ERC20 Transfer logs to/from
//   the protocol addresses:
//     • stable in  = Transfer(user → {basket,aux,vogue})   [mint / swap-in]
//     • stable out = Transfer({basket,aux,vogue} → user)   [redeem / swap-out]
//     • ETH flow   = WETH Transfer to/from the same set
//     • BTC flow   = BTCChannels ChannelOpened (in) / ChannelClosed (out), in sats
//
//   Best-effort + graceful: undeployed (0x0) or RPC range-limited → zeros.
//   PRODUCTION: if NEXT_PUBLIC_INDEXER_URL is set, the self-hosted indexer
//   (SPV/indexer/) serves this same NetFlow shape over unbounded history; we
//   prefer it and fall back to the bounded getLogs reconstruction below.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'
import { CONTRACTS, STABLES, INDEXER_URL } from './chains.ts'
import { getLogs, blockNumber, padAddr, TRANSFER_TOPIC, ZERO_ADDR, iface, readOne } from './eth.ts'

export interface StableFlow { symbol: string; netUsd: number; inUsd: number; outUsd: number }
export interface NetFlow {
  stables: StableFlow[]
  stablesNetUsd: number
  ethNet: number        // signed ETH (token units)
  btcNetSats: number    // signed sats
  fromBlock: number
  toBlock: number
  partial: boolean      // true if any getLogs call came back empty/limited
}

const PROTOCOL = () => [CONTRACTS.basket, CONTRACTS.aux, CONTRACTS.vogue]
  .filter(a => a && a !== ZERO_ADDR)

const sumTransfers = (logs: any[]): bigint =>
  logs.reduce((acc, l) => { try { return acc + BigInt(l.data) } catch { return acc } }, 0n)

// One asset's net token-unit flow into the protocol set over [from,to].
async function assetNet(token: string, decimals: number, from: number, to: number):
  Promise<{ inUnits: number; outUnits: number } | null> {
  if (!token || token === ZERO_ADDR) return null
  const prot = PROTOCOL().map(padAddr)
  if (prot.length === 0) return null
  const scale = (v: bigint) => Number(v) / 10 ** decimals
  const inLogs  = await getLogs({ address: token, fromBlock: from, toBlock: to, topics: [TRANSFER_TOPIC, null, prot] })
  const outLogs = await getLogs({ address: token, fromBlock: from, toBlock: to, topics: [TRANSFER_TOPIC, prot, null] })
  return { inUnits: scale(sumTransfers(inLogs)), outUnits: scale(sumTransfers(outLogs)) }
}

// Prefer the self-hosted indexer (unbounded history, DB-backed). Returns null
// if it isn't configured or is unreachable → caller falls back to getLogs.
async function fetchFromIndexer(windowHours: number): Promise<NetFlow | null> {
  if (!INDEXER_URL) return null
  try {
    const r = await fetch(`${INDEXER_URL}/flow?windowHours=${windowHours}`, { cache: 'no-store' })
    if (!r.ok) return null
    return await r.json() as NetFlow
  } catch { return null }
}

export async function fetchNetFlow(windowBlocks = 7200): Promise<NetFlow> {
  // ~12s/block ⇒ windowBlocks→hours for the indexer's time-window API.
  const viaIndexer = await fetchFromIndexer(Math.max(1, Math.round((windowBlocks * 12) / 3600)))
  if (viaIndexer) return viaIndexer

  const head = await blockNumber()
  const from = Math.max(head - windowBlocks, 0)
  const empty: NetFlow = {
    stables: [], stablesNetUsd: 0, ethNet: 0, btcNetSats: 0,
    fromBlock: from, toBlock: head, partial: head === 0,
  }
  if (head === 0 || PROTOCOL().length === 0) return empty

  let partial = false
  // ── Stables, by kind (≈ $1 each) ──
  const stables: StableFlow[] = []
  for (const s of STABLES) {
    const r = await assetNet(s.address, s.decimals, from, head)
    if (!r) { partial = true; continue }
    stables.push({ symbol: s.symbol, inUsd: r.inUnits, outUsd: r.outUnits, netUsd: r.inUnits - r.outUnits })
  }
  const stablesNetUsd = stables.reduce((a, s) => a + s.netUsd, 0)

  // ── ETH (WETH) ──
  let ethNet = 0
  const weth = await assetNet(CONTRACTS.weth, 18, from, head)
  if (weth) ethNet = weth.inUnits - weth.outUnits; else partial = true

  // ── BTC (channel open/close, in sats) ──
  let btcNetSats = 0
  if (CONTRACTS.btcChannels && CONTRACTS.btcChannels !== ZERO_ADDR) {
    const opened = await getLogs({ address: CONTRACTS.btcChannels, fromBlock: from, toBlock: head,
      topics: [ethers.id('ChannelOpened(bytes32,address,address,uint256,bytes,bytes,bytes32,uint32,bytes32,uint64)')] })
    const closed = await getLogs({ address: CONTRACTS.btcChannels, fromBlock: from, toBlock: head,
      topics: [ethers.id('ChannelClosed(bytes32,uint256)')] })
    // Decode sats by POSITION (first non-indexed word), not by arg name: the
    // deployed BTCChannels names these `sats` / `satsReturned`, so a name lookup
    // (`args.totalSats`) reads undefined → silently 0. Position is name-robust.
    const satsOf = (logs: any[]) => logs.reduce((acc, l) => {
      try {
        const p = iface.parseLog({ topics: l.topics, data: l.data })
        if (!p) return acc
        const sats = p.args.find((a: any) => typeof a === 'bigint') ?? 0n
        return acc + BigInt(sats)
      } catch { return acc }
    }, 0n)
    btcNetSats = Number(satsOf(opened) - satsOf(closed))
  }

  return { stables, stablesNetUsd, ethNet, btcNetSats, fromBlock: from, toBlock: head, partial }
}

// ════════════════════════════════════════════════════════════════════════
//   NATIVE-BTC INVENTORY LEVEL + DRAIN EARLY-WARNING — "the well" §6a instrument.
//
//   The read-only signal that tells us WHEN the (deferred) skew/MM/rebalancer well
//   is actually needed: how much native BTC sits in the pool (the VIRTUAL reservoir
//   = LP channel BTC) and how fast it's leaving. Reuses the net flow above + ONE
//   `totalSatsLocked` view read — NO Solidity, NO new on-chain state (the reservoir
//   is the channels themselves). Non-foreclosing lead-time signal per the spec.
// ════════════════════════════════════════════════════════════════════════

export interface BtcInventory {
  levelSats: number     // native BTC locked across all channels — the virtual reservoir
  netFlowSats: number   // signed net channel flow over the window (opens − closes)
  drainRatio: number    // net OUTFLOW as a fraction of the level this window (>0 ⇒ draining)
  status: 'ok' | 'watch' | 'warn'   // early-warning band → "when to build the well"
}

export async function fetchBtcInventory(windowBlocks = 7200): Promise<BtcInventory> {
  const [flow, level] = await Promise.all([
    fetchNetFlow(windowBlocks),
    readOne(CONTRACTS.btcChannels, 'totalSatsLocked'), // uint sats; null if undeployed/no-wallet
  ])
  const levelSats = level != null ? Number(level) : 0
  const netFlowSats = flow.btcNetSats
  // How much of the CURRENT inventory drained this window (net outflow only). A rising
  // ratio = the pool is trending toward empty faster than LPs replenish it — the exact
  // early-warning that says the well (skew to summon MM BTC) has become worth turning on.
  const drainRatio = levelSats > 0 ? Math.max(0, -netFlowSats) / levelSats : 0
  const status: BtcInventory['status'] =
    drainRatio >= 0.25 ? 'warn' : drainRatio >= 0.1 ? 'watch' : 'ok'
  return { levelSats, netFlowSats, drainRatio, status }
}
