// ════════════════════════════════════════════════════════════════════════
//   INDEXER — backfill + live poll for QU!D protocol flow events.
//
//   WHAT WE INDEX (mirrors spa/src/lib/flow.ts exactly):
//     • ERC20 Transfer(from,to,value) on each stable + WETH, where `from` OR
//       `to` is in the protocol set {basket, aux, vogue}. into-set = inflow,
//       out-of-set = outflow (sign handled at aggregation time).
//     • BTCChannels ChannelOpened (BTC in) / ChannelClosed (BTC out), in sats.
//
//   REORG SAFETY (the WHY):
//     We only advance the durable cursor to head - CONFIRMATIONS, so a chain
//     re-org shallower than CONFIRMATIONS can never have moved a block we've
//     already "finalized". Each poll re-scans the unconfirmed tail FROM the
//     cursor and upserts on UNIQUE(tx_hash,log_index) — a re-org that replaces
//     a log re-INSERTs with a new block_hash and overwrites the stale row, and
//     a log that vanishes in the re-org is harmless because the cursor never
//     advanced past it (it gets re-scanned next poll on the new chain). We
//     store block_hash so a re-scan's overwrite is observable/correct.
//
//   RESILIENCE: getLogs is chunked into CHUNK_SIZE block ranges and every RPC
//   call is retried with backoff; a transient RPC failure backs off and retries
//   rather than crashing the loop.
// ════════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers'
import { Config, protocolAddrs, ZERO_ADDR } from './config'
import { Db, EventRow } from './db'

const TRANSFER_TOPIC = ethers.id('Transfer(address,address,uint256)')
// Canonical signatures — match flow.ts. The on-chain event names the sats arg
// `sats`/`satsReturned`, but the canonical type list (used for the topic hash
// and ABI-coder positional decode) is what matters, so we decode by position.
const CHANNEL_OPENED_TOPIC = ethers.id(
  'ChannelOpened(bytes32,address,uint256,bytes,bytes,bytes32,uint32,bytes32,uint64)')
const CHANNEL_CLOSED_TOPIC = ethers.id('ChannelClosed(bytes32,uint256)')

// ERC20 topic-encode an address (left-pad to 32 bytes), lowercased.
const padTopicAddr = (a: string) =>
  '0x' + a.toLowerCase().replace(/^0x/, '').padStart(64, '0')

const coder = ethers.AbiCoder.defaultAbiCoder()
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

export class Indexer {
  private provider: ethers.JsonRpcProvider
  private running = false
  private headBlock = 0
  // Block-timestamp cache so we don't re-fetch the same block header repeatedly.
  private tsCache = new Map<number, number>()

  constructor(private cfg: Config, private db: Db) {
    // staticNetwork avoids a per-call chainId round-trip against the RPC.
    this.provider = new ethers.JsonRpcProvider(cfg.rpcUrl, undefined, {
      staticNetwork: true,
    })
  }

  // Retry wrapper: exponential backoff, capped. Never throws past `tries` —
  // callers treat a final failure as "skip this tick" (the loop continues).
  private async withRetry<T>(label: string, fn: () => Promise<T>, tries = 5): Promise<T> {
    let delay = 500
    for (let i = 0; i < tries; i++) {
      try {
        return await fn()
      } catch (err) {
        const last = i === tries - 1
        console.warn(`[indexer] ${label} failed (attempt ${i + 1}/${tries})${last ? '' : `, retrying in ${delay}ms`}: ${(err as Error).message}`)
        if (last) throw err
        await sleep(delay)
        delay = Math.min(delay * 2, 15_000)
      }
    }
    // Unreachable (loop either returns or throws), but satisfies the type.
    throw new Error(`${label}: exhausted retries`)
  }

  private async blockTimestamp(block: number): Promise<number> {
    const cached = this.tsCache.get(block)
    if (cached !== undefined) return cached
    const b = await this.withRetry(`getBlock(${block})`, () => this.provider.getBlock(block))
    const ts = b ? Number(b.timestamp) : 0
    this.tsCache.set(block, ts)
    return ts
  }

