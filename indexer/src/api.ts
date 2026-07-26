// ════════════════════════════════════════════════════════════════════════
//   API — node:http server exposing the dashboard's data.
//
//   GET /flow?windowHours=24
//     Returns a NetFlow JSON object SHAPE-COMPATIBLE with spa/src/lib/flow.ts's
//     `NetFlow` interface, so the SPA can swap its getLogs reconstruction for a
//     fetch() with a near-trivial change. Aggregated from the SQLite `events`
//     table over the requested time window.
//
//   GET /health
//     { ok, lastBlock, headBlock, behind } — lastBlock is the finalized cursor.
//
//   CORS is permissive (access-control-allow-origin: *) so the browser SPA can
//   fetch cross-origin from the indexer.
// ════════════════════════════════════════════════════════════════════════

import http from 'node:http'
import { URL } from 'node:url'
import { Config, ZERO_ADDR } from './config'
import { Db } from './db'
import { Indexer } from './indexer'

// ── NetFlow shapes — verbatim from spa/src/lib/flow.ts ──
export interface StableFlow { symbol: string; netUsd: number; inUsd: number; outUsd: number }
export interface NetFlow {
  stables: StableFlow[]
  stablesNetUsd: number
  ethNet: number        // signed ETH (token units)
  btcNetSats: number    // signed sats
  fromBlock: number
  toBlock: number
  partial: boolean      // true if the requested window isn't fully covered yet
}

// Scale a uint256 decimal string by `decimals` into a float (token units / USD
// at par). Matches flow.ts's `Number(v) / 10 ** decimals`.
const scale = (raw: bigint, decimals: number): number => Number(raw) / 10 ** decimals

// Compute NetFlow over a block window (fromExclusive, toInclusive].
function computeNetFlow(
  cfg: Config,
  db: Db,
  fromExclusive: number,
  toInclusive: number,
  partial: boolean,
): NetFlow {
  const prot = new Set(
    [cfg.contracts.basket, cfg.contracts.aux, cfg.contracts.vogue]
      .map(a => a.toLowerCase())
      .filter(a => a && a !== ZERO_ADDR),
  )

  // Per-token signed sums (BigInt for uint256 safety). into = to ∈ protocol
  // (inflow), out = from ∈ protocol (outflow). Exactly flow.ts's two passes,
  // re-derived from stored rows.
  const inByToken = new Map<string, bigint>()
  const outByToken = new Map<string, bigint>()
  for (const r of db.transfersInBlockWindow(fromExclusive, toInclusive)) {
    let v: bigint
    try { v = BigInt(r.amount_raw) } catch { v = 0n }
    if (prot.has(r.to_addr)) inByToken.set(r.token, (inByToken.get(r.token) ?? 0n) + v)
    if (prot.has(r.from_addr)) outByToken.set(r.token, (outByToken.get(r.token) ?? 0n) + v)
  }

  // ── Stables (≈ $1 each) ──
  const stables: StableFlow[] = []
  for (const s of cfg.stables) {
    if (!s.address || s.address === ZERO_ADDR) continue
    const key = s.address.toLowerCase()
    const inUsd = scale(inByToken.get(key) ?? 0n, s.decimals)
    const outUsd = scale(outByToken.get(key) ?? 0n, s.decimals)
    stables.push({ symbol: s.symbol, inUsd, outUsd, netUsd: inUsd - outUsd })
  }
  const stablesNetUsd = stables.reduce((a, s) => a + s.netUsd, 0)

  // ── ETH (WETH) ──
  let ethNet = 0
  const weth = cfg.contracts.weth
  if (weth && weth !== ZERO_ADDR) {
    const key = weth.toLowerCase()
    ethNet = scale(inByToken.get(key) ?? 0n, 18) - scale(outByToken.get(key) ?? 0n, 18)
  }

  // ── BTC (channel open in / close out, in sats) ──
  let openSats = 0n
  let closeSats = 0n
  for (const e of db.channelEventsInBlockWindow(fromExclusive, toInclusive)) {
    let v: bigint
    try { v = BigInt(e.amount_raw) } catch { v = 0n }
    if (e.kind === 'channel_open') openSats += v
    else if (e.kind === 'channel_close') closeSats += v
  }
  const btcNetSats = Number(openSats - closeSats)

  return {
    stables,
    stablesNetUsd,
    ethNet,
    btcNetSats,
    // fromBlock is the first block *included* in the window (cursor's exclusive
    // lower bound + 1), to mirror flow.ts's inclusive [fromBlock, toBlock].
    fromBlock: fromExclusive + 1,
    toBlock: toInclusive,
    partial,
  }
}

// Turn ?windowHours into a (fromExclusive, toInclusive] block window using the
// finalized cursor as the upper bound and stored block timestamps for the lower
// bound. partial = true if we don't yet have data back to the window start
// (mirrors flow.ts's "best-effort / range-limited → partial" semantics).
function windowToBlocks(
  cfg: Config,
  db: Db,
  windowHours: number,
): { fromExclusive: number; toInclusive: number; partial: boolean } {
  const toInclusive = db.getCursor() ?? Math.max(cfg.startBlock - 1, -1)
  const nowTs = Math.floor(Date.now() / 1000)
  const cutoffTs = nowTs - Math.max(windowHours, 0) * 3600

  // First indexed block at or after the cutoff is the window's lower edge.
  const firstAfter = db.firstBlockAtOrAfterTs(cutoffTs)
  const earliest = db.minBlock()

  // partial when our earliest indexed block is itself at/after the cutoff —
  // i.e. backfill isn't deep enough to cover the full requested window yet, so
  // the window's true lower edge lies before any data we hold.
  const partial =
    toInclusive < 0 ||         // nothing finalized
    earliest === null ||       // empty DB
    firstAfter === earliest    // first in-window block IS our earliest row

  // fromExclusive is one below the first in-window block. If no row is at/after
  // the cutoff (no activity in window), use toInclusive so the window is empty.
  const fromExclusive = firstAfter !== null ? firstAfter - 1 : toInclusive

  return { fromExclusive, toInclusive, partial }
}

export function startApi(cfg: Config, db: Db, indexer: Indexer): http.Server {
  const server = http.createServer(async (req, res) => {
    // CORS — permissive so the browser SPA can fetch cross-origin.
    res.setHeader('access-control-allow-origin', '*')
    res.setHeader('access-control-allow-methods', 'GET, OPTIONS')
    res.setHeader('access-control-allow-headers', 'content-type')
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return }

    const sendJson = (code: number, body: unknown) => {
      res.writeHead(code, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }

    try {
      const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)

      if (url.pathname === '/flow') {
        const raw = url.searchParams.get('windowHours')
        const windowHours = raw !== null && Number.isFinite(Number(raw)) ? Number(raw) : 24
        const { fromExclusive, toInclusive, partial } = windowToBlocks(cfg, db, windowHours)
        const flow = computeNetFlow(cfg, db, fromExclusive, toInclusive, partial)
        return sendJson(200, flow)
      }

      if (url.pathname === '/health') {
        const headBlock = await indexer.fetchHead()
        const lastBlock = indexer.lastFinalizedBlock
        const behind = headBlock > 0 ? Math.max(headBlock - lastBlock, 0) : 0
        return sendJson(200, { ok: true, lastBlock, headBlock, behind })
      }

      return sendJson(404, { error: 'not found', paths: ['/flow', '/health'] })
    } catch (err) {
      return sendJson(500, { error: (err as Error).message })
    }
  })

  server.listen(cfg.port, () => {
    console.log(`[api] listening on :${cfg.port}  (GET /flow?windowHours=24, GET /health)`)
  })
  return server
}