  // The addresses whose Transfers we watch. WETH + stables. Each non-0x0 token.
  private watchedTokens(): { address: string; decimals: number }[] {
    const out: { address: string; decimals: number }[] = []
    for (const s of this.cfg.stables) {
      if (s.address && s.address !== ZERO_ADDR) out.push({ address: s.address, decimals: s.decimals })
    }
    if (this.cfg.contracts.weth && this.cfg.contracts.weth !== ZERO_ADDR) {
      out.push({ address: this.cfg.contracts.weth, decimals: 18 })
    }
    return out
  }

  // getLogs with both the address filter and a topics filter. We do two passes
  // per token (to-protocol, from-protocol) exactly like flow.ts so we never
  // pull the whole Transfer firehose.
  private async getLogs(filter: ethers.Filter): Promise<ethers.Log[]> {
    return this.withRetry('eth_getLogs', () => this.provider.getLogs(filter))
  }

  // Index one [from,to] block range (inclusive) for all watched assets +
  // channel events, upserting rows. Returns the count indexed.
  private async indexRange(fromBlock: number, toBlock: number): Promise<number> {
    if (toBlock < fromBlock) return 0
    const prot = protocolAddrs(this.cfg).map(padTopicAddr)
    const rows: EventRow[] = []

    // Collect the distinct block numbers we see so we batch timestamp lookups.
    const pushTransferLog = async (log: ethers.Log, decimals: number) => {
      // Transfer: topics = [sig, from(indexed), to(indexed)], data = value.
      const from = log.topics[1] ? '0x' + log.topics[1].slice(26) : ''
      const to   = log.topics[2] ? '0x' + log.topics[2].slice(26) : ''
      let value: bigint
      try {
        value = log.data && log.data !== '0x' ? BigInt(log.data) : 0n
      } catch { value = 0n }
      rows.push({
        block_number: log.blockNumber,
        block_hash: log.blockHash,
        tx_hash: log.transactionHash,
        log_index: log.index,
        kind: 'transfer',
        token: log.address.toLowerCase(),
        from_addr: from.toLowerCase(),
        to_addr: to.toLowerCase(),
        amount_raw: value.toString(),
        decimals,
        ts: await this.blockTimestamp(log.blockNumber),
      })
    }

    if (prot.length > 0) {
      for (const tok of this.watchedTokens()) {
        // to ∈ protocol  (inflow)
        const inLogs = await this.getLogs({
          address: tok.address, fromBlock, toBlock,
          topics: [TRANSFER_TOPIC, null, prot],
        })
        for (const l of inLogs) await pushTransferLog(l, tok.decimals)
        // from ∈ protocol (outflow)
        const outLogs = await this.getLogs({
          address: tok.address, fromBlock, toBlock,
          topics: [TRANSFER_TOPIC, prot, null],
        })
        for (const l of outLogs) await pushTransferLog(l, tok.decimals)
      }
    }

    // ── BTCChannels open/close → sats ──
    const ch = this.cfg.contracts.btcChannels
    if (ch && ch !== ZERO_ADDR) {
      const opened = await this.getLogs({
        address: ch, fromBlock, toBlock, topics: [CHANNEL_OPENED_TOPIC],
      })
      for (const l of opened) {
        // Non-indexed data layout: (uint256 sats, bytes lpPubkey, bytes hopPubkey,
        // bytes32 fundingTxId, uint32 fundingVout, bytes32 fundingBlockHash,
        // uint64 fundingBlockHeight). sats is the first non-indexed word.
        const sats = this.decodeFirstUint(l.data,
          ['uint256', 'bytes', 'bytes', 'bytes32', 'uint32', 'bytes32', 'uint64'])
        rows.push(this.channelRow(l, 'channel_open', sats, await this.blockTimestamp(l.blockNumber)))
      }
      const closed = await this.getLogs({
        address: ch, fromBlock, toBlock, topics: [CHANNEL_CLOSED_TOPIC],
      })
      for (const l of closed) {
        // Non-indexed data: (uint256 satsReturned).
        const sats = this.decodeFirstUint(l.data, ['uint256'])
        rows.push(this.channelRow(l, 'channel_close', sats, await this.blockTimestamp(l.blockNumber)))
      }
    }

    this.db.upsertEvents(rows)
    return rows.length
  }

  // Positionally decode the leading uint from an event's data blob. Returns 0n
  // on any decode failure (graceful, like flow.ts's try/catch fold).
  private decodeFirstUint(data: string, types: string[]): bigint {
    try {
      const decoded = coder.decode(types, data)
      return BigInt(decoded[0])
    } catch {
      return 0n
    }
  }

  private channelRow(log: ethers.Log, kind: 'channel_open' | 'channel_close', sats: bigint, ts: number): EventRow {
    return {
      block_number: log.blockNumber,
      block_hash: log.blockHash,
      tx_hash: log.transactionHash,
      log_index: log.index,
      kind,
      token: log.address.toLowerCase(),
      from_addr: '',
      to_addr: '',
      amount_raw: sats.toString(),
      decimals: 0,
      ts,
    }
  }

  // Backfill from the resume point up to head-CONFIRMATIONS, chunk by chunk.
  // Returns the last finalized block reached.
  async backfill(): Promise<number> {
    const head = await this.withRetry('blockNumber', () => this.provider.getBlockNumber())
    this.headBlock = head
    const finalHead = Math.max(head - this.cfg.confirmations, 0)

    // Resume from the stored cursor if present, else from START_BLOCK. We index
    // (cursor, finalHead]; the cursor row itself was already finalized.
    const stored = this.db.getCursor()
    const start = stored !== null ? stored + 1 : this.cfg.startBlock
    if (finalHead < start) {
      // Nothing new to finalize; keep the cursor where it is.
      if (stored === null) this.db.setCursor(finalHead)
      return this.db.getCursor() ?? finalHead
    }

    console.log(`[indexer] backfill ${start}..${finalHead} (head=${head}, conf=${this.cfg.confirmations})`)
    let cursor = start
    while (cursor <= finalHead) {
      const to = Math.min(cursor + this.cfg.chunkSize - 1, finalHead)
      const n = await this.indexRange(cursor, to)
      this.db.setCursor(to)            // advance only over finalized blocks
      console.log(`[indexer] backfilled ${cursor}..${to} (${n} events)`)
      cursor = to + 1
    }
    return finalHead
  }

  // One live poll: advance the finalized cursor and re-scan the confirmed tail.
  private async poll(): Promise<void> {
    const head = await this.withRetry('blockNumber', () => this.provider.getBlockNumber())
    this.headBlock = head
    const finalHead = Math.max(head - this.cfg.confirmations, 0)
    const cursor = this.db.getCursor() ?? Math.max(this.cfg.startBlock - 1, -1)

    if (finalHead <= cursor) return  // no newly-finalized blocks yet

    // Re-scan (cursor, finalHead]. Chunked for range-limited RPCs. Idempotent
    // upserts mean a re-org within this newly-finalized span self-corrects.
    let from = cursor + 1
    while (from <= finalHead) {
      const to = Math.min(from + this.cfg.chunkSize - 1, finalHead)
      const n = await this.indexRange(from, to)
      this.db.setCursor(to)
      if (n > 0) console.log(`[indexer] live ${from}..${to} (${n} events, head=${head})`)
      from = to + 1
    }
    // Evict stale block-timestamp cache entries to bound memory.
    if (this.tsCache.size > 50_000) this.tsCache.clear()
  }

  // Start the live poll loop. Resolves immediately after kicking off backfill;
  // the loop runs until stop(). Each tick is wrapped so a thrown RPC error
  // backs off and retries next tick instead of killing the process.
  async start(backfillOnly = false): Promise<void> {
    await this.backfill()
    if (backfillOnly) {
      console.log('[indexer] backfill-only complete')
      return
    }
    this.running = true
    const tick = async () => {
      if (!this.running) return
      try {
        await this.poll()
      } catch (err) {
        console.warn(`[indexer] poll tick failed, will retry next interval: ${(err as Error).message}`)
      }
      if (this.running) setTimeout(tick, this.cfg.pollMs)
    }
    console.log(`[indexer] entering live poll (every ${this.cfg.pollMs}ms)`)
    setTimeout(tick, this.cfg.pollMs)
  }

  stop(): void {
    this.running = false
  }

  // For the /health endpoint.
  get lastFinalizedBlock(): number {
    return this.db.getCursor() ?? 0
  }
  get currentHead(): number {
    return this.headBlock
  }
  // Fetch a fresh head for health, tolerating RPC hiccups.
  async fetchHead(): Promise<number> {
    try {
      this.headBlock = await this.provider.getBlockNumber()
    } catch { /* keep last known */ }
    return this.headBlock
  }
}
